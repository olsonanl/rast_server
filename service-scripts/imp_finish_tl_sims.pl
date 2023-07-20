#
# Wrap up the sims computation.
#
# Cat all of the processed sims files in sims.job/sims.proc/* into a pipe
# to split_sims, writing output to sims.job/sims.split. The prefix given
# to split_sims is the sims.jobnum.
#
# Invoke flip_sims to create the flipped sims file.
#
# Invoke update_sims2 to merge the new sims with the previous sims
# (symlinked via prev_sims).
#
# Compute BBHs against the new sims.
#

use strict;
use FIG;
use FIG_Config;
use File::Copy;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;

#
# Set this so flip_sims can use it.
#
$ENV{SORT_ARGS} = "-S 10G -T $FIG_Config::temp";

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $max_hits = 300;

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'finish_tl_sims', $jobdir);

$stage or die "$0: Could not create job object";

my $job = $stage->job;
my $job_id = $job->id;

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

my $simdir = "$jobdir/sims.job";

my $procdir = "$simdir/sims.proc";

#
# Validate the timelogic sims - this script ensures that for every id that shows
# up in the input files, the corresponding raw sims file contains that id as well.
#
# This works in the TL case because it will generate a row of output for every input,
# even if the input does not match anything. NCBI blast does not do that.
#

$stage->run_process('validate_tl_sims',
		    "$FIG_Config::bin/validate_tl_sims",
		    $jobdir);

#
# Walk the task list, pushing the sims files into the split_sims pipeline.
#

my $sims_out = "$simdir/sims.split";
my $sims_prefix = "sims.$job_id";

open(SPLIT, "| $FIG_Config::bin/split_sims $sims_out $sims_prefix") or $stage->fatal("error starting $FIG_Config::bin/split_sims $sims_out $sims_prefix: $!");

open(TASK, "<$simdir/task.list") or $stage->fatal("Cannot open task list $simdir/task.list: $!");

while (<TASK>)
{
    chomp;
    my($id, $in, $nr, $args, $out, $err) = split(/\t/);

    my $sims = "$procdir/proc.$id";

    if (-s $sims > 0)
    {
	print "Process $sims\n";
	open(S, "<$sims") or $stage->fatal("Cannot open sims file $sims: $!");

	copy(\*S, \*SPLIT) or $stage->fatal("Error copying $sims to split pipeline: $!");

	close(S);
    }
}
if (!close(SPLIT))
{
    if ($!)
    {
	$stage->fatal("error closing SPLIT: $!");
    }
    else
    {
	$stage->fatal("error closing SPLIT: $?");
    }
    
}

print "Flip sims\n";
$stage->run_process("flip_sims",
		    "$FIG_Config::bin/flip_sims",
		    $sims_out,
		    "$simdir/sims.flipped");

print "Update\n";

my $pegsyn = "$jobdir/peg.synonyms.reduce_sims_index.btree";
if (! -f $pegsyn)
{
    $pegsyn = "$jobdir/peg.synonyms";
}

$stage->run_process("update_sims2",
		    "$FIG_Config::bin/update_sims2",
		    $pegsyn,
		    $max_hits,
		    "$jobdir/prev_sims",
		    "$jobdir/Sims.$job_id",
		    "$simdir/sims.flipped",
		    "$jobdir/ids.deleted");

print "Compute bbhs\n";

#
# And copy the new sims into place.
#

$stage->run_process("copy_sims",
		    "/bin/cp",
		    <$sims_out/*>,
		    "$jobdir/Sims.$job_id");

#
# Determine the list of complete genomes, given the list of NR sources.
#

open(COMP, ">$jobdir/complete.genomes") or die "Cannot write $jobdir/complete.genomes: $!";
if (open(NRSRC, "<$jobdir/nr.sources"))
{
    while (<NRSRC>)
    {
	chomp;
	if (m,^((.*)/rp/(\d+\.\d+))/Features/peg/fasta$,)
	{
	    my $dir = $1;
	    my $genome_jobdir = $2;
	    my $genome = $3;

	    #
	    # If it is a RAST organism, run assess_completeness.
	    #
	    if ($dir =~ m,48-hour,)
	    {
		#
		# If it is marked for NMPDR inclusion, assume complete for the purposes
		# of BBH computation.
		#
		my $jmeta = GenomeMeta->new(undef, "$genome_jobdir/meta.xml", readonly => 1);
		if ($jmeta->get_metadata("submit.nmpdr"))
		{
		    print COMP "$genome\n";
		}
		else
		{
		    my $rc = system("$FIG_Config::bin/assess_completeness", $dir);
		    if (-f "$dir/PROBABLY_COMPLETE")
		    {
			print COMP "$genome\n";
		    }
		}
	    }
	    elsif (-f "$dir/COMPLETE")
	    {
		print COMP "$genome\n";
	    }
	}
    }
    close(NRSRC);

    close(COMP);

    $stage->run_process('all_bbhs',
			"$FIG_Config::bin/all_bbhs",
			"-pegsyn", "$jobdir/peg.synonyms",
			"-sims", "$jobdir/Sims.$job_id",
			"$jobdir/complete.genomes",
			"$jobdir/BBHs");
}
else
{
    warn "Hm, can't open NR sources $jobdir/nr.sources: $!";
}

$stage->log("completed");
$stage->set_status("complete");
$stage->set_running("no");

