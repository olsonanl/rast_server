#!/usr/bin/perl

########################################################################
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
############
#
# This little utility can be used as an initial pass in annotating the proteins within
# a genome.  We suggest that you try something like
#
# assign_using_ff ../FigfamsData.Release.1 < fasta.for.genome > assignments 2> could.not.assign
#
# for your favorite genome and evaluate the results
#
###########################

use Carp;
use Data::Dumper;

my $usage = "usage: assign_using_ff [-l] [-f] Dir";

my $dir;
my $loose = 0;
my $full = 0;
while ( $ARGV[0] =~ /^-/ )
{
    $_ = shift @ARGV;
    if       ($_ =~ s/^-l//) { $loose         = 1 }
    elsif    ($_ =~ s/^-f//) { $full          = 1 }
    else                     { print STDERR  "Bad flag: '$_'\n$usage"; exit 1 }
}

($dir = shift @ARGV)
    || die $usage;

use lib "$dir/../bin";
use FF;
use FFs;
my $figfams = new FFs($dir);


$line = <STDIN>;
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
    my($famO,undef) = $figfams->place_in_family($seq,undef,$loose);
    if ($famO)
    {
	my $func = $full ? $famO->family_function(1) : $famO->family_function;
	print join("\t",($id,$func)),"\n";
    }
    else
    {
	print STDERR "$id was not placed into a FIGfam\n";
    }
}
