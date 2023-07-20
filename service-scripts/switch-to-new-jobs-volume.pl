#
# Do a nearly-atomic switch to a new jobs volume.
#

use strict;
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o old-volume new-volume",
				    ["dry-run", "Don't actually do anything"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 2;

my $old_volume = shift;
my $new_volume = shift;

my $migrate;
for my $ent (split(/:/, $ENV{PATH}))
{
    if (-x (my $p = "$ent/migrate-to-new-jobs-volume"))
    {
	$migrate = $p;
	last;
    }
}
$migrate or die "Cannot find migrate path\n";

my $rc = system("sudo", "-u" , "rastprod", $migrate, ($opt->dry_run ? "--dry-run" : ()), "--cleanup", $old_volume, $new_volume);
$rc == 0 or die "sudo $migrate failed\n";


$rc = system("sudo", "-u" , "rastprod", $migrate, ($opt->dry_run ? "--dry-run" : ()), "--cleanup", $old_volume, $new_volume);
$rc == 0 or die "sudo $migrate failed\n";

do_copy("$old_volume/jobs/JOBCOUNTER", "$new_volume/jobs/JOBCOUNTER");
do_unlink("/vol/rast-prod/jobs");
do_symlink("$new_volume/jobs", "/vol/rast-prod/jobs");


sub do_symlink
{
    my($old, $new) = @_;
    if ($opt->dry_run)
    {
	print STDERR "symlink $old $new\n";
    }
    else
    {
	my $rc = system("sudo", "-u", "rastcode", "ln", "-s", $old, $new);
	return $rc == 0;
    }
}

sub do_copy
{
    my($old, $new) = @_;
    if ($opt->dry_run)
    {
	print STDERR "cp $old $new\n";
    }
    else
    {
	my $rc = system("sudo", "-u", "rastcode", "cp", $old, $new);
	return $rc == 0;
    }
}

sub do_unlink
{
    my($path) = @_;
    if ($opt->dry_run)
    {
	print STDERR "rm $path\n";
    }
    else
    {
	my $rc = system("sudo", "-u", "rastcode", "rm", $path);
	return $rc == 0;
    }
}
