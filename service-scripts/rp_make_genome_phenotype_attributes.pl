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

my $prefix;
if ($genome =~/(\d+)\.\d+/){
    $prefix = $1;
}

open(IN,"/vol/seed-attributes/Genome_Phenotype_Data/reformatted_phenotype_data_from_Liz_030308.txt");
while($_ = <IN>){
    chomp($_);
    my $ncbi;
    if($_ =~/^\d+\t(\d+)/){$ncbi = $1;}
    if($prefix eq $ncbi){
	@cols = split("\t",$_);
	my $output_dir = "$jobdir/rp/$genome/attributes";
	if(! -d $output_dir){
	    `mkdir $output_dir`;
	}
	
	open(OUT,">$output_dir/phenotypes.txt");
	print OUT "$genome\tGC_Content\t$cols[7]\n";
	if($cols[8] =~/-/){
	    print OUT "$genome\tGram_Stain\tNegative\n";
	}
	elsif($cols[8] =~/\+/){
	    print OUT "$genome\tGram_Stain\tPositive\n";
	}
	else{
	    print OUT "$genome\tGram_Stain\t$cols[8]\n";
	}
	print OUT "$genome\tShape\t$cols[9]\n";
	print OUT "$genome\tArrangement\t$cols[10]\n";
	print OUT "$genome\tEndospores\t$cols[11]\n";
	print OUT "$genome\tMotility\t$cols[12]\n";
	print OUT "$genome\tSalinity\t$cols[13]\n";
	print OUT "$genome\tOxygen_Requirement\t$cols[14]\n";
	print OUT "$genome\tHabitat\t$cols[15]\n";
	print OUT "$genome\tTemperature_Range\t$cols[16]\n";
	print OUT "$genome\tOptimal_Temperature\t$cols[17]\n";
	print OUT "$genome\tPathogenic\t$cols[18]\n";
	print OUT "$genome\tPathogenic_In\t$cols[19]\n";
	if($cols[20] =~/(.*\w)/){
	    print OUT "$genome\tDisease\t$1\n";
	}
	close(OUT);
	last;
    }
}


