use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $fig = new FIGV("$jobdir/rp/$genome");

my @pegs = $fig->pegs_of($genome);
foreach my $peg (@pegs){
    my $seq = $fig->get_translation($peg);
    if($peg =~/fig\|(\d+.\d+.peg.\d+)/){
	$id = $1;
	`crc64 $id $seq >> $jobdir/rp/$genome/crc64_for_pegs_of_$genome.txt`;
    }
}
