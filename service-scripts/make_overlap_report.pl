# -*- perl -*-
########################################################################
# Copyright (c) 2003-2006 University of Chicago and Fellowship
# for Interpretations of Genomes. All Rights Reserved.
#
# This file is part of the SEED Toolkit.
#
# The SEED Toolkit is free software. You can redistribute
# it and/or modify it under the terms of the SEED Toolkit
# Public License.
#
# You should have received a copy of the SEED Toolkit Public License
# along with this program; if not write to the University of Chicago
# at info@ci.uchicago.edu or the Fellowship for Interpretation of
# Genomes at veronika@thefig.info or download a copy from
# http://www.theseed.org/LICENSE.TXT.
########################################################################

use strict;
use warnings;
use Data::Dumper;

use FIG;
my $fig = new FIG;

$0 =~ m/([^\/]+)$/;
my $this_tool_name = $1;

# First file is always the RNA file.
my $usage = "$this_tool_name [-h(elp)] [-parms=minlen,rna,conv,div,samestrand] ( OrgDir | Contigs Tbl_rna Tbl_2 Tbl_3 ... ) > detail 2> summary";

if ((not @ARGV) || ($ARGV[0] =~ m/^-h(elp)?/)) {
    die "\n   usage: $usage\n\n";
}

#...Default thresholds...
my $min_len            =  90;
my $max_rna            =  20;
my $max_convergent     =  50;
my $max_divergent      = 150;
my $max_normal_overlap = 120; # max allowable same-strand overlap

while (@ARGV && ($ARGV[0] =~ m/^-/))
{
    if ($ARGV[0] =~ m/-parms=(\d+),(\d+),(\d+),(\d+),(\d+)/) {
	($min_len, $max_rna, $max_convergent, $max_divergent, $max_normal_overlap)
	    = ($1, $2, $3, $4, $5);
	shift @ARGV;
    }
    else {
	die "Invalid arg $ARGV[0]\n\n   usage: $usage\n\n";
    }
}

if ($ENV{VERBOSE}) {
print STDERR <<END;

Thresholds:
min_len            = $min_len
max_rna            = $max_rna
max_convergent     = $max_convergent
max_divergent      = $max_divergent
max_normal_overlap = $max_normal_overlap

END
}


my $orgdir;
my $contigs_file;
my @tbl_files = ();
if ($contigs_file = shift @ARGV) {
    if (-d $contigs_file) {
	$orgdir =  $contigs_file;
	$orgdir =~ s/\/$//;
	$contigs_file = "$orgdir/contigs";
	@tbl_files = map { (-e $_) ? $_ : "/dev/null" } map { "$orgdir/Features/$_/tbl" } qw(rna peg orf);
    }
    elsif (-f $contigs_file) {
	@tbl_files = @ARGV;
    }
    else {
	die "\'$contigs_file\' is neither an existing file nor a directory\n\n   usage: $usage\n\n";
    }
}
else {
    die "No OrgDir or contigs file give\n\n   usage: $usage\n\n";
}

my $seq_of = &load_contigs($contigs_file);
my $tbl    = &load_tbl(@tbl_files);

use constant RNA     => 0;

use constant FID     => 0;
use constant TYPE    => 1;
use constant STRAND  => 2;
use constant START   => 3;
use constant STOP    => 4;
use constant LEFT    => 5;
use constant RIGHT   => 6;
use constant LEN     => 7;

use constant CONTIG  => 0;
use constant ID1     => 1;
use constant ID2     => 2;
use constant OVERLAP => 3;

my @bad_starts = ();
my @bad_stops  = ();
my @too_short  = ();

my @rna_overlaps         = ();
my @same_stop_pegs       = ();
my @embedded_pegs        = ();
my @same_strand_overlaps = ();
my @convergent_overlaps  = ();
my @divergent_overlaps   = ();
my @impossible_overlaps  = ();

