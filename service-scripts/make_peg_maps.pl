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
my $fig = new FIG;

my $usage = "usage: make_peg_maps Organisms1 Organisms2 Maps < OldNew.pairs";

(
 ($from = shift @ARGV) &&
 ($to   = shift @ARGV) &&
 ($maps = shift @ARGV)
)
    || die $usage;

&FIG::verify_dir($maps);

my $tmpG = "$FIG_Config::temp/genomes$$";
mkdir("$tmpG",0777) || die "could not make $tmpG";

&FIG::verify_dir("$tmpG/Seqs");
while (defined($_ = <STDIN>))
{
    if ($_ =~ /^(\d+\.\d+)\t(\d+\.\d+)$/)
    {
	$fromO = $1;
	$toO   = $2;

	&FIG::run("cp $from/$fromO/Features/peg/fasta $tmpG/Seqs/$fromO");
	&FIG::run("cp $to/$toO/Features/peg/fasta $tmpG/Seqs/$toO");
	&FIG::run("sims_all p 98 0.7 $tmpG/Seqs $tmpG/Sims $fromO $toO");
	&FIG::run("connections_between $tmpG/Sims 2 1 2> $tmpG/stderr > $tmpG/sets");
	undef %mapping;

	foreach $_ (`cat $tmpG/sets`)
	{
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
	open(TMP,">$maps/$fromO-$toO") || die "could not make $maps/$fromO-$toO";
	foreach $_ (sort { $a =~ /(\d+)$\t/; $x = $1; $b =~ /(\d+)\t/; $x <=> $1 } keys(%mapping))
	{
	    print TMP join("\t",($_,$mapping{$_})),"\n";
	}
	close(TMP);
	&FIG::run("rm -r $tmpG/*");
	&FIG::verify_dir("$tmpG/Seqs");
    }
    else
    {
	die "INVALID LINE: $_";
    }
}
system("rm -r $tmpG");
