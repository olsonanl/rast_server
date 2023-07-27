
#
# Compute PCHs from a file of expanded similarities that are extended with
# contig location information.
#
# The data is of the form
#
# 0	id1                       10	sim score (psc)	     
# 1 	id2			  11	bit score	     
# 2	pct identity		  12	len1		     
# 3	alignment length	  13	len2		     
# 4 	mismatch count		  14	genome1		     
# 5	gap count		  15	contig1		     
# 6	beg1			  16	contig-beg1	     
# 7	end1			  17	contig-end1	     
# 8	beg2			  18	genome2		     
# 9	end2			  19	contig2		     
# 				  20	contig-beg2	     
# 				  21	contig-end2          
#
# PCH calculation algorithm:
#
# Filter expanded similarities to include only FIG->FIG sims.
# Sort on the following fields, in this order:
# 
#     genome1 contig1 contig-beg1
#
# This gives us blocks of data in order on each contig.
#
# Conceptually, we now walk a window down the given genome
# (genome1). For the pegs in that window, we find, for each
# genome matched on the id2 side of the sims, pairs of
# pegs that are within the specified window size. These
# form potential PCHs with the corresponding pairs of pegs
# in genome1.
#
# For each id1, we build a data structure
#
# [id1, genome1, contig1, contig-beg1, contig-end1]
#
# The %id1map points from id1 to the id1 data structure.
#
# We also build an id2map that points from id2 to a similar data structure.
#
# Sims are stored as lists of pairs [id1-data, id2-data]
#
# Our window on the genome1 is now simply a list of the ids in the window.  
#
# We keep a list of the id1 data that is currently in our window. As we move
# from peg to peg in the sims file, we add the new id1 and throw out old id1
# that is now outside the window.
#
# For each window, we form groups of id2s for each genome, and
# scan them for pegs that are themselves within a window
# genome and are close enough to form a PCH.
# 
# The program, in more detail now.
#
# An outer loop consolidates all id2 information for each id1 encountered.
# As each new id1 is completed, handle_id1 is invoked. This will readjust the
# contents of the current window if necessary, and compare the new id1 to each
# of the ids currently in the window.
#

use FIG;
use strict;
use Data::Dumper;
use FileHandle;

my $fig = new FIG;

my $window = 5000;
my $cutoff = 1.0e-20;

my @window;

my %id1map;
my %id2map;

@ARGV == 1  or @ARGV == 2 or die "Usage: $0 expanded-sims-file [output file]\n";

my $esims = shift;

my $out_fh = \*STDOUT;

my $outfile;
if (@ARGV)
{
    $outfile = shift;
    $out_fh = new FileHandle(">$outfile") or &fatal("cannot open $outfile: $!");
}

-f $esims or die "Sims file $esims not found\n";

my $fh = new FileHandle("sort -k 15,16 -k 17,17n $esims |");
$fh or die "Sort failed: $!\n";

my %seen;

my @input_state;

while (1)
{
    my($id1_ent, $id2_list, $sim_list) = read_input_chunk($fh, \@input_state, $cutoff);
    last unless $id1_ent;

    my @sim_list = sort { $a->[4] <=> $b->[4] } @$sim_list;
    # print Dumper($id1_ent);

    #
    # We have a new id1.
    #
    # Add it to the end of the current window.
    # Remove any pegs at the front of the window that are now too far.
    # Compute any PCHs that result from the new peg and the rest of the window.
    #
    
    my($id1, $len1, $genome1, $contig1, $beg1, $end1) = @$id1_ent;
    my $min = $beg1 < $end1 ? $beg1 : $end1;
    my $thresh = $min - $window;

    #
    # If id1 is on a different contig than the contigs in the window, we
    # empty the window and begin again.
    #
    if (@window)
    {
	my $cand = $window[0]->[0];
	my($id2, $len2, $genome2, $contig2, $beg2, $end2) = @$cand;

	if ($contig2 ne $contig1 or $genome2 ne $genome1)
	{
	    @window = ();
	}
    }

    while (@window)
    {
	my $cand = $window[0]->[0];
	my($id2, $len2, $genome2, $contig2, $beg2, $end2) = @$cand;
	my $max = $beg2 > $end2 ? $beg2 : $end2;
	
	if ($max < $thresh)
	{
	    # print "Remove $cand->[0]: max=$max thresh=$thresh (beg1=$beg1 end1=$end1 beg2=$beg2 end2=$end2)\n";
	    shift(@window);
	}
	else
	{
	    #
	    # Since our window is sorted, we are done.
	    #
	    last;
	}
    }
    push(@window, [$id1_ent, $sim_list]);
    my @sim_window = map { @{$_->[1]} } @window;
    # print "Window: ", join("\t", map { $_->[0]->[0] } @window), "\n";
    #
    # Because we have only pushed sim_lists into the window if they came from a block of sims
    # that have id1s within the sim window, the id2s in that list are all candidates for PCHs.
    #
    # The map call above collapses all of the sims entries for the contents of the current window.
    # (XXX Dups may show up)
    #
    # Elts in sim_window are [[id1, <other id1 info> ], [id2, len2, genome2, contig2, start2, end2], [ sim info ]]
    #
    # Sort the sim list by genome2/contig2/start2
    # 
    @sim_window = sort { $a->[1]->[2] cmp $b->[1]->[2] or $a->[1]->[3] cmp $b->[1]->[3]  or
			     $a->[1]->[4] <=> $b->[1]->[4] } @sim_window;

    # map { my $id1 = $_->[0]->[0]; my $x2 = $_->[1]; print join("\t", $id1, @$x2, "\n") } @sim_window;

    #
    # Now walk the sim_window looking for pegs on the id2 side that are
    # in the same genome and close enough. These become PCHs.
    #

    my $last_genome;
    my @glist;
    while (@sim_window)
    {
	my $ent = shift(@sim_window);
	my($id1_ent, $id2_ent, $sim_ent) = @$ent;

	if ($id2_ent->[2] ne $last_genome)
	{
	    if ($last_genome)
	    {
		if (@glist > 1)
		{
		    process_candidate_pchs(\@glist, $out_fh);
		}
		@glist = ();
	    }
	    $last_genome = $id2_ent->[2];
	}
	push(@glist, $ent);
    }
			     
#    print Dumper(\@sim_window);

#    exit if @window > 3;

}

