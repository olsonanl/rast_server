my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $input_file = $jobdir."/$genome_PFAM_HMM_search_results.txt";

if(! -d "$jobdir/rp/$genome/attributes"){
    mkdir("$jobdir/rp/$genome/attributes");
}

my $output_file = $jobdir."/rp/$genome/attributes/PFAM_HMM_derived_attributes_for_$genome.txt";

open(IN,"$input_file");
open(PFAM,">$output_file");

print PFAM "$genome\tPFAM_attribute_by_HMM_search_on_TimeLogic\tPfam_version_22\n";

my $id;
my $pf;
my $start;
my $end;
my $evalue;
my $score;

while ($_ = <IN>){
    if($_ =~/(fig\|\d+.\d+.peg.\d+)/){
	$id = $1;
    }
    
    if($_ =~/^\sA\s=\s(PF\d+)/){
	$pf = $1;
    }
       
    if($_ =~/E_Value =\s+(.*)/){
	$evalue = $1;
	chomp($evalue);
    }
        
    if($_ =~ /QS =\s+(\d+)\s+QE =\s+(\d+)/){
	$start = $1;
	$end = $2;
    	if($evalue =~/(\d+.\d+)e-(\d+)/){
	    $part1 = $1;
	    $part2 = $2;
	    if($part2 > 19){
		$part2 = (1000 - $part2);
		$part1 = $part1 * 100;
		$score = $part2.".".$part1;
		print PFAM "$id\tPFAM::$pf\t$score;$start-$end\n";
	    }
	}
	if($evalue =~/^0/){
	    print PFAM "$id\tPFAM::$pf\t0.0;$start-$end\n";
	}
    }
}
close(IN);

