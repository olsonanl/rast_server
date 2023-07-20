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

package Assignments;

use Carp;
use Data::Dumper;
use FIG;
use SameFunc;

sub default_parms {

    my $x = <<END
external	sp	4
external	img	4
external	uni	1.3
external	kegg	1
external	gi	1
END
;
#
# TO PUT FIG ANNOTATIONS BACK IN ADD THE FOLLOWING LINE
#######################################################
#subsystems	trusted	20
#######################################################
# You may also improve things by adding lines like:
#
#genome	83333.1	15	Escherichia coli K12
#
#######################################################

    my @parms = split(/\n/,$x);
    my $fig = new FIG;
    my @trusted_subsystems = map { my $sub = $_; my $curr = $fig->subsystem_curator($sub); 
				   "$sub\t$curr\n" 
				 } 
                             grep { $fig->usable_subsystem($_) } 
                             $fig->all_subsystems;
    push(@parms,@trusted_subsystems,"//\n");
    return @parms;
}


sub choose_best_assignment {
    my($fig,$parms,$pegs,$external_ids,$ignore) = @_;
    my($peg,$id);

    my $functions = {};
    foreach $peg (@$pegs)
    {
	&load_peg_function($fig,$parms,$peg,$functions);
    }
    my @tmp = keys(%$functions);
    print STDERR &Dumper(['peg check',\@tmp,$functions]) if ($ENV{'DEBUG'} || $ENV{'VERBOSE'});

    if ((@tmp == 1) && (@$pegs >= 5)) { return $tmp[0] }

    foreach $id (@$external_ids)
    {
	&load_ext_function($fig,$parms,$id,$functions);
    }

    return &cleanup(&pick_function($fig,$parms,$functions));
}


sub cleanup {
    my($func) = @_;

    if (! $func)                                           { return "hypothetical protein" }
    if ($func =~ /^hypothetical (\S+ )?protein .*$/i)      { return "hypothetical protein" }
    if ($func =~ /^[a-zA-Z]{1,2}\d{2,5}( protein)?$/i)     { return "hypothetical protein" }
    if ($func =~ /^similar to ORF\d+$/)                    { return "hypothetical protein" }
    if ($func =~ /^(Alr|As|All|Tlr|Tll|Glr|Blr|Slr|SEW|pANL)\d+( protein)?$/i) { return "hypothetical protein" }
    if ($func =~ /^\d{5}/)                                 { return "hypothetical protein" }
    if ($func =~ /unknown protein/)                        { return "hypothetical protein" }
    
    return $func;
}

sub pick_function {
    my($fig,$parms,$functions) = @_;
    my($set,$score,$best_source,$poss_function);
    my(@scored);
    my @partitions = &SameFunc::group_funcs(keys(%$functions));
    if ($ENV{'VERBOSE'}) {  print STDERR "partition: ",&Dumper(\@partitions,$functions); }

    foreach $set (@partitions)
    {
	$score = &score_set($set,$functions);
	if ($ENV{'DEBUG'}) { print STDERR &Dumper([$score,$set]); }

        if ($ENV{'DEBUG'}) { print STDERR "picking from set ",&Dumper($set); }
	($poss_function,$best_source) = &pick_specific($fig,$parms,$set,$functions);
 	if ($ENV{'DEBUG'}) { print STDERR "picked $poss_function from $best_source\n"; }
	push(@scored,[$score,$poss_function,$best_source]);
    }
    @scored = sort { $b->[0] <=> $a->[0] } @scored;

    if ((@scored > 1) && $ENV{'VERBOSE'})
    {
	foreach $_ (@scored)
	{
	    print STDERR join("\t",@$_),"\n";
	}
	print STDERR "//\n";
    }
    return (@scored > 0) ? $scored[0]->[1] : "";
}

sub score_set {
    my($set,$functions) = @_;
    my($func,$x);

    my $score = 0;
    foreach $func (@$set)
    {
	if ($x = $functions->{$func})
	{
	    foreach $_ (@$x)
	    {
		$score += $_->[0];
	    }
	}
    }
    return $score;
}

sub pick_specific {
    my($fig,$parms,$set,$functions) = @_;
    my($best_func,$best_score,$func,$x,$best_source);

    $best_func  = "";
    $best_score = 0;
    $best_source = "";

    foreach $func (@$set)
    {
	if ($x = $functions->{$func})
	{
	    my $incr = @$x;
	    foreach $_ (@$x)
	    {
		my($sc,$peg,$in_sub) = @$_;
		$sc += $in_sub ? 10000 : 0;

		if (((100 * $sc) + $incr) > $best_score)
		{
		    $best_score = (100 * $sc) + $incr;
		    $best_func  = $func;
		    $best_source = $peg;
		}
	    }
	}
    }
    if ($ENV{'VERBOSE'}) { print STDERR &Dumper(["picked best source",$set,$functions,$best_func,$best_source]) }
    return ($best_func,$best_source);
}

