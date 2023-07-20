
#
# Prepare for sims computation.
#
# Compute the differences in the new and old NR, and pull the fasta data.
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'prepare_sims', $jobdir);

$stage or die "$0: Could not create job object";

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

#
# First compute the changes in ids.
#

my @cmd = ("$FIG_Config::bin/compute_changed_ids_for_nrs",
	   "$jobdir/prev_nr",
	   "$jobdir/prev_syn",
	   "$jobdir/nr",
	   "$jobdir/ids.added",
	   "$jobdir/ids.changed",
	   "$jobdir/ids.deleted");
$stage->run_process("compute_changed_ids_for_nrs", @cmd);

my $cmd = "$FIG_Config::bin/pull_fasta_entries $jobdir/nr < $jobdir/ids.added > $jobdir/seqs.added";

$stage->log("run $cmd");
my $rc = system($cmd);
if ($rc != 0)
{
    $stage->fatal("cmd failed with rc=$rc");
}

$stage->log("cmd completed");


$stage->log("completed");
$stage->set_running("no");
$stage->set_status("complete");

