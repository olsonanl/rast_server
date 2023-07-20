#
# Submit a timelogic sims job. This executes on the timelogic after having been
# submitted through sge.
#
# We createn a hash in the sims job dir that is a helper for looking
# up the various pieces of data. These include
#
# 'jobid',taskid: 	timelogic job identifier
# 'status',taskid:	current job status (unknown, queued, running, done, error).
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;
use DB_File;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $max_hits = 300;

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'submit_tl_sims', $jobdir);

$stage or die "$0: Could not create job object";

my $job = $stage->job;

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

my $simdir = "$jobdir/sims.job";
&FIG::verify_dir($simdir);

my $rawdir = "$simdir/sims.raw";
&FIG::verify_dir($rawdir);

my $procdir = "$simdir/sims.proc";
&FIG::verify_dir($procdir);

my $status_file = "$simdir/status.btree";
my %status;
my $status_tie;
if (-f $status_file)
{
    $status_tie = tie %status, 'DB_File', $status_file, O_RDWR, 0, $DB_BTREE;
    $status_tie or $stage->fatal("Cannot open status file $status_file: $!");
}
else
{
    $status_tie = tie %status, 'DB_File', $status_file, O_RDWR | O_CREAT, 0777, $DB_BTREE;
    $status_tie or $stage->fatal("Cannot create status file $status_file: $!");
}

#
# Reuse rp_chunk_sims to split the fasta into chunks and create the task.list to keep track of them
#

my $template = "tera-blastp-tabular";
my $target = "nr-import-" . $job->id;
my $chunk_size = 1_000_000;

#
# We first need to ensure that the NR is in place as a target.
#

my $target_ok;
my $fh = $stage->open_file("/decypher/cli/bin/dc_target |");
while (<$fh>)
{
    chomp;
    if ($_ eq $target)
    {
	print "$target is already created\n";
	$target_ok++;
	last;
    }
}
close($fh);

if (!$target_ok)
{
    $stage->run_process("dc_new_target_rt", "/decypher/cli/bin/dc_new_target_rt",
			-priority => '5',
			-template => 'format_aa_into_aa',
			-source => "$jobdir/nr",
			-targ => $target);
    my $fh = $stage->open_file("/decypher/cli/bin/dc_target |");
    while (<$fh>)
    {
	chomp;
	if ($_ eq $target)
	{
	    print "$target created successfully\n";
	    $target_ok++;
	    last;
	}
    }
    close($fh);
}

if (!$target_ok)
{
    $stage->fatal("Target $target not found, and attempt to create it failed.");
}

$stage->run_process("rp_chunk_sims", "$FIG_Config::bin/rp_chunk_sims",
		    "-size", $chunk_size,
		    "$jobdir/seqs.added", "$jobdir/nr", "$jobdir/peg.synonyms", $simdir);

#
# Walk the task list and submit each job.
#

my $tfh = $stage->open_file("$simdir/task.list");

while (my $ent = <$tfh>)
{
    chomp $ent;
    my($id, $in, $nr, $args, $out, $err) = split(/\t/, $ent);

    my $tl_id;
    my $fh = $stage->open_file("dc_template -priority 5 -template $template -query $in -targ $target |");
    while (<$fh>)
    {
	print $_;
	if (/OK.*\s+(\S+)/)
	{
	    $tl_id = $1;
	}
    }
    close($fh);

    if (defined($tl_id))
    {
	$status{'status', $id}  = 'queued';
	$status{'jobid', $id} = $tl_id;
	print "Mapped task $id to tl id $tl_id\n";
    }
    else
    {
	warn "Could not find TL id for task $id\n";
    }
}
close($tfh);

$stage->log("completed");
$stage->set_running("no");
$stage->set_status("complete");


