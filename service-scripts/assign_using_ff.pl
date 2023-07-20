#### #!/usr/bin/perl

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

my $usage = "usage: assign_using_ff [-md5skip] [-d] [-l] [-f] [-n] [-p] [-b] Dir [output_file] < input_file [ > [output_file] >& [stderr]]\n";
$usage .= "Flags:\n";
$usage .= "-d\tdebug mode\n";
$usage .= "-l\tloose mode\n";
$usage .= "-f\tprint FIGfam and assignment only\n";
$usage .= "-n\tplace nucleotide sequences in FIGfam\n";
$usage .= "-p\tprint full output which includes FIGfam assigned, top similarities. Each entry is separated by '\\' characters\n";
$usage .= "-b\tplace_in_family with bulk method (bulk is 50 sequences at a time)\n";
$usage .= "\n";
$usage .= "Input:\n";
$usage .= "Dir\tprovide the FIGfam directory\n";
$usage .= "input_file\tprovide the input fasta file in STDIN\n";
$usage .= "OutputFile\toutput file is optional, otherwise, you can output to STDERR and STDOUT\n\n";

$usage .= "Output:\n";
$usage .= "Output for all queries, including the ones with no assignment can be directed to a specific file by specifying the output_file parameter.\n";
$usage .= "If you want to have separate files for assigned and not assigned, pipe the output to STDOUT for assigned, and STDERR for not_assigned queries.\n\n";

my $dir;
my $debug;
my $loose = 0;
my $full = 0;
my $bulk;
my ($print_sims, $nuc, $stats);
while ( $ARGV[0] =~ /^-/ )
{
    $_ = shift @ARGV;
    if       ($_ =~ s/^-l//)   { $loose         = 1 }
    elsif    ($_ =~ s/^-md5skip//){$skipmd5       = 1 }
    elsif    ($_ =~ s/^-s//)   { $stats         = 1 }
    elsif    ($_ =~ s/^-f//)   { $full          = 1 }
    elsif    ($_ =~ s/^-d//)   { $debug         = 1 }
    elsif    ($_ =~ s/^-n//)   { $nuc           = 1 }
    elsif    ($_ =~ s/^-p//)   { $print_sims    = 1 }
    elsif    ($_ =~ s/^-b//)   { $bulk          = 1 }
    elsif    ($_ =~ s/^-h//)   { print $usage; exit 1 }
    else                     { print STDERR  "Bad flag: '$_'\n$usage"; exit 1 }
}

($dir = shift @ARGV)
    || die $usage;

($proc = shift @ARGV);

use FF;
use FFs;
my $figfams = new FFs($dir);
my $bulk_seqs = [];
my $max = 50;
my $all_blast_stats={};
my ($fh_out, $fh_err);

if ($proc)
{
    $fh_out = \*OUT;
    $fh_err = \*OUT;
    open ($fh_out, ">>$proc");
    open (STATS, ">>$proc".".stats") if ($stats);
}
else
{
    $fh_out = \*STDOUT;
    $fh_err = \*STDERR;
}

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
    
    if ($bulk){
	push (@$bulk_seqs, ">$id\n$seq\n");
	if (scalar @$bulk_seqs >= $max){
	    my ($output) = $figfams->place_in_family_bulk($bulk_seqs,$debug,undef,undef,$nuc,$skipmd5);
	    $bulk_seqs = [];
	    &report($output,$full,$print_sims,$fh_out,$fh_err);
	}
	else{
	    next;
	}
    }
    else{
	my($famO,$sims,$blast_stats) = $figfams->place_in_family($seq,$debug,$loose,undef,$nuc,$skipmd5);
	
	foreach my $familyname (sort keys %$blast_stats)
	{
	    $all_blast_stats->{$familyname}++;
	    #print STATS "$familyname\t".$blast_stats->{$familyname}."\n";
	}

	if ($famO)
	{
	    my $func = $full ? $famO->family_function(1) : $famO->family_function;
	    my $fam = $full ? $famO->family_id(1) : $famO->family_id;
	    if ($print_sims){
		#print OUT join("\t",($id,$fam,$func)),"\n";
		print $fh_out join("\t",($id,$fam,$func)),"\n";
		foreach my $sim (@$sims){
		    #print OUT join ("\t", @$sim),"\n";
		    print $fh_out join ("\t", @$sim),"\n";
		}
		#print OUT "\t//\n";
		print $fh_out "\t//\n";
	    }
	    elsif ($full)
	    {
		#print OUT join("\t",($id,$fam,$func)),"\n";
		print $fh_out join("\t",($id,$fam,$func)),"\n";
	    }
	    else{
		#print OUT join("\t",($id,$func)),"\n";
		print $fh_out join("\t",($id,$func)),"\n";
	    }
	    
	}
	else
	{
	    #print OUT "$id was not placed into a FIGfam";
	    print $fh_err "$id was not placed into a FIGfam";
	    if ($print_sims){
		#print OUT "\t//\n";
		print $fh_err "\t//\n";
	    }
	    else {
		#print OUT "\n";
		print $fh_err "\n";
	    }
	}
    }
}

if ( (scalar @$bulk_seqs > 0) && ($bulk) ){
    ($output) = $figfams->place_in_family_bulk($bulk_seqs,$debug,undef,undef,$nuc,$skipmd5);
    &report($output, $full, $print_sims,$fh_out,$fh_err);
}

#close OUT;
close $fh_out;

if ($stats)
{
    foreach my $family (sort {$all_blast_stats->{$b}<=>$all_blast_stats->{$a}} keys %$all_blast_stats)
    {
	print STATS join("\t",($family,$all_blast_stats->{$family})) . "\n";
    }
    close STATS;
}

sub report{
    my ($output,$full,$print_sims,$fh_out,$fh_err) = @_;

    foreach my $id (keys %$output)
    {
	my ($got, $sims) = @{$output->{$id}};
	#my ($id, $got, $sims) = @$out;
	if ($got){
            my $func = $full ? $got->family_function(1) : $got->family_function;
            my $fam = $full ? $got->family_id(1) : $got->family_id;
	    if ($full)
	    {
		#print OUT join("\t",($id,$fam,$func)),"\n";
		print $fh_out join("\t",($id,$fam,$func)),"\n";
	    }
            elsif ($print_sims)
	    {
                #print OUT join("\t",($id,$fam,$func)),"\n";
                print $fh_out join("\t",($id,$fam,$func)),"\n";
                foreach my $sim (@$sims){
                    #print OUT join ("\t", @$sim),"\n";
                    print $fh_out join ("\t", @$sim),"\n";
                }
                #print OUT "\t//\n";
                print $fh_out "\t//\n";
            }
            else
	    {
                #print OUT join("\t",($id,$func)),"\n";
                print $fh_out join("\t",($id,$func)),"\n";
            }

        }
        elsif (!$full)
        {
            #print OUT "$id was not placed into a FIGfam";
            print $fh_err "$id was not placed into a FIGfam";
            if ($print_sims){
                #print OUT "\t//\n";
                print $fh_err "\t//\n";
            }
            else {
                #print OUT "\n";
                print $fh_err "\n";
            }
	}
    }
}

