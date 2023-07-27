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
# Create a peg mapping file based on tbl files from two genome directories.
#-----------------------------------------------------------------------

use FIG;
use strict;
use FileHandle;

my $usage = "usage: make_peg_map_from_tbl gdir1 gdir2 [output-mapfile]";

@ARGV == 2 or @ARGV == 3 or die $usage;

my $from = shift @ARGV;
my $to   = shift @ARGV;
my $map  = shift @ARGV;

my $out_fh;
if ($map ne qq())
{
    $out_fh = new FileHandle(">$map");
    $out_fh or die "Cannot write output file $map: $!";
}
else
{
    $out_fh = \*STDOUT;
}

my %at;
my $line;
if (open(TBL, "cat $from/Features/*/tbl |")) {
    while (defined($line = <TBL>))  {
	chomp $line;
	my ($fid, $locus, @rest) = split /\t/o, $line;
	my ($contig, $beg, $end) = &FIG::boundaries_of($locus);
	
	# Keys of %at are of the form "contig <tab> end <tab> strand"
	my $key = join( qq(\t), ($contig, $end, (($beg < $end) ? qq(+) : qq(-))) );
	if ($contig && $beg && $end) {
	    $at{$key} = $fid;
	}
	else {
	    die "For 'from' file $from, could not parse line: $line";
	}
    }
    close(TBL);
}
else {
    die "Cannot open $from tbl files: $!";
}

if (open(TBL, "cat $to/Features/*/tbl |")) {
    while (defined($line = <TBL>)) {
	chomp $line;
	my ($fid, $locus, @rest) = split /\t/o, $line;
	my ($contig, $beg, $end) = &FIG::boundaries_of($locus);
	
	if ($contig && $beg && $end) {
	    my $key = join( qq(\t), ($contig, $end, (($beg < $end) ? qq(+) : qq(-))) );
	    
	    if (my $oldP = $at{$key}) {
		print $out_fh "$oldP\t$fid\n";
	    }
	}
	else {
	    die "For 'to' file $to, could not parse line: $line";
	}
    }
    close(TBL);
}
else {
    die "Cannot open $to tbl files: $!";
}

close($out_fh);

exit(0);
