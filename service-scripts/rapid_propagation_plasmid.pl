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
my $usage = "$self [--keep --code=num --errdir=dir --tmpdir=dir --chkdir=dir --meta=metafile] FromDir NewDir [NewDir must not exist]";

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

my $FIGfamsD = "$FIG_Config::data/FigfamsData";

my $code;
my $keep = 0;
my $fix_fs;
my $backfill_gaps;

my $rc   = GetOptions(
		      "keep!"      => \$keep,
		      "fix_fs!"    => \$fix_fs,
		      "backfill!"  => \$backfill_gaps,
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

if (! -d $FIGfamsD) {
    $trouble = 1;
    warn "$FIGfamsD does not exist";
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

if ($ENV{VERBOSE}) {
    print STDERR qq(procD = $procD\n);
    print STDERR qq(tmpD  = $tmpD\n);
    print STDERR qq(chkD  = $chkD\n);
    print STDERR qq(errD  = $errD\n);
    print STDRRR qq(\n);
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Set metafile variables ...
#-----------------------------------------------------------------------
if ($meta_file) {
    $meta = new GenomeMeta($taxonID, $meta_file);
    
    $meta->set_metadata("status.rp", "in_progress");
    $meta->add_log_entry("rp", ["Begin processing", $origD, $procD, $taxonID]);
    
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
    rename($restart_tmpD, $tmpD);
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
#...Reformat the contig if it is a circular contig
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.circular'))
{
    if ($meta->get_metadata('genome.topology') eq "Circular")
    {
	system("$bin/reformat_circular_contigs $tmpD < $tmpD/contigs > $tmpD/contigs_new");

	&make_restart($tmpD, $restart_tmpD, $chkD, qq(circular));
	$meta->set_metadata('status.rp.circular',1);
	
	# clean up the rp directory
	system("/bin/rm -f $tmpD/double_contig");
	system("/bin/rm -f $tmpD/tmp_contig.map");
	system("/bin/rm -f $tmpD/tmp_contig.fasta");
	system("/bin/mv $tmpD/extract_metagene_contigs_circular.stderr $errD/extract_metagene_contigs_circular.stderr");
	system("/bin/mv $tmpD/contigs $tmpD/contigs~");
	system("/bin/mv $tmpD/contigs_new $tmpD/contigs");    
    }
}

=head
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
	
	open(TMP, "<$tmpD/GENOME") || die "Could not read-open $tmpD/GENOME";
	$genome_bioname = <TMP>;
	chomp $genome_bioname;
	$genome_bioname =~ s/^\s+//o;
	$genome_bioname =~ s/^Candidatus\s+//io;
	close(TMP);
	
	if ($genome_bioname =~ m/^(\S+)\s+(\S+)/o) {
	    ($genus, $species) = ($1, $2);
	}
	else {
	    die "Could not extract genus and species from first line of $tmpD/GENOME";
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
	print STDERR qq(running: $cmd\n) if $ENV{VERBOSE};
	
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
=cut


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Run the fragments or plasmid sequences through the ORF caller (metagene)..
#   Create traninig data
#-----------------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.run_metagene'))
{
    if (! $keep) {
	&log($tmpD, 'Starting to run orf caller metagene');
	
	my $cmd = qq($bin/extract_metagene_contigs -exec=mga -peg=T -AA=T -genome=$taxonID -output-directory=$tmpD $tmpD/contigs $tmpD/features_mg.fasta >& $errD/extract_metagene_contigs.stderr);
	print STDERR qq(running: $cmd\n) if $ENV{VERBOSE};
	if (system($cmd)) {
	    warn "extract_metagene_contigs exited with errors\n";
	    &log("extract_metagene_contigs exited with errors\n");
	}
	else {
	    &log($tmpD, 'Finished extracting orfs using metagene caller');
	    $meta->set_metadata("genome.found_orfs_using_metagene", 1);
	}

    }
	
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(run_metagene));
    $meta->set_metadata('status.rp.run_metagene',1);
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Run the training data from the metagene caller through the ORF caller (GLIMMER)..
#-----------------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.run_glimmer'))
{
    if (! $keep) {
	&log($tmpD, 'Starting to run orf caller glimmer with training data');
	my $cmd = qq($bin/run_glimmer3 -train=$tmpD/metagene_seqs.map $taxonID $tmpD/contigs > $tmpD/glimmer_seqs.map);
	print STDERR qq(running: $cmd\n) if $ENV{VERBOSE};
	
	if (system($cmd)) {
	    warn "run_glimmer3 exited with errors\n";
            &log("run_glimmer3 exited with errors\n");
	}
	else {
	    #&log($tmpD, 'Finished extracting orfs using glimmer caller');
            #$meta->set_metadata("genome.found_orfs_using_glimmer", 1);
	    
	    if (-s qq($tmpD/glimmer_seqs.map)) {
		if (system("$bin/get_fasta_for_tbl_entries $tmpD/contigs < $tmpD/glimmer_seqs.map > $tmpD/glimmer.fasta")) {
		    warn "get_fasta_for_tbl_entries for the glimmer orfs exited with errors\n";
		    &log("get_fasta_for_tbl_entries for the glimmer orfs exited with errors\n");
		}
		else {
		    my @fids = map { m/^(\S+)/o
					 ? ($1)
					 : ()
				     } &FIG::file_read(qq($tmpD/glimmer_seqs.map));
		    
		    open( CALLED_BY, qq(>$tmpD/called_by) )
			|| die qq(Could not write-open \'$tmpD/called_by\');
		    print CALLED_BY map { qq($_\trun_glimmer\n) } @fids;
		    close(CALLED_BY);
		    
		    &log($tmpD, 'Finished extracting orfs using glimmer caller');
		    $meta->set_metadata("genome.found_orfs_using_glimmer", 1);
		}
	    }
	    else {
		#...Fall back to MGA calls
		if (system("$bin/get_fasta_for_tbl_entries $tmpD/contigs < $tmpD/metagene_seqs.map > $tmpD/glimmer.fasta")) {
		    warn "get_fasta_for_tbl_entries for the Metagene ORFs exited with errors\n";
		    &log("get_fasta_for_tbl_entries for the Metagene ORFs exited with errors\n");
		}
		else {
		    my @fids = map { m/^(\S+)/o
					 ? ($1)
					 : ()
				     } &FIG::file_read(qq($tmpD/metagene_seqs.map));
		    
		    open( CALLED_BY, qq(>$tmpD/called_by) )
			|| die qq(Could not write-open \'$tmpD/called_by\');
		    print CALLED_BY map { qq($_\tMGA\n) } @fids;
		    close(CALLED_BY);
		    
		    &log($tmpD, 'Finished extracting orfs after falling back to Metagene caller');
		}
	    }
	}
    }
    &make_restart($tmpD, $restart_tmpD, $chkD, qq(run_glimmer));
    $meta->set_metadata('status.rp.run_glimmer',1);
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#....Generate the Features directory and Cleanup
#_________________________________________________________________________
if (!$keep) {
    &FIG::verify_dir("$tmpD/Features/peg");
    #&run("/bin/mv $tmpD/features_mg.fasta $tmpD/Features/peg/fasta");
    #&run("/bin/mv $tmpD/metagene_seqs.map $tmpD/Features/peg/tbl");
    &run("/bin/mv $tmpD/glimmer_seqs.map $tmpD/Features/peg/tbl");
    &run("/bin/mv $tmpD/glimmer.fasta $tmpD/Features/peg/fasta");
    &run("$FIG_Config::ext_bin/formatdb -p -i $tmpD/Features/peg/fasta");
    &run("/bin/rm -f $tmpD/metagene.out");
    &run("/bin/rm -f $tmpD/metagene_seqs.map");
    &run("/bin/rm -f $tmpD/features_mg.fasta");    
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Find ORFs that can be placed in a FIGfam...
#-----------------------------------------------------------------------
if (! $meta->get_metadata('status.rp.assign_using_ff'))
{
    my $cmd = qq($bin/assign_using_ff -f -l $FIGfamsD < $tmpD/Features/peg/fasta > $tmpD/found 2> $errD/assign_using_ff.stderr);
    print STDERR qq(running: $cmd\n) if $ENV{VERBOSE};
    &run($cmd);
    
    &log($tmpD, 'Finished finding genes that could be placed in FIGfams');
    
    #...write FIGfam results to 'assigned_functions'...
    open (FH, "<$tmpD/found") || die "could not open $tmpD/found";
    open (ASSIGNED, ">$tmpD/assigned_functions") || die "could not open $tmpD/assigned_functions";
    my %seen;
    my $entry;
    while (defined($entry = <FH>)) {
	chomp $entry;
	if ($entry =~ m/^(fig\|\d+\.\d+\.peg\.\d+)\t(FIG\d+)\t(.*)$/) {
	    my ($peg, $fam, $func) = ($1, $2, $3);
	    $func =~ s/^FIG\d+[^:]+:\s*//;
	    if (! $seen{$peg}) {
		$seen{$peg} = 1;
		print ASSIGNED "$peg\t$func\n";
	    }
	}
    }
    close(FH);
    close(ASSIGNED);

    &make_restart($tmpD, $restart_tmpD, $chkD, qq(assign_using_ff));
    $meta->set_metadata('status.rp.assign_using_ff',1);
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



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# We need to defer these steps until after auto_assign runs,
# which is done in the script that calls rapid_propagation_plasmid:
#
#&run("$bin/initialize_ann_and_ev $newD 2> $errD/initialize_ann_and_ev.stderr");
#&run("cat $newD/proposed*functions | $bin/rapid_subsystem_inference $newD/Subsystems 2> $errD/rapid_subsystem_inference.stderr");
# &log($tmpD, 'Finished inferring subsystems');
#=======================================================================
#...BUT, we must still create a dummy "Subsystems/" dir to keep `auto_assign` from blowing up 
#=======================================================================

FIG::verify_dir(qq($newD/Subsystems));
FIG::run(qq(touch $newD/Subsystems/bindings));
FIG::run(qq(touch $newD/Subsystems/subsystems));

#-----------------------------------------------------------------------


#$meta->set_metadata("status.rp", "complete");
#$meta->set_metadata("rp.running", "no");


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# This step has been moved to rp_quality_check
#
# $meta->set_metadata("status.qc", "in_progress");
# &run("$bin/assess_gene_call_quality  $newD > $newD/quality.report 2>&1");
# $meta->set_metadata("status.qc", "complete");
#-----------------------------------------------------------------------

&run(  "/bin/cp -pR $procD/* $errD/");
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

    if ($cmd =~ m,^([^/]+?)(\s+.*)$,) {
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
