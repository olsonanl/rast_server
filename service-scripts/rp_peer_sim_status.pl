#
# Determine if the peer sims between the two organisms have been computed.
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

my $meta;

@ARGV == 2 or die "Usage: $0 job-id job-id\n";

my @job_ids = @ARGV;

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

#print Dumper(\@jobs);

my $ok = 0;
my $in_progress = 0;
my $missing = 0;
my $queued = 0;
for my $j1idx (0..@jobs-1)
{
    my($j1_id, $j1_jobdir, $j1_genome, $j1_orgdir) = @{$jobs[$j1idx]};
    for my $j2idx (0..@jobs-1)
    {
	next if $j1idx == $j2idx;
	my($j2_id, $j2_jobdir, $j2_genome, $j2_orgdir) = @{$jobs[$j2idx]};

	# print "check $j1_genome $j2_genome\n";

	if (-f "$j1_orgdir/sims/$j2_genome.queued")
	{
	    $queued++;
	}
	if (-f "$j1_orgdir/sims/$j2_genome.in_progress")
	{
	    $in_progress++;
	}
	elsif (-f "$j1_orgdir/sims/$j2_genome")
	{
	    $ok++;
	}
	else
	{
	    $missing++;
	}
    }
}

if ($missing)
{
    print "missing\n";
}
elsif ($in_progress)
{
    print "in_progress\n";
}
elsif ($queued)
{
    print "queued\n";
}
else
{
    print "complete\n";
}