my %start = map { $_ => 1 } qw(ATG GTG TTG ATN GTN TTN);
my %stop  = map { $_ => 1 } qw(TAA TAG TGA TAN TNA TGN TNG WAA TWW);

my %bad;
foreach my $contig (sort keys %$tbl)   # $tbl is the TBL files, ref to hash of contigs to lists of pegs
{
    my $contig_seq = $seq_of->{$contig};
    my $contig_len = length($contig_seq);
    
    my $x = $tbl->{$contig};
    for (my $i=0; $i < @$x; ++$i)
    {
	my ($fid, $type, $strand, $beg,$end, undef,undef, $len) = @ { $x->[$i] };

#...Checking for most serious type of problem: Invalid START or STOP codon. 
# If we find this problem for non-truncated features, entries for their FIDs
# in %bad will be set to 1, and details will be pushed onto appropriate list.
	
	# invalid starts and stops are okay near beginning and end of contigs
	my $truncated_start = 0;
	my $truncated_stop  = 0;  
	
	my $start = "";
	my $stop  = "";
	if (&type_of($fid) ne 'rna')
	{
	    if ($strand eq '+')
	    {
		$start = uc(substr($contig_seq, $beg-1, 3));
		$stop  = uc(substr($contig_seq, ($end-3), 3));
		
		if ($beg <= 300)                  { $truncated_start = 1; }
		if ($end >= ($contig_len - 300))  { $truncated_stop  = 1; }
	    }
	    else
	    {
		$start = substr($contig_seq, $beg-3, 3);
		$start = uc(&FIG::reverse_comp($start));
		
		$stop = substr($contig_seq, ($end-1), 3);
		$stop = uc(&FIG::reverse_comp($stop));
		
		if ($beg >= ($contig_len - 300))  { $truncated_start = 1; }
		if ($end <= 300)                  { $truncated_stop  = 1; }
	    }
	    
	    print STDERR "$fid may have truncated START\n" if ($truncated_start && $ENV{VERBOSE});
	    print STDERR "$fid may have truncated STOP\n"  if ($truncated_stop && $ENV{VERBOSE});	    
	    
	    unless ($truncated_start || $start{$start})
	    {
		$bad{$fid} = 1;
		push @bad_starts, [$fid, $strand, $start, $len, $truncated_start];
	    }
	    
	    unless ($truncated_stop  || $stop{$stop}) 
	    {
		$bad{$fid} = 1;
		push @bad_stops,  [$fid, $strand, $stop, $len, $truncated_stop];
	    }
	    
	    unless ($truncated_start || $truncated_stop || &is_rna($x, $i))
	    {
		if ($len < $min_len)
		{
		    $bad{$fid} = 1;
		    push @too_short, [$fid, $strand, $len, $truncated_start, $truncated_stop];
		}
	    }
	}
	
	
	for (my $j = &FIG::max(0, $i-100); $j < $i; ++$j)
	{
	    my $overlap = &overlaps($x->[$i]->[START], $x->[$i]->[STOP], $x->[$j]->[START], $x->[$j]->[STOP]);
	    
	    if ($overlap) # errors processed below are in order from most severe to least severe
	    {
		if    (&bad_rna_overlap($x, $i, $j) >= $max_rna) 
		{
		    $bad{$x->[$j]->[FID]} = 1;
		    push @rna_overlaps, [$contig, $i, $j, $overlap];
		}
		elsif (&bad_rna_overlap($x, $j, $i) >= $max_rna) 
		{
		    $bad{$x->[$i]->[FID]} = 1;
		    push @rna_overlaps, [$contig, $j, $i, $overlap];
		}
		elsif (&same_stop($x, $i, $j))
		{
		    #...NOTE: Special case of "embedded"...
		    
		    $bad{$x->[$i]->[FID]} = 1;
		    $bad{$x->[$j]->[FID]} = 1;
		    push @same_stop_pegs, [$contig, $i, $j, $overlap];
		}
		elsif ( &embedded($x, $i, $j) )
		{
		    $bad{$x->[$j]->[FID]} = 1;
		    push @embedded_pegs,  [$contig, $i, $j, $overlap];
		}
		elsif ( &embedded($x, $j, $i) )
		{
		    $bad{$x->[$j]->[FID]} = 1;
		    push @embedded_pegs,  [$contig, $j, $i, $overlap];
		}
		else
		{
		    if    (&same_strand($x, $i, $j))
		    {
			if (($_ = &normal_overlap($x, $i, $j)) >= $max_normal_overlap)
			{
			    $bad{$x->[$i]->[FID]} = 1;
			    $bad{$x->[$j]->[FID]} = 1;
			    push @same_strand_overlaps, [$contig, $j, $i, $overlap];
			}
		    }
		    elsif (&opposite_strand($x, $i, $j))
		    {
			if    ( &convergent($x, $i, $j) )
			{
			    if ($overlap >= $max_convergent)
                            {
				$bad{$x->[$i]->[FID]} = 1;
				$bad{$x->[$j]->[FID]} = 1;
				push @convergent_overlaps, [$contig, $j, $i, $overlap];
			    }
			}
			elsif ( &divergent($x, $i, $j) )
			{
			    if ($overlap >= $max_divergent)
			    {
				$bad{$x->[$i]->[FID]} = 1;
				$bad{$x->[$j]->[FID]} = 1;
				push @divergent_overlaps, [$contig, $j, $i, $overlap];
			    }
			}
			else
			{
			    $bad{$x->[$i]->[FID]} = 1;
			    $bad{$x->[$j]->[FID]} = 1;
			    push @impossible_overlaps, [$contig, $j, $i, $overlap];
			}
		    }
		    else
		    {
			$bad{$x->[$i]->[FID]} = 1;
			$bad{$x->[$j]->[FID]} = 1;
			push @impossible_overlaps, [$contig, $j, $i, $overlap];
		    }
		}
	    }
	}
    }
}


