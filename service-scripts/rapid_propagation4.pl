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

$SIG{HUP} = 'IGNORE';   # ... Force running 'nohup' ...

use strict;
use warnings;

use FIGV;
use FIG_Config;
use GenomeMeta;
use SAPserver;
use ANNOserver;
use gjoseqlib;

use Getopt::Long;
use File::Basename;
use Carp;

$ENV{PATH} .= ":" . join(":", $FIG_Config::ext_bin, $FIG_Config::bin);

#
# Make figfams.pm report details of family data used, for any FF based code.
#
$ENV{REPORT_FIGFAM_DETAILS} = 1;

$0 =~ m/([^\/]+)$/;
my $self = $1;
my $usage = "$self [--keep --glimmerV=[2,3] --kmerDataset=ReleaseID --code=num --errdir=dir --tmpdir=dir --chkdir=dir --meta=metafile] FromDir NewDir [NewDir must not exist]";


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

my ($tmpD, $restartD);
my ($meta_file, $meta);

my $bin    = $FIG_Config::bin;

my $procD  = "$FIG_Config::temp/tmp_rp.$$";
my $errD   = "";
my $chkD   = "";

my $code   = 11;
my $domain = "";

my $keep   = 0;
my $fix_fs = 0;
my $backfill_gaps   = 0;
my $glimmer_version = 3;
my $num_neighbors   = 30;

my $NR;
my $kmerDataset     = defined($FIG_Config::kmerDataset) ? $FIG_Config::kmerDataset : q();

my $rc   = GetOptions(
		      "keep!"      => \$keep,
		      "fix_fs!"    => \$fix_fs,
		      "backfill!"  => \$backfill_gaps,
		      "glimmerV=s" => \$glimmer_version,
		      "code=s"     => \$code,
		      "domain=s"   => \$domain,
		      "tmpdir=s"   => \$procD,
		      "errdir=s"   => \$errD,
		      "chkdir=s"   => \$chkD,
		      "meta=s"     => \$meta_file,
		      "nr=s"       => \$NR,
		      "kmerDataset=s" => \$kmerDataset,
		      );
if (!$rc) {
    die "\n   usage: $usage\n\n";
}
my $old = $keep ? " old" : "";


if (defined($code)) {
    if ($code !~ /^\d+$/) {
	die "Genetic code must be numeric\n";
    }
}
else {
    warn "Warning: No genetic code passed to $self. Defaulting to 11.\n";
    $code = 11;
}


#...Set $glimmer_version if user does not want the default version=3
if ($glimmer_version == 2) {
    $ENV{RAST_GLIMMER_VERSION} = $glimmer_version;
}    
elsif ($glimmer_version == 3) {
    $ENV{RAST_GLIMMER_VERSION} = $glimmer_version;
}
else {
    die "GLIMMER version $glimmer_version not supported. Only versions 2 and 3 supported";
}


#...Handle the mandatory arguments...
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

