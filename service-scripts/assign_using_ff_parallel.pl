#use strict;
use FIG;
my $fig = new FIG;
my $usage = "usage: assign_using_ff_parallel [-d] [-l] [-f] [-n] [-p] Dir nodes [outputF]";

my ($dir,$procs,$outD);
my $debug;
my $loose = 0;
my $full = 0;
my ($print_sims, $nuc);
while ( $ARGV[0] =~ /^-/ )
{
    $_ = shift @ARGV;
    if       ($_ =~ s/^-l//)   { $loose         = 1 }
    elsif    ($_ =~ s/^-f//)   { $full          = 1 }
    elsif    ($_ =~ s/^-b//)   { $bulk           = 1 }
    elsif    ($_ =~ s/^-d//)   { $debug         = 1 }
    elsif    ($_ =~ s/^-n//)   { $nuc           = 1 }
    elsif    ($_ =~ s/^-p//)   { $print_sims    = 1 }
    else                       { print STDERR  "Bad flag: '$_'\n$usage"; exit 1 }
}

($dir = shift @ARGV)
    || die $usage;

($procs = shift @ARGV) 
    || ($procs = 8);

($outF = shift @ARGV);

use FF;
use FFs;
my $figfams = new FFs($dir);

my @args;
push (@args, "-l") if $loose;
push (@args, "-d") if $debug;
push (@args, "-n") if $nuc;
push (@args, "-p") if $print_sims;
push (@args, "-f") if $full;
push (@args, "-b") if $bulk;

my $seen = {};
if ($outF){
    my @outfiles = glob ("$outF*");
    $\="\t//\n";

    foreach my $file (@outfiles){
	open (FH, "<$file");
	while (my $result = <FH>){
	    my ($id) = $result =~ /^(.*?)\s/;
	    $seen->{$id} =1;
	}
	close FH;
    }
    $\="\n";
}

print STDERR "Complete: " . scalar( keys %$seen) . "\n";

my $arg = join " ", @args;
my @procs = &start_procs("assign_using_ff $arg $dir", $outF, $procs);

my $nextP = 0;
my $line = <STDIN>;
while ($line && ($line =~ /^>(\S+)/))
{
    my $id = $1;
    my @seq = ();
    while (defined($line = <STDIN>) && ($line !~ /^>/))
    {
	$line =~ s/\s//g;
	push(@seq,$line);
    }
    my $seq = join("",@seq);
    $total++;
    if ($seen->{$id}){
	delete $seen->{$id};
	next;
    }
    $total_submit++;
    
    # get filehandle
    my $fh = $procs[$nextP];
    #print STDERR *$fh . "\n";
    #print STDERR "$fh $id\n";
    print $fh ">$id\n$seq\n";
    $nextP = ($nextP == $#procs) ? 0 : $nextP+1;
}
print STDERR "Total seqs: $total\n";
print STDERR "Submitted seqs: $total_submit\n";


&close_procs(\@procs);

my @outs = glob ("out_*");
foreach my $file (@outs){
    `cat $file`;
    #unlink $file;
}

sub start_procs {
    my($cmd, $outF, $procsN) = @_;
    
    my @procs = ();
    for (my $i=1;$i<=$procsN;$i++){
	my $fh = "F".$i;
	open($fh,"| $cmd $outF") || die $i;
#	open(F1,"| $cmd") || die $i;
	my $ofh = select $fh; $| = 1; select $ofh;
	push(@procs,\*$fh);
	print STDERR "starting process $i\n";
    }
    return @procs;
}

sub close_procs {
    my($procs) = @_;
    my $proc;

    for (my $i=0; ($i < @$procs); $i++)
    {
	print STDERR "CLOSING ",$i+1,"\n";
	my $fh = $procs->[$i];
	print $fh "x\n";
	close($fh);
	print STDERR "CLOSED ",$i+1,"\n";
    }
}


