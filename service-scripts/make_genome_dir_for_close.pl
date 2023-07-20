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

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# This program merges the assigned functions and aliases from
# an original directory (e.g., from a parsed RefSeq accession)
# into a genome directory produced by "rapid_propagation,"
# to create a final directory that can be imported into the SEED.
# -----------------------------------------------------------------------

use FIG;
use strict;
my $fig = new FIG;

my $usage = "usage: make_genome_dir_for_close OriginalGenomeDir CloseGenomeDir ReadyToGo";

my($origD, $closeD, $okD);
(
 ($origD      = shift @ARGV) && (-d $origD) &&
 ($closeD     = shift @ARGV) && (-d $closeD) &&
 ($okD        = shift @ARGV)
)
    || die $usage;

&FIG::verify_dir($okD);

system "cp -r $closeD/* $okD";
if (-s "$okD/assigned_functions") {
    system "mv $okD/assigned_functions $okD/proposed_functions";
}

my($entry, %valid, %at, %aliases);
if ((-d "$origD/Features") && open(TBL, "cat $origD/Features/*/tbl |"))
{
    while (defined($entry = <TBL>)) {
	chomp $entry;
	my ($fid, $loc, @aliases)   = split /\t/, $entry;
	my ($contig, $beg, $end, $strand) = $fig->boundaries_of($loc);
	if (defined($contig) && ($contig ne '') && $end && $strand)
	{
	    $valid{$fid}   = 1;
	    $at{qq($contig\t$end\t$strand)} = $fid;
	    $aliases{$fid} = join(qq(\t), @aliases);
	}
	else {
	    die "Could not parse TBL entry:\t$entry";
	}
    }
    close(TBL);
}

my(%old_func, %to, %from);

if (open(AF,"<$origD/assigned_functions")) {
    while (defined($entry = <AF>)) {
	if (($entry =~ /^(\S+)\t(\S.*\S)/) && $valid{$1}) {
	    $old_func{$1} = $2;
	}
    }
    close(AF);
}


if (open(TBL,"cat $closeD/Features/*/tbl |")) {
    while (defined($entry = <TBL>)) {
	chomp $entry;
	if ($entry =~ /^(\S+)\t(\S+)/) {
	    my ($fid, $loc) = ($1, $2);
	    my ($contig, $beg, $end, $strand) = $fig->boundaries_of($loc);
	    if (defined($contig) && ($contig ne '') && $end && $strand) {
		if (my $oldP = $at{qq($contig\t$end\t$strand)})	{
		    $to{$oldP}  = $fid;
		    $from{$fid} = $oldP;
		}
	    }
	    else {
		die "Could not parse TBL entry:\t$entry";
	    }
	}
    }
    close(TBL);
}


if (open(ORIG,"<$origD/assigned_functions")) {
    open(NEW,">$okD/assigned_functions") || die "could not open $okD/assigned_functions";
    while (defined($entry = <ORIG>)) {
	if (($entry =~ /^(\S+)\t(\S.*\S)/) && (my $new_fid = $to{$1})) {
	    my $func = $old_func{$1};
	    print NEW "$new_fid\t$func\n";
	}
    }
    close(NEW);
}


if (-s "$okD/Features/peg/tbl") {
    rename("$okD/Features/peg/tbl","$okD/Features/peg/tbl~")
	|| die "could not rename $okD/Features/peg/tbl~";
    
    open(IN,  "<$okD/Features/peg/tbl~") || die "could not open $okD/Features/peg/tbl~";
    open(OUT, ">$okD/Features/peg/tbl")  || die "could not open $okD/Features/peg/tbl";
    
    my($old, $extra);
    while (defined($entry = <IN>)) {
	if ($entry =~ /^(\S+)\t(\S+)/) {
	    my $peg = $1;
	    my $loc = $2;
	    if (($old = $from{$peg}) && ($extra = $aliases{$old})) {
		print OUT "$peg\t$loc\t$extra\n";
	    }
	    else {
		print OUT $entry;
	    }
	}
    }
    close(IN);
    close(OUT);
}