my $num_features = map { @ { $tbl->{$_} } } keys %$tbl;
print STDERR "Number of features:\t$num_features\n\n";

my $num_bad = (scalar keys %bad);

print STDOUT ("Bad STOP codons:\t", (scalar @bad_stops), "\n") if @bad_stops;
print STDERR ("Bad STOP codons:\t", (scalar @bad_stops), "\n") if @bad_stops;
foreach my $bad_stop (sort {$a->[0] cmp $b->[0]} @bad_stops)
{
    my $trunc = $bad_stop->[4] ? qq(,truncated) : qq();
    print STDOUT "$bad_stop->[0] ($bad_stop->[1],$bad_stop->[3]$trunc) has bad STOP codon \'$bad_stop->[2]\'\n";
}
print STDOUT "\n" if @bad_stops;


print STDOUT ("Bad START codons:\t", (scalar @bad_starts), "\n") if @bad_starts;
print STDERR ("Bad START codons:\t", (scalar @bad_starts), "\n") if @bad_starts;
foreach my $bad_start (sort {$a->[0] cmp $b->[0]} @bad_starts)
{
    my $trunc = $bad_start->[4] ? qq{,truncated} : qq{};
    print STDOUT "$bad_start->[0] ($bad_start->[1],$bad_start->[3]$trunc) has bad START codon '$bad_start->[2]'\n";
}
print STDOUT "\n" if @bad_starts;


print STDOUT ("Too short:\t", (scalar @too_short), "\n") if @too_short;
print STDERR ("Too short:\t", (scalar @too_short), "\n") if @too_short;
foreach my $too_short (sort {$a->[0] cmp $b->[0]} @too_short)
{
    my $trunc_start = $too_short->[3] ? qq{, truncated start} : qq{};
    my $trunc_stop  = $too_short->[4] ? qq{, truncated stop}  : qq{};
    print STDOUT "$too_short->[0] ($too_short->[1],$too_short->[2]$trunc_start$trunc_stop)\n";
}
print STDOUT "\n" if @too_short;


