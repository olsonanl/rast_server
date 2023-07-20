# -*- perl -*-
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

use FIG;
use strict;

$0 =~ m/([\/]+)$/;
my $self = $1;
my $usage = "usage: 
                     filter_overlaps MinPEGln MaxRNA MaxConvOv MaxDivOv MaxSameStrand
                                     KeepTBL1 KeepTBL2 ... KeepTBLn 
                                     < superset_tbl_entries > to_keep_entries";

my($min_peg_ln,$max_RNA_overlap,$max_convergent_overlap,$max_divergent_overlap);
my($max_same_strand_overlap,$tbl,$fid,$type,$loc,$contig,$beg,$end);
(
 ($min_peg_ln               = shift @ARGV) &&
 ($max_RNA_overlap          = shift @ARGV) &&
 ($max_convergent_overlap   = shift @ARGV) &&
 ($max_divergent_overlap    = shift @ARGV) &&
 ($max_same_strand_overlap  = shift @ARGV)
)
    || die $usage;

my $parms = { min_peg_ln                => $min_peg_ln,
	      max_RNA_overlap           => $max_RNA_overlap,
	      max_convergent_overlap    => $max_convergent_overlap,
	      max_divergent_overlap     => $max_divergent_overlap,
	      max_same_strand_overlap   => $max_same_strand_overlap
	    };

print STDERR ("$self: parms=", &FIG::flatten_dumper($parms), "\n") if $ENV{VERBOSE};

my $fig = FIG->new();
# constants for positions in "keep" lists
use constant LEFT   => 0;
use constant RIGHT  => 1;
use constant STRAND => 2;
use constant TYPE   => 3;
use constant FID    => 4;

my $keep = {};
foreach $tbl (@ARGV)
{
    print STDERR "Loading $tbl ...\n" if $ENV{VERBOSE};
    
    foreach $_ (`cat $tbl`)
    {
	if ($_ =~ /^(fig\|\d+\.\d+\.([^\.]+)\.\d+)\t(\S+)/)
	{
	    ($fid,$type,$loc) = ($1,$2,$3);
	    ($contig,$beg,$end) = $fig->boundaries_of($loc);
	    if (defined($contig))
	    {
		push(@{$keep->{$contig}},
		     [&FIG::min($beg,$end),&FIG::max($beg,$end),($beg < $end) ? "+" : "-",$type,$fid]);
	    }
	}
    }
}

foreach $contig (keys(%$keep))
{
    my $x = $keep->{$contig};
    $keep->{$contig} = [sort { ($a->[LEFT]  <=> $b->[LEFT]) or
			       ($b->[RIGHT] <=> $a->[RIGHT]) } @$x];
}

my $entry;
while (defined($entry = <STDIN>))
{
    if ($entry =~ /^(fig\|\d+\.\d+\.([^\.]+)\.\d+)\t(\S+)/)
    {
	($fid,$type,$loc) = ($1,$2,$3);
	if ($type =~ /^(rna|orf|peg|cds)$/io)
	{
	    ($contig,$beg,$end) = $fig->boundaries_of($loc);
	    if (&keep_this_one($parms,$keep,$contig,$beg,$end,$fid))
	    {
		print $entry;
	    }
	}
	else
	{
	    die "Invalid type '$type' in entry:  $entry";
	}
    }
    else
    {
	die "Malformed tbl entry: $entry";
    }
}

sub keep_this_one
{
    my ($parms,$keep,$contig,$beg,$end,$fid) = @_;
    my ($ln, $x, @overlaps, $min, $max, $strand, $i);
    
    if (($ln = (abs($end-$beg)+1)) < $min_peg_ln)
    {
	print STDERR "$fid failed length test: $beg $end $ln $min_peg_ln\n" if $ENV{VERBOSE};
	return 0;
    }
    
    print STDERR "Processing "
	, join(", ", (&FIG::min($beg, $end), &FIG::max($beg, $end), (($beg < $end) ? "+" : "-"), "     $fid"))
	,  "\n" if $ENV{VERBOSE};
    if ($x = $keep->{$contig})
    {
	@overlaps = ();
	$min = &FIG::min($beg,$end);
	$max = &FIG::max($beg,$end);
	$strand = ($beg < $end) ? "+" : "-";
	for ($i=0; ($i < @$x) && ($min > $x->[$i]->[RIGHT]); $i++) {};
	while (($i < @$x) && ($max >= $x->[$i]->[LEFT]))
	{
	    print STDERR "   pushing ", join(", ", @ { $x->[$i] } )
		, "\t(", &overlap($min, $max, $x->[$i]->[LEFT],  $x->[$i]->[RIGHT]), ")"
		, "\n" if $ENV{VERBOSE};
	    push(@overlaps,$x->[$i]);
	    $i++;
	}
	
	my $serious = 0;
	for ($i=0; ($i < @overlaps); ++$i) 
	{
	    if (&serious_overlap($parms,$min,$max,$strand,$overlaps[$i],$fid)) { ++$serious; }
	}
	print STDERR "\n" if $ENV{VERBOSE};
	return ($serious == 0);
    }
    return 1;
}

sub overlap
{
    my ($min, $max, $minO, $maxO) = @_;
    my $olap = &FIG::max(0, (&FIG::min($max,$maxO) - &FIG::max($min,$minO) + 1));
    return $olap;
}

sub serious_overlap {
    my($parms,$min,$max,$strand,$overlap,$fid) = @_;
    my($minO,$maxO,$strandO,$typeO,$fidO) = @$overlap;
    
    my $olap = &overlap($min, $max, $minO, $maxO);
    
    if (&embedded($min,$max,$minO,$maxO))
    {
	print STDERR "$fidO [kept] is embedded in $fid\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (&embedded($minO,$maxO,$min,$max))
    {
	print STDERR "$fid is embedded in $fidO [kept]\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO eq "rna") && ($olap > $parms->{max_RNA_overlap}))
    {
	print STDERR "too much RNA overlap: $fid overlaps $fidO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO !~ /^rna/) && ($olap > $parms->{max_convergent_overlap})
       && &convergent($min,$max,$strand,$minO,$maxO,$strandO))

    {
	print STDERR "too much convergent overlap: $fid overlaps $fidO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO !~ /^rna/) && ($olap > $parms->{max_divergent_overlap})
       && &divergent($min,$max,$strand,$minO,$maxO,$strandO))

    {
	print STDERR "too much divergent overlap: $fid overlaps $fidO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO !~ /^rna/) && ($strand eq $strandO)
       && ($olap > $parms->{max_same_strand_overlap}))
    {
	print STDERR "too much same_strand overlap: $fid overlaps $fidO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    return 0;
}

sub embedded {
    my($min,$max, $minO,$maxO) = @_;

    if (($min <= $minO) && ($maxO <= $max))
    {
	return 1;
    }
    return 0;
}

sub convergent {
    my($min,$max,$strand,$minO,$maxO,$strandO) = @_;

    if (($strand ne $strandO) && 
	((($min < $minO) && ($strand eq "+")) ||
	 (($minO < $min) && ($strandO eq "+"))))
    {
	return 1;
    }
    return 0;
}

sub divergent {
    my($min,$max,$strand,$minO,$maxO,$strandO) = @_;

    if (($strand ne $strandO) && 
	((($min < $minO) && ($strand eq "-")) ||
	 (($minO < $min) && ($strandO eq "-"))))
    {
	return 1;
    }
    return 0;
}
