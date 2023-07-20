use LWP;
use URI;
use FIGV;

my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);

my $fig = new FIGV("$jobdir/rp/$genome");

my @pegs = $fig->pegs_of($genome);
foreach my $peg (@pegs){
    my $seq = $fig->get_translation($peg);
    if($peg =~/(\d+.\d+.peg.\d+)/){$peg = $1;}
    my $file = $jobdir."/rp/$genome/$peg".".PHOBIUS_result";
    open(OUT,">$file");
    my $browser = LWP::UserAgent->new;
    my $url = "http://phobius.sbc.su.se/cgi-bin/predict.pl";
    my $response = $browser->post($url,
				  [
				   'protseq' => "$seq",
				   'format' => "nog",
				   'Submit' => "Submit"
				   ]
				      );
    print OUT $response->content;
    close(OUT);
    sleep(1);
}
