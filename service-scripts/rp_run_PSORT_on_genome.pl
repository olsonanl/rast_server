use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $fig = new FIGV("$jobdir/rp/$genome");

if(-e "$jobdir/rp/$genome/attributes/phenotypes.txt"){

    my $stain;
    open(IN,"$jobdir/rp/$genome/attributes/phenotypes.txt");
    while($_ = <IN>){
	if($_ =~/Gram_Stain\tPositive/){$stain = "positive";}
	elsif($_ =~/Gram_Stain\tNegative/){$stain = "negative";}
    }
    close(IN);

    if($stain){
	$results_dir = "/vol/seed-attributes/computation_results/Psort/$genome";
	
	if(! -d $results_dir){
	    `mkdir $results_dir`;
	}
	
	my $input_file = "$results_dir/$genome.fasta";
	my $output_file = "$results_dir/$genome.output";
	open(OUT,">$input_file");
	
	my @pegs = $fig->pegs_of($genome);
	foreach my $peg (@pegs){
	    if($peg =~/(\d+.\d+.peg.\d+)/){
		my $seq = $fig->get_translation($peg);
		print OUT ">$peg\n";
		print OUT "$seq\n";
	    }
	}
	close(OUT);
	
	open(QSUB,">$jobdir/rp/$genome/psort_job_$genome.sh");
	print QSUB "#!/usr/bin/sh\n";
	print QSUB "PATH=/home/mkubal/public_html/FIGdisk/env/cee/bin\n";

	if($stain eq "Positive"){
	    print QSUB "/vol/cee-2008-0403/linux-ppc/bin/psort -p $input_file > $output_file;\n";
	}
	else{
	    print QSUB "/vol/cee-2008-0403/linux-ppc/bin/psort -n $input_file > $output_file;\n";
	}
	close(QSUB);
	`qsub -q all.q $jobdir/rp/$genome/psort_job_$genome.sh`;
    }
}

