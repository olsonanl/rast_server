#
# Merge the processed sims with the last batch of computed sims.
#
# processed sims dir is first flipped into sims.flip
# update_sims2 then used to merge the flipped and delete ids
# that are to be deleted. 
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

my $stage = new JobStage('ImportJob', 'merge_sims', $jobdir);

$stage or die "$0: Could not create job object";
my $job = $stage->job();

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

#
# Set TMPDIR to somewhere with lots of space.
#
$ENV{TMPDIR} = $FIG_Config::temp;

my $flipped = "$simdir/sim.flips";

my @cmd = ("$FIG_Config::bin/flip_sims", "$simdir/processed", $flipped);
$stage->log("Running @cmd");
my $rc = system(@cmd);

if ($rc == -1)
{
    $stage->fatal("Flip cmd @cmd failed: $!");
}
elsif ($rc != 0)
{
    $stage->fatal("Flip cmd @cmd failed: rc=$rc");
}

my $merge_dir= "$simdir/merged";
if (-d $merge_dir)
{
    rename($merge_dir, "$merge_dir." . time);
}

@cmd = ("$FIG_Config::bin/update_sims2",
	"$jobdir/peg.synonyms", $hits_max, "$simdir/processed", "$simdir/merged",
	$flipped, "$jobdir/ids.deleted");
$stage->log("Running @cmd");
my $rc = system(@cmd);

if ($rc == -1)
{
    $stage->fatal("Merge cmd @cmd failed: $!");
}
elsif ($rc != 0)
{
    $stage->fatal("Merge cmd @cmd failed: rc=$rc");
}

$stage->log("completed");
$stage->set_running("no");
$stage->set_status("complete");
