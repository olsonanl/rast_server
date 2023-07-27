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
# Script derived from make_peg_maps, but optimized for the case of comparing
# two fasta files between which we wish to map.
#

use FIGV;
use FIG;
use strict;

my $usage = "usage: make_peg_maps fasta-from fasta-to mapfile";

my($from, $to, $maps);

(
 ($from = shift @ARGV) &&
 ($to   = shift @ARGV) &&
 ($maps = shift @ARGV)
)
    || die $usage;

#
# Determine the genome ID for each, and ensure that all the sequences
# in each file has the same id.
#

my($fromO, $toO);

if ($from =~ /(\d+\.\d+)$/ and -f "$from/GENOME")
{
    $fromO = $1;
    $from = "$from/Features/peg/fasta";
}
else
{
    $fromO = find_genome($from);
}

my $orgdir;
if ($to =~ /(\d+\.\d+)$/ and -f "$to/GENOME")
{
    $toO = $1;
    $orgdir = "-orgdir $to";
    $to = "$to/Features/peg/fasta";
}
else
{
    $toO = find_genome($to);
}

open(MAPS, ">$maps") or die "Cannot open $maps for writing: $!";

my $simsD = "$FIG_Config::temp/mapsims.$$";
mkdir($simsD, 0777) || die "could not mkdir $simsD: $!";

my $sims = "$simsD/$toO-$fromO";

&FIG::run("$FIG_Config::bin/sims_between $to $from p 98 0.7 > $sims");

my $sims = "$simsD/$fromO-$toO";

&FIG::run("$FIG_Config::bin/sims_between $from $to p 98 0.7 > $sims");

print "orgdir=$orgdir\n";
open(SETS, "$FIG_Config::bin/connections_between $orgdir $simsD 2 1 |") or
    die "Cannot open pipe from $FIG_Config::bin/connections_between $simsD 2 1: $!";

my %mapping;

while (<SETS>)
{
    chomp;
    if ($_ =~ /^(fig\|(\d+\.\d+)\.peg\.\d+)\t(fig\|(\d+\.\d+)\.peg\.\d+)$/)
    {
	if (($2 eq $fromO) && ($4 eq $toO))
	{
	    $mapping{$1} = $3;
	}
	elsif (($2 eq $toO) && ($4 eq $fromO))
	{
	    $mapping{$3} = $1;
	}
	else
	{
	    die "INVALID ORGS: $_";
	}
    }
}
close(SETS);

my $x;
foreach $_ (sort { $a =~ /(\d+)$\t/; $x = $1; $b =~ /(\d+)\t/; $x <=> $1 } keys(%mapping))
{
    print MAPS join("\t",($_,$mapping{$_})),"\n";
}
close(MAPS);
system("rm",  "-r", $simsD);

sub find_genome
{
    my($fa) = @_;
    my $g;
    open(F, "<$fa") or die "Cannot open fasta file $fa: $!";

    $_ = <F>;
    if (/^>fig\|(\d+\.\d+)\.peg/)
    {
	$g = $1;
    }
    else
    {
	die "Invalid fasta file $fa";
    }
    while (<F>)
    {
	if (/^>(\S+)/)
	{
	    my $id = $1;
	    if ($id !~ /^fig\|$g\.peg/)
	    {
		die "Invalid id $id found in $fa";
	    }
	}
    }
    close(F);
    return $g;
}
