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

use strict;
use DB_File;

my $usage = "usage: reformat_sims NR [optional additional fasta files] < sims > reformatted.sims";

die $usage unless ($ARGV[0]);

my @hashes;
my %ln;

push(@hashes, \%ln);

foreach my $fa (@ARGV) 
{
    if ($fa =~ /\.btree$/)
    {
	my $h = {};
	my $t = tie %$h, 'DB_File', $fa, O_RDONLY, 0, $DB_BTREE;
	$t or die "Cannot tie $fa as a btree\n";
	unshift(@hashes, $h);
    }
    else
    {
	open(FA, "<$fa") || die "Can't read $fa";
	
	$/ = "\n>";
	while (defined($_ = <FA>))
	{
	    chomp;
	    if ($_ =~ /^>?(\S+)[^\n]*\n(.*)/s)
	    {
		my $id  =  $1;
		my $seq =  $2;
		$seq =~ s/\s//gs;
		$ln{$id} = length($seq);
	    }
	}
	close(FA);
    }
}
$/ = "\n";
print STDERR "reformat_sims finished reading NR and other files\n";

my $last = "";
my $last_count = 0;
my %seen;
while (defined($_ = <STDIN>))
{
    chop;
    my ($id1,$id2,$iden,$ali_ln,$mis,$gaps,$b1,$e1,$b2,$e2,$psc,$bsc) =
	map { s/\s//g; $_ } split(/\t/,$_);

    if ($last eq "$id1,$id2")
    {
	++$last_count;
    }
    else
    {
	$last = "$id1,$id2";
	$last_count = 1;
    }

    if (($id1 ne $id2) && ($psc < 1.0e-2) && ($last_count < 3) &&
	((! $seen{$id1}) || ($seen{$id1} < 5) || ($psc < 1.0e-5)))
    {
	my($ln1, $ln2);
	for my $h (@hashes)
	{
	    $ln1 = $h->{$id1};
	    last if defined($ln1);
	}
	for my $h (@hashes)
	{
	    $ln2 = $h->{$id2};
	    last if defined($ln2);
	}
	if (defined($ln1) and defined($ln2))
	{
	    print join("\t",($id1,$id2,$iden,$ali_ln,$mis,$gaps,$b1,$e1,$b2,$e2,$psc,$bsc,$ln1,$ln2)),"\n" 
		or die "Error writing to stdout: $!";
	    ++$seen{$id1};
	}
	else
	{
	    print STDERR "failed: $_\n";
	}
    }
}
