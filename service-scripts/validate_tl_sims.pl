#
# Given a sims job directory, validate that each id in input file in the task list is present
# in the generated raw sims data in sims.raw/raw.XX. Note that the output fiel currently does
# not match the filename in the task.list, though it probably should.
#

use strict;
use FIG;
use FileHandle;
use FIG_Config;
use File::Copy;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $simdir = "$jobdir/sims.job";

open(TASK, "<$simdir/task.list") or die("Cannot open task list $simdir/task.list: $!");

my $errors;

while (<TASK>)
{
    chomp;
    my($id, $in, $nr, $args, $out, $err) = split(/\t/);

    if ($in !~ m,^/,)
    {
	$in = "$jobdir/$in";
    }
    if (!open(IN, "<$in"))
    {
	warn "Cannot open input file $in: $!";
	$errors++;
	next;
    }

    my %ids;
    {
	local $/ = "\n>";
	
	while (<IN>)
	{
	    if (/^>?(\S+)/)
	    {
		$ids{$1}++;
	    }
	}
	close(IN);
    }

    my $sims = $out;
    if (!open(SIMS, "<$sims"))
    {
	warn "Cannot open sims file $sims: $!";
	$errors++;
	next;
    }
    print "$sims\n";
    while (<SIMS>)
    {
	if (/^(\S+)/ and $ids{$1})
	{
	    delete $ids{$1};
	}
    }
    close(SIMS);
    if (%ids)
    {
	warn "Task $id missing sims\t", join("\t", keys %ids), "\n";
	$errors++;
    }
}

if ($errors)
{
    die "$errors errors occurred during validation\n";
}
