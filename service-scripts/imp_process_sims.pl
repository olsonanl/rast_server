
#
# Postprocess computed sims. 
#
# The sim compute happens in a sims workdir. The timelogic sim submission results in the
# creation of two files, a task list and a job map.
#
# The task.list maps a task number to input and output files, and parameters.
#
# The job map maps an input filename to a timelogic job number.
#
# The task of this script is to identify the output files for all tasks, to
# ensure they exist and to do a sanity check that the majority of the input
# sequences are accounted for in the generated data. Once the sanity
# checking is complete, standard SEED postprocessing is performed and a
# flipped sims file is created.
#

use strict;

use Data::Dumper;
use FIG;
use FIG_Config;
use File::Basename;
use File::Copy;
use ImportJob;
use GenomeMeta;
use JobStage;

my $hits_max = 300;

@ARGV == 2 or die "Usage: $0 job-dir sim-dir\n";

my $jobdir = shift;
my $simdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'process_sims', $jobdir);

$stage or die "$0: Could not create job object";
my $job = $stage->job();

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

#
# Load job map.
#

open(JM, "<$simdir/job.map") or $stage->fatal("Cannot open jobmap $simdir/job.map: $!");

my %jobmap;
while (<JM>)
{
    chomp;
    my($file, $tl_file) = split(/\t/);
    $jobmap{$file} = $tl_file;
}
close(JM);

open(TL, "<$simdir/task.list") or $stage->fatal("Cannot open task list $simdir/task.list: $!");

my @tasks;
while (<TL>)
{
    chomp;
    my($id, $in, $nr, $args, $out, $err) = split(/\t/);

    my $simfile = $jobmap{basename($in)};
    if (!$simfile)
    {
	$stage->fatal("Cannot map input file $in\n");
    }

    $simfile = "$simdir/sims/$simfile.out";
    if (! -f $simfile)
    {
	$stage->fatal("Cannot open mapped input file $simfile (for $in)");
    }

    push(@tasks, [$id, $in, $nr, $args, $out, $err, $simfile]);
}

#
# Process sims into $simdir/processed
#

my $procdir = "$simdir/processed";
if (-d $procdir)
{
    rename($procdir, "$procdir." . time);
}
mkdir($procdir) or $stage->fatal("cannot mkdir $procdir: $!");

my $syn = "$jobdir/peg.synonyms";
my $nr = "$jobdir/nr";

my $prefix = "sims." . $job->id();

my $pipeline = "reformat_timelogic_sims | ";
$pipeline .= "reduce_sims $syn $hits_max | reformat_sims $nr | split_sims $procdir $prefix";

open(PIPE, "|$pipeline") or $stage->fatal("cannot run pipeline $pipeline: $!");

for my $task (@tasks)
{
    my($id, $in, $nr, $args, $out, $err, $simfile) = @$task;

    open(F, "<$simfile") or $stage->fatal("Cannot open $simfile: $!");
    copy(\*F, \*PIPE);
    close(F);
}
close(PIPE) or $stage->fatal("Error closing pipeline $pipeline: \$!=$! \$?=$?");

$stage->log("completed");
$stage->set_running("no");
$stage->set_status("complete");
