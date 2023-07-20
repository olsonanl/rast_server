# -*- perl -*-
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
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
#-----------------------------------------------------------------------

use strict;
use warnings;

use FIG;

# usage: pull_orfs MinSize [circular] [stops] < FastaSeqs > pulled_orfs

($#ARGV >= 0) || die "usage: pull_orfs MinSize [circular] [stops] [-dna] [-genetic_code=num] < FastaSeqs > pulled_orfs";

my $minsize = 90;
if (@ARGV && ($ARGV[0] =~ m/^\d+$/o)) {
    $minsize = shift @ARGV;
}

my $stops      = q((TAA|TAG|TGA));
my $circular   = 0;
my $dna_output = 0;
my $genetic_code_num = 11;

my $trouble = 0;
while (@ARGV) {
    if ($ARGV[0] =~ m/^-{1,2}dna$/o) {
	$dna_output = 1;
    }
    elsif ($ARGV[0] =~ m/^[-]{0,2}circular$/o) {
	$circular = 1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}genetic_code=(\d+)$/o) {
	$genetic_code_num = $1;
    }
    elsif ($ARGV[0] =~ m/^([ACGTMRWSYKBDHVN]{3}(,[ACGTMRWSYKBDHVN]{3})*)/io) {
	$stops = $1;
	$stops = "\(".join(q(|), split(/,/o, $stops))."\)";
	print STDERR "Using stops=$stops\n";
    }
    else {
	$trouble = 1;
	warn "Unrecognized argument: '$ARGV[0]'\n";
    }
    shift @ARGV;
}


if ($circular) {
    print STDERR "treating contigs as circular\n";
}
else {
    print STDERR "treating contigs as not circular\n";
}


my $trans_table_hashP;
if ($genetic_code_num) {
    $trans_table_hashP = FIG::genetic_code($genetic_code_num);
}
else {
    $trans_table_hashP = FIG::standard_genetic_code();
}


while (defined($_ = <STDIN>) && ($_ !~ /^>/)) {}
while ($_ && ($_ =~ /^>(\S+)/))
{
    my $contig_id = $1;
#   print STDERR "processing $1\n";
    my $seq = "";
    while (defined($_ = <STDIN>) && ($_ !~ /^>/))
    {
	$seq .= $_;
    }
    $seq =~ s/\s//g;
    $seq =~ tr/a-z/A-Z/;
    $seq =~ s/U/T/g;
    if ($seq =~ /([^ACGTMRWSYKBDHVN])/)
    {
	my $bad = "";
	while ($seq =~ s/([^ACGTMRWSYKBDHVN])//)
	{
	    $bad .= "$1 ";
	}
	print STDERR "not processing contig \'$contig_id\' due to bad characters: $bad\n";
    }
    else
    {
#	print STDERR "sequence was ok\n";
	&process_frame($contig_id, $seq, 1, 0);
	&process_frame($contig_id, $seq, 2, 0);
	&process_frame($contig_id, $seq, 3, 0);

	my $seqR = &FIG::rev_comp(\$seq);
	$seqR = $$seqR;

	&process_frame($contig_id, $seqR, 1, 1);
	&process_frame($contig_id, $seqR, 2, 1);
	&process_frame($contig_id, $seqR, 3, 1);
    }
}

sub process_frame {
    my ($contig_id, $seqin, $frame, $comp) = @_;
    my (@stps,$i,$ln,$x,$orf_ln,$start,$end,$seq);

#    print STDERR "processing frame $frame for\n$seqin\n";
    $seq = $seqin;

    $ln = length($seqin);
    my @stops = ();
    for ($i=$frame-1; $i <= ($ln-3); $i += 3)
    {
	$x = substr($seq,$i,3);
	if ($x =~ /$stops/i)
	{
	    push(@stops,$i);
	}
    }

#    print STDERR "stops before circular: @stops\n";
    if ($circular)
    {
	$seq = $seq . $seq;
    }
    else
    {
	unshift( @stops, $frame-1-3 ); # stop before first amino acid
	push( @stops, $i );            # next stop is past end
    }
    
    my $lnB = length($seq);
    while (($i <= ($lnB-3)) && ($x = substr($seq,$i,3)) && ($x !~ /$stops/))
    {
	$i += 3;
    }

    if ($i <= ($lnB-3))
    {
	push(@stops,$i);
    }
#    print STDERR "stops after circular: @stops\n";

    for ($i=0; $i < $#stops; $i++)
    {
	$orf_ln = $stops[$i+1] - ($stops[$i]+3);
	if ($orf_ln >= $minsize)
	{
	    my $dna_subseq = substr($seq,$stops[$i]+3,$orf_ln);
#	    print STDERR "sub=$dna_subseq\n";
	    $start = $stops[$i]+4;
	    $end   = $stops[$i+1];

	    if ($start > $ln)
	    {
		$start = $start - $ln;
	    }

	    if ($end > $ln)
	    {
		$end = $end - $ln;
	    }

	    if ($comp)
	    {
		$start = ($ln+1) - $start;
		$end   = ($ln+1) - $end;
	    }
	    
	    if ($dna_output) {
		print ">$contig_id\_$start\_$end\n$dna_subseq\n";
	    }
	    else {
		my $prot_seq = &FIG::translate($dna_subseq, $trans_table_hashP);
		print ">$contig_id\_$start\_$end\n$prot_seq\n";
	    }
	}
    }
}
