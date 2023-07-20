
#
# Compute one piece of sims work.
#
# Usage: rp_compute_sims sims_job_dir
#
# SGE_TASK_ID is set to the taskid to be computed.
#

use GenomeMeta;
use FIG_Config;
use strict;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

my $sims_subdir = $ENV{SIMS_SUBDIR} || "sims.job";

my $sims_jobdir = "$jobdir/$sims_subdir";

-d $jobdir or die "$0: job dir $jobdir does not exist\n";
-d $sims_jobdir or die "$0: job dir $jobdir does not exist\n";

my $task_num = $ENV{SGE_TASK_ID};
my $num_tasks = $ENV{SGE_TASK_LAST} - $ENV{SGE_TASK_FIRST} + 1;
if ($ENV{OVERRIDE_SGE_NUM_TASKS} =~ /^(\d+)$/)
{
    $num_tasks = $1;
}

$task_num =~ /^\d+$/ or die "$0: SGE_TASK_ID not numeric\n";

my $meta = new GenomeMeta(undef, "$jobdir/meta.xml");

if ($task_num == 1 and $meta->get_metadata("status.sims") eq 'queued')
{
    $meta->set_metadata("status.sims", "in_progress");
}

open(TL, "<$sims_jobdir/task.list") or die "$0: cannot open tasklist $sims_jobdir/task.list: $!\n";

my ($in, $nr, $flags, $out, $err);

my @my_work;

while (<TL>)
{
    chomp;
    my @a = split(/\t/);
    my $work_id = $a[0];

    if ($ENV{SIMS_NO_WRAP})
    {
	if ($work_id == $task_num)
	{
	    #($in, $nr, $flags, $out, $err) = @a[1 .. 5];
	    push(@my_work, [@a[1..5]]);
	}
    }
    else
    {
	if ((($work_id - $task_num) % $num_tasks) == 0)
	{
	    #($in, $nr, $flags, $out, $err) = @a[1 .. 5];
	    push(@my_work, [@a[1..5]]);
	}
    }
}
close(TL);

for my $work_ent (@my_work)
{
    my($in, $nr, $flags, $out, $err) = @$work_ent;

    $in or die "Could not find task $task_num";

    #$meta->add_log_entry($0, ['running ', $task_num, $in, $nr, $flags, $out, $err]);
    print "Computing on $in\n";
    my $t1 = time;
    
    my $blast_args = "$flags -i $in -d $nr -o $out";
    
    if ($ENV{NSLOTS} =~ /^(\d+)$/)
    {
	my $n = $1;
	print "Running $n processor blast due to parallel environment '$ENV{PE}'\n";
	$blast_args .= " -a $n";
    }
    
    open(E, ">$err") or die "Cannot open $err: $!";
    open(P, "$FIG_Config::ext_bin/blastall $blast_args 2>&1 |") or die "Cannot run blastall: $!";
    
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