print STDOUT ("RNA overlaps:\t", (scalar @rna_overlaps), " over $max_rna bp\n")
    if @rna_overlaps;
print STDERR ("RNA overlaps:\t", (scalar @rna_overlaps), " over $max_rna bp\n")
    if @rna_overlaps;
foreach my $pair (sort by_overlap @rna_overlaps)
{
    &print_pair_report($pair, 'RNA overlap');
}
print STDOUT "\n" if @rna_overlaps;


print STDOUT ("Same-STOP PEGs:\t", (scalar @same_stop_pegs), "\n") if @same_stop_pegs;
print STDERR ("Same-STOP PEGs:\t", (scalar @same_stop_pegs), "\n") if @same_stop_pegs;
foreach my $pair (sort by_overlap @same_stop_pegs)
{
    &print_pair_report($pair, 'same-STOP');
}
print STDOUT "\n" if @same_stop_pegs;


print STDOUT ("Embedded PEGs:\t", (scalar @embedded_pegs), "\n") if @embedded_pegs;
print STDERR ("Embedded PEGs:\t", (scalar @embedded_pegs), "\n") if @embedded_pegs;
foreach my $pair (sort by_overlap @embedded_pegs)
{
    &print_pair_report($pair, 'embedded');
}
print STDOUT "\n" if @embedded_pegs;

print STDOUT ("Convergent overlaps:\t", (scalar @convergent_overlaps), " over $max_convergent bp\n")
    if @convergent_overlaps;
print STDERR ("Convergent overlaps:\t", (scalar @convergent_overlaps), " over $max_convergent bp\n")
    if @convergent_overlaps;
foreach my $pair (sort by_overlap @convergent_overlaps)
{
    &print_pair_report($pair, 'convergent overlap');
}
print STDOUT "\n" if @convergent_overlaps;


print STDOUT ("Divergent overlaps:\t", (scalar @divergent_overlaps), " over $max_divergent bp\n")
    if @divergent_overlaps;
print STDERR ("Divergent overlaps:\t", (scalar @divergent_overlaps), " over $max_divergent bp\n")
    if @divergent_overlaps;
foreach my $pair (sort by_overlap @divergent_overlaps)
{
    &print_pair_report($pair, 'divergent overlap');
}
print STDOUT "\n" if @divergent_overlaps;


print STDOUT ("Same-strand overlaps:\t", (scalar @same_strand_overlaps), " over $max_normal_overlap bp\n")
    if @same_strand_overlaps;
print STDERR ("Same-strand overlaps:\t", (scalar @same_strand_overlaps), " over $max_normal_overlap bp\n")
    if @same_strand_overlaps;
foreach my $pair (sort by_overlap @same_strand_overlaps)
{
    &print_pair_report($pair, 'same-strand');
}
print STDOUT "\n" if @same_strand_overlaps;


print STDOUT ("Impossible overlaps:\t", (scalar @impossible_overlaps), "\n") if @impossible_overlaps;
print STDERR ("Impossible overlaps:\t", (scalar @impossible_overlaps), "\n") if @impossible_overlaps;
foreach my $pair (sort by_overlap @impossible_overlaps)
{
    &print_pair_report($pair, 'impossible');
}
print STDOUT "\n" if @impossible_overlaps;


if ($num_bad) {
    print STDOUT   "$num_bad PEGs had problems\n";
    print STDERR "\n$num_bad PEGs had problems\n\n";
    # exit(1);
} else {
    print STDERR "\nNo problems found\n\n";
    # exit(0);
}
exit(0);


sub by_overlap
{
    return (($b->[OVERLAP] <=> $a->[OVERLAP]) || ($a->[ID1] <=> $b->[ID1]) || ($a->[ID2] <=> $b->[ID2]));
}

