use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $complete = shift(@ARGV);

my $fig = new FIGV("$jobdir/rp/$genome");

if($complete){
    my $input_file = "$jobdir/rp/$genome/Features/peg/fasta";
    `/vol/interpro-4.3/ppc/iprscan/bin/iprscan -cli -appl hmmpfam -iprlookup -goterms -i $input_file -o $jobdir/rp/$genome/iprscan_result_for_$genome.xml`;
}
else{
    my $fasta_file = "$jobdir/rp/$genome/partial_$genome.fa";
    open(INPUT_FILE,">$fasta_file");
    my %already;
    my @attributes = $fig->get_attributes(['fig|$genome.%'],'%_interpro_download');
    foreach my $attribute (@attributes){
	$already{@$attribute[0]} = 1;
    }

    my @pegs = $fig->pegs_of($genome);
    foreach my $peg (@pegs){
	if(! $already{$peg}){
	    my $seq = $fig->get_translation($peg);
	    print INPUT_FILE ">$peg\n$seq\n";
	}
    }
    close(INPUT_FILE);
    `/vol/interpro-4.3/ppc/iprscan/bin/iprscan -cli -appl hmmpfam -iprlookup -goterms -i $fasta_file -o $jobdir/rp/$genome/iprscan_result_for_$genome.xml`;
    
}
