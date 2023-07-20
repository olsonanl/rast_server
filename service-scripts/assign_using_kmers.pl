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
use strict;
use Carp;
use Data::Dumper;
use DB_File;
use Kmers;
use Getopt::Long;

=head1 assign_using_kmers Script

=head2 Introduction

    assign_using_kmers [options] KmerData

Assign Using Kmers

This script takes a FASTA file of proteins from the standard input and writes
the function of each to the standard output. A local Kmers data set is used to determine the
function when possible. When not possible, a message will be written to the
standard error output.

=head2 Command-Line Options

=over 4

=item --kmer N

=item --all

=item --scoreThreshold N

=item --hitThreshold N

=item --seqHitThreshold N

=item --normalizeScores

=item --detailed

=cut

my $usage = "usage: assign_using_kmers [opts] KmerData< fasta > assignments 2> non-matched\n";


my %kmer_opts = (-kmer => 8 );
sub setopt {
    my($name, $val) = @_;
    #print "$name => $val\n";
    $kmer_opts{"-$name"} = $val;
}

my @opts = qw(kmer all scoreThreshold hitThreshold seqHitThreshold normalizeScores);

if (!GetOptions("kmer=i" => \&setopt,
		"all" => \&setopt,
		"scoreThreshold=f" => \&setopt,
		"hitThreshold=f" => \&setopt,
		"seqHitThreshold=f" => \&setopt,
		"normalizeScores" => \&setopt))
		
{
    die $usage;
}

my $kmers;
if (@ARGV == 1)
{
    #
    # Traditional usage.
    #
    my $kmerD = shift;
    $kmers = Kmers->new($kmerD);
}
elsif (@ARGV == 3)
{
    #
    # Experiment support - specify setI.db, FRI.db, table.binary
    #
    # Table will need to match the -kmer selected. That's up to the user,
    # if it doesn't the lookup later will fail.
    #
    my ($setI, $frI, $table) = @ARGV;
    $kmers = Kmers->new(-table => $table, -setIdb => $setI, -frIdb => $frI);
}
else
{
    die $usage;
}

$kmers or die "Could not create kmers object";

my $line = <STDIN>;
my @seqs;
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

    my @ans = $kmers->assign_functions_to_prot_set({ %kmer_opts, -seqs => [[$id, undef, $seq]] });

    for my $ans (@ans)
    {
	my($id,$func,$set,$score, $non_overlap_hits, $overlap_hits, $details) = @$ans;
	print join("\t", $id, $func, $score, $non_overlap_hits, $overlap_hits), "\n";
    }
}

