#
# Move the active RAST to a new jobs volume.
#
# Usage: migrate-to-new-jobs-volume old-volume new-volume
#
# for each item I in $old-volume/jobs:
#
# If I a symlink: create symlink in $new-volume/jobs/I to the target of the symlink
# If I a job-directory  (numbered filename): create symlink in $new-volume/jobs/I to $old-volume/jobs/I
# Keep count of maximum job number seen
#
# For each item I in $old-volume/jobs/incoming:
# same deal.
#
# Look at contents of JOBCOUNTER. If empty, replace with max job + 1.
#

use strict;
use Fcntl ':mode';
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o old-volume new-volume",
				    ["dry-run", "Don't actually do anything"],
				    ["cleanup", "Assume the migration has been performed, and starting at JOBCOUNTER moving backwards add the missing links"],
				    ["help|h", "Show this help message"]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 2;

my $old_volume = shift;
my $new_volume = shift;

if ($opt->cleanup)
{
    cleanup_migration($old_volume, $new_volume);
}
else
{
    migrate_links("$old_volume/jobs", "$new_volume/jobs", 1);
    #migrate_links("$old_volume/jobs/incoming", "$new_volume/jobs/incoming");
}

sub cleanup_migration
{
    my($old, $new) = @_;

    open(JC, "<", "$old/jobs/JOBCOUNTER") or die "Cannot open $old/jobs/JOBCOUNTER: $!";
    my $max = <JC>;
    chomp $max;
    close(JC);
    $max =~ /^\d+$/ or die "Value of $old/jobs/JOBCOUNTER '$max' not a number\n";

    my $job = $max;
    while (1)
    {
	my $new_jobdir = "$new/jobs/$job";
	my @s = stat($new_jobdir);
	last if @s;

	migrate_one_link($job, "$old/jobs", "$new/jobs", 1);
	$job--;
    }
}


sub migrate_links
{
    my($old, $new, $jobcheck) = @_;

    -d $new or do_mkdir($new) or die "Cannot mkdir $new: $!";

    my $max_job = 0;
    
    opendir(D, $old);
    while (my $p = readdir(D))
    {
	if ($jobcheck && $p =~ /^\d+$/)
	{
	    $max_job = $p if $p > $max_job;
	}
	
	migrate_one_link($p, $old, $new, $jobcheck);
    }

    $max_job++;
    if ($jobcheck)
    {
	open(J, "<", "$old/JOBCOUNTER");
	my $j = <J>;
	if (!$j)
	{
	    print "Need to write $max_job\n";
	}
    }
}

sub migrate_one_link
{
    my($p, $old, $new, $jobcheck) = @_;
    
    my $old_path = "$old/$p";
    my @stat = lstat($old_path);
    
    if (!@stat)
    {
	die "stat $old_path failed: $!";
    }

    if (-l "$new/$p")
    {
	print "$new/$p already a link\n";
	return;
    }
    
    my $mode = $stat[2];
    
    if ($jobcheck && $p =~ /^\d+$/)
    {
	if (S_ISLNK($mode))
	{
	    my $target = readlink($old_path);
	    print "Link $target to $new/$p\n";
	    do_symlink($target, "$new/$p") or die "Error symlinking $target to $new/$p: $!";
	}
	elsif (S_ISDIR($mode))
	{
	    my $target = "$old_path";
	    print "Link $target to $new/$p\n";
	    do_symlink($target, "$new/$p") or die "Error symlinking $target to $new/$p: $!";
	}
    }
    elsif (!$jobcheck && $p =~ /^\d/)
    {
	if (S_ISLNK($mode))
	{
	    my $target = readlink($old_path);
	    print "Link $target to $new/$p\n";
	    do_symlink($target, "$new/$p") or die "Error symlinking $target to $new/$p: $!";
	}
	elsif (S_ISDIR($mode))
	{
	    my $target = "$old_path";
	    print "Link $target to $new/$p\n";
	    do_symlink($target, "$new/$p") or die "Error symlinking $target to $new/$p: $!";
	}
    }
}

sub do_mkdir
{
    my($dir) = @_;
    if ($opt->dry_run)
    {
	print STDERR "mkdir $dir\n";
    }
    else
    {
	mkdir($dir);
    }
}

sub do_symlink
{
    my($old, $new) = @_;
    if ($opt->dry_run)
    {
	print STDERR "symlink $old $new\n";
    }
    else
    {
	symlink($old, $new);
    }
}
