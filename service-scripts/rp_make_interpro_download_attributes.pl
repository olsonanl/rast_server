my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $attribute_file =  "$jobdir/rp/$genome/attributes/interpro_download_attributes.txt";
my $crc64_mapping_file = "$jobdir/rp/$genome/crc64_for_pegs_of_$genome.txt";

open(RESULTS,">$attribute_file");

my @files = ("uniparc_match_1.dump","uniparc_match_2.dump","uniparc_match_3.dump","uniparc_match_4.dump","uniparc_match_5.dump","uniparc_match_6.dump","uniparc_match_7.dump");

my %id_crc;

open(IN,$crc64_mapping_file);
while($_ = <IN>){
    chomp($_);
    my ($id,$crc) = split("\t",$_);
    $id_crc{$crc} = $id;
}
close(IN);

my $interpro_download_dir = "/vol/seed-attributes/Interpro_Download_Dump";
foreach my $file (@files){
    open(IN,"$interpro_download_dir/$file");
    my $crc;
    my $db;
    my $db_id;

    my $id;
    my $bitscore;
    my $evalue;
    my $length;
    my $start;
    my $end;
    my $record = 0;

    my $interpro_id;
    
    while ($_ = <IN>){
	if($record){
	    if($_ =~ /match id=\"(\w+\d+)\".*dbname=\"(\w+)\"/){
		$db_id = $1;
		$db = $2;
	    }
	    
	    if($_ =~ /ipr id=\"(\w+\d+)\"/){
                $interpro_id = $1;
	    }
	    
	    if($_ =~ /lcn start=\"(\d+)\"\s+end=\"(\d+)\"\s+score=\"(.*)\"/){
		$start = $1;
		$end = $2;
		$bitscore = $3;
		my $db_size = 679928271;
		
		if($db){
		    print RESULTS "$id\t$db"."::$db_id"."_interpro_download\t$bitscore;$start-$end\n";
		    print RESULTS "$id\tIPR::$interpro_id"."_interpro_download\t$bitscore;$start-$end\n";
		}
	    }
	}
	
	if($_ =~/length=\"(\d+)\"\s+crc64=\"(.*)\"/){
	    $length = $1;           
            $crc = $2;
	    $record = 0;
	}
	if($id_crc{$crc}){
	    $id = $id_crc{$crc};
	    $record = 1;
	}
    }
    close(IN);
}

print RESULTS "$genome\tInterpro_Domain_Download\tRelease 15.0\n";
close(RESULTS);
