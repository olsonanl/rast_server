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

$SIG{HUP} = 'IGNORE';   # ... Force running `nohup' ...

use GenomeMeta;
use Getopt::Long;
use FIG;
use FIG_Config;
use strict;
use File::Basename;
use Carp;

$ENV{PATH} .= ":" . join(":", $FIG_Config::ext_bin, $FIG_Config::bin);

#
# Make figfams.pm report details of family data used, for any FF based code.
#
$ENV{REPORT_FIGFAM_DETAILS} = 1;

$0 =~ m/([^\/]+)$/;
my $self = $1;
my $usage = "$self [--keep --glimmerV=[2,3] --code=num --errdir=dir --tmpdir=dir --chkdir=dir --meta=metafile] FromDir NewDir [NewDir must not exist]";

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Explanation of the various work directories
# ===========================================
# $origD --- the original raw genome directory
# $newD  --- the destination for the completed rapid propagation
# $procD --- the temp directory in which the intermediate computations are held
# $tmpD  --- the genome directory held within $procD
# $errD  --- the directory to which error outputs are written to.
# $chkD  --- the directory "Checkpoint" directories are copied to.
#
# In RAST we are called with the following assignments:
# $origD  =  jobdir/raw/<genomeid>
# $newD   =  jobdir/rp/<genomeid>
# $procD  =  /scratch/tmprp.job<jobnumber>.<pid>
# $errD   =  jobir/rp.errors
# $chkD   =  jobdir/Restart
#-----------------------------------------------------------------------

my ($tmpD, $restart_tmpD);
my ($meta_file, $meta);

my $bin    = $FIG_Config::bin;

my $procD  = "$FIG_Config::temp/$$";
my $errD   = "";
my $chkD   = "";

my $NR     = "$FIG_Config::fortyeight_data/nr";
my $pegsyn = "$FIG_Config::fortyeight_data/peg.synonyms";

my $code;
my $keep = 0;
my $fix_fs;
my $backfill_gaps;
my $glimmer_version = 3;

my $num_neighbors = 10;

my $rc   = GetOptions(
		      "keep!"      => \$keep,
		      "fix_fs!"    => \$fix_fs,
		      "backfill!"  => \$backfill_gaps,
		      "glimmerV=s" => \$glimmer_version,
		      "code=s"     => \$code,
		      "tmpdir=s"   => \$procD,
		      "errdir=s"   => \$errD,
		      "chkdir=s"   => \$chkD,
		      "meta=s"     => \$meta_file,
		      "nr=s"       => \$NR,
		      );
if (!$rc) {
    die "\n   usage: $usage\n\n";
}
my $old = $keep ? " old" : "";

if (!defined($code))
{
    warn "Warning: No genetic code passed to $self. Defaulting to 11.\n";
    $code = 11;
}
if ($code !~ /^\d+$/)
{
    die "Genetic code must be numeric\n";
}

if ($glimmer_version == 2) {
    $ENV{RAST_GLIMMER_VERSION} = $glimmer_version;
}    
elsif ($glimmer_version == 3) {
    $ENV{RAST_GLIMMER_VERSION} = $glimmer_version;
}
else {
    die "GLIMMER version $glimmer_version not supported. Only versions 2 and 3 supported";
}

my $trouble = 0;
my ($origD, $newD) = @ARGV;

if (!-d $origD) {
    $trouble = 1;
    warn "$origD does not exist";
}

if (-d $newD) {
    $trouble = 1;
    warn "$newD already exists";
}

die "\n\n   usage: $usage\n\n" if $trouble;


my $taxonID = basename($origD);
if ($taxonID !~ /^\d+\.\d+$/) {
    die "FromDir must end in a valid genome identifier (e.g., \"83333.1\"\n";
}

&FIG::verify_dir($procD);



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Define temporary, error, and checkpoint directories.
#-----------------------------------------------------------------------
$tmpD         = "$procD/$taxonID";
&FIG::verify_dir($tmpD);

if (! $errD) {
    $errD = $tmpD;
}

if (! $chkD) {
    $chkD = $errD;
}