sub print_pair_report
{
    my ($pair, $msg, $threshold) = @_;
    $threshold = defined($threshold) ? $threshold : 0;
    
    my $x = $tbl->{$pair->[CONTIG]};
    my ($i, $j) = ($pair->[ID1], $pair->[ID2]);
    
    print "$x->[$i]->[FID]\t$x->[$j]->[FID]\t"
	, "($x->[$i]->[STRAND],$x->[$i]->[LEN] / $x->[$j]->[STRAND],$x->[$j]->[LEN]) $msg ($pair->[OVERLAP]bp)\n"
	if ($pair->[OVERLAP] > $threshold);
}


sub load_contigs
{
    my ($contigs_file) = @_;
    
    open (CONTIGS, "<$contigs_file") or die "Could not read-open $contigs_file";
    print STDERR "Loading contigs file $contigs_file ...\n" if $ENV{VERBOSE};
    
    my $contigs = {};
    my $num_contigs = 0;
    while ( (! eof(CONTIGS)) && ( my ($id, $seqP) = &get_a_fasta_record(\*CONTIGS) ) )
    {
	++$num_contigs;
    	$$seqP =~ tr/a-z/A-Z/;
	$contigs->{$id} = $$seqP;
    }
    print STDERR "Read $num_contigs contigs file $contigs_file\n\n" if $ENV{VERBOSE};
    
    return $contigs;
}


