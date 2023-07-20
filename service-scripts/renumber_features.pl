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

use strict;
use warnings;

use FIG;
my $fig = FIG->new();

my $usage = "renumber_features [-print_map] OrgD [> id.map]";

my $print_map;
my $trouble = 0;
while (@ARGV && ($ARGV[0] =~ m/^-/)) {
    if ($ARGV[0] =~ m/^-{1,2}print_map/) {
	$print_map = 1;
    }
    else {
	$trouble = 1;
	print STDERR "Invalid arg: $ARGV[0]\n";
    }
    shift @ARGV;
}
die "\nThere were invalid arguments.\n\n   usage: $usage\n\n" if $trouble;

my $orgD;
(($orgD = shift @ARGV) && (-d $orgD))
    || die "Non-existent genome directory: $orgD\n\n   usage: $usage\n\n";

opendir(FEAT,"$orgD/Features") || die "no Features directory";
my @types = grep { $_ !~ /^\./ } readdir(FEAT);
closedir(FEAT);

use constant FID     => 0;
use constant LOC     => 1;
use constant REST    => 2;
use constant CONTIG  => 3;
use constant LEFT    => 4;
use constant RIGHT   => 5;


my (%seen, $genome, @tbl, @entries, $entry, %trans, $to);

foreach my $type (@types)
{
    undef %seen;
    undef $genome;
    undef @tbl;
    
    if ((-s "$orgD/Features/$type/fasta") && (-s "$orgD/Features/$type/tbl"))
    {
	rename("$orgD/Features/$type/fasta", "$orgD/Features/$type/fasta~")
	    || die "could not rename $orgD/Features/$type/fasta";
	rename("$orgD/Features/$type/tbl", "$orgD/Features/$type/tbl~")
	    || die "could not rename $orgD/Features/$type/tbl";
	
	@entries = `cat $orgD/Features/$type/tbl~`;
	for (my $i=$#entries; ($i >= 0); $i--)
	{
	    $entry = $entries[$i];
	    chomp $entry;
	    
	    my ($fid, $loc, @rest) = split /\t/, $entry;
	    my $rest = join(qq(\t), @rest) || qq();
	    
	    if ($fid && (not $seen{$fid})) {
		$seen{$fid} = 1;
		if (! $genome) { $genome = $fig->genome_of($fid) }
		
		my ($contig, $beg, $end) = $fig->boundaries_of($loc);
		
		if (defined($contig) && ($contig ne '') && $beg && $end) {
		    my $left  = $fig->min($beg, $end);
		    my $right = $fig->max($beg, $end);
		    push(@tbl, [$fid, $loc, $rest, $contig, $left, $right]);
		}
		else {
		    die "Bad entry: $entry";
		}
	    }
	    else {
		die "Duplicate FID for entry: $entry";
	    }
	}
	
	
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# At this point @tbl is a list of features, each of which is
# [$fid, $contig, $start, $stop, $aliasesP]
#-----------------------------------------------------------------------
	open(OUT,">$orgD/Features/$type/tbl")
	    || die "could not open $orgD/Features/$type/tbl";
	
	@tbl = sort { ($a->[CONTIG] cmp $b->[CONTIG]) ||
		      ($a->[LEFT]   <=> $b->[LEFT])   ||
		      ($a->[RIGHT]  <=> $b->[RIGHT])
		  } @tbl;
	
	my $i = 1;
	foreach my $x (@tbl)
	{
	    my ($fid, $loc, $rest) = @$x;
	    $to = "fig\|$genome\.$type\.$i"; 
	    $trans{$fid} = $to;
	    print OUT "$to\t$loc\t$rest\n";
	    $i++;
	    print STDOUT "$fid\t$to\n" if $print_map;
	}
	close(OUT);
	
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Map the IDs in the FASTA file
#-----------------------------------------------------------------------
	open(IN,  "<$orgD/Features/$type/fasta~") || die "could not open $orgD/Features/$type/fasta~";
	open(OUT, ">$orgD/Features/$type/fasta")  || die "could not open $orgD/Features/$type/fasta";
	while (defined($_ = <IN>))
	{
	    if (($_ =~ /^>(\S+)/) && ($to = $trans{$1})) {
		print OUT ">$to\n";
	    }
	    else {
		print OUT $_;
	    }
	}
	
	if ($type eq qq(peg)) {
	    system(qq(formatdb -i $orgD/Features/$type/fasta -p T))
		&& warn(qq(!!! WARNING: formatdb failed on $orgD/Features/$type/fasta));
	}
    }
}

opendir(ORGD,$orgD) || die "could not open $orgD";
my @files = grep { $_ =~ /functions$/ } readdir(ORGD);
closedir(ORGD);

foreach my $file (@files)
{
    if (-s "$orgD/$file")    {  &trans("$orgD/$file", \%trans);  }
}

&trans("$orgD/found",        \%trans);
&trans("$orgD/called_by",    \%trans);
&trans("$orgD/annotations",  \%trans,  qq(no-sort), qq(//\n));

if (-s "$orgD/special_pegs") {
    &trans("$orgD/special_pegs", \%trans);
}

exit(0);

sub trans {
    my ($file, $trans, $nosort, $new_eor) = @_;
    
    my $to;
    if (rename("$file","$file~")) {
	my $old_eor;
	my $entry;
	my @lines = ();
	if ($new_eor) { ($old_eor, $/) = ($/, $new_eor); }
	
	open(IN, "<$file~") || die "could not open $file~";
	while (defined($entry = <IN>)) {
	    chomp $entry;
	    if ($entry =~ /^(\S+)\b(.*)$/so) {
		print STDERR ( qq(matched:\n),
			       qq(\$1 = "$1"\n),
			       qq(\$2 = "$2"\n),
			       qq(\n),
			       )
		    if $ENV{VERBOSE};
		
		if ($to = $trans->{$1}) {
		    push(@lines,"$to$2$/");
		}
		else {
		    print STDERR qq(!!! could not translate:\n$entry\n\n) if $ENV{VERBOSE};
		}
	    }
	    else {
		print STDERR "Did not match:\n$entry\n" if $ENV{VERBOSE};
	    }
	}
	close(IN);
	if ($new_eor) { $/ = $old_eor; }
	
	open(OUT,">$file") || die "could not open $file";
	if ($nosort) {
	    foreach $entry (@lines) {
		print OUT $entry;
	    }
	}
	else {
	    foreach $entry (sort { $a =~ /^fig\|\d+\.\d+\.([a-z]+)\.(\d+)/;
				   my ($x1, $x2) = ($1, $2); 
				   $b =~ /^fig\|\d+\.\d+\.([a-z]+)\.(\d+)/;
				   my ($y1, $y2) = ($1, $2); 
			       ($x1 cmp $y1) or ($x2 <=> $y2) } @lines)
	    {
		print OUT $entry;
	    }
	}
	close(OUT);
    }
}
	
