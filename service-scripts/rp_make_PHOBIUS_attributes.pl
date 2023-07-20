my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);
my $date = localtime();

opendir(DIR,$jobdir."/rp/$genome");

if(! -d "$jobdir/rp/$genome/attributes"){
    `mkdir $jobdir/rp/$genome/attributes`;
}

open(PHOB,">$jobdir/rp/$genome/attributes/PHOBIUS_attributes_for_$genome.txt");

my @files = readdir(DIR);

print PHOB "$genome\tPhobius_run_on_remote_server\t$date\n";
foreach my $file (@files){
    if ($file =~/($genome.peg.\d+).PHOBIUS_result/){
	my $peg = "fig|".$1;
	open(IN,$jobdir."/rp/$genome/$file");
	my @tm_locations = ();
	while ($_ = <IN>){
	    if($_ =~/SIGNAL\s+(\d+)\s+(\d+)/){
		print PHOB "$peg\tPhobius::signal\t$1-$2\n";
	    }
	    if($_ =~/TRANSMEM\s+(\d+)\s+(\d+)/){
		my $loc = "$1-$2";
	        push(@tm_locations,$loc);
	    }
	}
	close(IN);
	if(scalar(@tm_locations) > 0){
	    my $loc_string = join(",",@tm_locations);
	    print PHOB "$peg\tPhobius::transmembrane\t$loc_string\n";
	}
    }
}

close(PHOB);

`rm $jobdir/rp/$genome/*.PHOBIUS_result`;