sub load_tbl
{
    my(@tbl_files) = @_;
    
    my %used;
    my $tbl = {};
    
    my $num_fids_total = 0;
    my $num_fids_kept  = 0;
    for (my $file_num=0; $file_num < @tbl_files; ++$file_num)
    {
	my $tbl_file = $tbl_files[$file_num];
	print STDERR "Loading tbl file $tbl_file ...\n" if $ENV{VERBOSE};
	
	my $num_fids_read = 0;
	open(TBL,"<$tbl_file") || die "Could not read-open $tbl_file";
	
	while (defined(my $entry = <TBL>))
	{
	    ++$num_fids_total;
            chomp $entry;
	    
	    if ($entry =~ /^(\S+)\s+(\S+)/)
	    {
		++$num_fids_read;
		my ($fid, $locus) = ($1, $2);
		if ($fig->is_genome($fig->genome_of($fid)) && $fig->is_deleted_fid($fid)) {
		    print STDERR "Skipping deleted feature $fid\n";
		}
		else {
		    my ($contig, $beg, $end) = $fig->boundaries_of($locus);
		    
		    my $len    = 1 + abs($end-$beg);
		    my $strand = ($beg < $end) ? q(+) : q(-);
		    
		    my $left   = &FIG::min($beg, $end);
		    my $right  = &FIG::max($beg, $end);
		    
		    if (not defined($tbl->{$contig})) {
			$tbl->{$contig} = [];
			print STDERR "   Creating tbl hash-entry for contig $contig\n"
			    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		    }
		    
		    if (not defined($used{$fid})) {
			if (defined($fid)    && defined($file_num) &&
			    defined($strand) && defined($beg)   && defined($end) &&
			    defined($left)   && defined($right) && defined($len)
			    ) {
			    ++$num_fids_kept;
			    push @ { $tbl->{$contig} }, [$fid,$file_num,$strand,$beg,$end,$left,$right,$len];
			    my $x = $tbl->{$contig};
			    $used{$fid} = $#$x;
			    print STDERR qq($contig\t$#$x:\t$entry\n);
			}
			else {
			    die qq(Bad entry: \'$entry\');
			}
		    }
		    else {
			$tbl->{$contig}->[$used{$fid}] = [$fid,$file_num,$strand,$beg,$end,$left,$right,$len];
			print STDERR "Overwriting entry for $fid\n" if $ENV{VERBOSE};
		    }
		}
	    }
	    else
	    {
		print STDERR "Skipping invalid entry $entry\n";
	    }
	}
	close(TBL);
	print STDERR "Scanned $num_fids_read features from $tbl_file\n\n" if $ENV{VERBOSE};
    }
    print STDERR "Read $num_fids_total FIDs --- kept $num_fids_kept\n\n" if $ENV{VERBOSE};
    
    foreach my $contig (keys(%$tbl))
    {
	my $x = $tbl->{$contig};
	print STDERR Dumper($contig, $x);
	
	if (defined($x) && (@$x > 0)) {
	    $tbl->{$contig} = [ sort {  ($a->[LEFT]  <=> $b->[LEFT])
				     || ($b->[RIGHT] <=> $a->[RIGHT]) } @$x ];
	}
    }

    return $tbl;
}


sub get_a_fasta_record
{
    my ($fh) = @_;
    my ( $old_eol, $entry, @lines, $head, $id, $seq );

    if (not defined($fh))  { $fh = \*STDIN; }

    $old_eol = $/;
    $/ = "\n>";

    $entry =  <$fh>;
    chomp $entry;
    @lines =  split( /\n/, $entry );
    $head  =  shift @lines;
    $head  =~ s/^>?//;
    $head  =~ m/^(\S+)/;
    $id    =  $1;

    $seq   = join( "", @lines );

    $/ = $old_eol;
    return ( $id, \$seq );
}


sub overlaps
{
    my ($beg1, $end1, $beg2, $end2) = @_;

    my ($left1, $right1, $left2, $right2);

    $left1  = &FIG::min($beg1, $end1);
    $left2  = &FIG::min($beg2, $end2);

    $right1 = &FIG::max($beg1, $end1);
    $right2 = &FIG::max($beg2, $end2);

    if ($left1 > $left2)
    {
        ($left1, $left2)   = ($left2, $left1);
        ($right1, $right2) = ($right2, $right1);
    }

    my $ov = 0;
    if ($right1 >= $left2) { $ov = &FIG::min($right1,$right2) - $left2 + 1; }

    return $ov;
}

sub type_of
{
    my ($id) = @_;
    
    if ($id =~ m/^fig\|\d+\.\d+\.([^\.]+)\.\d+$/) { return $1; }
    return undef;
}

sub is_rna
{
    my ($x, $i) = @_;

    return ($x->[$i]->[TYPE] == RNA);
}

sub same_strand
{
    my ($x, $i, $j) = @_;
    
    return ($x->[$i]->[STRAND] eq $x->[$j]->[STRAND]);
}

sub opposite_strand
{
    my ($x, $i, $j) = @_;

    return ($x->[$i]->[STRAND] ne $x->[$j]->[STRAND]);
}

sub bad_rna_overlap
{
    my ($x, $i, $j) = @_;

    #...For now, treat all RNA overlaps as "non-removable"
    if (&is_rna($x, $i) && (not &is_rna($x, $j))) {
	return &overlaps($x->[$i]->[START], $x->[$i]->[STOP],  $x->[$j]->[START], $x->[$j]->[STOP]);
    }
    else {
	return 0;
    }
}

sub embedded
{
    my ($x, $i, $j) = @_;
    
    my $left_i  = $x->[$i]->[LEFT];
    my $right_i = $x->[$i]->[RIGHT];
    
    my $beg_j   = $x->[$j]->[START];
    my $end_j   = $x->[$j]->[STOP];
    
    if (  &FIG::between($x->[$i]->[START], $x->[$j]->[START], $x->[$i]->[STOP])
       && &FIG::between($x->[$i]->[START], $x->[$j]->[STOP],  $x->[$i]->[STOP])
       )
    {
	return &overlaps($left_i, $right_i, $beg_j, $end_j);
    }

    return 0;
}

sub convergent
{
    my ($x, $i, $j) = @_;

    my $beg_i   = $x->[$i]->[START];
    my $end_i   = $x->[$i]->[STOP];

    my $beg_j   = $x->[$j]->[START];
    my $end_j   = $x->[$j]->[STOP];

    if (   &FIG::between($beg_i, $end_j, $end_i)
       &&  &FIG::between($beg_j, $end_i, $end_j)
       && !&FIG::between($beg_j, $beg_i, $end_j)
       && !&FIG::between($beg_i, $beg_j, $end_i)
       )
    {
	return &overlaps($beg_i, $end_i, $beg_j, $end_j);
    }

    return 0;
}

sub divergent
{
    my ($x, $i, $j) = @_;

    my $beg_i   = $x->[$i]->[START];
    my $end_i   = $x->[$i]->[STOP];

    my $beg_j   = $x->[$j]->[START];
    my $end_j   = $x->[$j]->[STOP];

    if (   &FIG::between($beg_i, $beg_j, $end_i)
       &&  &FIG::between($beg_j, $beg_i, $end_j)
       && !&FIG::between($beg_j, $end_i, $end_j)
       && !&FIG::between($beg_i, $end_j, $end_i)
       )
    {
	return &overlaps($beg_i, $end_i, $beg_j, $end_j);
    }

    return 0;
}

sub normal_overlap
{
    my ($x, $i, $j) = @_;
    
    if ($x->[$i]->[LEFT] > $x->[$j]->[LEFT]) {
	($i, $j) = ($j, $i);
    }
    
    my $beg_i    = $x->[$i]->[START];
    my $end_i    = $x->[$i]->[STOP];
    my $strand_i = $x->[$i]->[STRAND];
    
    my $beg_j    = $x->[$j]->[START];
    my $end_j    = $x->[$j]->[STOP];
    my $strand_j = $x->[$j]->[STRAND];
    
    if    (($strand_i eq '+') && ($strand_j eq '+'))
    {
	if (($beg_i < $beg_j) && ($beg_j <= $end_i) && ($end_i < $end_j))
	{
	    return &overlaps($beg_i, $end_i,  $beg_j, $end_j);
	}
    }
    elsif (($strand_i eq '-') && ($strand_j eq '-'))
    {
	if (($end_i < $end_j) && ($end_j <= $beg_i) && ($beg_i < $beg_j))
	{
	    return &overlaps($beg_i, $end_i,  $beg_j, $end_j);
	}
    }
    else
    {
	&impossible_overlap_warning($x, $i, $j, "Opposite strands in a normal_overlap");
	return 0;
    }
}


sub same_stop
{
    my ($x, $i, $j) = @_;

    my $end_i   = $x->[$i]->[STOP];
    my $end_j   = $x->[$j]->[STOP];

    if (  (not &is_rna($x, $i)) && (not &is_rna($x, $j))
       && &same_strand($x, $i, $j) && ($end_i == $end_j))
    {
	return 1;
    }
    else {
	 return 0;
    }
}


sub removable {
    my ($x, $i, $j) = @_;
    
    my $left_1  = $x->[$i]->[LEFT];
    my $right_1 = $x->[$i]->[RIGHT];
    
    my $beg_2   = $x->[$j]->[START];
    my $end_2   = $x->[$j]->[STOP];
    
    return (  
	      ($left_1 <= $beg_2) && ($beg_2 <= $right_1)
	   && 
	      (($end_2 < $left_1) || ($end_2 >  $right_1))
	   );
}



sub impossible_overlap_warning
{
    my ($x, $i, $j, $msg) = @_;
    
    if (defined($msg)) {
	print STDERR (q(Impossible overlap in $msg:),
		      qq(\n$i:\t),  join(qq(\t), @ { $x->[$i] }),
		      qq(\n$j:\t),  join(qq(\t), @ { $x->[$j] }),
		      qq(\n\n)
		      );
	
	confess( $msg );
    }
    else {
	print STDERR (q(Impossible overlap:),
		      qq(\n$i:\t),  join(qq(\t), @ { $x->[$i] }),
		      qq(\n$j:\t),  join(qq(\t), @ { $x->[$j] }),
		      qq(\n\n)
		      );
	
	confess( q(aborted) );
    }
    
    return 0;
}
