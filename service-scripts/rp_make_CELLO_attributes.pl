my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);
my $date = localtime();

opendir(DIR,$jobdir."/rp/$genome");

if(! -d "$jobdir/rp/$genome/attributes"){
    `mkdir $jobdir/rp/$genome/attributes`;
}

open(CELLO,">$jobdir/rp/$genome/attributes/CELLO_attributes_for_$genome.txt");

print CELLO "$genome\tCELLO_computed_against_all_pegs\t$date\n";
@files = readdir(DIR);
foreach $file (@files){
    if ($file =~/(\d+.\d+.peg.\d+).CELLO_result/){
	$peg = $1;
	open(IN,"$jobdir/rp/$genome/$file");
	my $score; 
        my $location;
	while($_ = <IN>){
	    if($_ =~/(Membrane|Extracellular|CellWall|Cytoplasmic|Periplasmic|InnerMembrane|OuterMembrane)\s?..td..td..nbsp..nbsp..nbsp..nbsp.(\d.\d+).nbsp..nbsp.\*/){
		$score = $2;
		if($1 =~/^Membrane/){$location = "membrane"}
		if($1 =~/Extracellular/){$location = "extracellular"}
		if($1 =~/CellWall/){$location = "cell wall"}
		if($1 =~/Cytoplasmic/){$location = "cytoplasm"}
		if($1 =~/OuterMembrane/){$location = "outer membrane"}
		if($1 =~/InnerMembrane/){$location = "inner membrane"}
		if($1 =~/Periplasmic/){$location = "periplasm"}
		
		print CELLO "fig|$peg\tCELLO::$location\t$score\n";
	    }
	}
	close(IN);
    }
}

`rm $jobdir/rp/$genome/*.CELLO_result`;