sub process_candidate_pchs
{
    my($list, $out_fh) = @_;
    if (0)
    {
	print "Candidates: \n";
	for my $ent (@$list)
	{
	    my($id1_ent, $id2_ent, $sim_ent) = @$ent;
	    
	    print "$id1_ent->[0]\t$id2_ent->[0]\t$sim_ent->[8]\n";
	}
    }

    #
    # Walk a window down the id2 pegs.
    #
    # If when we add a peg to a window, and there are any pegs in there already,
    # we generate PCHs for each pair.
    #

    my @window;

    for my $ent (@$list)
    {
	#
	# id2_ent is the item we are adding to the window. Determine the
	# location that is $window_size from the smallest coord on id2's gene.
	#
	my($id1_ent, $id2_ent, $sim_ent) = @$ent;
	
	my($id2, $len2, $genome2, $contig2, $start2, $end2) = @$id2_ent;

	my $min = $start2 < $end2 ? $start2 : $end2;
	my $thresh = $min - $window;

	# print "Add $id2 $contig2 $start2 $end2 $thresh to window\n";
	
	while (@window)
	{

	    my $cand = $window[0]->[1];
	    my ($cid, $clen, $cgenome, $ccontig, $cstart, $cend) = @$cand;
	    my $cmax = $cstart > $cend ? $cstart : $cend;

	    # print "Examine $cid $ccontig $cstart $cend\n";
	    if ($ccontig ne $contig2 or $cmax < $thresh)
	    {
		#
		# Outside the window or on a different contig, remove.
		#
		# print "remove from window\n";
		shift(@window);
	    }
	    else
	    {
		#
		# Inside the window. Since the data is sorted, we are done.
		#
		# print "in window still\n";
		last;
	    }
	}

	#
	# Now anything that is in the window is a PCH with the new id.
	#
	
	for my $w (@window)
	{
	    my ($p11, $p12, $sim1) = @$ent;
	    my ($p21, $p22, $sim2) = @$w;

	    my $i11 = $p11->[0];
	    my $i12 = $p12->[0];
	    my $i21 = $p21->[0];
	    my $i22 = $p22->[0];

	    if ($i11 ne $i21 and $i12 ne $i22 and not $seen{$i11, $i12, $i21, $i22})
	    {
		print $out_fh join("\t", $i11, $i21, $i12, $i22, $sim1->[0], $sim2->[0], $sim1->[8], $sim2->[8]), "\n";
#		print "PCH: $i11 $i21 $i12 $i22 $sim1->[8] $sim2->[8]\n";
		$seen{$i11, $i12, $i21, $i22}++;
	    }
	}
	push(@window, $ent);
    }
}

#
# Read the next chunk of sims data. These are all the lines with the same
# id1. Use @$input_state as a buffer for the line of readahead we need.
sub read_input_chunk
{
    my($fh, $input_state, $cutoff)  = @_;

    my @id2_list;
    my @sim_list;
    my $cur_id;

    my($id1_ent, $id2_ent, $sim_info);
    if (!@$input_state)
    {
	my @line;
	while (<$fh>)
	{
	    chomp;
	    @line = split(/\t/);
	    if ($line[0] =~ /^fig/ and $line[1] =~ /^fig/)
	    {
		#print "Got initial line @line\n";
		last;
	    }
	}

	return unless defined($_);

	($id1_ent, $id2_ent, $sim_info) = proc_line(\@line);
    }
    else
    {
	($id1_ent, $id2_ent, $sim_info) = @$input_state;
	@$input_state = ();
    }

    my $cur_id1 = $id1_ent->[0];

    if ($id2_ent->[2] eq '')
    {
	die Dumper($id2_ent);
    }

    if ($sim_info->[8] <= $cutoff and $fig->is_prokaryotic($id2_ent->[2]))
    {
	push(@id2_list, $id2_ent);
	push(@sim_list, $sim_info);
    }

    while (<$fh>)
    {
	chomp;
	my @line = split(/\t/);
	if ($line[0] !~ /^fig/ or $line[1] !~ /^fig/)
	{
	    next;
	}
	my ($n_id1_ent, $id2_ent, $sim_info) = proc_line(\@line);
	if ($n_id1_ent->[0] ne $cur_id1)
	{
	    @$input_state = ($n_id1_ent, $id2_ent, $sim_info);
	    return ($id1_ent, \@id2_list, \@sim_list);
	}
	if ($id2_ent->[0] =~ /^fig/ and $sim_info->[8] <= $cutoff and $fig->is_prokaryotic($id2_ent->[2]))
	{
	    push(@id2_list, $id2_ent);
	    push(@sim_list, $sim_info);
	}
    }

    return ($id1_ent, \@id2_list, \@sim_list);
}

sub proc_line
{
    my($dat) = @_;

    my $i1 = [@$dat[0,12,14,15,16,17]];
    my $i2 = [@$dat[1,13,18,19,20,21]];
    my $sim = [@$dat[2,3,4,5,6,7,8,9,10,11]];

    return ($i1, $i2, [$i1, $i2, $sim]);
}
