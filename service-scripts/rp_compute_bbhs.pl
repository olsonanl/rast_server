
#
# Compute BBHs from expanded sims.
#

use DB_File;

use Data::Dumper;
use Carp;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Sim;

@ARGV == 1 or @ARGV ==2  or die "Usage: $0 job-dir [cutoff]\n";

my $jobdir = shift;

my $cutoff = 1.0e-10;
$cutoff = shift if @ARGV > 0;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

my $sims_file = "$jobdir/rp/$genome/expanded_similarities";

#open(SIM, "<$sims_file") or &fatal("Cannot open expanded sims $sims_file: $!");
open(SIM, "cat $sims_file; perl -ane 'print join(\"\\t\", \@F[1,0,2..11,13,12,14]), \"\\n\"' $sims_file | sort |")
or &fatal("failed ropning sims file\n");

$meta->add_log_entry($0, "start BBH processing on $hostname in $jobdir");

my $tmp = "$FIG_Config::temp/rp_compute_bbh.$$";

my $bbh_file = "$jobdir/rp/$genome/bbhs";
my $bbh_index = "$jobdir/rp/$genome/bbhs.index";

$meta->set_metadata("status.bbhs", "in_progress");

open(BBHS, "| sort > $bbh_file") or &fatal("Cannot open sort pipe to $bbh_file: $!");
open(SORT, "| sort > $tmp") or &fatal("Cannot open sort pipe to $tmp: $!");

$DB_BTREE->{'flags'} = R_DUP;
unlink($bbh_index);

my %bbh_tie;
my $bbh_db = tie %bbh_tie, "DB_File", $bbh_index, O_RDWR | O_CREAT, 0666, $DB_BTREE
    or &fatal("Error opening DB_File tied to $bbh_index: $!\n");

my($id1, $id2, $psc, $bsc, $ln1, $ln2, $genome1, $genome2);

my $line = <SIM>;

open(F, ">$FIG_Config::temp/best.$$");
while ($line and $line =~/^(\S+)/)
{
    my $cur = $1;
#   print "cur=$cur\n";

    my %best;
#
# Each entry in %best is keyed on "$peg\t$genome2" and contains a tuple
# [$score, $peg-pair, $nsc]
#
# Sims line looks like:
# 0,                  1,                   2,      3,     4,    5,    6,  7,  8,  9,  10,    11,  12,  13
# id1,                id2,                 %iden,  nali,  nmis, ngap, b1, e1, b2, e2, psc,   bsc, ln1, ln2
# fig|83331.3.peg.11  fig|1806.1.peg.3442  100.00  50     0     0     1   50  1   50  2e-23  110  50   50
    
    while ((($id1, $id2, $psc, $bsc, $ln1, $ln2) =
	    #            0      1      2     3     4     5     6     7     8     9      10      11      12      13
	    $line =~ /^(\S+)\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/) 
	   and $id1 eq $cur)
    {
	if (($genome1) = $id1 =~ /^fig\|(\d+\.\d+)/ and ($genome2) = $id2 =~ /^fig\|(\d+\.\d+)/ and $psc < $cutoff)
	{
#	    print "id1=$id1 id2=$id2 $genome1 $genome2\n";
	    my $nsc = sprintf("%0.3f",$bsc / (($ln1 > $ln2) ? $ln1 : $ln2));
	    
	    my($x1, $x2) = $id1 lt $id2 ? ($id1, $id2) : ($id2, $id1);
	    
	    update_best(\%best, $id1, $genome2, $psc, $nsc, "$x1\t$x2");
#	    update_best(\%best, $id2, $genome1, $psc, $nsc, "$x1\t$x2");
	}
	$line = <SIM>;
    }

#    print F "$cur\t--------\n";
#    print F Dumper(\%best);
    for my $key (keys(%best))
    {
	my($psc, $pair, $nsc, $ok) = @{$best{$key}};
	if (defined($pair) and $ok)
	{
	    print SORT join("\t", $pair, $psc, $nsc), "\n";
	}
    }
}
close(F);
close(SIM);
close(SORT) or &fatal("Sort pipe failed with \$!=$! \$?=$?");

$meta->add_log_entry($0, "wrote sorted best to $tmp");

open(SBEST, "<$tmp") or &fatal("cannot open generated tmpfile $tmp: $!");

$line = <SBEST>;
while ($line && ($line =~ /^(\S+)\t(\S+)/))
{
    my $curr1 = $1;
    my $curr2 = $2;
    my @set = ();
    while ($line && ($line =~ /^(\S+)\t(\S+)\t(\S+)\t(\S+)/) && ($1 eq $curr1) && ($2 eq $curr2))
    {
	push(@set,[$1,$2,$3,$4]);
	$line = <SBEST>;
    }
    @set = sort { $a->[2] <=> $b->[2] } @set;
    if ((@set > 1) && ($set[0]->[1] eq $set[1]->[1]))
    {
	my($id1, $id2, $psc, $nsc) = @{$set[0]};
	print BBHS join("\t", $id1, $id2, $psc, $nsc), "\n";
	print BBHS join("\t", $id2, $id1, $psc, $nsc), "\n";

	$bbh_tie{$id1} = join(",", $id2, $psc, $nsc);
	$bbh_tie{$id2} = join(",", $id1, $psc, $nsc);
    }
}
close(BBHS) or &fatal("error closing sort pipe to $bbh_file: \$!=$! \$?=$?\n");

untie %bbh_tie;

$meta->add_log_entry($0, "finish bbh computation on $jobdir");
$meta->set_metadata("bbhs.running", "no");
$meta->set_metadata("status.bbhs", "complete");
exit(0);

sub update_best
{
    my($best, $id1, $genome2, $psc, $nsc, $pair) = @_;

    my $key = "$id1\t$genome2";
    my $cur = $best->{$key};
    if (defined($cur))
    {
	#
	# Already one in there; update if we are clearly better.
	#

	my $curLogScore = &FIG::neg_log($cur->[0]);
	my $newLogScore = &FIG::neg_log($psc);

	my $differential = $newLogScore - $curLogScore;
	if ($differential > 5)
	{
	    $best->{$key} = [$psc, $pair, $nsc, 1];
#	    print "$id1: new best for $genome2 by $differential is $pair\n";
	}
	elsif ($differential > -5)
	{
	    print F "$id1: reject best for $genome2 by $differential is $pair  psc=$psc nsc=$nsc old was @$cur\n";
	    $cur->[3] = 0;
	    if ($differential > 0)
	    {
#		print "        update score to $psc\n";
		$cur->[0] = $psc;
	    }
	}
    }
    else
    {
	$best->{$key} = [$psc, $pair, $nsc, 1];
#	print "$id1: initial best for $genome2 is $pair\n";
    }
}



sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("status.bbhs", "error");
	$meta->set_metadata("bbhs.running", "no");
    }

    croak "$0: $msg";
}
    