$restartD = "$chkD/$taxonID.restart";



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Set metafile variables ...
#-----------------------------------------------------------------------
if ($meta_file) {
    $meta = GenomeMeta->new($taxonID, $meta_file);
    
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
else {
    die "$self now requires a meta file";
}

my $restart = 0;
if (-d $restartD) {
    warn "NOTE: This is a restart run\n";
    $meta->add_log_entry("rp", ["Restart of previous job"]);
    
    $restart = 1;
    system "rm -r $tmpD";
    system(qq(cp -R $restartD $tmpD))
	&& die qq(Could not copy $restartD ==>  $tmpD);
}
else {
    &my_run("/bin/cp -R $origD $procD");
    &make_restart($chkD, $tmpD, $restartD, qq(orig));
    
    if (! $keep) {
	&my_run("rm -fR $tmpD/Features/* $tmpD/assigned_functions");
    }
}

if (not $domain) {
    if ($meta) {
	print STDERR "Getting Domain from metafile \'$meta_file\'\n";
	$domain = $meta->get_metadata('genome.domain');
    }
    
    if (not $domain) {
	if (-s qq($origD/TAXONOMY)) {
	    print STDERR "Getting Domain from \'$origD/TAXONOMY\'\n";
	    my $taxonomy = &FIG::file_head(qq($origD/TAXONOMY), 1);
	    ($domain) = ($taxonomy =~ m/^\s*(Archaea|Bacteria|Vir\w+)/o);
	}
    }
    
    if (not $domain) {
	die "Genome Domain not provided via command-line, metafile, or organism directory --- aborting";
    }
}

if ($code) {
    print STDERR "Using genetic code $code\n" if $ENV{VERBOSE};
    
    open( GENETIC_CODE, ">$tmpD/GENETIC_CODE" )
	|| die "Could not write-open $tmpD/GENETIC_CODE";
    print GENETIC_CODE "$code\n";
    close(GENETIC_CODE) || die "Could not close $tmpD/GENETIC_CODE";
}



########################################################################
#...Main Body of Code...
########################################################################

my $figV  = FIGV->new($tmpD);
my $sapO  = SAPserver->new();
my $annoO = ANNOserver->new();

my $trans_table = FIG::genetic_code($code);

my $contigs_file = qq($tmpD/contigs);
my $contig_lens  = {};
%$contig_lens = map { $_->[0] => length($_->[2]) } read_fasta($contigs_file);

my $min_contig_len =   2_000;
my $min_tot_dna    = 100_000;
my $max_frac_short =    0.90;

my $result;
my $initial_fasta_txt;
my $initial_calls;
if ((not &is_too_small( $contig_lens, $min_contig_len, $min_tot_dna))    &&
    (not &is_metagenome($contig_lens, $min_contig_len, $max_frac_short)) &&
    (not &is_raw_reads( $contig_lens, $min_contig_len))                  &&
    (0 == &run_find_genes($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code,
			  $chkD,$tmpD,$restartD,$errD,
			  q(find_genes_based_on_kmers.stage-0.stderr),
			  $kmerDataset))
    ) {
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Large genome ...
#-----------------------------------------------------------------------
    if (!$keep) {
	&make_restart($chkD,$tmpD,$restartD, qq(find_genes_based_on_kmers.stage-0));
    }
    &find_rnas($keep, $meta,$figV,$sapO,$annoO, $domain,$taxonID, $chkD,$tmpD,$restartD,$errD, q(find_rnas.stderr));
    &find_special_proteins($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD);
    &post_process_rnas_and_glimmer($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code,
				   $chkD,$tmpD,$restartD,$errD,
				   q(postprocess_rna_and_glimmer.stderr),
				   $kmerDataset);
    
    &correct_frameshifts($keep,$fix_fs, $meta,$figV,$sapO,$annoO, $chkD,$tmpD,$restartD,$errD);
    &find_and_backfill_missing_and_miscalled($keep,$backfill_gaps, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD);
}
elsif (0 == &run_mga($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $kmerDataset)) {
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Small genome, plasmid, or fragment ...
#-----------------------------------------------------------------------
    if (!$keep) {
	if (($domain eq q(Bacteria)) || ($domain eq q(Archaea))) {
	    &find_rnas($keep, $meta,$figV,$sapO,$annoO, $domain,$taxonID, $chkD,$tmpD,$restartD,$errD, q(find_rnas.stderr));
	}
	&post_process_mga($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code,
			  $chkD,$tmpD,$restartD,$errD,
			  qq(postprocess_mga.stderr), $kmerDataset);
	
	&correct_frameshifts($keep,$fix_fs, $meta,$figV,$sapO,$annoO, $chkD,$tmpD,$restartD,$errD);
	&find_and_backfill_missing_and_miscalled($keep,$backfill_gaps, $meta,$figV,$sapO,$annoO, $taxonID,$code,
						 $chkD,$tmpD,$restartD,$errD);
    }
}
else {
    &kmer_approach();
}

&cleanup($bin, $keep, $origD,$restartD, $tmpD,$errD,$newD);

$meta->set_metadata("status.rp", "complete");
$meta->set_metadata("rp.running", "no");

exit(0);

    


########################################################################
#...Utility routines...
########################################################################
sub date_stamp {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,	$yday,$isdst) = localtime(time);
    return sprintf ("%4d-%02d-%02d %02d:%02d:%02d",
		    ($year+1900, $mon+1, $mday, $hour, $min, $sec)
	);
}

sub log {
    my($dir,$message) = @_;

    my $whole_message = scalar(localtime(time)) . ": $message";

    open( LOG, ">>$dir/log");
    print LOG  "$whole_message\n";
    close(LOG);

    $meta->add_log_entry("rp", $whole_message) if $meta;
}

sub my_run {
    my($cmd, $nofatal) = @_;
    $cmd =~ s/\n/ /gs;
    
    use Carp qw( cluck );
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
        print STDERR (&date_stamp(), q(: running ), $cmd, qq(\n\n));
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
	if ($nofatal) {
	    cluck   "WARNING, rc=$rc, reason=$msg: $cmd";
	}
	else {
	    confess "FAILED, rc=$rc, reason=$msg: $cmd";
	}
    }
}


sub is_too_small {
    my ($contigs_lens, $min_contig_len, $min_tot_dna) = @_;
    
    my $tot_dna = 0;
    foreach my $contig (keys %$contig_lens) {
	if ($contig_lens->{$contig} >= $min_contig_len) {
	    $tot_dna += $contig_lens->{$contig};
	}
    }
    
    my $rc = ($tot_dna < $min_tot_dna) || 0;
    print STDERR qq(too_small: tot_dna=$tot_dna, min_tot_dna=$min_tot_dna ==> rc=$rc\n\n)
	if $ENV{VERBOSE};
    return $rc
}


sub is_metagenome {
    my ($contigs_lens, $min_contig_len, $max_frac_short) = @_;
    
    my $tot_dna = 0;
    my $tot_short_dna = 0;
    foreach my $contig (keys %$contig_lens) {
	$tot_dna += $contig_lens->{$contig};
	if ($contig_lens->{$contig} <= $min_contig_len) {
	    $tot_short_dna += $contig_lens->{$contig};
	}
    }
    
    my $rc = ($tot_short_dna >= $max_frac_short * $tot_dna) || 0;
    print STDERR qq(is_metagenome: tot_dna=$tot_dna, tot_short_dna=$tot_short_dna, max_frac_short=$max_frac_short ==> rc=$rc\n\n)
	if $ENV{VERBOSE};
    return $rc;
}


