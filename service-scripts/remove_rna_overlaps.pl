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

use FIG;
my $fig = FIG->new();

use GenomeMeta;

$0 =~ m/([^\/]+)$/;
my $self = $1;

my $usage = "$self  [-code=genetic_code_number] [-max=overlap (Default: 10)] [-meta=metafile]  OrgDir";

my $trouble     =  0;
my $max_overlap = 10;
my $metafile    = "";
my $code_number = undef;
while (@ARGV && ($ARGV[0] =~ m/^-/)) {
    if ($ARGV[0] =~ m/-{1,2}help/) {
	print STDERR "\n  usage:  $usage\n\n";
	exit(0);
    }
    elsif ($ARGV[0] =~ m/^-{1,2}code=(\d+)$/) {
	$code_number = $1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}max=(\d+)$/) {
	$max_overlap = $1;
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

my $org_dir;
(($org_dir = shift) && (-d $org_dir)) || die "OrgDir $org_dir does not exist";

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
    $meta->add_log_entry("qc", ["Removing PEGs that overlap RNAs", $org_id, $org_dir]);
    $ENV{VERBOSE} = $meta->get_metadata('env.verbose') || 0;
}

use constant  FID     =>  0;
use constant  CONTIG  =>  1;
use constant  START   =>  2;
use constant  STOP    =>  3;
use constant  LENGTH  =>  4;
use constant  ENTRY   =>  5;

my @features = ();
my ($overlap, $num_overlaps, %skip);
my ($rna_tbl, $peg_tbl, $peg_fasta);
my ($fid, $seqP, %seq_of);

if (!-s "$org_dir/Features/peg/tbl") {
    die "zero-size $org_dir/Features/peg/tbl";
}
else {
    $rna_tbl = (-s "$org_dir/Features/rna/tbl") ? "$org_dir/Features/rna/tbl" : "/dev/null";
    $peg_tbl = "$org_dir/Features/peg/tbl";
    
    foreach my $entry (`cat $rna_tbl $peg_tbl`) {
	chomp $entry;
	my ($fid, $loc) = split /\t/, $entry;
	
	my ($contig, $beg, $end) = $fig->boundaries_of($loc);
	if ($contig && $beg && $end) {
	    my $len = 1 + abs($end-$beg);
	    push @features, [$fid, $contig, $beg, $end, $len, $entry];
	}
	else {
	    die "Could not parse location $loc";
	}
    }
    my $num_features = (scalar @features);
    print STDERR "Read $num_features features from $org_dir\n" if $ENV{VERBOSE};
    
    @features = sort {  ($a->[CONTIG] cmp $b->[CONTIG])
                     || (&min($a->[START],$a->[STOP]) <=> &min($b->[START],$b->[STOP]))
                     || (&max($b->[START],$b->[STOP]) <=> &max($a->[START],$a->[STOP]))
                     } @features;
    
    $peg_fasta = "$org_dir/Features/peg/fasta";
    open(FASTA, "<$peg_fasta") || die "Could not read-open $peg_fasta";
    while (($fid, $seqP) = $fig->read_fasta_record(\*FASTA)) {
	$seq_of{$fid} = $$seqP;
    }
    close(FASTA) || die "Could not close $peg_fasta";
    
    for (my $i=0; ($i < @features); ++$i) {
	for (my $j=$i+1
	    ; (($j < @features) && ($overlap = &overlap($features[$i],$features[$j])))
	    ; ++$j) 
	{
	    if ($overlap > $max_overlap) {
		if (($features[$i]->[FID] =~ m/\.rna\./) && ($features[$j]->[FID] =~ m/\.peg\./)) {
		    ++$num_overlaps; 
		    print STDERR "$features[$i]->[FID]\t($features[$i]->[LENGTH])"
			, "\toverlaps\t"
			, "$features[$j]->[FID]\t($features[$j]->[LENGTH])\t",
			, "by $overlap\n"
			if $ENV{VERBOSE};
		    
		    $skip{$features[$j]->[FID]} = 1;
		}
		
		if (($features[$j]->[FID] =~ m/\.rna\./) && ($features[$i]->[FID] =~ m/\.peg\./)) {
		    ++$num_overlaps; 
		    print STDERR "$features[$j]->[FID]\t($features[$j]->[LENGTH])"
			, "\toverlaps\t"
			, "$features[$i]->[FID]\t($features[$i]->[LENGTH])\t",
			, "by $overlap\n"
			if $ENV{VERBOSE};
		    
		    $skip{$features[$i]->[FID]} = 1;
		}
	    }
	}
    }
    
    if (!-s "$peg_tbl~") {
	system("cp -p $peg_tbl $peg_tbl~") && die "Could not back up $peg_tbl to $peg_tbl~";
    }
    
    if (!-s "$peg_fasta~") {
	system("cp -p $peg_fasta $peg_fasta~") && die "Could not back up $peg_fasta to $peg_fasta~";
    }
    
    open(TBL,   ">$peg_tbl")   || die "Could not write-open $peg_tbl";
    open(FASTA, ">$peg_fasta") || die "Could not write-open $peg_fasta";
    foreach my $feature (@features) {
	next if ($feature->[FID] =~ m/\.rna\./);
	if (not $skip{$feature->[FID]}) {
	    my $seq = $seq_of{$feature->[FID]};
	    print TBL "$feature->[ENTRY]\n";
#	    print STDERR "$feature->[FID],\t$feature->[ENTRY],\t$seq_of{$feature->[FID]}\n";
	    &FIG::display_id_and_seq($feature->[FID], \$seq, \*FASTA);
	}
    }
    close(FASTA) || die "Could not close $peg_fasta";
    close(TBL)   || die "Could not close $peg_tbl";
}

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
