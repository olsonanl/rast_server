#
# Reset a job that has failed rapid_propagation.
#
# Need to ensure that status.rp is "error". We aren't handling anything more general at the moment.
#
# We zero out any status.rp.* values, set status.rp to not_started, rp.running to no.
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Carp 'croak';
use POSIX;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift @ARGV;
(-d $jobdir) || die "$0: job dir $jobdir does not exist\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
($genome =~ /^\d+\.\d+/o) || die "$0: Cannnot find genome ID for jobdir $jobdir\n";


my $meta = GenomeMeta->new($genome, "$jobdir/meta.xml");
if ($meta->get_metadata("status.rp") ne "error") {
    die "Job is not in RP error state\n";
}


if (-f "$jobdir/ACTIVE") {
    die "Job is still marked ACTIVE\n";
}


my $found_rp = 0;
foreach my $key ($meta->get_metadata_keys()) {
    if ($key =~ /^status.rp$/) { $found_rp = 1; }
    if (($key =~ /^status\.(\S+)$/) && $found_rp) {
	my $stage  = $1;
	my $oldval = $meta->get_metadata($key);
	print "Old value of $key: $oldval\n";
	if ($key =~ /^status\.rp\.\S+$/) {
	    $meta->set_metadata($key, 0);
	}
	else {
	    $meta->set_metadata("status\.$stage",  "not_started");
	    $meta->set_metadata("$stage\.running", "no");
	}
    }
}

$meta->set_metadata("status.pre_pipeline", "not_started");
$meta->set_metadata("status.rp", "");
$meta->set_metadata("rp.error." . time, $meta->get_metadata("rp.error"));
$meta->set_metadata("rp.error", "");
$meta->set_metadata("genome.error_notification_sent", "no");

my $rpdir = "$jobdir/rp/$genome";
if (-d $rpdir) {
    my $new = "$rpdir." . strftime("%Y-%m-%d-%H-%M-%S", localtime);
    if (rename($rpdir, $new)) {
	print "Moved old processed data $rpdir to $new\n";
    }
    else {
	die "Error renaming $rpdir to $new: $!\n";
    }
}


my $rperr = "$jobdir/rp.errors";
if (-d $rperr) {
    my $new = "$rperr." . strftime("%Y-%m-%d-%H-%M-%S", localtime);

    if (rename($rperr, $new)) {
	print "Moved rp.error dir to $new\n";
	mkdir($rperr);
    }
    else {
	warn "Error moving rp.error dir to $new: $!";
    }
}

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

print "Job reset. touch $jobdir/ACTIVE to restart\n";
