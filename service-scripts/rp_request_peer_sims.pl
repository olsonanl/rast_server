#
# Request the computation of all-to-all sims between a set of organism directories.
#

use strict;
use Data::Dumper;
use Carp;
use DB_File;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use FileHandle;
use Sim;
use GeneralJob;
use FileLocking qw(lock_file unlock_file);
use File::Slurp;
use Getopt::Long::Descriptive;

my $meta;

my($opt, $usage) = describe_options("%c %o login job-id job-id ...",
				    ["dry-run", "Don't actually run the job"],
				    ["help|h", "Show this help message"]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV < 3;

my $login = shift;
my @job_ids = @ARGV;

$FIG_Config::general_jobdir ne '' or die "\$FIG_Config::general_jobdir must be set\n";

#
#
# First walk the list of jobs we're setting up sims for and touch the
# orgdir/sims/org2.queued file to mark them as queued for computation.
#

my @jobs;
for my $j (@job_ids)
{
    my $d = "$FIG_Config::rast_jobs/$j";
    my $g = &FIG::file_head("$d/GENOME_ID", 1);
    $g or die "cannot read jobdir $g";
    chomp $g;
    my $simdir = "$d/rp/$g";

    if (! -d "$simdir/sims")
    {
	mkdir("$simdir/sims");
    }
    if (! -f "$simdir/sims/lock")
    {
	open(LF, ">", "$simdir/sims/lock");
	close(LF);
    }

    push(@jobs, [$j, $d, $g, $simdir]);
}

my %need;

for my $j1idx (0..@jobs-1)
{
    my($j1_id, $j1_jobdir, $j1_genome, $j1_orgdir) = @{$jobs[$j1idx]};

    #
    # Lock the sims dir while we are doing this check.
    #

    open(LF, "+<", "$j1_orgdir/sims/lock") or die
	"Cannot open lockfile $j1_orgdir/sims/lock: $!";
    lock_file(\*LF);
   
    for my $j2idx (0..@jobs-1)
    {
	next if $j1idx == $j2idx;
	my($j2_id, $j2_jobdir, $j2_genome, $j2_orgdir) = @{$jobs[$j2idx]};

	my $simfile_base = "$j1_orgdir/sims/$j2_genome";

	print "checking $simfile_base\n";
	if (-f "$simfile_base.queued")
	{
	    print "$j1_genome $j2_genome already queued\n";
	}
	elsif (-f "$simfile_base.in_progress")
	{
	    print "$j1_genome $j2_genome already in progress\n";
	}
	elsif (-f "$simfile_base")
	{
	    print "$j1_genome $j2_genome already computed\n";
	}
	else
	{
	    my($j1, $j2) = sort { $a <=> $b } ($j1idx, $j2idx);
	    
	    $need{$j1,$j2}++;
	}
    }

    close(LF);
}

if (%need == 0)
{
    print "No compute needed\n";
    exit 0;
}

my $jobid = GeneralJob->create_new_job($FIG_Config::general_jobdir);
my $job = GeneralJob->new($FIG_Config::general_jobdir, $jobid);

my $work = $job->dir;
write_file("$work/USER", "$login\n");

open(PAIRLIST, ">", "$work/pairs") or die "Cannot write $work/pairs: $!";
for my $pair (sort keys %need)
{
    my ($j1idx, $j2idx) = split(/$;/, $pair);
    
    #my($id, $jobdir, $genome, $orgdir) = @{$jobs[$jidx]};
    #print "Need to compute $id $jobdir $genome $orgdir\n";
    print "need to compute $j1idx $j2idx\n";

    mark_queued($j1idx, $j2idx);

    my $j1 = $jobs[$j1idx]->[0];
    my $j2 = $jobs[$j2idx]->[0];

    print PAIRLIST "$j1\t$j2\n";
}
close(PAIRLIST);

my $rc = system("rast-submit-rast-job",
		($opt->dry_run ? ("--dry-run") : ()),
		"--peer-sims", $work,
		"--cpus", 4);
$rc == 0 or die "Error submitting job\n";
print "Submitted $jobid\n";

sub mark_queued
{
    my($from, $to) = @_;

    my $g1 = $jobs[$from]->[2];
    my $g2 = $jobs[$from]->[2];

    my $d1 = $jobs[$from]->[1] . "/rp/$g1";
    my $d2 = $jobs[$to]->[1] . "/rp/$g2";

    print "mark $g1  $g2 / $d1 $d2\n";

    -d "$d1/sims" or mkdir "$d1/sims" or die "cannot mkdir $d1/sims: $!";
    if (!open(LF, "+<", "$d1/sims/lock"))
    {
	open(LF, "+>", "$d1/sims/lock") or die
	    "Cannot open lockfile $d1/sims/lock: $!";
    }
    lock_file(\*LF);

    open(S, ">", "$d1/sims/$g2.queued") or die "cannot mark $d1/sims/$g2.queued: $!";
    close(LF);
}

