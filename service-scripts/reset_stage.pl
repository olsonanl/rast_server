#
# Reset the given stage of the job, and set the job to active
# (remove ERROR, touch ACTIVE).
#

use strict;
use Job48;

my $usage = "reset_stage jobdir stage";

@ARGV == 2 or die $usage;

my $jobdir = shift;
my $stage = shift;

my $job = Job48->new($jobdir);

if ($job->to_be_deleted()) {
    print "Job marked for deletion, not changing\n";
    exit;
}

if ($job->active()) {
    print "Job is still active, not changing\n";
    exit;
}

my $meta    = $job->meta();
my $jobddir = $job->dir();
my $status  = $meta->get_metadata("status.$stage");

if ($status ne 'error') {
    print "Job stage $stage is not in error, not changing\n";
    exit(1);
}

$meta->set_metadata("status.$stage", "not_started");
$meta->set_metadata("$stage.running", "no");


my $cfile = "$jobdir/CANCEL";
if (-f $cfile) {
    print "Clearing CANCEL file.\n";
    unlink($cfile) || die "Could not remove CANCEL file \'$cfile\'";
}


my $efile = "$jobdir/ERROR";
if (-f $efile) {
    my $etext = `cat $efile`;
    print "Clearing ERROR file: $etext\n";
    unlink($efile) || die "Could not remove ERROR file \'$efile\'";
}

open(TMP, ">$jobdir/ACTIVE") or die "cannot touch $jobdir/ACTIVE: $!";
close(TMP);