$restart_tmpD = "$chkD/$taxonID.restart";



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Set metafile variables ...
#-----------------------------------------------------------------------
if ($meta_file) {
    $meta = new GenomeMeta($taxonID, $meta_file);
    
    $meta->set_metadata("status.rp", "in_progress");
    $meta->add_log_entry("rp", ["Begin processing", $origD, $procD, $taxonID]);
    
    $meta->set_metadata("rp.glimmer_version", $glimmer_version);
    
    if ($fix_fs) {
	$meta->set_metadata("correction.frameshifts", 1);
    }
    
    if ($backfill_gaps) {
	$meta->set_metadata("correction.backfill_gaps", 1);
    }
    
    $ENV{DEBUG}   = $meta->get_metadata('env.debug')   || 0;
    $ENV{VERBOSE} = $meta->get_metadata('env.verbose') || 0;
}
else
{
    die "$self now requires a meta file";
}

my $restart = 0;
if (-d $restart_tmpD) {
    warn "NOTE: This is a restart run\n";
    $meta->add_log_entry("rp", ["Restart of previous job"]);
    
    $restart = 1;
    system "rm -r $tmpD";
    system(qq(cp -R $restart_tmpD $tmpD))
	&& die qq(Could not copy $restart_tmpD ==>  $tmpD);
}
else {
    &run("/bin/cp -pR $origD $procD");
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(orig));
    
    if (! $keep) {
	&run("rm -fR $tmpD/Features/* $tmpD/assigned_functions");
    }
}

