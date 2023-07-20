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

use Assignments;

use FIG;
use FIGV;

$| = 1;

#usage: auto_assign [ParmFile] [sims=Sims] < list_of_peg_ids_and_seqs > assignments

use strict;

my($simsP,%sims,$computed_sims,$id1,$id2,$psc,$sim,$i);
$simsP = {};
$computed_sims = 0;
for ($i=0; ($i < @ARGV) && ($ARGV[$i] !~ /sims=/i); $i++) {}
if (($i < @ARGV) && ($ARGV[$i] =~ /^sims=(\S+)/) && open(SIMS,"<$1"))
{
    $computed_sims = 1;
    splice(@ARGV,$i,1);
    while (defined($_ = <SIMS>))
    {
	if (($_ =~ /^([^,]+),\d+,([^,]+),(\d+),[^,]+,([^,]+)/) || 
	    ($_ =~ /^([^\t]+)\t([^\t]+)(\t[^\t]*){8}\t([^\t]+)/))
	{
	    $id1 = $1; $id2 = $2; $psc = $4;
	    $sim = [$id1,
		    $id2,
		    undef,
		    undef,
		    undef,
		    undef,
		    undef,
		    undef,
		    undef,
		    undef,
		    $psc,
		    undef,
		    undef,
		    undef,
		    undef,
		    undef
		    ];
	    bless($sim,"Sim");
	    push(@{$sims{$id1}},$sim);
	}
    }
    close(SIMS);
    $simsP = \%sims;
}

my $parms;
my $orgdir;

while (@ARGV > 0)
{
    if ($ARGV[0] =~ /^-(\S+)/)
    {
	my $arg = $1;
	shift;
	if ($arg eq 'orgdir')
	{
	    $orgdir = shift;
	}
	else
	{
	    die "Unknown argument $arg\n";
	}
    }
    else
    {
	last;
    }
}

my $fig;
if ($orgdir)
{
    $fig = new FIGV($orgdir);
}
else
{
    $fig = new FIG;
}

if (@ARGV > 0)
{
    $parms = &Assignments::load_parms($ARGV[0]);
}
else
{
    $parms = &Assignments::load_parms();
}
# &Assignments::print_parms($parms);

my($prot,$sims,$based_on_sims,$based__on_neigh,$assignments,$seq);
my($based_on_neigh);
while (defined($_ = <STDIN>) && ($_ =~ /^(\S+)(\t(\S+))?/))
{
    $prot = $1;
    $seq  = $3 ? $3 : "";
    $sims             = &get_similarities($fig,$parms,$prot,$seq,$computed_sims,$simsP);
#print STDERR Dumper($prot, $sims);
    my($pegs,$external_ids) = &similar_ids($fig,$sims);
#    print STDERR &Dumper(["equiv.ids",$pegs,$external_ids]);

    my $best_function;
    if ($best_function = &Assignments::choose_best_assignment($fig,$parms,$pegs,$external_ids))
    {
	print "$prot\t$best_function\n";
    }
}

sub similar_ids {
    my($fig,$sims) = @_;
    my($sim,$id2);

    my $pegs = [];
    my $external_ids = [];

    foreach $sim (@$sims)
    {
	$id2 = $sim->id2;
	if ($id2 =~ /^fig/)
	{
	    if (@$pegs < 10)
	    {
		push(@$pegs,$id2);
	    }
	}
	elsif (@$external_ids < 20)
	{
	    push(@$external_ids,$id2);
	}
    }
    return ($pegs,$external_ids);
}

sub get_similarities {
    my($fig,$parms,$prot,$seq,$computed_sims,$sims) = @_;
    my(@sims,$x);

    my $cutoff = 1.0e-10;
    @sims = ();

    if ($computed_sims)
    {
	if ($x = $sims->{$prot}) { @sims = @$x }
    }
    elsif (! $seq)
    {
	@sims = $fig->sims($prot,80,$cutoff,"all");
    }
    return \@sims;
}

