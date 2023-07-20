
#
# Given the computed glimmer and critica calls from earlier runs of rp_glimmer
# and rp_critica, use build_nr to compute the mappings between these calls and
# the peg calls in the genome, extract the sims that we can from the
# precomputed sims, and compute the remaining sims as needed.
#

use Data::Dumper;
use Carp;
use strict;
use Job48;
use FIGV;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Sim;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $job = new Job48($jobdir);
$job or die "cannot create job for $jobdir";

my $hostname = `hostname`;
chomp $hostname;

my $genome = $job->genome_id();
my $meta = $job->meta();

$meta->add_log_entry($0, "start teach-sims processing on $hostname in $jobdir");


my $work = "$jobdir/teach_sims_work";
my $orgdir = "$jobdir/rp/$genome";

&FIG::verify_dir($work);
chdir $work or &fatal("chdir $work failed: $!");

open(SRCS, ">$work/nr.sources") or &fatal("cannot write $work/nr.sources: $!");

for my $type (qw(peg glimmer critica))
{
    print SRCS "$orgdir/Features/$type/fasta\n";
}
close(SRCS);

&run("$FIG_Config::bin/build_nr",
     "-emit-singletons",
     "$work/nr.sources", "/dev/null", "/dev/null",
     "$work/teach.nr", "$work/teach.ps");

#
# Read the generated peg.synonyms. We are going to build a list
# @sims_to_compute of xxx ids that do not have peg ids.
# Also compute the mapping %peg_to_teach of pegid => [id]
# for the ids that do map to pegs.
#

my @sims_to_compute;
my %peg_to_teach;
my %xxx_to_teach;

open(PULL, "| $FIG_Config::bin/pull_fasta_entries $work/teach.nr > $work/sims.nr") or
    &fatal("cannot open pull pipeline: $!");

open(PS, "<$work/teach.ps") or &fatal("Cannot open $work/teach.ps: $!");

while (<PS>)
{
    chomp;
    if (/^([^,]+),(\d+)\t(.*)/)
    {
	my $ps = $1;
	my $ps_len = $2;
	my @pairs = map { [ split(/,/, $_) ] } split(/;/, $3);

	my @pegs = grep { $_->[0] =~ /^fig\|\d+\.\d+\.peg/ } @pairs;
	my @rest = grep { $_->[0] !~ /^fig\|\d+\.\d+\.peg/ } @pairs;
#	print Dumper(\@pairs, \@pegs, \@rest);
	
	if (@pegs)
	{
	    my $rep = $pegs[0]->[0];
	    $peg_to_teach{$rep} = [@rest];
	}
	else
	{
	    push(@sims_to_compute, $ps);
	    $xxx_to_teach{$ps} = [@rest];
	    print PULL "$ps\n";
	}
    }
}
print Dumper(\@sims_to_compute, \%xxx_to_teach, \%peg_to_teach);
close(PS);
if (!close(PULL))
{
    &fatal("error closing pull pipeline; \$!=$! \$?=$?");
}

$meta->add_log_entry($0, "finish critica computation on $jobdir");
$meta->set_metadata("status.critica", "complete");
exit(0);


sub run
{
    my(@cmd) = @_;
    print "Run @cmd\n";
    my $rc = system(@cmd);
    $rc == 0 or &fatal("Cmd failed with rc=$rc: @cmd");
 }

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("status.bbhs", "error");
    }

    croak "$0: $msg";
}
    
