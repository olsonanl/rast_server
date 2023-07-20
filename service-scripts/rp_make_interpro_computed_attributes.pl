my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

open(IN,"$jobdir/rp/$genome/iprscan_results_for_$genome.xml");
open(RESULTS,">$jobdir/rp/$genome/attributes/interpro_computed_attributes.txt");

my $id;
my $interpro_id;
my $db;
my $db_id;
my $match = 0;

while ($_ = <IN>){
    if($_ =~/(\d+.\d.peg.\d+)/){
	$id = $1;
	$id = "fig|".$id;
	$match = 0;
    }

    if($_ =~ /interpro id=\"(\w+\d+)\"/){
	$interpro_id = $1."_computed_against_interpro_r15";
    }
      
    if($_ =~/match\sid=\"(.*)\"\sname=\"(.*)\"\sdbname=\"(.*)\"/){ 
	$db_id = $1."_computed_against_interpro_r15";
	$db = $3;
	$match = 1;
    }
    
    if($match){
	if($_ =~/location start=\"(\d+)\"\send=\"(\d+)\"\sscore=\"(.*)\"\sstatus/){
	    $start = $1;
	    $end = $2;
	    $score = $3;
	    if($score =~/(\d+)e-(\d+)/){
		$part1 = $1;
		$part2 = $2;
		if($part2 > 9){
		    $part2 = (1000 - $part2);
		    $part1 = $part1 * 100;
		    $score = $part2.".".$part1;
		    print RESULTS "$id\t$db::$db_id\t$score;$start-$end\n";
		    print RESULTS "$id\tIPR::$interpro_id\t$score;$start-$end\n";
		}
	    }
	    if($score eq "0"){
		print RESULTS "$id\t$db::$db_id\t0.0;$start-$end\n";
		print RESULTS "$id\tIPR::$interpro_id\t0.0;$start-$end\n";
	    }
	}
    }
}
close(IN);

print RESULTS "$genome\tInterpro_Domain_Computed\tRelease 15.0\n";
close(RESULTS);
