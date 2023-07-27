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


$usage = "usage: compute_simple_scores MinSc < filtered.pchs > scored";
($minsc = shift @ARGV)
    || die $usage;

while (defined($_ = <STDIN>) && ($_ =~ /\t0$/)) {}
while ($_ && ($_ =~ /^(\S+\t\S+)/))
{
    $curr = $1;
    $n = 0;
    while ($_ && ($_ =~ /^(\S+\t\S+)/) && ($1 eq $curr))
    {
	$n++;
	while (defined($_ = <STDIN>) && ($_ =~ /\t0$/)) {}
    }

    if ($n >= $minsc)
    {
	print "$curr\t$n\n";
    }
}
