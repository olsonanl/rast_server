use Data::Dumper;
use Carp;
use FIG_Config;

use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);
my $date = localtime();

if(! -d "$jobdir/rp/$genome/attributes"){
    `mkdir $jobdir/rp/$genome/attributes`;
}

my $fig = new FIGV("$jobdir/rp/$genome");

my $of = $genome.".sim2human.txt";
open(IN,"/vol/seed-attributes/computation_results/Sim2Human/$of");
open(OUT,">$jobdir/rp/$genome/attributes/similar_to_human.txt");
my %sim;
while($_ = <IN>){
    if($_ =~/(fig\|\d+.\d+.peg.\d+)/){
	    my $peg = $1;
	    $sim{$peg} = 1;
	}
}
close(IN);

my @pegs = $fig->pegs_of($genome);
foreach my $peg (@pegs){
    if($sim{$peg}){
	print OUT "$peg\tsimilar_to_human\tyes\n";
    }
    else{
	    print OUT "$peg\tsimilar_to_human\tno\n";
	}
}
$date = `date`;
chomp($date);
print OUT "$genome\tsimilar_to_human_computed_for_all_pegs\t$date\n";
close(OUT);

