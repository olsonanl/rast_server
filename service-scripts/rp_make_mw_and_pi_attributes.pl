use Data::Dumper;
use Carp;
use FIG_Config;

use lib '/vol/cee-2007-1108/linux-debian-x86_64/lib/perl5/site_perl/5.8.8/Bio/Tools';
use SeqStats;
use pICalculator;
use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);
my $date = localtime();

if(! -d "$jobdir/rp/$genome/attributes"){
    `mkdir $jobdir/rp/$genome/attributes`;
}

my $fig = new FIGV("$jobdir/rp/$genome");

open(MW,">$jobdir/rp/$genome/attributes/molecular_weight_for_$genome.txt");
open(ISO,">$jobdir/rp/$genome/attributes/isoelectric_point_for_$genome.txt");

print MW "$genome\tmolecular_weight_computed_against_all_pegs\t$date\n";
print ISO "$genome\tisoelectric_point_computed_against_all_pegs\t$date\n";

my @pegs = $fig->pegs_of($genome);
foreach $peg (@pegs){
    my $seq = $fig->get_translation($peg);
    $mw_seqobj = Bio::PrimarySeq->new(-seq=>$seq,
				      -alphabet=>'protein',
				      -id=>'test');
    
    $weight = Bio::Tools::SeqStats->get_mol_wt($mw_seqobj);
    print MW "$peg\tmolecular_weight\t$$weight[0]\n";
    #print "$peg\tmolecular_weight\t$$weight[0]\n";
    
    $pi_seqobj = Bio::Seq->new(-seq=>$seq,
			       -alphabet=>'protein',
			       -id=>'test');
    
    $calc = Bio::Tools::pICalculator->new(-places => 2);
    $calc->seq($pi_seqobj);
    $iep = $calc->iep;
    print ISO "$peg\tisoelectric_point\t$iep\n";
    #print "$peg\tisoelectric_point\t$iep\n";
}

close(ISO);
close(MW);	
