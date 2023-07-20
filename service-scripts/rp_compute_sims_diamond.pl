
#
# Compute sims using diamond.
#
# Usage: rp_compute_sims_diamond sims_job_dir
#
# if P3_ALLOCATED_CPU is set, use that many threads.
#

use GenomeMeta;
use FIG_Config;
use strict;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

my $sims_subdir = $ENV{SIMS_SUBDIR} || "sims.job";

my $sims_jobdir = "$jobdir/$sims_subdir";

-d $jobdir or die "$0: job dir $jobdir does not exist\n";
-d $sims_jobdir or die "$0: sims job dir $sims_jobdir does not exist\n";

my $meta = new GenomeMeta(undef, "$jobdir/meta.xml");
$meta->set_metadata("status.sims", "in_progress");

open(TL, "<$sims_jobdir/task.list") or die "$0: cannot open tasklist $sims_jobdir/task.list: $!\n";

my ($in, $nr, $flags, $out, $err);

my @my_work;

while (<TL>)
{
    chomp;
    my @a = split(/\t/);
    my $work_id = $a[0];

    push(@my_work, [@a[1..5]]);
}
close(TL);

for my $work_ent (@my_work)
{
    my($in, $nr, $flags, $out, $err) = @$work_ent;

    #$meta->add_log_entry($0, ['running ', $task_num, $in, $nr, $flags, $out, $err]);
    print "Computing on $in\n";
    my $t1 = time;
    
    if (-f "$nr.dmnd")
    {
	$nr = "$nr.dmnd";
    }
    my @args = ("--block-size", 5,
    	"-c1",
	"-e", "1e-4",
	"--masking", 0,
	"--threads", ($ENV{P3_ALLOCATED_CPU} // 1),
	"--sensitive",
	"-k", "300",
	"--outfmt", "6",
	"-d", $nr,
	"-q", $in,
	"-o", $out);

    open(E, ">$err") or die "Cannot open $err: $!";
    open(P, "diamond blastp @args 2>&1 |") or die "Cannot run diamond: $!";
    
    while (<P>)
    {
	print;
	print E $_;
    }
    
    my $rc = close(P);
    
    my $t2 = time;
    my $elap = $t2 - $t1;
    
    my $min = int($elap / 60);
    my $sec = $elap % 60;
    
    printf E "%d:%02d $t1 $t2 $elap\n", $min, $sec;
    printf "%d:%02d $t1 $t2 $elap\n", $min, $sec;
    
    if (!$rc)
    {
	if ($!)
	{
	    #	$meta->add_log_entry($0, ['blastall close error', $!]);
	    print "Error closing blastall: $!\n";
	    print E "Error closing blastall: $!\n";
	}
	else
	{
	    my $err = $?;
	    #	$meta->add_log_entry($0, ['blastall nonzero exit', $err]);
	    print "Nonzero exit status $err from blastall\n";
	    print E "Nonzero exit status $err from blastall\n";
	}
	last;
    }
    else
    {
	#    $meta->add_log_entry($0, ['blastall success', $elap]);
	print E "SUCCESS\n";
    }
    
    close(E);
}
