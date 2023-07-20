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

use Carp;
use Data::Dumper;

use FIG;
use FIGV;

use FS_RAST;
use FF;
use FFs;
use gjoseqlib;

$0 =~ m/([^\/]+)$/;
my $self = $1;

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# We assume that the OrgDir contains either a "clestest.genomes" file
# or a "neighbors" file that gives the nearest neighboring genomes.
# We assume the genomes are sorted by some approximation to distance.
# We use the nearest two genomes to provide template PEGs
# for seeking potential frameshifts and fixing them.
#
# (Correction will be skipped for any PEGs in the "special_pegs" file,
# since the algorithm will sometimes edit out selenocystine codons.)
#-----------------------------------------------------------------------

my $usage = "$self [-nofatal] [-code=genetic_code_number] [-justMark] OrgDir";

my $trouble     = 0;
my $nofatal     = 0;
my $just_mark   = 0;
my $code_number = undef;
while (@ARGV && ($ARGV[0] =~ m/^-/)) {
    if ($ARGV[0] =~ m/-help/) {
	print STDERR "\n  usage:  $usage\n\n";
	exit(0);
    }
    elsif ($ARGV[0] =~ m/^-{1,2}nofatal$/) {
	$nofatal = 1;
    }
    elsif (($ARGV[0] =~ m/^-{1,2}justMark$/) ||
	   ($ARGV[0] =~ m/^-{1,2}just_mark$/)
	   ) {
	$just_mark = 1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}code=(\d+)$/) {
	$code_number = $1;
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
my $figV = FIGV->new( $org_dir );

if (not defined($code_number)) {
    if (-s "$org_dir/GENETIC_CODE") {
	$_ = $figV->file_read(qq($org_dir/GENETIC_CODE));
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

if ($just_mark) { unlink "$org_dir/possible.frameshifts" }

my $org_id;
if ($org_dir =~ m{(\d+\.\d+)/?}) {
    $org_id = $1;
}
else {
    die "Org-dir $org_dir does not end in a properly formated taxon-id";
}

my %is_special;
if (-s qq($org_dir/special_pegs)) {
    %is_special = map { m/^(\S+)/o ? ($1 => 1) : () } $figV->file_read(qq($org_dir/special_pegs));
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Long-form code to read neighbors so we can display error messages along the way.
#-----------------------------------------------------------------------
my @neighbors;
my $max_neighbors = 5;

my $neighbors_file;
if    (-s ($_ = qq($org_dir/closest.genomes))) { $neighbors_file = $_; }
elsif (-s ($_ = qq($org_dir/neighbors)))       { $neighbors_file = $_; }
else  {
    if ($nofatal) {
	warn qq(Could not locate \'$org_dir/closest.genomes\' or \'$org_dir/neighbors\');
	exit(0);
    }
    else {
	die qq(Could not locate \'$org_dir/closest.genomes\' or \'$org_dir/neighbors\');
    }
}

if (open(NEAREST, "<$neighbors_file")) {
    my $line;
    while (defined($line = <NEAREST>) && @neighbors < $max_neighbors) {
	chomp $line;
	if (my ($org) = ($line =~ /^(\d+\.\d+)/o)) {
	    if (! $figV->is_genome($org)) {
		warn "Neighbor $org does not exist in $FIG_Config::organisms\n";
		next;
	    }
	    push(@neighbors, $org);
	}
	else {
	    warn "Neighbors line does not have an org id: '$_'\n";
	}
    }
}
else {
    if ($nofatal) {
	warn qq(Cannot open \'$org_dir/$neighbors_file\'\: $!);
	exit(0);
    }
    else {
	die qq(Cannot open \'$org_dir/$neighbors_file\'\: $!);
    }
}

if (@neighbors == 0) {
    if ($nofatal) {
	warn qq(Neighbors file \'$org_dir/$neighbors_file\' did not contain any valid neighbors);
	exit(0);
    }
    else {
	die qq(Neighbors file \'$org_dir/$neighbors_file\' did not contain any valid neighbors);
    }
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Set up environment for correction procedure.
#-----------------------------------------------------------------------
my $deleted_fids  = {};
my $tbl_entries   = {};
my $fasta_entries = {};
my $by_contig     = {};
my $nxt_peg       = 1;
my $figfams       = FFs->new( $FIG_Config::FigfamsData, $figV );
my $state         = [$figV,$org_dir,\@neighbors,$tbl_entries,$fasta_entries,$by_contig,$deleted_fids,\$nxt_peg,$code_number,$figfams,$just_mark];

&load_features("$org_dir/Features/peg",$state);



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Call the correction procedure, and collect results.
#-----------------------------------------------------------------------
my @annotations = &fix_frameshifts($state);



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Write annotations for corrected sequences unless running in "just_mark" mode.
#-----------------------------------------------------------------------
if ((@annotations > 0) && (! $just_mark)) {
    # if frameshifts were detected and corrected
    $_ = @annotations; 
    &dump_features(\@annotations,$state);
    &write_annotations($state,\@annotations);
}


#...And we are done.
exit(0);



sub load_features {
    my ($FeatureDir,$state) = @_;
    
    my ($figV,$org_dir,$neighbors,$tbl_entries,$fasta_entries,$by_contig,$deleted_fids,$nxt_pegP,$code_number,$figfams) = @$state;
    
    open(TBL,"<$FeatureDir/tbl") || die "could not open $FeatureDir/tbl";
    
    my $line;
    while (defined($line = <TBL>)) {
	chomp $line;
	my ($id, $loc, @aliases) = split(/\t/, $line);
	my ($contig, $beg, $end) = &FIG::boundaries_of($loc);
	$tbl_entries->{$id} = [$loc, join("\t",@aliases)];
	push(@{$by_contig->{$contig}}, [$beg,$end,$id]);
	if (($id =~ /\.peg\.(\d+)$/) && ($1 >= $$nxt_pegP)) { $$nxt_pegP = $1+1; }
    }
    close(TBL);
    
    my @fasta = &gjoseqlib::read_fasta("$FeatureDir/fasta");
    foreach my $x (@fasta)
    {
	$fasta_entries->{$x->[0]} = $x->[2];
    }
}

sub dump_features {
    my ($annotations, $state) = @_;
    my ($figV, $org_dir, $neighbors, $tbl_entries, $fasta_entries,
	$by_contig, $deleted_fids, $nxt_pegP, $code_number, $figfams) = @$state;
    
    my %by_type;
    foreach my $fid (keys(%$tbl_entries)) {
	if ($fid =~ /^fig\|\d+\.\d+\.([a-zA-Z]+)\./) {
	    push(@{$by_type{$1}},$fid);
	}
	else {
	    confess "invalid feature ID: $fid";
	}
    }
    
    foreach my $type (sort keys(%by_type)) {
	my @fids = sort { $a =~ /(\d+)$/; my $e1 = $1; 
		          $b =~ /(\d+)$/; my $e2 = $1; 
		          ($e1 <=> $e2) 
		        } 
	           @{$by_type{$type}};
	rename("$org_dir/Features/$type/tbl","$org_dir/Features/$type/tbl~");
	open(TBL,">$org_dir/Features/$type/tbl")  
	    || die "could not open $org_dir/Features/$type/tbl";
	
	rename("$org_dir/Features/$type/fasta","$org_dir/Features/$type/fasta~");
	open(FASTA,">$org_dir/Features/$type/fasta")  
	    || die "could not open $org_dir/Features/$type/fasta";
	
	foreach my $fid (@fids) {
	    next if ($deleted_fids->{$fid});
	    my $entry = $tbl_entries->{$fid};
	    my ($loc,$aliases) = @$entry;
	    print TBL join("\t",($fid,$loc,$aliases)),"\n";
	    my $seq = $fasta_entries->{$fid};
	    print FASTA ">$fid\n$seq\n";
	}
	close(TBL);
	close(FASTA);
    }
}

sub write_annotations {
    my ($state, $annotations) = @_;
    my ($figV, $org_dir, $neighbors, $tbl_entries, $fasta_entries,
	$by_contig, $deleted_fids, $nxt_pegP, $code_number, $figfams) = @$state;
    
    open(ANN,">>$org_dir/annotations")
	|| confess "could not open $org_dir/annotations";

    my $time_made = time;
    foreach my $annotation (@$annotations) {
	my ($fid,$text) = @$annotation;
	print ANN "$fid\n$time_made\nRAST_frameshift_correction\n$text\n//\n";
    }
    close(ANN);
}

sub fix_frameshifts {
    my ($state) = @_;
    my ($figV, $org_dir, $neighbors, $tbl_entries, $fasta_entries,
	$by_contig, $deleted_fids, $nxt_pegP, $code_number, $figfams, $just_mark) = @$state;
    
    my @annotations = ();  # we return an annotaton for each detected frameshift;
    
    &FIG::run("$FIG_Config::ext_bin/formatdb -i $org_dir/Features/peg/fasta -p T");
    
    my %orf;
    foreach my $neigh (@$neighbors) {
	(-s "$FIG_Config::organisms/$neigh/Features/peg/fasta") 
	    || confess "$FIG_Config::organisms/$neigh/Features/peg/fasta does not exist";
	
	my $cmd  = "$FIG_Config::ext_bin/blastall";
	my @args = ('-i', "$FIG_Config::organisms/$neigh/Features/peg/fasta",
		    '-d', "$org_dir/Features/peg/fasta",
		    '-m', '8',
		    '-p', 'blastp', '-FF',
		    '-g', 'F',
		    '-e', '1.0e-20'
		    ); 
	
	my @sims = map { $_ =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+\s+){3}(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)/;
			 [$1,$2,$3,$5,$6,$7,$8,$9]
			 } $figV->run_gathering_output($cmd, @args);
	
	foreach my $sim (@sims) {
	    my ($id1,$id2, $iden, $b1,$e1, $b2,$e2, $psc) = @$sim;
	    
	    next if $figV->is_deleted_fid($id1);
	    next if $is_special{$id2};
	    
	    my $ln1 = length($figV->get_translation($id1));
	    my $ln2 = length($figV->get_translation($id2));
	    
	    if (not $ln1) {
		print STDERR "WARNING: Could not get translation length for id1=$id1 --- skipping\n";
		next;
	    }
	    
	    if (($iden > 40) && (! $figV->possibly_truncated($id1))) {
		if (($e1 - $b1) < (0.9 * $ln1)) {
		    my $curr = $orf{$id2};
		    if ((! $curr) || ($curr->[0] < ($e1-$b1))) {
			$orf{$id2} = [ ($e1-$b1), $id1, $b1,$e1,$ln1, $b2,$e2,$ln2 ];
		    }
		}
	    }
	}
    }
    
    foreach my $orf_id (keys(%orf)) {
	if (! $deleted_fids->{$orf_id}) {
	    my ($loc, $translation, $anno) = &check_for_fs($state, $orf_id, $orf{$orf_id});
	    
	    if ($anno  && $just_mark && open(FS,">>$org_dir/possible.frameshifts")) {
		print FS ">$orf_id\n";
		my ($against, $against_func, $against_figfam) = &extract_against($anno,$figV);
		if ($against) {
		    print FS "$against\t$against_func\t$against_figfam\n";
		}
		else {
		    print FS "???\n";
		}
		print FS "$loc\n$translation\n$anno\n//\n";
		close(FS);
	    }
	    elsif ($anno  && (! $just_mark)) {
		my  $peg = &replace_orfs($state,$orf_id,$loc,$translation);
		my ($famO, $sims) = $figfams->place_in_family($translation);
		if ($famO) {
		    my $func = $famO->family_function;
		    push(@annotations, [$peg, "Set master function to\n$func\n"]);
		    open(ASSIGN, ">>$org_dir/assigned_functions")
			|| confess "could not open $org_dir/assigned_functions";
		    print ASSIGN "$peg\t$func\t\n";
		    close(ASSIGN);
		    open(FOUND, ">>$org_dir/found")
			|| confess "could not open $org_dir/found";
		    print FOUND (join("\t", ($peg, $famO->family_id,$func)), "\n");
		    close(FOUND);
		}
		open( CALLED_BY,">>$org_dir/called_by")
		    || confess "could not open $org_dir/called_by";
		print CALLED_BY "$peg\tcorrect_frameshifts\n";
		close(CALLED_BY);
		    
		push (@annotations, [$peg,$anno]);
	    }
	}
    }
    
    my @deleted_pegs = grep { $_ =~ /\.peg\.\d+$/ } keys(%$deleted_fids);
    if ((@deleted_pegs > 0) && (-s "$org_dir/assigned_functions")) {
	rename("$org_dir/assigned_functions","$org_dir/assigned_functions~");
	open(IN,"<$org_dir/assigned_functions~") || confess "could not open $org_dir/assigned_functions~";
	open(OUT,">$org_dir/assigned_functions") || confess "could not open $org_dir/assigned_functions";
	
	while (defined($_ = <IN>)) {
	    if (($_ =~ /^(\S+)/) && (! $deleted_fids->{$1})) {
		print OUT $_;
	    }
	}
	close(IN);
	close(OUT);
    }
    return @annotations;
}


sub check_for_fs {
    my ($state, $orf_id, $orf_entry) = @_;
    
    my $genome = &FIG::genome_of($orf_id);
    my ($figV, $org_dir, $neighbors, $tbl_entries, $fasta_entries, $by_contig, $deleted_fids, $nxt_pegP, $code_number, $figfams) = @$state;
    
    my (undef, $template_peg, $b1,$e1,$ln1, $b2,$e2,$ln2) = @$orf_entry;
    my $loc = $tbl_entries->{$orf_id}->[0];
    my ($contig,$bD,$eD) = &FIG::boundaries_of($loc);
    my $ln_contig = $figV->contig_ln($genome,$contig);
    
    my ($bDa,$eDa);  # beg of DNA (adjusted) and end of DNA adjusted
    if ($bD < $eD) {
	$bDa = &FIG::max(($bD + 3*($b2 - 1)  - 3*($b1 - 1)  - 300),  1);
	$eDa = &FIG::min(($eD - 3*($ln2-$e2) + 3*($ln1-$e1) + 300),  $ln_contig);
    }
    else {
	$bDa = &FIG::min(($bD - 3*($b2 - 1)  + 3*($b1 - 1)  + 300),  $ln_contig);
	$eDa = &FIG::max(($eD + 3*($ln2-$e2) - 3*($ln1-$e1) - 300),  1);
    }
    my $dna = $figV->dna_seq($genome,join("_",($contig,$bDa,$eDa)));
    
    my $params = {};
    $params->{family}  = [[ $template_peg, "", $figV->get_translation($template_peg) ]];
    $params->{code}    = $code_number;
    my ($new_loc, $new_translation, undef, $annotation) = &FS_RAST::best_match_in_family($params, [$contig,$bDa,$eDa,$dna]);

    if ($new_loc) {
	my $patched = $figV->dna_seq($genome,$new_loc);
	my $trans_new_dna = $figV->translate($patched);
#	print STDERR "$new_loc\n$patched\n$new_translation\n$trans_new_dna\n$patched\n//\n";
    }
    
    return ($new_loc ? ($new_loc,$new_translation,$annotation) : undef);
}
	
sub replace_orfs { 
    my ($state, $orf_id, $loc, $translation) = @_;
    
    my ($figV, $org_dir, $neighbors, $tbl_entries, $fasta_entries, $by_contig, $deleted_fids, $nxt_pegP, $code_number, $figfams) = @$state;
    my $genome = &FIG::genome_of($orf_id);
    my $peg    = "fig|$genome\.peg\.$$nxt_pegP";
    ++$$nxt_pegP;
    
    $tbl_entries->{$peg}   = [$loc,""];
    $fasta_entries->{$peg} = $translation;
    
    my ($contig,$beg,$end) = &FIG::boundaries_of($loc);
    my $x = $by_contig->{$contig};
    foreach my $tuple (@$x) {
	my ($b2,$e2,$id2) = @$tuple;
	if (&bad_overlap($beg,$end, $b2,$e2)) {
	    delete $tbl_entries->{$id2};
	    delete $fasta_entries->{$id2};
	    $deleted_fids->{$id2} = 1;
	}
    }
    return $peg;
}

sub bad_overlap {
    my ($b1,$e1, $b2,$e2) = @_;
    
    if ($b1 > $e1) { ($b1,$e1) = ($e1,$b1) }
    if ($b2 > $e2) { ($b2,$e2) = ($e2,$b2) }
    if (&FIG::between($b1,$b2,$e1) && (($e1-$b2) >= 50)) { return 1 }
    if (&FIG::between($b2,$b1,$e2) && (($e2-$b1) >= 50)) { return 1 }
    return 0;
}

sub extract_against {
    my ($anno, $figV) = @_;

    my ($against, $against_func, $against_figfam);
    if ($anno =~ /\((fig\|\d+\.\d+\.peg\.\d+)\):/) {
	$against = $1;
	$against_func = $figV->function_of($against);
	my $ffs  = FFs->new($FIG_Config::FigfamsData, $figV);
	my @fams = $ffs->families_containing_peg($against);
	if (@fams > 0) {
	    $against_figfam = join(",",@fams);
	}
	else {
	    $against_figfam = "not in FIGfam";
	}
	return ($against, $against_func, $against_figfam);
    }
    else {
	return undef;
    }
}
    
