#
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
#

#
# Version of remove_clustered_pchs that does not use the genomeid/pegid form.
#
###########################################
#
# RAO: I have changed this to keep all PCHs, but adding a code (0 means "do not count in score")
#

use strict;

use DB_File;
use Data::Dumper;
use FIG;
use FIGV;
my $fig;

my %CloseCache;

use DBrtns;

my $usage = "usage: remove_clustered_pchs2 [-orgdir orgdir] [-cache genome-similarity-cache] CutOff < all_pchs > filtered_pchs";

my $cache;
my $orgdir;

while ((@ARGV > 0) && ($ARGV[0] =~ /^-/))
{
    my $arg = shift @ARGV;
    if ($arg =~ /^-orgdir/)
    {
	$orgdir = shift @ARGV;
    }
    elsif ($arg =~ /^-cache/)
    {
	$cache = shift @ARGV;
    }
    else
    {
	die "Unknown option $arg\n";
    }
}

my($cutoff);

@ARGV == 1 or die $usage;

(
 ($cutoff   = shift @ARGV) 
)
    || die $usage;

if ($orgdir)
{
    $fig = new FIGV($orgdir);
}
else
{
    $fig = new FIG;
}

my(%cache, $cache_tie);;
if ($cache)
{
    $cache_tie = tie %cache, 'DB_File', $cache, O_RDONLY, 0666, $DB_BTREE;
    $cache_tie or die "cannot tie $cache: $!\n";
    
}

my($keep, $discard);

my %closeness;

open(SORT, "sort -k 1,2 -k 5,5n |");
#my $pch = <STDIN>;
my $pch = <SORT>;
while ($pch && ($pch =~ /^(\S+\t\S+)/))
{
    my $curr = $1;
    my @set = ();

    #
    # The input is four "columns" of pegs, followed by two iden columsn and two paranN columns.
    # Each peg column is really a pair of numbers.
    #

    while ($pch and
	   $pch =~ /^((\S+)\t(\S+))\t   # first two. $1 is the pair.
	             (\S+)\t		    # third peg col, $4.
	             (\S+)\t		    # fourth peg col, $5
	   	     (\S+)\t(\S+)\t		    # and the iden  columns. $6 and $7
	   	     (\S+)\t(\S+)  	    	    # and the paran cols $8 and $9
	            /x and
	   ($1 eq $curr))
    {
	# warn "got 1='$1' 4='$4' 5='$5' 6='$6' 7='$7'\n";

	#
	# We remap the line for output.
	#

	my $remap = join("\t",
			 $2, $3, $4, $5,
			 $6, $7, $8, $9);
	my $max_iden = ($6 < $7) ? $7 : $6;
	push(@set,[$4,$5,$remap,$max_iden]);
	$pch = <SORT>;
    }
    &process_set(\@set);
}
warn "keep=$keep discard=$discard\n";


# You have a list of PCHs.  Basically, we sort them based on max % identity
# between the corresponding genes in each PCH.
#
# We are trying to build a set of PCHs (marked by 1s) such that
#
#    1. The % identity is below the cutoff for each PCH and
#
#    2. The % identity between the "other" pairs of the PCHs is
#       always below the cutoff.
#
# 

sub process_set {
    my($set) = @_;
    my($pch,$i);

#    warn "Process " . Dumper($set);

    my @unprocessed = sort { $a->[3] <=> $b->[3] } @$set;

    if (@unprocessed > 0)
    {
	while ($pch = shift @unprocessed)
	{
	    #
	    # $pch here is a triple (peg3, peg4, whole line from file)
	    #
	    if ($pch->[3] <= $cutoff)
	    {
		print $pch->[2] . "\t1\n";

		my $genome = $fig->genome_of($pch->[0]);

		for ($i = $#unprocessed; ($i >= 0); $i--)
		{
		    if (too_close($fig, $genome, $fig->genome_of($unprocessed[$i]->[0])))
		    {
			print $unprocessed[$i]->[2] . "\t0\n";
			splice(@unprocessed,$i,1);
		    }
		}
	    }
	    else
	    {
		print $pch->[2] . "\t0\n";
	    }
	}
    }
}

sub too_close
{
    my($fig, $g1, $g2) = @_;

    return 1 if $g1 eq $g2;
    
    #
    # Look in local cache.
    #

    my $close = $CloseCache{$g1};
    if (defined($close))
    {
	return $close->{$g2};
    }

    #
    # Look in tied cache.
    #

    my $tc = $cache{$g1, $g2};

    if (defined($tc))
    {
	return $tc;
    }

    #
    # See if we have cached values for the g1 genome.
    # If we do (and at some point, if g2 is not our virtual
    # organism), return 0 as there were apparently no sims.
    #
    if (exists($cache{$g1}))
    {
	return 0;
    }

    warn "computing similarity for $g1 g2=$g2\n";
    my @gsim = $fig->compute_genome_similarity($g1);

    $close = {};
    for my $ent (@gsim)
    {
	my($cg2, $is_sim) = @$ent;
	$close->{$cg2} = $is_sim;
    }
    $CloseCache{$g1} = $close;
    return $close->{$g2};
}