sub load_ext_function {
    my($fig,$parms,$id,$functions) = @_;

    my $func = $fig->function_of($id);
    if ($func && # (! &FIG::hypo($func)) && 
	($id =~ /^([A-Za-z]{2,4})\|/) && ($_ = $parms->{'external'}->{$1}))
    {
	push(@{$functions->{$func}},[$_,$id]);
    }
}

sub load_peg_function {
    my($fig,$parms,$peg,$functions) = @_;

    my $func = $fig->function_of($peg);
    if ($func) # (! &FIG::hypo($func))
    {
	my $value = 1;

	my $genome = &FIG::genome_of($peg);
	if ($_ = $parms->{'genome'}->{$genome})
	{
	    $value += $_;
	}
	my $subv = 0;
	my @subs = ();
	foreach my $sub ($fig->peg_to_subsystems($peg))
	{
	    if (1) # (&solid_sub_assign($fig,$sub,$peg,$func))
	    {
		push(@subs,$sub);
	    }
	}
	my $sub;
	my $in_sub = 0;
	foreach $sub (@subs)
	{
	    if ($_ = $parms->{'subsystems'}->{$sub})
	    {
		if ($_ > $subv)
		{
		    $subv = $_;
		}
		$in_sub = 1;
	    }
	}
	$value += $subv;
	push(@{$functions->{$func}},[$value,$peg,$in_sub]);
    }
}

sub solid_sub_assign {
    my($fig,$sub,$peg,$func) = @_;

    my $curator = $fig->subsystem_curator($sub);
    $curator =~ s/^master://;
    return ($fig->usable_subsystem($sub) && &made_by_curator($fig,$peg,$func,$curator));
}

sub made_by_curator {
    my($fig,$peg,$func,$curator) = @_;

    my @ann = $fig->feature_annotations($peg,"rawtime");
    my $i;
    my $funcQ = quotemeta $func;
    for ($i=$#ann; 
	 ($i >= 0) && (($ann[$i]->[2] !~ /$curator/) || ($ann[$i]->[3] !~ /Set \S+ function to\n$funcQ/s));
	 $i--) {}
    return ($i >= 0);
}

sub equivalent_ids {
    my($fig,$parms,$pegs) = @_;
    my($peg,@aliases,$alias,%external_ids,%pegs,$tuple);

    foreach $peg (@$pegs)
    {
	$pegs{$peg} = 1;
	@aliases = $fig->feature_aliases($peg);
	foreach $alias (@aliases)
	{
	    if (($alias =~ /^([A-Za-z]{2,4})\|\S+$/) && $parms->{"external"}->{$1})
	    {
		$external_ids{$alias} = 1;
	    }
	}
	foreach $tuple ($fig->mapped_prot_ids($peg))
	{
	    if (($tuple->[0] =~ /^fig\|/) && $fig->is_real_feature($tuple->[0]))
	    {
		$pegs{$tuple->[0]} = 1;
	    }
	    elsif (($tuple->[0] =~ /^([A-Za-z]{2,4})\|\S+$/) && $parms->{"external"}->{$1})
	    {
		$external_ids{$tuple->[0]} = 1;
	    }
	}
    }
    return ([sort { &FIG::by_fig_id($a,$b) }  keys(%pegs)],[sort keys(%external_ids)]);
}

sub load_parms {
    my($parmsF) = @_;
    my @parmsS;

    my $wts = {};

    if ($parmsF)
    {
	@parmsS = `cat $parmsF`;
    }
    else
    {
	@parmsS = &default_parms;
    }
    while ($_ = shift @parmsS)
    {
	chomp;
	my($type,$data,$val) = split(/\t/,$_);
	if ($type eq 'subsystems')
	{
	    my $x;
	    while (($x = shift @parmsS) && ($x !~ /^\/\//))
	    {
		if ($x =~ /^(\S[^\t]+\S)/)
		{
		    $wts->{$type}->{$1} = $val;
		}
	    }
	}
	else
	{
	    $wts->{$type}->{$data} = $val;
	}
    }
    return $wts;
}

sub print_parms {
    my($parms) = @_;
    my($type,$data,$val,$wt_by_type);

    print STDERR "Parameters:\n";
    foreach $type (sort keys(%$parms))
    {
	print STDERR "\n\t$type\n";
	$wt_by_type = $parms->{$type};
	foreach $data (sort keys(%$wt_by_type))
	{
	    $val = $wt_by_type->{$data};
	    print STDERR "\t\t$data\t$val\n";
	}
    }
    print STDERR "\n";
}


1;
