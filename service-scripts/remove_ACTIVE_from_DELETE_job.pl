# -*- perl -*-

use strict;
use warnings;
use Data::Dumper;

use Job48;

my $jobnum = shift;
my $job = Job48->new($jobnum);

if ($job->to_be_deleted()) {
    if ($job->active()) {
	my $jobdir = $job->dir();
	print STDERR "Removing '$jobdir/ACTIVE'\n";
	unlink( "$jobdir/ACTIVE") or die "Could not remove '$jobdir/ACTIVE' from job in 'DELETE' state";
    }
}
