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

use FIGV;
use FF;
use FFs;
use Sim;
use GenomeMeta;

use Carp;

$0 =~ m/([^\/]+)$/;
my $self = $1;

my $usage = "$self [-code=genetic_code_number] [-meta=metafile] OrgDir";

my $trouble     =  0;
my $metafile    = "";
my $code_number = undef;
while (@ARGV && ($ARGV[0] =~ m/^-/)) {
    if ($ARGV[0] =~ m/-help/) {
	print STDERR "\n  usage:  $usage\n\n";
	exit(0);
    }
    elsif ($ARGV[0] =~ m/^-{1,2}code=(\d+)$/) {
	$code_number = $1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}meta=(\S+)$/) {
	$metafile = $1;
    }
    else {
	$trouble = 1;
	print STDERR "Invalid arg: $ARGV[0]\n";
    }
    
    shift @ARGV;
}

if ($trouble) {
    die "\nThere were invalid arguments.\n\n  usage:  $usage\n\n";
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Obselescent data...
#=======================================================================
# my %sizeof_figfam;
# my $ff_2c_file = qq($FIG_Config::FigfamsData/families.2c);
# open(FF_2C, qq(<$ff_2c_file)) || die qq(Could not read-open file=\'$ff_2c_file\');
# while (defined($_ = <FF_2C>)) {
#     chomp $_;
#     if ($_ =~ m/^(FIG\d{6})/o) {
# 	++$sizeof_figfam{$1};
#     }
#     else {
# 	die qq(In \'$ff_2c_file\', could not parse line=\'$_\');
#     }
# }
#-----------------------------------------------------------------------


my $org_dir;
(($org_dir = shift) && (-d $org_dir))
    || die (qq(OrgDir \"$org_dir\" does not exist), qq(\n\n   usage: $usage\n\n));

my $fig     = FIGV->new($org_dir);
my $figfams = FFs->new($FIG_Config::FigfamsData, $fig);

if (not defined($code_number)) {
    if (-s "$org_dir/GENETIC_CODE") {
	$_ = `cat $org_dir/GENETIC_CODE`;
	if ($_ =~ m/^(\d+)/o) {
	    $code_number = $1;
	    print STDERR "Using genetic code $code_number\n" if $ENV{VERBOSE};
	}
	else {
	    die "Could not handle contents of $org_dir/GENETIC_CODE: $_";
	}
    }
    else {
	#...Default to "standard" code...
	$code_number = 11;
    }
}


my $org_id;
if ($org_dir =~ m{(\d+\.\d+)/?}) {
    $org_id = $1;
}
else {
    die "Org-dir $org_dir does not end in a properly formated taxon-id";
}

my $meta;
if ($metafile) {
    $meta = GenomeMeta->new($org_id, $metafile);
    $meta->add_log_entry("qc", ["Resolving embedded PEGs", $org_id, $org_dir]);
    $ENV{VERBOSE} = $meta->get_metadata('env.verbose') || 0;
}


use constant  FID       =>  0;
use constant  LOC       =>  1;
use constant  CONTIG    =>  2;
use constant  START     =>  3;
use constant  STOP      =>  4;
use constant  LEFT      =>  5;
use constant  RIGHT     =>  6;
use constant  STRAND    =>  7;
use constant  LENGTH    =>  8;
use constant  NUM_FRAGS =>  9;
use constant  ENTRY     => 10;


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++    
#...Load feature coordinates...
#-----------------------------------------------------------------------
my @features = ();
my ($overlap, $num_overlaps, %skip);

my $rna_tbl = "$org_dir/Features/rna/tbl";
my $peg_tbl = "$org_dir/Features/peg/tbl";

if (!-s $peg_tbl) {
    die "zero-size $org_dir/Features/peg/tbl";
}
else {
    my $rna_tbl = (-s $rna_tbl) ? $rna_tbl : "/dev/null";
    
    foreach my $entry (`cat $rna_tbl $peg_tbl`) {
	chomp $entry;
	
	my ($fid, $loc) = split(/\t/o, $entry);
	my ($contig, $beg, $end) = $fig->boundaries_of($loc);
	
	my $len         = (1 + abs($end-$beg));
	my $strand      = ($end <=> $beg);
	
	my $left        = &min($beg, $end);
	my $right       = &max($beg, $end);
	
	my $num_frags   = (@_ = split(/,/o, $loc));
	
	push @features, [$fid, $loc, $contig, $beg, $end, $left, $right, $strand, $len, $num_frags, $entry];
    }
}
my $num_features = (scalar @features);
print STDERR "Read $num_features features from $org_dir\n" if $ENV{VERBOSE};

@features = sort {  ($a->[CONTIG] cmp $b->[CONTIG])
		 || ($a->[LEFT]   <=> $b->[LEFT])
		 || ($b->[RIGHT]  <=> $a->[RIGHT])
		 || ($a->[STRAND] <=> $b->[STRAND])
                 } @features;


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++    
#...Load PEG sequences...
#-----------------------------------------------------------------------
my ($fid, $seqP, %seq_of);
my $peg_fasta = "$org_dir/Features/peg/fasta";
if (-s $peg_fasta) {
    open(FASTA, "<$peg_fasta") || die "Could not read-open $peg_fasta";
    while(($fid, $seqP) = $fig->read_fasta_record(\*FASTA))
    {
	$seq_of{$fid} = $$seqP;
    }
    close(FASTA) || die "Could not close $peg_fasta";
}
else {
    die "No PEG sequence file $peg_fasta";
}


my %in_fam;
my %score_of;
for (my $i=0; ($i < @features); ++$i) {
    for (my $j=$i+1
	 ; (($j < @features) && ($overlap = &overlap($features[$i],$features[$j])))
	 ; ++$j) 
    {
	++$num_overlaps;
	
	if (&is_embedded($features[$i], $features[$j])
	    && (&is_peg($features[$j]->[FID]))
	    ) {
	    #... [$j] is embedded in [$i] ...
	    &process_embedded($i, $j);
	}
	
	if (&is_embedded($features[$j], $features[$i])
	    && (&is_peg($features[$i]->[FID]))
	    ) {
	    #... [$i] is embedded in [$j] ...
	    &process_embedded($j, $i);
	}
    }
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Back up original PEG calls and sequences...
#-----------------------------------------------------------------------
if (!-s "$peg_tbl~") {
    system("cp -p $peg_tbl $peg_tbl~") && die "Could not back up $peg_tbl to $peg_tbl~";
}
open(TBL, ">$peg_tbl")   || die "Could not write-open $peg_tbl";

if (!-s "$peg_fasta~") {
    system("cp -p $peg_fasta $peg_fasta~") && die "Could not back up $peg_fasta to $peg_fasta~";
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Dump out surviving PEG calls and sequences...
#-----------------------------------------------------------------------
open(FASTA, ">$peg_fasta") || die "Could not write-open $peg_fasta";
foreach my $feature (@features) {
    $fid = $feature->[FID];
    next if (&is_rna($fid));
    
    if (not $skip{$fid}) {
	print TBL "$feature->[ENTRY]\n";
	&FIG::display_id_and_seq($fid, \$seq_of{$fid}, \*FASTA);
    }
}
close(TBL)   || die "Could not close $peg_tbl";
close(FASTA) || die "Could not close $peg_fasta";


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Back up assignments, then dump out surviving assignments...
#-----------------------------------------------------------------------
my %assigned;
my $assigned  = "$org_dir/assigned_functions";
if (-f $assigned) {
    %assigned = map { m/^(\S+)\t([^\t\n]+)/;  $1 => $2 } `cat $assigned`;
    if (!-s "$assigned~") {
	rename($assigned, "$assigned~")
	    || die "Could not rename $assigned to $assigned~: $!";
    }
    
    open(FUNC, ">$assigned") || die "Could not write-open $assigned: $!";
    foreach my $fid (sort { &FIG::by_fig_id($a, $b) } keys %assigned) {
	if (not defined($skip{$fid})) {
	    print FUNC "$fid\t$assigned{$fid}\n";
	}
    }
    close(FUNC) || die "Could not close $assigned: $!";
}

exit(0);


sub is_peg {
    return ($_[0] =~ m/\.peg\./);
}

sub is_rna {
    return ($_[0] =~ m/\.rna\./);
}


sub is_in_family {
    my ($fid) = @_;
    
    my $fam   = $in_fam{$fid};
    my $score = $score_of{$fid};
    
    if (not defined($fam)) {
	my ($famO, $sims) = $figfams->place_in_family($seq_of{$fid});
	
	if (not $famO) {
	    $fam   = $in_fam{$fid}   = q();
	    $score = $score_of{$fid} = 0; 
	    print STDERR (qq(*** Caching $fid => \"\",\tscore => 0\n)) if $ENV{VERBOSE};
	}
	else {
	    $fam   = $in_fam{$fid}   = $famO->family_id();
	    $score = $score_of{$fid} = &score_sims($sims);
	    print STDERR (qq(*** Caching $fid => $fam,\tscore => $score\n)) if $ENV{VERBOSE};
	    print STDERR (qq(sims:\n), Dumper(map { &FIG::flatten_dumper($_) } @$sims))
		if ($ENV{VERBOSE} && ($ENV{VERBOSE} > 1));
	    print STDERR qq(\n) if $ENV{VERBOSE};
	}
    }
    
    return ($fam, $score);
}


sub score_sims {
    my ($sims) = @_;
    
    my $score = 0;
    foreach my $sim (@$sims) {
	$score += $sim->bsc();
# 	if ((($sim->e1() - $sim->b1()) > (0.7)*$sim->ln1()) &&
# 	    (($sim->e2() - $sim->b2()) > (0.7)*$sim->ln2())
# 	    ) {
# 	}
    }
    
    return $score;
}


sub process_embedded {
    my ($i, $j) = @_;
#... [$j] is embedded in [$i] ...
    
    my $fid_i = $features[$i]->[FID];
    my $fid_j = $features[$j]->[FID];
    
    return if ($skip{$fid_i} || $skip{$fid_j});
    
    if ($features[$i]->[LOC] eq $features[$j]->[LOC]) {
	print STDERR "$fid_j\t"
	    , "deleted in favor of\t"
	    , "$fid_i\t"
	    , "with identical locus\n"
	    if $ENV{VERBOSE};
	
	$skip{$fid_j} = 1;
	return
    }
    
    my $len_i = $features[$i]->[LENGTH];
    my $len_j = $features[$j]->[LENGTH];
    
    if (not &is_in_family($fid_j)) {
	print STDERR "$fid_j\t($len_j bp)\t"
	    , "is embedded in\t"
	    , "$fid_i\t($len_i bp)\t"
	    , "and is not in a family --- deleting (i=$i, j=$j)"
	    , "\n"
	    if $ENV{VERBOSE};
	
	$skip{$fid_j} = 1;
    }
    elsif (not &is_in_family($fid_i)) {
	print STDERR "$fid_i\t($len_i bp)\t"
	    , "contains\t"
	    , "$fid_j\t($len_j bp)\t"
	    , "and is not in a family --- deleting (i=$i, j=$j)"
	    , "\n"
	    if $ENV{VERBOSE};
	
	$skip{$fid_i} = 1;
    }
    else {
	#...Both PEGs are in families...
	
	if ($metafile) {
	    $meta->add_log_entry("qc", ["Embedded pair, both in families"
					, $in_fam{$fid_i}
					, $in_fam{$fid_j}]
				 );
	}

 	my $figfam_i = FF->new($in_fam{$fid_i}, $figfams);
 	my $figfam_j = FF->new($in_fam{$fid_j}, $figfams);
	
 	my $score_i  = $figfam_i->list_members();
 	my $score_j  = $figfam_j->list_members();
	
#	my $size_i   = $sizeof_figfam{$figfam_i};
#	my $size_j   = $sizeof_figfam{$figfam_j};
	
	if    ($score_i < (1/2) * $score_j) {
	    print STDERR "$fid_i\t"
		, "(len=$len_i, fam=$in_fam{$fid_i}, score=$score_i)\t"
		, "deleted in favor of\t"
		, "$fid_j\t"
		, "(len=$len_j, fam=$in_fam{$fid_j}, score=$score_j)\n"
		if $ENV{VERBOSE};
	    
	    $skip{$fid_i} = 1;
	}
	elsif ($score_j < (1/2) * $score_i) {
	    print STDERR "$fid_j\t"
		, "(len=$len_j, fam=$in_fam{$fid_j}, score=$score_j)\t"
		, "deleted in favor of\t"
		, "$fid_i\t"
		, "(len=$len_i, fam=$in_fam{$fid_i}, score=$score_i)\n"
		if $ENV{VERBOSE};
	    
	    $skip{$fid_j} = 1;
	}
	else {
	    my $num_frags_i = $features[$i]->[NUM_FRAGS];
	    my $num_frags_j = $features[$j]->[NUM_FRAGS];
	    
	    if (($num_frags_i > 1) && ($num_frags_j > 1)) {
		if ($num_frags_i < $num_frags_j) {
		    print STDERR "$fid_j\t"
			, "(len=$len_j, fam=$in_fam{$fid_j}, score=$score_j, num_frags=$num_frags_j)\t"
			, "deleted in favor of\t"
			, "$fid_i\t"
			, "(len=$len_i, fam=$in_fam{$fid_i}, score=$score_i, num_frags=$num_frags_i)\n"
			if $ENV{VERBOSE};
	    
		    $skip{$fid_j} = 1;
		}
		elsif (($num_frags_j < $num_frags_i)) {
		    print STDERR "$fid_i\t"
			, "($len_i bp, $in_fam{$fid_i}, score=$score_i, num_frags=$num_frags_i)\t"
			, "deleted in favor of\t"
			, "$fid_j\t"
			, "($len_j bp, $in_fam{$fid_j}, score=$score_j, num_frags=$num_frags_j)\n"
			if $ENV{VERBOSE};
		    
		    $skip{$fid_i} = 1;
		}
		else {
		    if    ($len_i < $len_j) {
			print STDERR "$fid_j\t"
			    , "(len=$len_j, fam=$in_fam{$fid_j}, score=$score_j, num_frags=$num_frags_j)\t"
			    , "deleted in favor of\t"
			    , "$fid_i\t"
			    , "(len=$len_i, fam=$in_fam{$fid_i}, score=$score_i, num_frags=$num_frags_i)\n"
			    if $ENV{VERBOSE};
			
			$skip{$fid_j} = 1;
		    }
		    elsif ($len_i < $len_j) {
			print STDERR "$fid_i\t"
			    , "(len=$len_i, fam=$in_fam{$fid_i}, score=$score_i, num_frags=$num_frags_i)\t"
			    , "deleted in favor of\t"
			    , "$fid_j\t"
			    , "(len=$len_j, fam=$in_fam{$fid_j}, score=$score_j, num_frags=$num_frags_j)\n"
			    if $ENV{VERBOSE};
			
			$skip{$fid_i} = 1;
		    }
		}
	    }
	    else {
		print STDERR "$fid_i\t"
		    , "(len=$len_i, fam=$in_fam{$fid_i}, score=$score_i)\t"
		    , "and\t"
		    , "$fid_j\t"
		    , "(len=$len_j, fam=$in_fam{$fid_j}, score=$score_j)\t"
		    , "are both in families, and have comparable scores --- skipping"
		    , "\n";
	    }
	}
    }
    print STDERR qq(\n) if $ENV{VERBOSE};
    
    return;
}



sub overlap {
    my ($p1, $p2) = @_;
    
    if ($p1->[CONTIG] ne $p2->[CONTIG]) {
	return 0;
    }
    
    my $left1  = &min($p1->[START], $p1->[STOP]);
    my $left2  = &min($p2->[START], $p2->[STOP]);
    my $right1 = &max($p1->[START], $p1->[STOP]);
    my $right2 = &max($p2->[START], $p2->[STOP]);
    
    if ($left1 > $left2)
    { 
	($left1, $left2)   = ($left2, $left1); 
	($right1, $right2) = ($right2, $right1);
    }
    
    my $olap = 0;
    if ($right1 >= $left2) { $olap = &min($right1,$right2) - $left2 + 1; }
    
    return $olap;
}

sub is_embedded {
    my ($p1, $p2) = @_;
    
    if ($p1->[CONTIG] ne $p2->[CONTIG]) {
	return 0;
    }
    
    if (  &between($p1->[START], $p2->[START], $p1->[STOP])
       && &between($p1->[START], $p2->[STOP],  $p1->[STOP])
       )
    {
	return 1;
    }
    
    return 0;
}

sub between {
    my ($x, $y, $z) = @_;
    
    if ($z < $x)   { ($x, $z) = ($z, $x); }
    return (($x <= $y) && ($y <= $z));
}

sub min {
    my ($x, $y) = @_;
    
    return (($x < $y) ? $x : $y);
}

sub max {
    my ($x, $y) = @_;
    
    return (($x > $y) ? $x : $y);
}