sub is_raw_reads {
    my ($contigs_lens, $min_contig_len) = @_;
    
    my $tot_long_dna = 0;
    foreach my $contig (keys %$contig_lens) {
	if ($contig_lens->{$contig} >= $min_contig_len) {
	    $tot_long_dna += $contig_lens->{$contig};
	}
    }
    
    my $rc = ($tot_long_dna == 0) || 0;
    print STDERR qq(is_raw_reads: tot_long_dna=$tot_long_dna ==> rc=$rc\n\n)
	if $ENV{VERBOSE};
    return $rc;
}




sub make_restart {
    my($chkD, $tmpD, $restartD, $checkpoint_extension) = @_;
    print STDERR (qq(\nmake_restart:\n),
		  qq(   extension=\'$checkpoint_extension\'\n),
		  qq(   chkD=\'$chkD\'\n),
		  qq(   tmpD=\'$tmpD\'\n),
		  qq(   restartD=\'$restartD\'\n\n)
		  ) if ($ENV{DEBUG} && (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1)));
    
    if (-d $restartD) {
	system(q(/bin/rm), q(-fR), $restartD)
	    && confess qq(Could not remove restartD=\'$restartD\');
    }
    
    system(q(/bin/cp), q(-R), $tmpD, $restartD)
	&& die qq(Could not copydir tmpD=\'$tmpD\' to restartD=\'$restartD\');
    
    system(q(/bin/touch), $restartD)
	&& die qq(Could not touch timestamp for restartD=\'$restartD\');
    
    if ($chkD && (-d $chkD) && $checkpoint_extension) {
	my $name = basename($tmpD);
	my $chkD_extended = qq($chkD/$name.$checkpoint_extension);
	
	system(q(/bin/cp), q(-R), $tmpD, $chkD_extended)
	    && die qq(Could not copydir tmpD=\'$tmpD\' to chkD=\'$chkD_extended\');
	
	system(q(/bin/touch), $chkD_extended)
	    && die qq(Could not touch timestamp for chkD=\'$chkD_extended\');
    }
    
    return 1;
}


sub find_rnas {
    my ($keep, $meta,$figV,$sapO,$annoO, $domain,$taxonID, $chkD,$tmpD,$restartD,$errD, $errfile_name) = @_;
    my ($msg, $tmp, $genus, $species);
    
    warn (qq(find_rnas: domain=), $domain, qq(\n)) if ($ENV{VERBOSE} || $ENV{DEBUG});
    
#... Skip if not a prokaryote ...
    return 1 if (!$domain || ($domain ne q(Bacteria)) && ($domain ne q(Archaea)));
    
#... Generates 'closeset.genomes' file as a side-effect
#    (yes, I know it's bad practice! :-(
    if (-s "$tmpD/Features/peg/tbl") {
	($tmp, $genus, $species) = &find_nearest_neighbor($figV, $sapO, $tmpD, $num_neighbors);
	$msg = qq(find_nearest_neighbor returns: domain=$domain, genus=$genus, species=$species);
	warn($msg, qq(\n\n)) if $ENV{VERBOSE};
	&log($tmpD, $msg)    if $ENV{VERBOSE};
    }
    if ($keep) { return 1; }
    warn (qq(find_rnas: new domain=), $domain, qq(\n)) if ($ENV{VERBOSE} || $ENV{DEBUG});
    
    $domain  = $domain  ? substr($domain, 0, 1) : $tmp;
    $genus   = $genus   ? quotemeta($genus)     : q(Unknown);
    $species = $species ? quotemeta($species)   : q(sp.);
    
    my $contigs_fh;
    my $contigs_file = qq($tmpD/contigs);
    open($contigs_fh, qq(<$contigs_file))
	|| die qq(Could not read-open \'$contigs_file\');
    
    my $results = $annoO->find_rnas(-input   => $contigs_fh,
				    -domain  => $domain,
				    -genus   => $genus,
				    -species => $species,
				    );
    close($contigs_fh);
    
    my ($rna_fasta, $rna_tuples) = @$results;
    
    if (not $rna_fasta) {
	$msg = q(No RNAs found);
	warn ($msg, qq(\n)) if $ENV{VERBOSE};
	&log($tmpD, $msg);
    }
    else {
	my $tmp_rna_fh;
	my $tmp_rna_fasta_file = qq($FIG_Config::temp/tmp_rna.$$.fasta);
	open($tmp_rna_fh, qq(>$tmp_rna_fasta_file))
	    || die qq(Could not write-open \'$tmp_rna_fasta_file\');
	print $tmp_rna_fh $rna_fasta;
	close($tmp_rna_fh);
	
	open($tmp_rna_fh, qq(<$tmp_rna_fasta_file))
	    || die qq(Could not read-open \'$tmp_rna_fasta_file\');
	
	my %seq_of = map { $_->[0] => $_->[2] } read_fasta($tmp_rna_fh);
	
	foreach my $feature (@$rna_tuples) {
	    my ($id, $contig, $beg, $end, $func) = @$feature;
	    my $loc = join(q(_), ($contig, $beg, $end));
	    my $fid = $figV->add_feature(q(master:rast), $taxonID, q(rna), $loc, q(), $seq_of{$id},
					 qq($tmpD/called_by), q(find_rnas));
	    if ($fid) {
		$figV->assign_function($fid, q(master:rast), $func);
	    }
	    else {
		die (qq(Could not add feature=$id\n), Dumper($rna_tuples, \%seq_of));
	    }
	}
    }
    
    return 1;
}

sub find_special_proteins {
    my ($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD) = @_; 
    if ($keep) { return 1; }
    
    my @contigL = &gjoseqlib::read_fasta(qq($tmpD/contigs));
    
    my $selenoL = $annoO->find_special_proteins(-contigs   => \@contigL,
						-templates => q(selenoprotein),
						-comment   => q(selenoprotein),
						);
    
    my $pyrroL  = $annoO->find_special_proteins(-contigs   => \@contigL,
						-templates => q(pyrrolysine),
						-comment   => q(pyrrolysoprotein),
						);
    open(SPECIAL, qq(>$tmpD/special_pegs))
	|| die qq(Could not write-open special_pegs file '$tmpD/special_pegs');
    foreach my $prot (@$selenoL, @$pyrroL) {
	my $type = $prot->{comment};
	my $func = $prot->{reference_def};
	
	my $fid  = $figV->add_feature(q(master:rast), $taxonID, q(peg), $prot->{location}, q(),
				      $prot->{sequence}, qq($tmpD/called_by), q(find_special_proteins));
	if ($fid) {
	    print SPECIAL qq($fid\t$type\n);
	    $figV->assign_function($fid, q(master:rast), $func, q(), qq($tmpD/assigned_functions));
	}
	else {
	    die (qq(Could not add feature=$fid\n), Dumper($prot));
	}
    }
    close(SPECIAL);
    
    return 1;
}


sub run_find_genes {
    my ($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name, $kmerDataset) = @_;
#    use IPC::Run qw( run timeout );
    
    my $old = $keep ? q(old) : q();
    my $kmerDataSwitch = $kmerDataset ? qq(-kmerDataset=$kmerDataset) : q();

    my $rc = &my_run(qq(find_genes_based_on_kmers $kmerDataSwitch $tmpD $tmpD/found $old \> $errD/$errfile_name 2\>\&1));
    
    if ($ENV{VERBOSE}) {
	if ($rc == 0) {
	    print STDERR qq(run_find_genes succeeded:\trc=$rc);
	}
	else {
	    print STDERR qq(run_find_genes failed:\trc=$rc);
	}
    }
    
    return $rc;
}


sub post_process_rnas_and_glimmer {
    my ($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name, $kmerDataset) = @_;
    my ($msg, $rc);
    my $kmerDataSwitch = $kmerDataset ? qq(-kmerDataset=$kmerDataset) : q();
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Promote remaining ORFs to PEGs...
#-----------------------------------------------------------------------
    if (! $meta->get_metadata('status.rp.postprocess_rnas_and_glimmer')) {
	if ($keep) {
#...If just re-annotating an existing set of calls,
#   write assigned_functions for the PEG IDs listed in the found file.
	    
	    system "rm -fR $tmpD/Features/orf";
	    open(IN,"<$tmpD/found") || die "could not open $tmpD/found";
	    open(OUT,">$tmpD/assigned_functions") || die "could not open $tmpD/assigned_functions";
	    my %seen;
	    while (defined($_ = <IN>)) {
		chomp;
		my ($peg, undef, $func) = split(/\t/,$_);
		if (! $seen{$peg}) {
		    $seen{$peg} = 1;
		    print OUT "$peg\t$func\n";
		}
	    }
	    close(IN);
	    close(OUT);
	}
	else {
	    &my_run("$bin/find_genes_based_on_kmers $kmerDataSwitch $tmpD $tmpD/found > $errD/find_genes_based_on_kmers.stage-1.stderr 2>&1");
	    &log($tmpD, 'Finished first pass of finding genes matching families found in close genomes');
	    &make_restart($chkD, $tmpD, $restartD,  qq(find_genes_based_on_kmers.stage-1));
	    
	    &my_run("$bin/find_genes_based_on_kmers $kmerDataSwitch $tmpD $tmpD/found > $errD/find_genes_based_on_kmers.stage-2.stderr 2>&1");
	    &log($tmpD, 'Finished second pass of finding genes matching families found in close genomes');
	    &make_restart($chkD, $tmpD, $restartD,  qq(find_genes_based_on_kmers.stage-2));
	    
#...Promote the remaining ORFs to PEGs (writes functions to the assigned_functions file)
	    print STDERR (qq(before promotion:\t), `wc $tmpD/Features/*/tbl`, qq(\n))
		if ($ENV{DEBUG} && (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1)));
	    &my_run("$bin/promote_orfs_to_pegs $tmpD $tmpD/found > $errD/promote_orfs.stderr 2>&1");
	    print STDERR (qq(after promotion:\t), `wc $tmpD/Features/*/tbl`, qq(\n))
		if ($ENV{DEBUG} && (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1)));
	    &log($tmpD, 'Finished promoting genes that could not be placed in any FIGfam');
	}
	
	&make_restart($chkD, $tmpD, $restartD,  qq(promote_orfs_to_pegs));
	$meta->set_metadata('status.rp.promote_orfs_to_pegs',1);
    }
    
    return 1;
}

sub cleanup {
    my ($bin, $keep, $origD, $restartD, $tmpD, $errD, $newD) = @_;
    
    if (!$keep) {
	if (!-d qq($tmpD/Features/peg))        { mkdir(qq($tmpD/Features/peg));            }
	if (!-e qq($tmpD/Features/peg/tbl))    { open(TMP, qq(>$tmpD/Features/peg/tbl));   }
	if (!-e qq($tmpD/Features/peg/fasta))  { open(TMP, qq(>$tmpD/Features/peg/fasta)); }
	close(TMP);
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
    &my_run("$bin/make_genome_dir_for_close $origD $tmpD $newD 2> $errD/make_genome_dir_for_close.stderr");
    &make_restart($chkD, $newD, $restartD, qq(make_genome_dir_for_close));
    
    &my_run("$bin/renumber_features -print_map $newD > $errD/renumber_features.map 2> $errD/renumber_features.stderr");
    &make_restart($chkD, $newD, $restartD, qq(renumber_features));
    
#   &my_run("cat $newD/proposed*functions | $bin/rapid_subsystem_inference $newD/Subsystems 2> $errD/rapid_subsystem_inference.stderr");
#   &log($tmpD, 'Finished inferring subsystems');
    
    if (-s "$tmpD/Features/peg/fasta") {
	&my_run("$FIG_Config::ext_bin/formatdb -p -i $tmpD/Features/peg/fasta", 1);
    }
    
    system("/bin/cp -R  $procD/* $errD/");
    unless ($ENV{DEBUG})  {
	system("/bin/rm -fR $procD");
    }
    
    return 1;
}


sub run_mga {
    my ($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name, $kmerDataset) = @_;
    my $msg;
    
    return (1) if ($code != 11);
    my $trans_table = $figV->standard_genetic_code();
    
    my $contigs_file = qq($tmpD/contigs);
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Run the fragments or plasmid sequences through the ORF caller (metagene)..
#   Create training data
#-----------------------------------------------------------------------------
    if (! $meta->get_metadata('status.rp.run_mga')) {
	if ($keep) {
	    #...Do nothing --- Annotations will be handled by &post_process_mga();
	}
	else {
	    $msg = q(Starting to run MGA);
	    warn ($msg, qq(\n)) if $ENV{VERBOSE};
	    &log($tmpD, $msg);
	    
	    my $mga_pipe;
	    open($mga_pipe, qq($FIG_Config::mga_bin/mga $contigs_file -s |))
		|| die qq(Could not pipe-out open MGA);
	    
	    my @mga_hits;
	    my $line = <$mga_pipe>;    print STDERR (q(MGA: ), $line)  if ($ENV{DEBUG} && defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    while ($line && ($line =~ m/^\#\s+(\S+)/o)) {
		my $contig_id = $1;
		$line = <$mga_pipe>;   print STDERR (q(MGA: ), $line)  if ($ENV{DEBUG} && defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		$line = <$mga_pipe>;   print STDERR (q(MGA: ), $line)  if ($ENV{DEBUG} && defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		$line = <$mga_pipe>;   print STDERR (q(MGA: ), $line)  if ($ENV{DEBUG} && defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		while ($line && $line !~ /^\#/) {
		    chomp $line;
		    my ($id, $start, $end, $strand, $frame, $trunc) = split(/\t/, $line);
		    push @mga_hits, [$id, $contig_id, $start, $end, $strand, $frame, $trunc, $line];
		    $line = <$mga_pipe>;   print STDERR (q(MGA: ), $line)  if ($ENV{DEBUG} && defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		}
	    }
	    close($mga_pipe);
	    
	    $msg = q(MGA completed);
	    warn ($msg, qq(\n)) if $ENV{VERBOSE};
	    &log($tmpD, $msg);
	    
	    foreach my $call (@mga_hits) {
		my ($id, $contig_id, $left, $right, $strand, $frame, $trunc, $line) = @$call;
		print STDERR (join(qq(\t), ($id, $contig_id, $left, $right, $strand, $frame, $trunc, $line)), qq(\n))
		    if ($ENV{DEBUG} && defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		
		my ($beg, $end);
		if ($strand eq "+") {
		    ($beg, $end) = ($left, $right);
		}
		else {
		    ($beg, $end) = ($right, $left);
		}
		
		my $sign = ($end <=> $beg);
		print STDERR qq(RP4: beg=$beg,\tend=$end,\tsign=$sign\n)
		    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		
		if    ($trunc eq qq(01)) {
		    print STDERR qq(Fixed truncated START:\t($beg, $end) ==> ) if $ENV{VERBOSE};
		    $beg = $end   - $sign * ( 3 * int( (1 + abs($end-$beg)) / 3) - 1);
		    print STDERR qq(($beg, $end):\t$line\n)  if $ENV{VERBOSE};
		}
		elsif ($trunc eq qq(10)) {
		    warn qq(Fixed truncated STOP:\t($beg, $end) ==> ) if $ENV{VERBOSE};
		    $end   = $beg + $sign * ( 3 * int( (1 + abs($end-$beg)) / 3) - 1);
		    print STDERR qq(($beg, $end):\t$line\n) if $ENV{VERBOSE};
		}
		elsif ($trunc eq qq(00)) {
		    warn qq(Fixed double-truncated partial:\t($beg, $end) ==> )
			if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		    $beg = $beg + $sign * $frame;
		    $end = $beg + $sign * ( 3 * int( (1 + abs($end-$beg)) / 3) - 1);
		    print STDERR qq(($beg, $end):\t$line\n) if $ENV{VERBOSE};
		}
		print STDERR qq(===> beg=$beg,\tend=$end,\tsign=$sign\n\n)
		    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		
		my $loc = join(q(_), ($contig_id, $beg, $end));
		my $seq = $figV->dna_seq($taxonID, $loc);
		my $pep = $figV->translate($seq, $trans_table, 1);
		$pep =~ s/\*$//o;

		if (my $fid = $figV->add_feature(q(master:rast), $taxonID, q(orf), $loc, q(), $pep)) {
		    #...Suceeded, do nothing...
		}
		else {
		    die (q(Could not add ORF: ), $loc, qq(\t), $pep) unless $fid;
		}
	    }
 	}
    }
    
    &make_restart($chkD, $tmpD, $restartD,  qq(run_mga));
    $meta->set_metadata('status.rp.run_mga',1);
    
    return 0;
}


sub post_process_mga {
    my ($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name, $kmerDataset) = @_;
    my ($msg, $tbl_file, $fasta_file, @prot_seqs);
    
    my $loc_of_protH = {};
    my $seq_of_protH = {};
    my $assignmentsH;
    
    if ($keep) {
	$tbl_file       = qq($tmpD/Features/peg/tbl);
	%$loc_of_protH  = map { m/^(\S+)\t(\S+)/o ? ($1 => $2) : () } &SeedUtils::file_read($tbl_file);
	
	$fasta_file     = qq($tmpD/Features/peg/fasta);
	@prot_seqs      = &gjoseqlib::read_fasta(\$fasta_file);
	$assignmentsH   = &get_kmer_based_functions($annoO, 8, 2, 2, \@prot_seqs, $kmerDataset);
	
	%$seq_of_protH  = map { ($_->[0] => $_->[2]) } @prot_seqs;
	
	if (not &add_pegs($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name,
			  $loc_of_protH, $seq_of_protH, $assignmentsH, q(postprocess_mga))) {
	    die qq(Could not add PEGs);
	}
    }
    else {
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Run the training data from the metagene caller through the ORF caller (GLIMMER)..
#-----------------------------------------------------------------------------
	my $tmp_orf_tbl = qq($tmpD/Features/orf/tbl);
	if (! $meta->get_metadata('status.rp.annoserver.call_genes')) {
	    if (!-s $tmp_orf_tbl) {
		$msg = q(No MGA ORFs found to train GLIMMER with);
		warn ($msg, qq(\n)) if $ENV{VERBOSE};
		&log($tmpD, $msg);
	    }
	    else {
		$msg = q(Using MGA as training data for 'annoO->find_genes');
		warn ($msg, qq(\n)) if $ENV{VERBOSE};
		&log($tmpD, $msg);
		
		my %tmp_trainH = map { m/^(\S+)\s+(\S+)/o ? ($1 => $2) : () } &SeedUtils::file_read($tmp_orf_tbl);
#		print STDERR Dumper(\%tmp_trainH);
		
		my ($contigs_fh, $retval_pair, $prot_callsL);
		my $contigs_file = qq($tmpD/contigs);
		open($contigs_fh, qq(<$contigs_file))
		    || die qq(Could not read-open contigs file \'$contigs_file\');
		if ($retval_pair = $annoO->call_genes(-input             => $contigs_fh,
						      -trainingLocations => \%tmp_trainH,
						      -geneticCode       => $code
						      )
		    ) {
		    ($fasta_file, $prot_callsL) = @$retval_pair;
		    @prot_seqs     = &gjoseqlib::read_fasta(\$fasta_file);
		    %$loc_of_protH = map { $_->[0] => join(q(_), ($_->[1], $_->[2], $_->[3])) } @$prot_callsL;
		    %$seq_of_protH = map { $_->[0] => $_->[2] } @prot_seqs;
#		    print STDERR Dumper($prot_callsL, \@prot_seqs, $loc_of_protH, $seq_of_protH);
		    
		    if (@prot_seqs > 0) {
			$msg = q(Completed 'annoO->call_genes');
			warn ($msg, qq(\n)) if $ENV{VERBOSE};
			&log($tmpD, $msg);
			
			my $assignmentsH = &get_kmer_based_functions($annoO, 8, 2, 2, \@prot_seqs, $kmerDataset);
			
			if (&add_pegs($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name,
				      $loc_of_protH, $seq_of_protH, $assignmentsH, q(postprocess_mga))
			    ) {
			    system("rm -fR $tmpD/Features/orf")
				&& die qq(Could not remove ORF directory \'$tmpD/Features/orf\');
			}
			else {
			    die qq(Could not add PEGs);
			}
		    }
		    else {
			$msg = q(FAILED 'annoO->find_genes');
			warn ($msg, qq(\n)) if $ENV{VERBOSE};
			&log($tmpD, $msg);
		    }
		}
	    }
	}
	&make_restart($chkD, $tmpD, $restartD,  qq(recall_genes_using_glimmer));
	$meta->set_metadata('status.rp.recall_genes_using_glimmer',1);
    }
    
    
# #+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# #...Promote remaining ORFs to PEGs...
# #-----------------------------------------------------------------------
#     if (! $meta->get_metadata('status.rp.promote_orfs_to_pegs')) {
# 	if ($keep) {
# #+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# #...If just re-annotating an existing set of calls,
# #   write assigned_functions for the PEG IDs listed in the found file.
# #-----------------------------------------------------------------------
# 	    system "rm -fR $tmpD/Features/orf";
# 	    my %func_of = map { m/^(\S+)\t([^\t]+)/o ? ($1 => $2) : () } &SeedUtils::file_read(qq($tmpD/found));
# 	    foreach my $fid (sort { &SeedUtils::by_fig_id($a,$b) } (keys %func_of)) {
# 		$figV->assign_function($fid, q(master:rast), $func_of{$fid});
# 	    }
# 	}
# 	else {
# #+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# #...Promote the remaining ORFs to PEGs (make assigned_functions entries)
# #-----------------------------------------------------------------------
# 	    &my_run("$bin/promote_orfs_to_pegs $tmpD $tmpD/found > $errD/promote_orfs.stderr 2>&1");
# 	    &log($tmpD, 'Finished promoting genes that could not be placed in any FIGfam');
# 	}
#	
# 	&make_restart($chkD, $tmpD, $restartD,  qq(promote_orfs_to_pegs));
# 	$meta->set_metadata('status.rp.promote_orfs_to_pegs',1);
#   }
    
    return 1;
}

sub add_pegs {
    my ($keep, $meta,$figV,$sapO,$annoO, $taxonID,$code, $chkD,$tmpD,$restartD,$errD, $errfile_name,
	$loc_of_protH, $seq_of_protH, $assignmentsH, $tool_name) = @_;
    
    open(FOUND, qq(>>$tmpD/found))
	|| die qq(could not append-open "found" file '$tmpD/found');
    
    my $fid;
    foreach my $prot_id (sort { &SeedUtils::location_cmp($loc_of_protH->{$a}, $loc_of_protH->{$b}) } (keys %$loc_of_protH)) {
	my $loc = $loc_of_protH->{$prot_id};
	my $seq = $seq_of_protH->{$prot_id};
	
	if ($keep) {
	    $fid = $prot_id;
	    open( CALLED_BY, qq(>>$tmpD/called_by)) || die qq(Could not append-open \'$tmpD/called_by\');
	    print CALLED_BY  qq($fid\t$tool_name\n);
	    close(CALLED_BY);
	}
	else {
	    $fid = $figV->add_feature(q(master:rast), $taxonID, q(peg), $loc, q(), $seq,
				      qq($tmpD/called_by), $tool_name);
	}
	
	my $func = q();
	if ($fid) {
	    if (defined($assignmentsH->{$prot_id}) && defined($func = $assignmentsH->{$prot_id}->[0])) {
		print FOUND (join(qq(\t), ( $fid, @ { $assignmentsH->{$prot_id} })), qq(\n));
		
		if (not $figV->assign_function($fid, q(master:rast), $func, 2, qq($tmpD/assigned_functions))) {
		    die (qq(Could not add function for prot_id=$prot_id, fid=$fid, func=$func\n),
			 Dumper($loc_of_protH, $seq_of_protH, $assignmentsH)
			 );
		}
	    }
	}
	else {
	    die (qq(Could not add feature=$prot_id\n), Dumper($loc_of_protH, $seq_of_protH, $assignmentsH));
	}
    }
    
    close(FOUND);
    return 1;
}
    

sub kmer_approach {
    die (q(Method 'kmer_approach' not yet implemented), qq(\n), Dumper(\@_));
}


sub get_kmer_based_functions {
    my ($annoO, $kmer, $scoreThreshold, $seqHitThreshold, $protL, $kmerDataset) = @_;
    my @kmerDataset = $kmerDataset ? (q(-kmerDataset) => $kmerDataset) : ();
    
    my $result_handle = $annoO->assign_function_to_prot(-input => $protL,
							-kmer  => $kmer,
							-assignToAll     => 0,
							-scoreThreshold  => $scoreThreshold,
							-seqHitThreshold => $seqHitThreshold,
							@kmerDataset
							);
    my $resultH = {};
    while (my $result = $result_handle->get_next()) {
	my ($prot_id, $function, $otu, $score, $nonoverlap_hits, $overlap_hits) = @$result;
	if (defined($nonoverlap_hits) && ($nonoverlap_hits > 0)) {
	    $resultH->{$prot_id} = [$function, $otu, $score, $nonoverlap_hits, $overlap_hits];
	}
    }
    return $resultH;
}

sub find_nearest_neighbor {
    my ($figV, $sapO, $orgdir, $num_neighbors) = @_;
    
    my $outfile = qq($orgdir/closest.genomes);
    print STDERR qq(\nfind_nearest_neighbor: outfile=$outfile\n) if $ENV{VERBOSE};
    
    my @out = $figV->run_gathering_output(q(find_approx_neigh), $orgdir, $num_neighbors);
    open(TMP, qq(>$outfile))
	|| die qq(could not write-open \'$outfile\');
    print TMP @out;
    close(TMP);
    print STDERR (@out, qq(\n)) if $ENV{VERBOSE};
    
    if (@out) {
	my ($closest, $genus, $species) = ($out[0] =~ m/^(\S+)\t\d+\t(\S+)\s+(\S+)/o);
	my $result = $sapO->genome_domain(-ids => [$closest]);
	my $domain = $result->{$closest};
	return ($domain, $genus, $species);
    }
    
    return ();
}



sub correct_frameshifts {
    my ($keep,$fix_fs, $meta,$figV,$sapO,$annoO, $chkD,$tmpD,$restartD,$errD) = @_;
    
    if ($fix_fs || $meta->get_metadata("correction.frameshifts")) {
	if (! $meta->get_metadata('status.rp.correct_frameshifts')) {
	    if ($keep) {
		#...Annotate FS only...
		&my_run("correct_frameshifts -nofatal -code=$code $tmpD -justMark > $errD/correct_frameshifts.stderr 2>&1");
	    }
	    else {
		&my_run("correct_frameshifts -nofatal -code=$code $tmpD > $errD/correct_frameshifts.stderr 2>&1");
	    }
	    
	    &make_restart($chkD, $tmpD, $restartD,  qq(correct_frameshifts));
	    $meta->set_metadata('status.rp.correct_frameshifts',1);
	}
    }
    
    return 1;
}


sub find_and_backfill_missing_and_miscalled {
    my ($keep,$backfill, $meta,$figV,$sapO,$annoO, $taxon_ID,$code, $chkD,$tmpD,$restartD,$errD) = @_;
#...Look for missing genes and miscalled genes
    
    if ($keep || (not $backfill)) {
	return 1;
    }
    else {
	if (not $meta->get_metadata("correction.backfill_gaps")) {
	    return 1;
	}
	else {
	    mkdir("$tmpD/CorrToReferenceGenomes")
		|| die qq(Could not create $tmpD/CorrToReferenceGenomes);
	    
	    my $missing_dir = qq($tmpD/Missing_Genes);
	    mkdir($missing_dir) || die qq(Could not create dir $missing_dir/);
	    my @closest_genomes = map { m/^(\d+\.\d+)/o ? ($1) : () } &FIG::file_read(qq($tmpD/closest.genomes));
	    foreach my $ref_genome (@closest_genomes) {
		my $corr_table = qq($tmpD/CorrToReferenceGenomes/$ref_genome);
		&my_run("svr_corresponding_genes -d $tmpD $taxonID $ref_genome > $corr_table");
		
		#
		# It is possible that corresponding genes generates zero-length output
		# in the event that there is asynchrony between the servers and the local
		# seed. Just skip them if that is the case.
		#
		if (-s $corr_table) {
		    &my_run("find_missing_genes --orgdir $tmpD --corr $corr_table --ref $ref_genome > $missing_dir/$ref_genome 2> $missing_dir/$ref_genome\.err");
		}
		else {
		    print STDERR "Zero-length correspondence table generated for $ref_genome\n";
		}
	    }
	    &my_run("merge_missing_gene_output $tmpD $missing_dir > $tmpD/missing_genes.out 2> $errD/missing_genes.err");
	    
	    my @missing_pegs = map { chomp; $_ =~ s/\%0A/\n/go; $_ } &FIG::file_read(qq($tmpD/missing_genes.out));
	    
	    foreach my $missing (@missing_pegs) {
		my ($loc, $frameshift, $length, $adjacent, $ref_pegs, $template_peg, $translation, $FS_evidence) = split(qq(\t), $missing);
		$loc =~ s/$taxonID\://g;
		my $new_fid = $figV->add_feature(q(rast), $taxonID, q(peg), $loc, undef, $translation);
		if (not $new_fid) {
		    die qq(Could not add new PEG at loc=$loc, translation=$translation);
		}
		else {
		    my $annot = (q(Gene prediction based on template PEG ) . $template_peg . qq(\n)
				 . q(with support from PEGs) . $ref_pegs . qq(\n)
			);
		    
		    $figV->add_annotation($new_fid, q(rast), $annot);
		    
		    if ($frameshift) {
			$FS_evidence ||= qq(Sequence contains a probable frameshift);
			$figV->add_annotation($new_fid, q(rast), $FS_evidence);
		    }
		}
	    }
	}
	
	if (!-s "$tmpD/closest.genomes") {
	    &log($tmpD, qq(Could not find any nearby genomes --- skipping \'backfill_gaps\'));
	}
	else {
	    my $peg_tbl   = "$tmpD/Features/peg/tbl";
	    my $rna_tbl   = (-s "$tmpD/Features/rna/tbl") ? "$tmpD/Features/rna/tbl" : "";
	    my $extra_tbl = "$tmpD/Features/peg/tbl.extra";
	    
	    if (!-s "$tmpD/closest.genomes") {
		&log($tmpD, "Could not find any nearby genomes --- skipping \'backfill_gaps\'");
	    }
	    else {
		my $peg_tbl   = "$tmpD/Features/peg/tbl";
		my $rna_tbl   = (-s "$tmpD/Features/rna/tbl") ? "$tmpD/Features/rna/tbl" : "";
		my $extra_tbl = "$tmpD/Features/peg/tbl.extra";
		
		&my_run("backfill_gaps -orgdir=$tmpD -genetic_code=$code $tmpD/closest.genomes  $taxonID $tmpD/contigs $rna_tbl $peg_tbl > $extra_tbl 2> $errD/backfill_gaps.stderr");
		if (-s $extra_tbl) {
		    open( CALLED_BY, ">>$tmpD/called_by") || die "Could not append-open $tmpD/called_by";
		    print CALLED_BY map { m/^(\S+)/ ? qq($1\tbackfill_gaps\n) : qq() } &FIG::file_read($extra_tbl);
		    close(CALLED_BY);
		    &my_run("cat $extra_tbl >> $peg_tbl");
		    &my_run("get_fasta_for_tbl_entries -code=$code $tmpD/contigs < $extra_tbl >> $tmpD/Features/peg/fasta");
		    system("rm -f $extra_tbl") && warn "WARNING: Could not remove $extra_tbl";
		}
	    }
	    
	    &make_restart($chkD, $tmpD, $restartD,  qq(backfill_gaps));
	    $meta->set_metadata('status.rp.backfill_gaps',1);
	}
    }
    
    return 1;
}

