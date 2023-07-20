use LWP;
use URI;
use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $fig = new FIGV("$jobdir/rp/$genome");
my $fasta = $jobdir."/rp/$genome/Features/peg/fasta";
my $human_db = $FIG_Config::organisms."/9606.3/Features/peg/fasta";
`blastall -i $fasta -p blastp -m 8 -e .00001 -d $human_db > /vol/seed-attributes/computation_results/Sim2Human/$genome.sim2human.txt`;
