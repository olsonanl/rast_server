
#
# Compute sims for the NR build.
#
# This 
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

my $stage = new JobStage('ImportJob', 'build_nr', $jobdir);

$stage or die "$0: Could not create job object";

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

my @cmd = ("$FIG_Config::bin/build_nr",
	   "-emit-singleton-sets",
	   "-skip-duplicates",
	   "$jobdir/nr.sources",
	   "$jobdir/prev_nr",
	   "$jobdir/prev_syn",
	   "$jobdir/nr",
	   "$jobdir/peg.synonyms");

$stage->log("Run @cmd");

my $pid = open(P, "-|");
$stage->log("created child $pid");

my $errfh = $stage->open_error_file("build_nr", "w");
$errfh->autoflush(1);

if ($pid == 0)
{
    open(STDERR, ">&STDOUT");
    exec(@cmd);
    die "Cmd failed: $!\n";
}


while (<P>)
{
    print "Rec $_\n";
    print $errfh $_;
}

if (!close(P))
{
    my $msg = "error closing build_nr pipe: \$?=$? \$!=$!";
    print $errfh "$msg\n";
    close($errfh);
    print "$msg\n";
    $stage->fatal($msg);
}

close($errfh);


$stage->log("completed");
$stage->set_running("no");
$stage->set_status("complete");