if ($code) {
    print STDERR "Using genetic code $code\n" if $ENV{VERBOSE};
    
    open( GENETIC_CODE, ">$tmpD/GENETIC_CODE" )
	|| die "Could not write-open $tmpD/GENETIC_CODE";
    print GENETIC_CODE "$code\n";
    close(GENETIC_CODE) || die "Could not close $tmpD/GENETIC_CODE";
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Find RNAs...
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.RNAs'))
{
    if (! $keep) {
	my $rna_tool = $ENV{RP_SEARCH_FOR_RNAS};
	my ($genome_bioname, $genus, $species, $taxonomy);
	if (-x $rna_tool) {
	    print STDERR "Using RNA-finder $rna_tool\n" if $ENV{VERBOSE};
	}
	else {
	    warn "RNA-finder $rna_tool does not exist --- searching for others\n";
	    if ($rna_tool = `which search_for_rnas`) {
		chomp $rna_tool;
	    }
	    else {
		die "Cannot locate an RNA-finder --- aborting";
	    }
	}
	
	$genome_bioname = &FIG::file_head(qq($tmpD/GENOME), 1);
	chomp $genome_bioname;
	$genome_bioname =~ s/^\s+//o;
	$genome_bioname =~ s/[\s\n]+/ /gso;
	$genome_bioname =~ s/^Candidatus\s+//io;
	$genome_bioname =~ s/\s+$//o;
	
	if    ($genome_bioname =~ m/^(\S+)\s+(\S+)/o) {
	    ($genus, $species) = ($1, $2);
	}
	elsif ($genome_bioname =~ m/^(\S+)$/o) {
	    ($genus, $species) = ($1, qq(sp.));
	    $genome_bioname    = qq($genus sp.);
	}
	else {
	    die qq(Could not extract genus and species from $tmpD/GENOME);
	}
	
	open(TMP, "<$tmpD/TAXONOMY") || die "Could not read-open $tmpD/TAXONOMY";
	$taxonomy = <TMP>;
	chomp $taxonomy;
	$taxonomy =~ s/^\s+//o;
	my $domain = uc substr($taxonomy, 0, 1);
	die "Invalid domain: $domain" unless ($domain =~ m/^(A|B|E|V)$/o);
	
	my $rna_dir = "$tmpD/Features/rna";
	&FIG::verify_dir($rna_dir);
	
	my $cmd = "$rna_tool --tmpdir=$tmpD --contigs=\"$tmpD/contigs\" --orgid=$taxonID --domain=$domain --genus=$genus --species=$species --log=$errD/search_for_rnas.log";
	$cmd =~ s/\n/ /gs;
	warn "$cmd\n" if $ENV{VERBOSE};
	
	my @out = `$cmd 2>> $errD/search_for_rnas.log`;
	if ($? != 0) {
	    my ($rc, $sig, $msg) = &FIG::interpret_error_code($?);
	    die "$msg: $cmd";
	}
	
	my @sorted = sort {
	    $a =~ m/^\S+\t(\S+)/o;   my $x = $1;
	    $b =~ m/^\S+\t(\S+)/o;   my $y = $1;
	    &FIG::by_locus($x, $y)
	    } @out;
	
	if (@sorted) {
	    open( RNA_TBL, ">$rna_dir/tbl" )
		|| die "Could not write-open $rna_dir/tbl";
	    
	    open( ASSIGNED_FUNC, ">$tmpD/assigned_functions" )
		|| die "Could not append-open $tmpD/assigned_functions";
	    
	    my $num = 0;
	    foreach my $line (@sorted) {
		chomp $line;
		if ($line =~ m/^\S+\t(\S+)/o) {
		    
		    ++$num;
		    my $fid = "fig|$taxonID.rna.$num";
		    print RNA_TBL "$fid\t$1\n";
		    
		    if ($line =~ m/^\S+\t\S+\t(.*)$/o) {
			print ASSIGNED_FUNC  "$fid\t$1\n";
		    }
		}
		else {
		    warn "Could not parse RNA line: $line\n";
		}
	    }
	    
	    close(RNA_TBL);
	    close(ASSIGNED_FUNC);
	    
	    &run("get_dna $tmpD/contigs < $rna_dir/tbl > $rna_dir/fasta");
	}
	
	if (!-s "$rna_dir/tbl") {
	    warn "No RNAs found --- removing $rna_dir\n";
	    &run("rm -fR $rna_dir");
	}
    }
    
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(RNA));
    $meta->set_metadata('status.rp.RNAs',1);
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Find Selenoproteins, etc....
#-----------------------------------------------------------------------

if (! $meta->get_metadata('status.rp.find_special_proteins'))
{
    if (not $keep) {
	&run("find_special_proteins $tmpD > $errD/find_special_proteins.stderr 2>&1");
    }
    
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(special));
    $meta->set_metadata('status.rp.find_special_proteins',1);
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Find "nearby" genomes, and project their PEGs onto this genome...
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.find_neighbors'))
{
    &log($tmpD, 'Starting to find close genomes');
    
    if (system("$bin/find_neighbors $tmpD $num_neighbors $tmpD/found $old > $tmpD/neighbors 2> $errD/find_neighbors.stderr")) {
	warn "find_neighbors exited with errors --- falling back to find_neighbors_using_figfams\n";
	&log("find_neighbors exited with errors --- falling back to find_neighbors_using_figfams\n");
    }
    else {
	&log($tmpD, 'Finished finding close genomes');
    }
    
    my @neighbors;
    if (open(NEIGHBORS, "<$tmpD/neighbors")) {
	while (<NEIGHBORS>) {
	    chomp;
	    my($taxonID, @rest) = split(/\t/);
	    push(@neighbors, $taxonID);
	}
	close(NEIGHBORS);
    }
    
    $meta->set_metadata("genome.found_neighbors_univ", @neighbors > 0 ? 1 : 0);
    if (@neighbors == 0) {
	&log($tmpD, "No close neighbors could be found using the Universal FIGfams");
	
	&run("$bin/find_neighbors_using_figfams $tmpD $num_neighbors $tmpD/found $old > $tmpD/neighbors 2> $errD/find_neighbors_using_figfams.stderr");
	&log($tmpD, 'Finished finding close genomes based on FIGfams');
	
	if (open(NEIGHBORS, "<$tmpD/neighbors"))  {
	    while (<NEIGHBORS>) {
		chomp;
		my($taxonID, @rest) = split(/\t/);
		push(@neighbors, $taxonID);
	    }
	    close(NEIGHBORS);
	}
	
	$meta->set_metadata("genome.found_neighbors_figfam", @neighbors > 0 ? 1 : 0);
    }
    $meta->set_metadata("genome.neighbors", \@neighbors);
    
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(find_neighbors));
    $meta->set_metadata('status.rp.find_neighbors',1);
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...If a set of nearest neighbors were found,
#   then project their PEGs onto the new genome
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.find_genes_based_on_neighbors'))
{
    if ((-s "$tmpD/neighbors") &&
	((grep { m/^\d+\.\d+/ } `cat $tmpD/neighbors`) > 0)
	) 
    {
	&run("$bin/find_genes_based_on_neighbors $tmpD $tmpD/found $old < $tmpD/neighbors > $errD/find_genes_based_on_neighbors.stage-1.stderr 2>&1");
	&log($tmpD, 'Finished first pass of finding genes matching families found in close genomes');
	
	if (! $keep)  ## rerunning has no effect if you are not recalling genes
	{
	    &run("$bin/find_genes_based_on_neighbors $tmpD $tmpD/found $old < $tmpD/neighbors > $errD/find_genes_based_on_neighbors.stage-2.stderr 2>&1");
	    &log($tmpD, 'Finished second pass of finding genes matching families found in close genomes');
	}
    }
    else {
	&log($tmpD, "No close neighbors found --- skipping find_genes_based_on_neighbors");
    }
    
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(find_genes_based_on_neighbors));
    $meta->set_metadata('status.rp.find_genes_based_on_neighbors',1);
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Find and promote ORFs that can be placed in a FIGfam...
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.find_genes_in_families'))
{
    &run("$bin/find_genes_in_families $tmpD $tmpD/found $old > $errD/find_genes_in_families.stderr 2>&1");
    &log($tmpD, 'Finished finding genes that could be placed in some FIGfam');
    
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(find_genes_in_families));
    $meta->set_metadata('status.rp.find_genes_in_families',1);
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Promote remaining ORFs to PEGs...
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.promote_orfs_to_pegs'))
{
    if ($keep) {
#...If just re-annotating an existing set of calls,
#   write assigned_functions for the PEG IDs listed in the found file.
	
	system "rm -fR $tmpD/Features/orf";
	open(IN,"<$tmpD/found") || die "could not open $tmpD/found";
	open(OUT,">$tmpD/assigned_functions") || die "could not open $tmpD/assigned_functions";
	my %seen;
	while (defined($_ = <IN>)) {
	    chomp;
	    my($peg,undef,$func) = split(/\t/,$_);
	    if (! $seen{$peg}) {
		$seen{$peg} = 1;
		print OUT "$peg\t$func\n";
	    }
	}
	close(IN);
	close(OUT);
    }
    else {
#...Promote the remaining ORFs to PEgs (writes functions to the assigned_functions file)
	&run("$bin/promote_orfs_to_pegs $tmpD $tmpD/found > $errD/promote_orfs.stderr 2>&1");
	
	&log($tmpD, 'Finished promoting genes that could not be placed in any FIGfam');
    }
    
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(promote_orfs_to_pegs));
    $meta->set_metadata('status.rp.promote_orfs_to_pegs',1);
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Correct possible frameshift errors...
#-----------------------------------------------------------------------
if ($fix_fs || $meta->get_metadata("correction.frameshifts"))
{
    if (! $meta->get_metadata('status.rp.correct_frameshifts'))
    {
	&run("correct_frameshifts -code=$code $tmpD > $errD/correct_frameshifts.stderr 2>&1");
	
	&make_restart($tmpD, $restart_tmpD, $chkD, qq(correct_frameshifts));
	$meta->set_metadata('status.rp.correct_frameshifts',1);
    }
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Backfill gaps to pick up any remaining missing PEGs...
#-----------------------------------------------------------------------
if ($backfill_gaps || $meta->get_metadata("correction.backfill_gaps"))
{
    if (! $meta->get_metadata('status.rp.backfill_gaps'))
    {
	if (not $keep) {
	    if ((-s "$tmpD/neighbors") &&
		((grep { m/^\d+\.\d+/ } `cat $tmpD/neighbors`) > 0)
		) 
	    {
		my $peg_tbl   = "$tmpD/Features/peg/tbl";
		my $rna_tbl   = (-s "$tmpD/Features/rna/tbl") ? "$tmpD/Features/rna/tbl" : "";
		my $extra_tbl = "$tmpD/Features/peg/tbl.extra";
		
		&run("backfill_gaps -orgdir=$tmpD -genetic_code=$code $tmpD/neighbors $taxonID $tmpD/contigs $rna_tbl $peg_tbl > $extra_tbl 2> $errD/backfill_gaps.stderr");
		if (-s $extra_tbl) {
		    open( CALLED_BY, ">>$tmpD/called_by") || die "Could not append-open $tmpD/called_by";
		    print CALLED_BY map { m/^(\S+)/ ? qq($1\tbackfill_gaps\n) : qq() } `cat $extra_tbl`;
		    close(CALLED_BY);
		    &run("cat $extra_tbl >> $peg_tbl");
		    &run("get_fasta_for_tbl_entries -code=$code $tmpD/contigs < $extra_tbl >> $tmpD/Features/peg/fasta");
		    system("rm -f $extra_tbl") && warn "WARNING: Could not remove $extra_tbl";
		}
		
		&make_restart($tmpD, $restart_tmpD, $chkD, qq(backfill_gaps));
		$meta->set_metadata('status.rp.backfill_gaps',1);
	    }
	}
    }
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# make_genome_dir_for close will copy $tmpD to $newD, and rename the copied
# assigned_functions to proposed_functions.
#
# In the case where we are not keeping genecalls, we wish to recreate the
# assigned_functions from the original raw directory. 
# We can use the tbl-based peg mapping that make_genome_dir_for_close also uses
# to do this; and in fact do this inline here, after make_genome_dir_for_close.
#-----------------------------------------------------------------------
&run("$bin/make_genome_dir_for_close $origD $tmpD $newD 2> $errD/make_genome_dir_for_close.stderr");
&make_restart($newD, $restart_tmpD, $chkD, qq(make_genome_dir_for_close));

&run("$bin/renumber_features -print_map $newD > $errD/renumber_features.map 2> $errD/renumber_features.stderr");
&make_restart($newD, $restart_tmpD, $chkD, qq(renumber_features));

&run("cat $newD/proposed*functions | $bin/rapid_subsystem_inference $newD/Subsystems 2> $errD/rapid_subsystem_inference.stderr");
&log($tmpD, 'Finished inferring subsystems');



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# We need to defer this step until after auto_assign runs, which in
# &run("$bin/initialize_ann_and_ev $newD 2> $errD/initialize_ann_and_ev.stderr");
#-----------------------------------------------------------------------
$meta->set_metadata("status.rp", "complete");
$meta->set_metadata("rp.running", "no");


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# This step has been moved to rp_quality_check
#
# $meta->set_metadata("status.qc", "in_progress");
# &run("$bin/assess_gene_call_quality  $newD > $newD/quality.report 2>&1");
# $meta->set_metadata("status.qc", "complete");
#-----------------------------------------------------------------------

system("/bin/cp -pR $procD/* $errD/");
system("/bin/rm -fR $procD");
exit(0);


########################################################################
sub log {
    my($dir,$message) = @_;

    my $whole_message = scalar(localtime(time)) . ": $message";

    open(L, ">>$dir/log");
    print L "$whole_message\n";
    close(L);

    $meta->add_log_entry("rp", $whole_message) if $meta;
}

sub run {
    my($cmd) = @_;
    $cmd =~ s/\n/ /gs;
    
    if ($cmd =~ m{^([^/]+?)(\s+.*)$}) {
	my $prog = $1;
	my $rest = $2;

	my $changed;
	for my $dir (split(/:/, $ENV{PATH})) {
	    my $path = "$dir/$prog";
	    if (-x $path) {
		warn "using $path\n";
		$cmd = "$path $rest";
		++$changed;
		last;
	    }
	}
	warn "Cmd running bare command $prog\n" unless $changed;
    }
    
    if ($ENV{FIG_VERBOSE}) {
        my @tmp = `date`;
        chomp @tmp;
        print STDERR "$tmp[0]: running $cmd\n";
    }
    
    if ($meta) {
	$meta->add_log_entry("rp", ['run_start', $cmd]);
    }
    
    my $rc = system($cmd);
    if ($meta) {
	$meta->add_log_entry("rp", ['run_finish', $cmd, $rc]);
    }

    if ($rc != 0) {
	my $msg;
	(undef, undef, $msg) = &FIG::interpret_error_code($rc);
	confess "FAILED, rc=$rc, reason=$msg: $cmd";
    }
}

sub make_restart {
    my($tmpD, $restart_tmpD, $chkD, $checkpoint_extension) = @_;
    
    if (-d $restart_tmpD) {
	system "/bin/rm -r $restart_tmpD";
    }
    
    system "/bin/cp -pR $tmpD $restart_tmpD";
    system "touch       $restart_tmpD";
    
    if ($chkD && (-d $chkD) && $checkpoint_extension) {
	my $name = basename($tmpD);
	system "/bin/cp -pR $tmpD $chkD/$name.$checkpoint_extension";
	system "touch       $chkD/$name.$checkpoint_extension";
    }
    
    return 1;
}
