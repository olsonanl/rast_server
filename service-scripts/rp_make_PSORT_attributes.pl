my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);
my $date = localtime();

if(! -d "$jobdir/rp/$genome/attributes"){
    `mkdir $jobdir/rp/$genome/attributes`;
}

if(-e "$jobdir/rp/$genome/attributes/phenotypes.txt"){

    
    my $stain;
    open(IN,"$jobdir/rp/$genome/attributes/phenotypes.txt");
    while($_ = <IN>){
	if($_ =~/Gram_Stain\tPositive/){$stain = "Positive";}
	elsif($_ =~/Gram_Stain\tNegative/){$stain = "Negative";}
    }
    close(IN);

    print "$stain\n";

    my $score_threshold;
    if($stain =~/(Negative|Positive)/){
        if($stain eq "Negative"){$score_threshold = 2;}
        else{$score_threshold = 2.5;}
        $results = "/vol/seed-attributes/computation_results/Psort/$genome/$genome.output";
        open(IN,$results);
        my $peg;
        my $record = 0;
	open(OUT,">$jobdir/rp/$genome/attributes/psort.txt");
        while ($_ = <IN>){
            chomp($_);
            if($record){
                if($_ =~/(\w+)\s+(\d+.\d+)/){print OUT "$peg\tPSORT::$1\t$2\n";}
		elsif($_ =~/(\w+)\s+.*multiple.*(\d+.\d+)/){print OUT "$peg\tPSORT::$1\t$2\n";}
                elsif($_ =~/Unknown/){print OUT "$peg\tPSORT::unknown\tunknown\n";}
                $record = 0;
            }
            else{
                if($_ =~/(fig\|\d+.\d+.peg.\d+)/){$peg = $1;}
                if($_ =~/(CytoplasmicMembrane)\s+(\d+.\d+)/){if($2 > $score_threshold){print OUT "$peg\tPSORT_score::$1\t$2\n";}}
                if($_ =~/(Cytoplasmic)\s+(\d+.\d+)/){if($2 > $score_threshold){print OUT "$peg\tPSORT_score::$1\t$2\n";}}
                if($_ =~/(OuterMembrane)\s+(\d+.\d+)/){if($2 > $score_threshold){print OUT "$peg\tPSORT_score::$1\t$2\n";}}
                if($_ =~/(Periplasmic)\s+(\d+.\d+)/){if($2 > $score_threshold){print OUT "$peg\tPSORT_score::$1\t$2\n";}}
                if($_ =~/(Extracellular)\s+(\d+.\d+)/){if($2 > $score_threshold){print OUT "$peg\tPSORT_score::$1\t$2\n";}}
                if($_ =~/(Cellwall)\s+(\d+.\d+)/){if($2 > $score_threshold){print OUT "$peg\tPSORT_score::$1\t$2\n";}}
            }
            if($_ =~/Final Prediction/){$record = 1}
        }
	close(OUT);
    }
}


