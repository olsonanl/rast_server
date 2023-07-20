use LWP;
use URI;
use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

$fig = new FIGV("$jobdir/rp/$genome");

my @pegs = $fig->pegs_of($genome);
foreach my $peg (@pegs){
    $seq = $fig->get_translation($peg);
    if($peg =~/(\d+.\d+.peg.\d+)/){$peg = $1;}
    $file = $jobdir."/rp/$genome/$peg".".CELLO_result";
    open(OUT,">$file");
    
    #CELLO
    print OUT "\nXXXCELLOXXX\n";
    #temp Hack for JGI genonme
    my $species = "gramp";
#    if($gram eq "positive"){
#	$species = "gramp";
#    }
#    else{
#	$species = "pro";
#    }
    
    my $browser = LWP::UserAgent->new;
    $url = "http://cello.life.nctu.edu.tw/cgi/main.cgi";
    my $response = $browser->post($url,
				  [
				   'species' => $species,
				   'file' => " ",
				   'seqtype' => "prot",
				   'fasta' => $seq,
				       'Submit' => "Submit",
				   ]
				  );
    
    print OUT $response->content;
    close(OUT);
}

