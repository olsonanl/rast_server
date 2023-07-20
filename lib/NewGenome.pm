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

package NewGenome;

use strict;
use FIG;
my $fig;
eval {
    $fig = new FIG;
};

use Carp qw(:DEFAULT cluck);
use Data::Dumper;

# use Memoize;
# memoize('search_for_upstream_start');
# memoize('search_for_upstream_stop');
# memoize('search_for_downstream_start');
# memoize('extend_to_downstream_stop');

use vars '$AUTOLOAD';
sub AUTOLOAD
{
    my ($self, @args) = @_;
    
    confess "\nObject accessed via unknown method $AUTOLOAD,\n"
	, "with args: ", join(", ", @args), "\n\n"
	, Dumper($self);
}

sub DESTROY
{
    #...Currently, nothing needs to be done...
}

sub what_methods
{
    foreach my $symname (sort keys %NewGenome::)
    {
	local *name = $NewGenome::{$symname};
	print STDERR "$symname\n" if defined(&name);
    }
}

use constant _CONTIG    => 0;
use constant _LOC_END   => 1;
use constant _STRAND    => 2;
use constant _LENGTH    => 3;
use constant _ORF_LEN   => 4;
use constant _ORF_TRANS => 5;
use constant _ORF_SIMS  => 6;

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# This is the constructor.  Presumably, $class is 'NewGenome'.  
# usage: my $newG = new NewGenome($dir)
#-----------------------------------------------------------------------
sub new 
{
    my ($class, $dir, @features) = @_;
    
    my $newG = {};
    bless  $newG, $class;
    
#...This is a _DANGEROUS_ hack --- fix ASAP !!!
    $newG->{_glimmer_version} = 3;                 #...Default to GLIMMER-3
    $newG->{_glimmer_path}    = $FIG_Config::bin;
    
    if (defined($ENV{RAST_GLIMMER_VERSION})) {
	my $glimmer_version = $ENV{RAST_GLIMMER_VERSION};
	
	if    ($glimmer_version == 2) {
	    #...Do nothing
	    print STDERR "ORF calls will use GLIMMER-2\n" if $ENV{VERBOSE};
	}
	elsif ($glimmer_version == 3) {
	    $newG->{_glimmer_version} = 3;
	    $newG->{_glimmer_path} = "$FIG_Config::ext_bin/../apps/glimmer3/bin";
	    print STDERR "ORF calls will use GLIMMER-3\n" if $ENV{VERBOSE};
	}
	else {
	    confess "ERROR: Only GLIMMER-2 or GLIMMER-3 are currently supported";
	}
    }
    
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Load mandatory "skeleton directory" data files...
#----------------------------------------------------------------------- 
    $newG->{_dir} = $dir;
    ($dir =~ /^(.*\/)?(\d+\.\d+)$/) || die "Skeleton path $dir does not end in a well-formed Org-ID";
    my $taxid = $newG->{_taxid} = $2;
    
    (-s "$dir/contigs")   || die "$dir/contigs does not exist or has zero size";
    (-s "$dir/GENOME")    || die "$dir/GENOME does not exist or has zero size";
    (-s "$dir/PROJECT")   || die "$dir/PROJECT does not exist or has zero size";
    (-s "$dir/TAXONOMY")  || die "$dir/TAXONOMY does not exist or has zero size";
    
    &FIG::verify_dir("$dir/Features");
    
    $newG->{_genome}   = &FIG::file_head(qq($dir/GENOME), 1)   or die "Could not read $dir/GENOME";
    chomp $newG->{_genome};
    
    $newG->{_project}  = &FIG::file_read(qq($dir/PROJECT))     or die "Could not read $dir/PROJECT";
    chomp $newG->{_project};
    
    $newG->{_taxonomy} = &FIG::file_head(qq($dir/TAXONOMY), 1) or die "Could not read $dir/TAXONOMY";
    chomp $newG->{_taxonomy};
    
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Build genetic code data...
#-----------------------------------------------------------------------    
    if (-s "$dir/GENETIC_CODE") {
	my $code = &FIG::file_head(qq($dir/GENETIC_CODE), 1);
	chomp $code;
	if ($code =~ m/^(\d+)/o) {
	    print STDERR "Using genetic code $1\n" if $ENV{VERBOSE};
	    $newG->{_genetic_code_number} = $1;
	    $newG->{_translation_table}   = &FIG::genetic_code($1);
	}
	else {
	    die "Sorry, cannot handle non-numeric genetic code $code";
	}
    }
    else {
	#...Default to standard code:
	print STDERR "Using standard genetic code\n" if $ENV{VERBOSE};
	$newG->{_genetic_code_number} = 11;
	$newG->{_translation_table}   = &FIG::standard_genetic_code();
    }

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Add ambiguous codons that _could_ be STOPs or STARTs...
#-----------------------------------------------------------------------
    my @ambigs = qw(a c g t u m r w s y k b d h v n x);
    
#...STOPs: Disabled because they seem to cause problems
#  =====================================================
#     foreach my $x (@ambigs) {
# 	foreach my $y (@ambigs) {
# 	    foreach my $z (@ambigs) {
# 		my $codon = $x.$y.$z;
# 		if (grep {
# 		    &FIG::translate($_, $newG->{_translation_table}) eq qq(*)
# 		    } (&_expand_ambigs($codon)))
# 		{
# 		    $newG->{_translation_table}->{uc($codon)} = qq(*);
# 		}
# 	    }
# 	}
#     }
    
    $newG->{_valid_start_codons} = {};
    foreach my $x (@ambigs) {
	foreach my $y (@ambigs) {
	    foreach my $z (@ambigs) {
		my $codon = $x.$y.$z;
		if (grep { $_ =~ m/^[agt]tg/io } (&_expand_ambigs($codon))) {
		    $newG->{_valid_start_codons}->{uc($codon)} = qq(M);
		}
	    }
	}
    }
    
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Check contigs IDs for dups, while building nucleotide stats...
#-----------------------------------------------------------------------    
    my $contig_seqs = {};
    my $contig_lens = {};
    open(CONTIGS,"<$dir/contigs") || die "could not read-open $dir/contigs";
    
    my ($id, $seqP);
    my $GC_count = 0;
    my $AT_count = 0;
    my $trouble  = 0;
    while (($id, $seqP) = &FIG::read_fasta_record(\*CONTIGS))
    {
	if (defined($contig_lens->{$id})) {
	    $trouble = 1;
	    warn "Duplicate contig ID: $id\n";
	    next;
	}
	
	$contig_seqs->{$id} = lc($$seqP);
	$contig_lens->{$id} = length($$seqP);
	
	$GC_count += ($$seqP =~ tr/gcGC//);
	$AT_count += ($$seqP =~ tr/atAT//);
    }
    close(CONTIGS);
    
    if ($trouble) {
	die "\nAborted due to duplicate contig IDs\n\n";
    }
    
    $newG->{_contig_seqs} = $contig_seqs;
    $newG->{_contig_lens} = $contig_lens;
    $newG->{_GC_content}  = ($GC_count + 1) / ($GC_count + $AT_count + 2);
    

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Auxilliary hashes to support insertion and deletion of features:
#-----------------------------------------------------------------------
    $newG->{_used_list}  = {};
#   $newG->{_sort_left}  = {};
#   $newG->{_sort_right} = {};
#   $newG->{_overlaps}   = {};

    
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Quit here if no features will be imported:
#-----------------------------------------------------------------------
    if (grep { m/^none/o } @features) {
	return $newG;
    }
    
    
########################################################################
########################################################################
########################################################################


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Import existing features:
#-----------------------------------------------------------------------    

    if (-d "$dir/Features/rna") {
	print STDERR "Directory $dir/Features/rna exists, and will be loaded\n" if $ENV{VERBOSE};
    }
#   else {
# 	if (grep { m/^(rna|all)$/io } @features) {
# 	    foreach my $entry ( $newG->find_rna() )
# 	    {
# 		chomp $entry;
# 		my (undef, $seed_loc, $func) = split /\t/, $entry;
# 		$newG->add_feature( -type => 'rna'
# 				    , -loc  => $newG->from_seed_loc($seed_loc)
# 				    , -func => $func )
# 		    || die "Could not add RNA entry $entry";
# 	    }
# 	}
#     }
    
    if (not @features)  { $features[0] = 'all'; }
    if ($features[0] eq 'all') {
	print STDERR "Loading all features: " if $ENV{VERBOSE};
	if (-d "$dir/Features") {
	    opendir(FEATURES, "$dir/Features") || confess "Could not opendir $dir/Features";
	    @features = grep { (-d "$dir/Features/$_") && !m/^\./o } readdir(FEATURES);
	    closedir(FEATURES) || confess "Could not closedir $dir/Features";
	    
	    if ($ENV{VERBOSE}) {
		if (@features) {
		    print STDERR join(", ", @features);
		}
		else {
		    print STDERR "No feature directories found.";
		}
		
		print STDERR "\n";
	    }
	}
	else {
	    confess "No directory '$dir/Features' found";
	}
    }
    
    if (@features)
    {
	if ($newG->import_features(@features)) {
	    print STDERR ("Imported ", join(', ', @features), "\n") if $ENV{VERBOSE};
	}
    }
    
    return $newG;
}

sub import_features
{
    my ($self, @types) = @_;
    my (%orf_lens, $orf_len);
    
    my $dir   = $self->get_genome_dir();
    my $taxid = $self->get_taxid();
    
    if (not @types)
    {
	print STDERR "No feature-types specified --- defaulting to all subdirectories in $dir/Features\n"
	    if $ENV{VERBOSE};
	
	opendir(FEATURES, "$dir/Features")
	    || confess "Could not opendir $dir/Features";
	
	(@types = grep { (not m/^\./o) && (-d "$dir/Features/$_") } readdir(FEATURES))
	    || confess "Could not find any subdirectories in $dir/Features";
	
	closedir(FEATURES) || confess "Could not closedir $dir/Features";
    }
    
    
    foreach my $type (@types) {
	my $feature_dir = "$dir/Features/$type";
	print STDERR "Importing features from $feature_dir\n" if $ENV{VERBOSE};
	
	if (!-d "$feature_dir") {
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1)) {
		cluck "WARNING: Feature directory $feature_dir does not exist";
	    }
	    else {
		warn  "WARNING: Feature directory $feature_dir does not exist";
	    }
	    next;
	}
	
	if (!-s "$feature_dir/tbl") {
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1)) {
		cluck "WARNING: Tbl file $feature_dir/tbl does not exist";
	    }
	    else {
		warn  "WARNING: Tbl file $feature_dir/tbl does not exist";
	    }
	    next;
	}
	
	
	if (($type eq 'orf') && (-s "$feature_dir/orf_len")) {
	    open(ORF_LEN, "<$feature_dir/orf_len")
		|| confess "Could not read-open $feature_dir/orf_len";
	    
	    %orf_lens = map { m/^(\S+)\t(\d+)/o ? ($1 => $2)
				                : do { warn("Malformed ORF-length entry $_");
						       ();
						     }
			    } <ORF_LEN>;
	    close(ORF_LEN) || die "Could not close $feature_dir/orf_len";
	}
	
	
	my %tmp_seq_of;
	undef %tmp_seq_of;
	
	if (!-s "$feature_dir/fasta") {
	    confess "Fasta file $feature_dir/fasta does not exist";
	}
	else {
	    open(FASTA, "<$feature_dir/fasta") || confess "Could not read-open $feature_dir/fasta";
	    my $entry;
	    while (my ($fid, $seqP) = &FIG::read_fasta_record(\*FASTA)) {
		if (length($$seqP)) {
		    print STDERR "Caching sequence for feature $fid\n" if $ENV{VERBOSE};
		    
		    if (($type eq 'peg') || ($type eq 'orf')) {
			    $$seqP =~ s/\*$//o;
			}
		    $tmp_seq_of{$fid} = $$seqP;
		}
		else {
		    warn "Sequence for $fid has zero-length FASTA entry --- not caching\n";
		}
	    }
	    close(FASTA) || die "Could not close $feature_dir/fasta";
	}
	
	open(TBL, "<$feature_dir/tbl") || confess "Could not read-open $feature_dir/tbl";
	
	my ($entry, $fid, $locus, $rest);
	my ($contig_id, $beg, $end, $loc);
	while (defined($entry = <TBL>)) {
	    chomp $entry;
	    if ($entry =~ m/^(\S+)\t(\S+)/o) {
		($fid, $locus) = ($1, $2);
	    } else {
		confess "Malformed TBL entry: $entry";
	    }
	    
	    if ($fid =~ m/^fig\|(\d+\.\d+)\.([^\/]+)\.(\d+)/o) {
		confess "Taxon-ID $taxid does not match FID $fid" unless ($1 eq $taxid);
		confess "Type $type does not match FID $fid" unless ($2 eq $type);
	    }
	    else {
		confess "Malformed FID in $type entry $entry";
	    }
	    
	    $loc = $self->from_seed_loc($locus);
	    
	    my $func    = "";
	    my $aliases = [];
	    if (($type eq 'rna') && ($entry =~ m/^\S+\t\S+\t(\S.*)$/o)) {
		$func = $1;
	    }
	    elsif ($entry =~ m/^\S+\t\S+\t(\S.*\S)$/o) {
		@$aliases = [ split /\t/, $1 ];
	    }
	    
	    if (($type eq 'peg') || ($type eq 'orf')) {
		my $dna_seq     = $self->get_dna_subseq($loc);
		my $start_codon = substr($dna_seq, 0, 3);
		if ((not $self->is_valid_start_codon($start_codon)) && (not $self->possibly_truncated($locus)))
		{
		    if ($fid) {
			warn "WARNING: Feature $fid has invalid START codon '$start_codon'.\n";
		    }
		    else {
			warn "WARNING: Feature at loc="
			    , $self->flatten_dumper($loc),
			    , " has invalid START codon '$start_codon'.\n";
		    }
#		    next;
		}
	    }
	    
	    
	    if (not defined($tmp_seq_of{$fid})) {
		warn "Attempt to add feature $fid without corresponding FASTA entry --- skipping\n";
		next;
	    }
	    
	    if ($type eq 'orf') {
		if (!-s "$feature_dir/orf_len") {
		    my ($tmp, $junk, $failed) = $self->search_for_upstream_stop($loc);
		    $loc = $self->copy_loc($tmp);
		}
		else {
		    if ($orf_len = $orf_lens{$fid}) {
			$self->set_orf_length($loc, $orf_len);
		    }
		    else {
			confess "FID $fid has an undefined ORF length";
		    }
		}
	    }
	    
	    $self->add_feature( -type => $type,
				-fid  => $fid,
				-loc  => $loc,
				-seq  => $tmp_seq_of{$fid},
				-func => $func,
				-aliases => $aliases
				)
		|| warn "Could not add feature for $feature_dir/tbl entry $entry";
	    
	    delete $tmp_seq_of{$fid};
	}
	close(TBL) || die "Could not close $feature_dir/tbl";
	
	
	if (my @leftovers = keys %tmp_seq_of) {
	    die "Unprocessed FASTA entries left in sequence cache --- aborting: "
		, join(qq(, ), @leftovers);
	}
    }
    
    
    if (-s "$dir/assigned_functions")
    {
	print STDERR "Opening file $dir/assigned_functions\n" if $ENV{VERBOSE};
	open(FUNC, "<$dir/assigned_functions")
	    || confess "Could not read-open $dir/assigned_functions";
	
	my $entry;
	while (defined($entry = <FUNC>))
	{
	    print STDERR "Reading entry: $entry" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    
	    chomp $entry;
	    if ($entry =~ m/^(\S+)\t(.*)$/o)
	    {
		my ($fid, $func) = ($1, $2);
		if ($self->is_feature($fid)) {
		    $self->set_function($fid, $func)
			|| confess "Could not set function for FID $fid to $func";
		}
		else {
		    warn "Skipping attempt to set function of undefined feature $fid" if $ENV{VERBOSE};
		}
	    }
	    else
	    {
		confess "Malformed entry in $dir/assigned_functions:\n$entry";
	    }
	}
	close(FUNC) || die "Could not close $dir/assigned_functions";
    }
    else {
	print STDERR "File $dir/assigned_functions is empty\n" if $ENV{VERBOSE};
    }
    
    return 1;
}

sub export_features
{
    my ($self, @types) = @_;
    my $dir = $self->get_genome_dir();
    
    if ((not @types) || ($types[0] =~ m/all/o)) { @types = $self->get_feature_types(); }
    
    open(FUNC, ">$dir/assigned_functions")
	|| confess "Could not write-open $dir/assigned_functions";
    
    foreach my $type (@types)
    {
	my $feature_dir = "$dir/Features/$type";
	
	my @fids = $self->get_fids_for_type($type);
	if (@fids > 0) {
	    print STDERR "Exporting ", (scalar @fids), " $type features\n" if $ENV{VERBOSE};
	    
	    use File::Path;    
	    (-d $feature_dir)
		|| mkpath($feature_dir, 0, 0777)
		|| confess "Could not create path $feature_dir";
	    
	    open(TBL,   ">$feature_dir/tbl")
		|| confess "Could not write-open $feature_dir/tbl";
	    
	    open(FASTA, ">$feature_dir/fasta")
		|| confess "Could not write-open $feature_dir/fasta";
	    
	    if ($type eq 'orf') {
		open(ORF_LEN, ">$feature_dir/orf_len")
		    || confess "Could not write-open $feature_dir/orf_len";
		
		foreach my $fid (@fids) {
		    my $orf_loc = $self->get_feature_loc($fid);
		    my $orf_len = $self->get_orf_length($orf_loc);
		    if ((not defined($orf_len)) || (not $orf_len)) {
			confess "Could not fetch ORF boundaries for $fid:\n"
			    , Dumper($self->{_features}->{$fid});
		    }
		    print ORF_LEN "$fid\t$orf_len\n"; 
		}
		close(ORF_LEN) || die "Could not close $feature_dir/orf_len";
	    }
	    
	    foreach my $fid (@fids)
	    {
		my $seed_loc = $self->get_seed_loc($fid);
		$seed_loc   || confess "Could not get SEED-format locus for $fid";
		print STDERR "Exporting FID $fid,"
		    , " loc=", &flatten_dumper($self->get_feature_loc($fid))
		    , " seed_loc=$seed_loc\n"
		    if $ENV{VERBOSE};
		
		my $seq = $self->get_feature_sequence($fid);
		$seq || confess "Could not get sequence for $fid";
		
		print TBL "$fid\t$seed_loc\t\n";
		&FIG::display_id_and_seq($fid, \$seq, \*FASTA);
		
		my $func = $self->get_function($fid);
		print FUNC "$fid\t$func\n" if $func;
	    }
	    close(FASTA) || die "Could not close $feature_dir/fasta";
	    close(TBL)   || die "Could not close feature_dir/tbl";
	}
	else {
 	    if (-d $feature_dir) {
		print STDERR "No exportable features of type $type --- removing directory $feature_dir\n"
		    if $ENV{VERBOSE};
		my $v = $ENV{VERBOSE} ? qq(v) : qq();
 		system("/bin/rm -fR$v $feature_dir")
		    && warn "Could not remove directory $feature_dir";
 	    }
	}
    }
    close(FUNC)  || die "Could not close $dir/assigned_functions";
    
    return 1;
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Accessor functions ...
#-----------------------------------------------------------------------

sub get_taxid
{
    my ($self) = @_;
    return $self->{_taxid};
}

sub get_genome_dir
{
    my ($self) = @_;
    return $self->{_dir};
}

sub get_genome_name
{
    my ($self) = @_;
    return $self->{_genome};
}

sub get_project
{
    my ($self) = @_;
    return $self->{_project};
}

sub get_taxonomy
{
    my ($self) = @_;
    return $self->{_taxonomy};
}

sub get_genetic_code_number {
    my ($self) = @_;
    return $self->{_genetic_code_number};
}

sub get_translation_table {
    my ($self) = @_;
    return $self->{_translation_table};
}

sub get_GC_content {
    my ($self) = @_;
    return $self->{_GC_content};
}

sub get_contig_ids
{
    my ($self) = @_;
    return ( sort keys % { $self->{_contig_lens} } );
}

sub get_contig_length
{
    my ($self, $contig_id) = @_;
    confess "No contig_id" unless defined($contig_id);
    
    my $len;
    if ($len = $self->{_contig_lens}->{$contig_id})
    {
	return $len;
    }
    else
    {
	confess "No sequence for contig_id $contig_id";
	return undef;
    }
}

sub get_contig_seqP
{
    my ($self, $contig_id) = @_;
    confess "No contig_id" unless defined($contig_id);
    
    if (defined($self->{_contig_seqs}->{$contig_id}))
    {
	return \do{ $self->{_contig_seqs}->{$contig_id} };
    }
    else
    {
	confess "No sequence for contig_id $contig_id";
	return undef;
    }
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Feature accessors ...
#-----------------------------------------------------------------------

sub is_feature
{
    my ($self,$fid) = @_;
    
    return defined($self->{_features}->{$fid});
}

sub is_used {
    my ($self, $loc) = @_;
    
    my $contig = $loc->[_CONTIG];
    my $strand = $loc->[_LOC_END];
    my $end    = $loc->[_STRAND];
    my $key    = $contig.$strand.$end;
    
    return $self->{_used_list}->{$key};
}

sub get_feature_types
{
    my ($self) = @_;
    
    return keys % { $self->{_features}->{_maxnum} };
}

sub get_fids_for_type
{
    my ($self, @types) = @_;
    my $type = join('|', @types);
    
    my $patt;
    if ((not $type) || ($type =~ m/all/o)) {
	$patt = qr/^[^_]\w+$/o;
    } else {
	$patt = qr/^$type$/;
    }
    
    my $featureP = $self->{_features};
    if (wantarray) {
	return sort { &FIG::by_fig_id($a, $b) } 
	            grep { $featureP->{$_}->{_type} =~ m/$patt/ }
                    keys %$featureP;
    }
    else {
	return (scalar grep { $featureP->{$_}->{_type} =~ m/$patt/ } keys %$featureP);
    }
}

sub get_feature_object
{
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    return $self->{_features}->{$fid};
}

sub get_feature_type
{
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    return $self->{_features}->{$fid}->{_type};
}

sub get_feature_loc
{
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    return $self->{_features}->{$fid}->{_loc};
}

sub get_feature_length
{
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    
    my $beg = $self->get_feature_beginpoint($fid);
    my $end = $self->get_feature_endpoint($fid);
    
    return (1 + abs($end-$beg));
}


sub set_feature_aliases
{
    my ($self, $fid, @aliases) = @_;
    
    return undef if not $self->is_feature($fid);
    
    return $self->{_features}->{$fid}->{_aliases} = [ @aliases ];
}

sub get_feature_aliases
{
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    
    return $self->{_features}->{$fid}->{_aliases};
}


sub from_seed_loc {
    my ($self, $loc) = @_;
    
    my @loc = ();
    my @seed_loc = split /,/, $loc;
    foreach my $exon (@seed_loc) {
	if ($exon =~ m/(\S+)_(\d+)_(\d+)/o) {
	    my ($contig_id, $beg, $end) = ($1, $2, $3);
	    my $len = 1 + abs($end - $beg);
	    my $strand = ($end > $beg) ? qq(+) : qq(-) ;
	    
	    push @loc, [$contig_id, $end, $strand, $len];
	}
	else {
	    confess "Could not parse exon $exon";
	}
    }
    
    return [@loc];
}

sub to_seed_loc {
    my ($self, $loc) = @_;
    if (ref($loc->[0]) ne 'ARRAY') { $loc = [$loc]; }

    my @exon_locs = ();
    foreach my $exon (@$loc) {
        my ($contig_id, $end, $strand, $len) = @$exon;
        my $sign = ($strand eq qq(+)) ? +1 : -1 ;
        my $beg  = $end - $sign*($len-1);
        push @exon_locs, join(qq(_), ($contig_id, $beg, $end));
    }

    return join(qq(,), @exon_locs);
}


sub get_seed_loc {
    my ($self, $fid) = @_;
    return undef if not $self->is_feature($fid);
    
    my $seed_loc = "";
    my @loc = @ { $self->get_feature_loc($fid) };
    foreach my $exon (@loc) {
	my ($contig_id, $end, $strand, $len) = @$exon;
	my $sign = ($strand eq qq(+)) ? +1 : -1 ;
	my $beg  = $end - $sign*($len-1);
	$exon = join('_', ($contig_id, $beg, $end));
    }
    $seed_loc = join(",", @loc);
    
    return $seed_loc;
}

sub set_feature_loc {
    my ($self, $fid, $loc) = @_;
    if (not $self->is_feature($fid)) {
	confess "Attempt to set location of undefined feature $fid";
    }
    
    if (ref($loc->[0]) ne 'ARRAY') { $loc = [$loc]; }
    
    return ($self->{_features}->{$fid}->{_loc} = $loc);
}

sub get_feature_contig {
    my ($self, $fid) = @_;
    return undef if not $self->is_feature($fid);
    
    my $loc = $self->get_feature_loc($fid);
    return $loc->[0]->[_CONTIG];
}


sub get_feature_strand {
    my ($self, $fid) = @_;
    return undef if not $self->is_feature($fid);
    
    my $loc = $self->get_feature_loc($fid);
    return $loc->[0]->[_STRAND];
}

sub get_feature_sign {
    my ($self, $fid) = @_;
    return undef if not $self->is_feature($fid);
    
    my $loc = $self->get_feature_loc($fid);
    return (($loc->[0]->[_STRAND] eq qq(+)) ? +1 : -1);
}


sub get_feature_endpoint {
    my ($self, $fid) = @_;
    return undef if not $self->is_feature($fid);
    confess "Problem with feature $fid:\n", &flatten_dumper($self->{_features}->{$fid})
	unless (  $self->{_features}->{$fid}->{_loc}
	       && $self->{_features}->{$fid}->{_loc}->[-1]
	       && $self->{_features}->{$fid}->{_loc}->[-1]->[_LOC_END]);
    
    return $self->{_features}->{$fid}->{_loc}->[-1]->[_LOC_END];
}

sub set_feature_endpoint {
    my ($self, $fid, $end) = @_;
    if (not $self->is_feature($fid)) {
	$self->{_features}->{$fid} = []; 
    }
    
    $self->{_features}->{$fid}->{_loc}->[-1]->[_LOC_END] = $end;
}


sub get_feature_beginpoint {
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    
    my $loc  =  $self->get_feature_loc($fid);
    my $sign = ($self->get_feature_strand($fid) eq qq(+)) ? +1 : -1 ;
    my $contig_length = $self->get_contig_length($self->get_feature_contig($fid));
    
    my $end  = $self->get_exon_end($loc->[-1]);
    my $len  = $self->get_exon_length($loc->[-1]);
    my $beg  = &FIG::max( 1, &FIG::min( ($end - $sign*($len-1) ), $contig_length ) );
    
#   print STDERR "BEG: fid=$fid\tsign=$sign\tend=$end\tlen=$len\tbeg=$beg\tcontig_length=$contig_length\n";
    return $beg;
}


sub get_feature_leftbound {
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    
    my $beg = $self->get_feature_beginpoint($fid);
    my $end = $self->get_feature_endpoint($fid);
    
    return &FIG::min($beg, $end);
}

sub get_feature_rightbound {
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    
    my $beg = $self->get_feature_beginpoint($fid);
    my $end = $self->get_feature_endpoint($fid);
    
    return &FIG::max($beg, $end);
}


sub get_feature_dna {
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    return $self->get_dna_subseq($self->{_features}->{$fid}->{_loc});
}


sub get_feature_sequence {
    my ($self, $fid) = @_;
    
    return undef if not $self->is_feature($fid);
    return undef if not $self->{_features}->{$fid}->{_seq};
    
    my $seq = $self->{_features}->{$fid}->{_seq};
    
    if ($self->get_feature_type($fid) eq qq(orf)) {
	my $len = $self->get_feature_length($fid);
#	warn (qq(ORF $fid:\t), $len, qq(\t), ($len - 3)/3, qq(\n));
	$seq =  substr($seq, -($len - 3)/3);
	$seq =~ s/^[MLV]/M/;
    }
    
    return $seq;
}

sub set_feature_sequence {
    my ($self, $fid, $seq) = @_;
    my $type = $self->get_feature_type($fid);
    
    if (not defined($type)) {
	confess "Attempt to set sequence of undefined feature $fid";
    }
    
    if (($type eq 'peg') || ($type eq 'orf')) {
	if ($seq =~ m/[^ABCDEFGHIKLMNPQRSTVWXxYZ]/o) {
	    $seq =~ tr/ABCDEFGHIKLMNPQRSTVWXYZ/abcdefghiklmnpqrstvwxyz/;
	    confess "Translation for FID $fid contains invalid chars:\n"
		, $seq;
	}
    }
    
    $self->{_features}->{$fid}->{_seq} = $seq;
}

sub get_function {
    my ($self, $fid) = @_;
    
    if (not $self->is_feature($fid)) {
	print STDERR "WARNING: Attempt to get function of undefined feature $fid\n";
	return undef;
    }
    
    return $self->{_features}->{$fid}->{_func};
}

sub set_function {
    my ($self, $fid, $func) = @_;
    print STDERR "Setting function of $fid to $func\n"
	if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
    
    if (not $self->is_feature($fid)) {
	print STDERR "WARNING: Attempt to set function of undefined feature $fid to $func\n";
	return undef;
    }
    
    return ($self->{_features}->{$fid}->{_func} = $func);
}

sub get_exon_contig {
    my ($self, $loc) = @_;
    
    return $loc->[_CONTIG];
}

sub get_exon_end {
    my ($self, $loc) = @_;
    
    return $loc->[_LOC_END];
}

sub get_exon_length {
    my ($self, $loc) = @_;
    
    return $loc->[_LENGTH];
}

sub set_exon_length {
    my ($self, $loc, $len) = @_;
    my $orf_length;
    
    if (defined($orf_length = $self->get_orf_length($loc))) {
	if ($len <= $orf_length) {
	    return ($loc->[_LENGTH] = $len);
	}
	else {
	    return undef;
	}
    }
    
    return ($loc->[_LENGTH] = $len);
}


sub get_orf_length {
    my ($self, $loc) = @_;
    my $orf_len;
    
    if (ref($loc) eq 'ARRAY') {
	if (ref($loc->[-1]) ne 'ARRAY') { $loc = [$loc]; }
	
	if (defined($orf_len = $loc->[-1]->[_ORF_LEN])) {
	    return $orf_len;
	}
    }
    else {
	confess "Not a location object:\n", &flatten_dumper($loc);
    }
    
    return undef; 
}

sub set_orf_length {
    my ($self, $loc, $orf_len) = @_;
    
    if (ref($loc) eq 'ARRAY') {
	if (ref($loc->[-1]) eq 'ARRAY') {
	    print STDERR "Setting ORF-len RefRef\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    $loc->[-1]->[_ORF_LEN] = $orf_len;
	} else {
	    print STDERR "Setting ORF-len Ref\n"    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    $loc->[_ORF_LEN] = $orf_len;
	}
    }
    else {
	confess STDERR "Attempt to set ORF length to $orf_len for a non-location object:\n"
	    , &flatten_dumper($loc);
    }
    
    return $loc;
}


sub get_orf_sequence {
    my ($self, $fid) = @_;
    
    return undef if not $self->{_features}->{$fid};
    return $self->{_features}->{$fid}->[_ORF_TRANS];
}

sub set_orf_sequence {
    my ($self, $fid, $trans) = @_;
    if (not $self->{_features}->{$fid}) {
	confess STDERR "Undefined feature $fid";
        return undef;
    }
    
    if ($trans =~ m/[^ABCDEFGHIKLMNPQRSTVWXYZ]/o) {
	$trans =~ tr/ABCDEFGHIKLMNPQRSTVWXYZ/abcdefghiklmnpqrstvwxyz/;
	croak "Translation for FID $fid contains invalid chars:\n"
	    , $trans;
    }
    
    $self->{_features}->{$fid}->[_ORF_TRANS] = $trans;
}


sub get_orf_sims {
    my ($self, $fid) = @_;
    
    return undef if not $self->{_features}->{$fid};
    return $self->{_features}->{$fid}->[_ORF_SIMS];
}

sub set_orf_sims {
    my ($self, $fid, $simobj) = @_;
    if (not $self->{_features}->{$fid}) {
	$self->{_features}->{$fid} = []; 
    }
    
    $self->{_features}->{$fid}->[_ORF_SIMS] = $simobj;
}

sub get_all_orfs {
    my ($self, $min_len) = @_;
    
    my $orfs = {};
    %$orfs = map { $_ => NewGenome::ORF->new($self, $_) } $self->get_fids_for_type('orf');
    
    return $orfs;
}


# sub get_overlapping_fids
# {
#     my ($self, $fid) = @_;
#    
#     if (not $self->is_feature($fid))
#     {
# 	confess "Attempt to find overlaps for non-existent feature $fid";
#     }
#    
#     my $overlaps = $self->{_overlaps};
#     return keys % { $overlaps->{$fid} };
# }

# sub get_overlap
# {
#     my ($self, $fid1, $fid2) = @_;
#    
#     if (not $self->is_feature($fid1))
#     {
# 	confess "Attempt to find overlaps for non-existent feature $fid1";
#     }
#    
#     if (not $self->is_feature($fid2))
#     {
# 	confess "Attempt to find overlaps for non-existent feature $fid2";
#     }
#    
#     my $overlaps = $self->{_overlaps};
#     if (defined($overlaps->{$fid1}))
#     {
# 	if (defined($overlaps->{$fid1}->{$fid2}))
# 	{
# 	    return $overlaps->{$fid1}->{$fid2};
# 	}
#     }
#    
#     return 0;
# }


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Region Comparisons ...
#-----------------------------------------------------------------------

sub contains_embedded {
    my ($self, $fid1, $fid2) = @_;
    
    my $beg1 = $self->get_feature_beginpoint( $fid1 );
    my $end1 = $self->get_feature_endpoint(   $fid1 );
    
    my $beg2 = $self->get_feature_beginpoint( $fid2 );
    my $end2 = $self->get_feature_endpoint(   $fid2 );
    
    if (&FIG::between($beg1, $beg2, $end1) && &FIG::between($beg1, $end2, $end1))
    {
	return $self->get_feature_length($fid2);
    }
    
    return  0;
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Utility functions ...
#-----------------------------------------------------------------------

sub is_rna {
    my ($self, $fid) = @_;
    
    return ($self->is_feature($fid) && ($self->{_features}->{$fid}->{_type} eq 'rna'));
}

sub is_valid_start_codon {
    my ($self, $start) = @_;
    
    return $self->{_valid_start_codons}->{uc($start)};
}

sub translate {
    my ($self, $seq, $toM) = @_;
    
    my $trans = &FIG::translate($seq, $self->get_translation_table);
    
    if ($toM && $self->is_valid_start_codon(substr($seq, 0, 3))) {
	substr($trans, 0, 1) = qq(M);
    }
    
    return $trans
}

sub _parse_exon {
    my ($exon) = @_;
    
    if ($exon =~ m/^(\S+):(\d+)([+-])(\d+)$/o) {
	return ($1, $2, $3, $4);
    }
    else {
	confess "Invalid exon string $exon";
    }
}

sub make_exon {
    my ($self, @args) = @_;
    
    return [ @args ];
}

sub make_loc {
    my ($self, @args) = @_;
    
    return [ [@args] ];
}

sub copy_loc {
    my ($self, $loc) = @_;
    my $new_loc = [];
    
    if (ref($loc->[0]) eq 'ARRAY') {
	foreach my $exon (@$loc) { push @$new_loc, [ @$exon ]; }
    }
    else {
	@$new_loc = @$loc;
    }
    
    return $new_loc;
}

sub parse_loc {
    my ($self, $loc_string) = @_;
    
    my $loc = [];
    my @exons = split /,/, $loc_string;
    foreach my $exon (@exons) {
	push @$loc, [ &_parse_exon($exon) ];
    }
    
    return $loc;
}

sub compare_loc {
    my ($self, $a, $b) = @_;
    
    return $self->compare_left($a, $b);
}

sub compare_left {
    my ($self, $a, $b) = @_;
    
    my $A_contig = $self->get_feature_contig($a);
    my $B_contig = $self->get_feature_contig($b);
    
    my $A_strand = $self->get_feature_strand($a);
    my $B_strand = $self->get_feature_strand($b);

    my $A_left  = $self->get_feature_leftbound($a);
    my $B_left  = $self->get_feature_leftbound($b);
    
    my $A_right = $self->get_feature_rightbound($a);
    my $B_right = $self->get_feature_rightbound($b);
    
    my $A_len   = $self->get_feature_length($a);
    my $B_len   = $self->get_feature_length($b);
    
    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2)) {
	print STDERR "A = ($a, $A_contig, $A_strand, $A_left, $A_right, $A_len)\n";
	print STDERR "B = ($b, $B_contig, $B_strand, $B_left, $B_right, $B_len)\n";
    }
    
    return (  ($A_contig cmp $B_contig)
           || ($A_left   <=> $B_left)
           || ($B_len    <=> $A_len)
           || ($A_strand cmp $B_strand)
	   );
}


sub compare_right {
    my ($self, $a, $b) = @_;
    
    my $A_contig = $self->get_feature_contig($a);
    my $B_contig = $self->get_feature_contig($b);
    
    my $A_strand = $self->get_feature_strand($a);
    my $B_strand = $self->get_feature_strand($b);

    my $A_left  = $self->get_feature_leftbound($a);
    my $B_left  = $self->get_feature_leftbound($b);
    
    my $A_right = $self->get_feature_rightbound($a);
    my $B_right = $self->get_feature_rightbound($b);
    
    my $A_len   = $self->get_feature_length($a);
    my $B_len   = $self->get_feature_length($b);
    
    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2)) {
	print STDERR "A = ($a, $A_contig, $A_strand, $A_left, $A_right, $A_len)\n";
	print STDERR "B = ($b, $B_contig, $B_strand, $B_left, $B_right, $B_len)\n";
    }
    
    return (  ($A_contig cmp $B_contig)
           || ($A_right  <=> $B_right)
           || ($B_len    <=> $A_len)
           || ($A_strand cmp $B_strand)
	   );
}


sub possibly_truncated {
    my($self, $loc) = @_;
    
    my $seed_loc;
    if (ref($loc) eq qq(ARRAY)) {
	$seed_loc = $self->to_seed_loc($loc);
    }
    else {
	$seed_loc = $loc;
    }
    
    my ($contig_id, $beg, $end) = $fig->boundaries_of( $seed_loc );
    my $contig_len = $self->get_contig_length( $contig_id );
    
    if ((! $self->_near_end($contig_len, $beg)) && (! $self->_near_end($contig_len, $end)))
    {
        return 0;
    }
    return 1;
}

sub _near_end {
    my($self, $contig_len, $x) = @_;

    return (($x < 300) || ($x > ($contig_len - 300)));
}


sub overlap_between {
    my ($self, $a, $b) = @_;
    
    my $A_contig = $self->get_feature_contig($a);
    my $B_contig = $self->get_feature_contig($b);
    return 0 if ($A_contig ne $B_contig);
    
    my $A_left  = $self->get_feature_leftbound($a);
    my $B_left  = $self->get_feature_leftbound($b);
    
    my $A_right = $self->get_feature_rightbound($a);
    my $B_right = $self->get_feature_rightbound($b);
    
    if ($A_left > $B_left) {
	($A_left,  $B_left)  = ($B_left, $A_left);
	($A_right, $B_right) = ($B_right, $A_right);
    }
    
    my $overlap = 0;
    if ($A_right >= $B_left) { $overlap = &FIG::min($A_right, $B_right) - $B_left + 1; }
    
    return $overlap;
}

sub on_forward_strand {
    my ($self, $loc) = @_;
    
    warn "on_forward_strand: ", join(', ', @$loc) if ($ENV{VERBOSE} && ($ENV{VERBOSE} > 2));
    return ($loc->[_STRAND] eq qq(+));
}

sub on_reverse_strand {
    my ($self, $loc) = @_;
    
    warn "on_reverse_strand: ", join(', ', @$loc) if ($ENV{VERBOSE} && ($ENV{VERBOSE} > 2));
    return ($loc->[_STRAND] eq qq(-));
}

sub check_bounds {
    my ($self, $loc) = @_;
    if (ref($loc->[0]) ne 'ARRAY') { $loc = [$loc]; }
    
    my $ok = 1;
    foreach my $exon (@$loc) {
	my ($contig_id, $end, $strand, $len) = @$exon;
	print STDERR "Checking exon $contig_id, $end, $strand, $len\n"
	    if ($ENV{VERBOSE} && ($ENV{VERBOSE} > 2));
	
	my $contig_length;
	if (defined($contig_length = $self->get_contig_length($contig_id))) {
	    if ($self->on_forward_strand($exon)) {
		my $beg = ($end - $len) + 1;
		if (($beg <= 0) || ($end > $contig_length)) {
		    $ok = 0;
		    print STDERR "\tOut-of-bounds plus-strand exon coordinates $contig_id\_$beg\_$end"
			, " (contig_length = $contig_length)\n" if $ENV{VERBOSE};
		}
	    }
	    else {
		my $beg = ($end + $len) - 1;
		if (($end <= 0) || ($beg > $contig_length)) {
		    $ok = 0;
		    print STDERR "\tOut-of-bounds minus-strand exon coordinates $contig_id\_$beg\_$end"
			, " (contig_length = $contig_length)\n" if $ENV{VERBOSE};
		}
	    }
	}
    }
    
    return $ok;
}

sub get_dna_subseq  {
    my ($self, $loc) = @_;
    my ($contig_seqP, $beg);
    
    if (ref($loc->[0]) ne 'ARRAY') { $loc = [$loc]; }
    
    my $dna_seq = "";
    foreach my $exon (@$loc) {
	my ($contig_id, $end, $strand, $len) = @$exon;
	
	if (not $self->check_bounds($exon)) {
	    my $x = &flatten_dumper($loc);
	    cluck "Exon $contig_id:$end$strand$len is out of bounds, loc: $x\n" 
	        if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    return undef;
	}
	
	print STDERR "Getting exon $contig_id, $end, $strand, $len\n" 
	    if ($ENV{VERBOSE} && ($ENV{VERBOSE} > 2));
	
	if (defined($self->get_contig_length($contig_id))) {
	    $contig_seqP = $self->get_contig_seqP($contig_id);
	    
	    if ($self->on_forward_strand($exon)) {
		$beg = ($end - $len) + 1;
		$dna_seq .= substr($$contig_seqP, $beg-1, $len);
	    }
	    else {
		$beg = ($end + $len) - 1;
		$dna_seq .= &FIG::reverse_comp(substr($$contig_seqP, $end-1, $len));
	    }
	}
	else {
	    print STDERR "Invalid contig $contig_id\n";
	}
    }
    print STDERR "dna_seq = $dna_seq\n" if ($ENV{VERBOSE} && ($ENV{VERBOSE} > 2));
    
    return $dna_seq;
}

sub flatten_dumper {
    
    my $x = Dumper($_[0]);
    
    $x =~ s/\$VAR\d+\s+\=\s+//o;
    $x =~ s/\n//gso;
    $x =~ s/\s+/ /go;
    $x =~ s/\'//go;
#   $x =~ s/^[^\(\[\{]+//o;
#   $x =~ s/[^\)\]\}]+$//o;
    
    return $x;
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Feature manipulation ...
#-----------------------------------------------------------------------

sub delete_features_of_type {
    my ($self, @types) = @_;
    
    if ((not @types) || ($types[0] =~ m/all/o)) { @types = $self->get_feature_types(); }
    my $type = join(", ", @types);
	
    my @fids = $self->get_fids_for_type(@types);
    my $s = (@fids != 1) ? 's' : '' ;
    print STDERR "Preparing to delete ", (scalar @fids), " feature$s of type $type\n"
	if $ENV{VERBOSE};
    
    foreach my $fid (@fids) {
	$self->delete_feature($fid) || confess "Could not delete feature $fid";
    }
    
    return 1;
}

sub delete_feature {
    my ($self, $fid) = @_;
    print STDERR "Deleting feature $fid\n" if $ENV{VERBOSE};
    
    if (not $self->is_feature($fid)) {
	confess "Attempt to delete non-existent feature $fid";
    }
    
    my $contig_id = $self->get_feature_contig($fid);
    my $strand    = $self->get_feature_strand($fid);
    my $end       = $self->get_feature_endpoint($fid);
    
#     my $overlaps  = $self->{_overlaps};
#     foreach my $x (keys % { $overlaps->{$fid} } )
#     {
# 	if (delete $overlaps->{$x}->{$fid})
# 	{
# 	    print STDERR "   Deleting $x --> $fid from _overlap structure\n" if $ENV{VERBOSE};
# 	}
# 	else
# 	{
# 	    confess "Could not delete $x --> $fid from _overlap structure";
# 	}
#     }
#    
#     if (delete $overlaps->{$fid})
#     {
# 	print STDERR "Deleting $fid from _overlap structure\n" if $ENV{VERBOSE};
#     }
#     else
#     {
# 	confess "Could not delete $fid from _overlap structure";
#     }
    
    my $key  = "$contig_id$strand$end";
    my $used = $self->{_used_list}->{$key};
    my $ok   = "";
    for (my $i=0; $i < @$used; ++$i) { 
	if ($used->[$i] eq $fid) { $ok = splice(@$used, $i, 1); last; }
    }
    
    if (not $ok) {
	confess "Could not delete $fid from _used structure, key $key, _used list = "
	    , join(", ", @$used);
    }
    
    
#     my ($i, $sort);
#     $sort = $self->{_sort_left}->{$contig_id};
# #   print STDERR &Dumper($sort);
#     if (not @$sort) { confess "_sort_left structure for $contig_id is empty\n", &Dumper($self); }
#     for ($i=0; ($i < @$sort) && ($sort->[$i] ne $fid); $i++) {}
#     if ($i < @$sort) {
# 	splice(@$sort, $i, 1) || confess "Could not delete $fid from _sort_right at i=$i";
#     } else {
# 	confess "Could not delete $fid\n";
#     }
#    
#     $sort = $self->{_sort_right}->{$contig_id};
# #   print STDERR &Dumper($sort);
#     if (not @$sort) { confess "_sort_right structure for $contig_id is empty\n", &Dumper($self); }
#     for ($i=0; ($i < @$sort) && ($sort->[$i] ne $fid); $i++) {}
#     if ($i < @$sort) {
# 	splice(@$sort, $i, 1) || confess "Could not delete $fid from _sort_right at i=$i";
#     } else {
# 	confess "Could not delete $fid\n";
#     }
    
    
    if (not delete $self->{_features}->{$fid})
    {
	confess "Could not delete $fid from _features structure";
    }
    
    return 1;
}

sub add_feature {
    my ($self, %args) = @_;
    
    my $type    = $args{-type} || confess "No feature type given";
    
    my $fid     = $args{-fid};
    my $func    = $args{-func};
    my $seq     = $args{-seq};
    my $aliases = $args{-aliases};
    my $annot   = $args{-annot};
    
    my $tax_id  = $self->get_taxid;
    my $base    = "fig|$tax_id.$type";
    
    my $loc  = $args{-loc}  || confess "No feature loc given";
    if ($ENV{VERBOSE}) {
	print STDERR qq(Attempting to add '$type' feature);
	if ($ENV{VERBOSE} > 2) {
	    print STDERR qq(\n   args = ) . &flatten_dumper(\%args) . qq(\n);
	}
	else {
	    print STDERR qq(, loc=) . &flatten_dumper($loc) . qq(\n);
	}
    }
    
    if (ref($loc) ne 'ARRAY') {
	confess "Non-ARRAYref loc object passed to add_feature --- \%args =\n"
	    , Dumper(\%args);
    }
    
    if (ref($loc->[0]) ne 'ARRAY') { $loc = [$loc]; }
    my ($contig_id, $end, $strand, $len) = @ { $loc->[-1] };
    
    $len = 0;
    foreach my $exon (@$loc) {
	$len += $self->get_exon_length($exon);
    }
    
    if ( (($type eq 'peg') || ($type eq 'orf')) && (($len % 3) != 0) )  {
	warn "Triality test fails for loc: " . &flatten_dumper($loc) . "\n";
	return undef;
    }
    
    if (not defined($self->{_features})) {
	$self->{_features} = {};
	$self->{_features}->{_maxnum} = {};
	print STDERR "No previous features --- creating feature-pointer\n" if $ENV{VERBOSE};
    }
    
    if (not defined($self->{_features}->{_maxnum}->{$type})) {
	$self->{_features}->{_maxnum}->{$type} = 0;
	print STDERR "No previous features of type $type\n" if $ENV{VERBOSE};
    }
    my $numref = \$self->{_features}->{_maxnum}->{$type};
    
    if (not $fid) {
	$fid = $base . qq(.) . ++$$numref;
    }
    else {
	if ($fid =~ m/\.(\d+)$/o) {
	    $$numref = &FIG::max($$numref, $1);
	}
	else {
	    confess "Malformed FID $fid";
	}
    }
    
    if (defined($self->{_features}->{$fid})) {
	confess "FATAL ERROR: Redefining existing feature $fid";
    }
    
    if (defined($contig_id) && $end && $strand && $len) {
	my $new_feature = {};
	
	$new_feature->{_type}  = $type;
	$new_feature->{_loc}   = $loc;
	
	if (defined($func))  { $new_feature->{_func} = $func; }
	
	if ($seq) { 
	    $new_feature->{_seq} = $seq; 
	}
	else {
	    if (($type eq 'peg') || ($type eq 'orf')) {
		my $tmp_loc = $self->copy_loc($loc);
		if ($type eq 'orf') {
		    my $orf_len = $self->get_orf_length($tmp_loc->[-1]);
		    $self->set_exon_length($tmp_loc->[-1], $orf_len)
			|| confess "For FID $fid, Could not set len=orf_len=$orf_len for tmp_loc="
			          , &flatten_dumper($tmp_loc);
		}
		
		my $dna = $self->get_dna_subseq($tmp_loc);
		if (my $pep = &FIG::translate($dna, $self->get_translation_table, 1)) {
		    $pep =~ s/\*$//o;
		    if ($pep =~ m/\*/o) {
			confess "Translation of $fid contains internal STOPs --- skipping\n";
			return undef;
		    }
		    $new_feature->{_seq} = $pep;
		}
		else {
		    confess "Translation failed for $dna";
		}
	    }
	    else {
		$new_feature->{_seq} = $self->get_dna_subseq($loc);
	    }
	}
	
	if (defined($aliases)) {
	    if (ref($aliases) eq 'ARRAY') {
		$new_feature->{_aliases} = $aliases;
	    }
	    else {
		confess "-aliases field is not an ARRAY ref for feature: "
		    . &flatten_dumper($aliases, $new_feature) . "\n";
	    }
	}
	
	
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... This is a crude hack, since it only allows immediately writing
#    an annotation.
#... Properly implemented, annotations should be handled as a queue,
#    with proper access methods.
#-----------------------------------------------------------------------
	if (defined($annot)) {
	    if (ref($annot) eq 'ARRAY') {
		my $timestamp = time();
		my $annot_file = $self->get_genome_dir() . qq(/annotations);
		my $annot_user = $annot->[0];
		my $annot_text = $annot->[1];
		
		open( ANNOT, ">>$annot_file")
		    || confess "Could not append-open $annot_file";
		
		print ANNOT "$fid\n$timestamp\n$annot_user\n$annot_text\n//\n";
		
		close(ANNOT)
		    || confess "Could not close $annot_file";
	    }
	    else {
		confess "-annot field is not an ARRAY ref for feature: "
                    . &flatten_dumper($annot, $new_feature) . "\n";
	    }
	}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...And finally, store the new feature in the NewGenome object struct:
#-----------------------------------------------------------------------
	$self->{_features}->{$fid} = $new_feature;
#=======================================================================
	
    }
    else {
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Object creation is being aborted because one or more of
#   $contig_id, $end, $strand, or $len are missing or nil;
#   signal failure by returning 'undef'.
#------------------------------------------------------------------------
	$fid = undef;
    }
    
    if ($ENV{VERBOSE}) {
	if ($ENV{VERBOSE} == 1) {
	    print STDERR "Added feature $fid at $contig_id:$end$strand$len"
		, (($#{$loc->[0]} == 4) ? (defined($loc->[0]->[4]) ? ",$loc->[0]->[4]" : ',undef') : "")
		, " func=$func"
		, "\n";
	}
	else {
	    print STDERR "Added feature $fid at $contig_id:$end$strand$len:\n   "
		, &flatten_dumper($self->{_features}->{$fid}), "\n\n";
	}
    }
    
    my $key = "$contig_id$strand$end";
    if (not defined($self->{_used_list}->{$key})) { $self->{_used_list}->{$key} = []; }
    push @ { $self->{_used_list}->{$key} }, $fid;
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Update dynamic overlap structures ...
#-----------------------------------------------------------------------
#     my $sort;
#    
#     my $mid = 0;
#     if (not defined($self->{_sort_left}->{$contig_id}))
#     {
# 	$self->{_sort_left}->{$contig_id} = [$fid];
#     }
#     else
#     {
# 	$sort = $self->{_sort_left}->{$contig_id};
#	
#  	my $low  = 0;
#  	my $high = $#$sort;
#  	my $mid;
#  	my $cmp;
#	
#  	while ($low < $high)
#  	{
#  	    $mid = int( ($low+$high) / 2 );
#	    
#  	    $cmp = $self->compare_left($fid, $sort->[$mid]);
# # 	    print STDERR "low=$low, high=$high, mid=$mid, cmp=$cmp\n";
#	    
#  	    if ( $cmp > 0 ) { $low = $mid+1; } else { $high = $mid; }
#  	}
#	
# 	$cmp = $self->compare_left($fid,$sort->[$high]);
# 	if ($cmp == 0)
# 	{
# #	    print STDERR "IT IS AT $high\n";
# 	    splice @$sort, $high, 0, $fid;
# 	}
# 	elsif ($cmp > 0)
# 	{
# #	    print STDERR "INSERT after $high\n";
# 	    splice @$sort, $high+1, 0, $fid;
# 	}
# 	else
# 	{
# #	    print STDERR "INSERT before $high\n";
# 	    splice @$sort, $high-1, 0, $fid;
# 	}
#     }
#    
#     $mid = 0;
#     if (not defined($self->{_sort_right}->{$contig_id}))
#     {
# 	$self->{_sort_right}->{$contig_id} = [$fid];
#     }
#     else
#     {
# 	$sort = $self->{_sort_right}->{$contig_id};
#	
#  	my $low  = 0;
#  	my $high = $#$sort;
#  	my $mid;
#  	my $cmp;
#	
#  	while ($low < $high)
#  	{
#  	    $mid = int( ($low+$high) / 2 );
#	    
#  	    $cmp = $self->compare_right($fid, $sort->[$mid]);
# # 	    print STDERR "low=$low, high=$high, mid=$mid, cmp=$cmp\n";
#	    
#  	    if ( $cmp > 0 ) { $low = $mid+1; } else { $high = $mid; }
#  	}
#	
# 	$cmp = $self->compare_right($fid,$sort->[$high]);
# 	if ($cmp == 0)
# 	{
# #	    print STDERR "IT IS AT $high\n";
# 	    splice @$sort, $high, 0, $fid;
# 	}
# 	elsif ($cmp > 0)
# 	{
# #	    print STDERR "INSERT after $high\n";
# 	    splice @$sort, $high+1, 0, $fid;
# 	}
# 	else
# 	{
# #	    print STDERR "INSERT before $high\n";
# 	    splice @$sort, $high-1, 0, $fid;
# 	}
#     }
#    
#     my $overlaps = $self->{_overlaps};
#     if (not defined($overlaps->{$sort->[$mid]})) { $overlaps->{$sort->[$mid]} = {}; }
#    
#     $sort = $self->{_sort_left}->{$contig_id};
#     for (my $i=$mid+1; $i <= $#$sort; ++$i)
#     {
# 	my $lap = $self->overlap_between($sort->[$mid], $sort->[$i]);
# 	last unless $lap;
#	
# 	if (not defined($overlaps->{$sort->[$i]})) { $overlaps->{$sort->[$i]} = {}; }
#	
# 	$overlaps->{$sort->[$mid]}->{$sort->[$i]} = $lap;
# 	$overlaps->{$sort->[$i]}->{$sort->[$mid]} = $lap;
#	
# 	print STDERR "Adding overlaps between $sort->[$mid] <--> $sort->[$i]\n"
# 	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
#     }
#    
#     $sort = $self->{_sort_right}->{$contig_id};
#     for (my $i=$mid-1; $i >= 0; --$i)
#     {
# 	my $lap = $self->overlap_between($sort->[$mid], $sort->[$i]);
# 	last unless $lap;
#	
# 	if (not defined($overlaps->{$sort->[$i]})) { $overlaps->{$sort->[$i]} = {}; }
#	
# 	$overlaps->{$sort->[$mid]}->{$sort->[$i]} = $lap;
# 	$overlaps->{$sort->[$i]}->{$sort->[$mid]} = $lap;
#	
# 	print STDERR "Adding overlaps between $sort->[$mid] <--> $sort->[$i]\n"
# 	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
#     }
    
    return $fid;
}

sub remove_overlaps {
    my ($self, $closest_org, $min_len) = @_;
    my $dir = $self->get_genome_dir();
    
    my $rna = (-s "$dir/Features/rna/tbl") ? "$dir/Features/rna/tbl" : '/dev/null';
    my $peg = (-s "$dir/Features/peg/tbl") ? "$dir/Features/peg/tbl" : '/dev/null';
    my $orf = (-s "$dir/Features/orf/tbl") ? "$dir/Features/orf/tbl" : '/dev/null';
    print STDERR "In remove_overlaps:\n   rna=$rna\n   peg=$peg\n   orf=$orf\n"
	if $ENV{VERBOSE};
    
    $self->export_features('all');

    my @tbl;
    if ($ENV{VERBOSE}) {
	@tbl = `$FIG_Config::bin/filter_overlaps 90 20 50 150 150 $rna $peg < $orf 2>> $dir/overlap_removal.log`;
    }
    else {
	@tbl = `$FIG_Config::bin/filter_overlaps 90 20 50 150 150 $rna $peg < $orf`;
    }
    print STDERR "Keeping ", (scalar @tbl), " ORFs\n" if $ENV{VERBOSE};
#   die "aborting";
    
    my %keep = map { m/^(\S+)/o; $1 => 1 } @tbl;
    
    my $num_deleted = 0;
    foreach my $fid ($self->get_fids_for_type('orf')) {
	if (not $keep{$fid}) {
	    print STDERR "Attempting to delete $fid\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    $self->delete_feature($fid) || confess "Could not delete $fid";
	    ++$num_deleted;
	}
    }
    
    $self->export_features('all');
    
    return $num_deleted;
}

# sub remove_overlapping_fids
# {
#     my ($self, %args) = @_;
#     my ($type, $olap, $type2);
#
#     my $num_deleted = 0;
#    
#     my $fid        = $args{-fid} || confess "No FID given to ".__PACKAGE__."::remove_overlaps";
#     my $rna_maxlap = $args{-rna} || 20;
#    
#     my @overlapping_fids = $self->get_overlapping_fids($fid);
#     return (0) unless @overlapping_fids;
#    
#     $type = $self->get_feature_type($fid);
#
#     if ($type eq 'rna')
#     {
# 	foreach my $fid2 (@overlapping_fids)
# 	{
# 	    $type2 = $self->get_feature_type($fid2);
# 	    $olap  = $self->get_overlap($fid, $fid2);
#	    
# 	    if (($olap > $rna_maxlap) && (($type2 eq 'peg') || ($type2 eq 'orf')))
# 	    {
# 		$self->delete_feature($fid2) || confess "Could not delete $fid2 overlapping $fid by $olap";
# 		++$num_deleted;
# 	    }
# 	}
#	
# 	return $num_deleted;
#     }
#    
#     if ($type eq 'peg')
#     {
# 	foreach my $fid2 (@overlapping_fids)
# 	{
# 	    $type2 = $self->get_feature_type($fid2);
# 	    if ($self->contains_embedded($fid, $fid2) && ($type2 eq 'orf'))
# 	    {
# 		$self->delete_feature($fid2) || confess "Could not delete $fid2 overlapping $fid by $olap";
# 		++$num_deleted;
# 	    }
# 	}
#     }
#    
#     return $num_deleted;
# }


sub find_rna {
    my ($self) = @_;
    
    my $default_tool = "/vol/search_for_rnas-2007-0625/search_for_rnas";
    # my $default_tool = "/vol/search_for_rnas/bin/search_for_rnas";	# old version
    # my $default_tool = "$ENV{HOME}/rna_search/search_for_rnas";

    my $tool = $ENV{RP_SEARCH_FOR_RNAS};
    if (!$tool) {
	$tool = $default_tool;
    }
    
    if (-x $tool) {
	my $taxid    = $self->get_taxid();
	my $dir      = $self->get_genome_dir();

	my $bioname  = $self->get_genome_name();
	my ($genus, $species);
	if ($bioname =~ m/^(\S+)\s+(\S+)/o) {
	    ($genus, $species) = ($1, $2);
	} else {
	    confess "Could not parse bioname $bioname";
	}
	
	my $taxonomy = $self->get_taxonomy();
	my $domain   = uc(substr($taxonomy, 0, 1));
	
	my $cmd;
	if ($ENV{VERBOSE}) {
	     $cmd = "$tool --contigs=$dir/contigs --orgid=$taxid --domain=$domain --genus=$genus --species=$species --log=$dir/rna.log";
	     warn "Finding RNAs with $cmd\n";
	}
	else {
	    $cmd = "$tool --contigs=$dir/contigs --orgid=$taxid --domain=$domain --genus=$genus --species=$species --log=$dir/rna.log 2> /dev/null";
	}
	my @tbl = `$cmd`;
	if ($?)	{
	    my($rc, $sig, $msg) = &FIG::interpret_error_code($?);
	    confess "$msg: $cmd";
	}
	
	return @tbl;
    }
    else {
	cluck "No RNA-finder tool found at $tool\n";  
	return ();
    }
}

sub possible_orfs {
    my ($self, $min_len) = @_;
    my $class = ref($self);
    my $taxon = $self->get_taxid();
    
    if (not $min_len) {
	$min_len = 90;
	cluck "Setting min_len = $min_len bp by default \n" if $ENV{VERBOSE};
    }
    
    print STDERR "Beginning call to GLIMMER-$self->{_glimmer_version}\n" if $ENV{VERBOSE};
    print STDERR ("pwd=", `pwd`) if $ENV{VERBOSE};
    
    my $org  = $self->get_taxid();
    my $dir  = $self->get_genome_dir();
    my $code = $self->get_genetic_code_number();
    
    my $cmd  = qq();
    if    ($self->{_glimmer_version} == 2) {
	$cmd = "$FIG_Config::bin/run_glimmer2  $org  $dir/contigs  -code=$code";
    }
    elsif ($self->{_glimmer_version} == 3) {
	$cmd = "$FIG_Config::bin/run_glimmer3  -code=$code  $org  $dir/contigs";
    }
    else {
	confess "ERROR: GLIMMER-$self->{_glimmer_version} is not supported";
    }
    
    my $err_tmp = "$FIG_Config::temp/glimmer.$$.stderr";
    open(GLIM, "$cmd 2> $err_tmp |") or confess "Error opening glimmer pipe $cmd: $!\n";
    
    my @tmp_tbl;
    while (<GLIM>) {
	push(@tmp_tbl, $_);
    }
    
    if (!close(GLIM)) {
	open(ERR, "<$err_tmp");
	while (<ERR>) {
	    print STDERR $_;
	}
	close(ERR);
	confess "Glimmer pipe close failed \$?=$? \$!=$!\n";
    }
    
    my ($loc, $tmp_loc, $orf_len, $fid);
    foreach my $entry (@tmp_tbl) {
	chomp $entry;
	my ($tmp_fid, $locus) = split /\t/, $entry;
	
	if ($locus =~ m/(\S+)_(\d+)_(\d+)/o) {
	    my ($contig_id, $beg, $end) = ($1, $2, $3);
	    my $len     = 1 + abs($end - $beg);
	    my $strand  = ($end > $beg) ? qq(+) : qq(-) ;
	    
	    $loc = $self->make_loc($contig_id, $end, $strand, $len)
		|| confess "Could not create loc=$contig_id:$end$strand$len";
	    print STDERR "Created loc=", &flatten_dumper($loc), "\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    
	    $tmp_loc = $self->search_for_upstream_stop($loc)
		|| confess "Could not find ORF boundary for loc=", &flatten_dumper($loc); 
	    print STDERR "ORF upstream STOP loc=", &flatten_dumper($tmp_loc), "\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    
	    if (defined($orf_len = $self->get_orf_length($tmp_loc))) {
		if ($orf_len < $min_len) {
		    print STDERR (qq(Skipping too-short ORF ($orf_len bp) at tmp_loc=)
				  , &flatten_dumper($tmp_loc)
				  , qq(\n)
				  )
			if $ENV{VERBOSE};
		    next;
		}
	    }
	    else {
		print STDERR (qq(Could not extract ORF length from tmp_loc=)
			      , &flatten_dumper($tmp_loc)
			      , qq( --- Skipping\n)
			      );
		next;
	    }
	    
	    if ($orf_len < $len) {
		$self->set_exon_length($tmp_loc, $orf_len)
		    || confess (qq(Could not set tmp_loc length field to ORF length for loc=)
				, &flatten_dumper($tmp_loc)
				);
		
		print STDERR "Reset len=$orf_len, tmp_loc=", &flatten_dumper($tmp_loc), "\n"
		    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		
		if (defined($tmp_loc = $self->search_for_downstream_start($tmp_loc))) {
		    print STDERR "First START is at tmp_loc=", &flatten_dumper($tmp_loc), "\n"
			if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		}
		else {
		    print STDERR (qq(Could not find first START in ORF loc=)
				  , &flatten_dumper($tmp_loc)
				  , qq( --- Skipping\n)
				  )
			if $ENV{VERBOSE};
		    next;
		}
	    }
	    
	    if (defined($fid = $self->add_feature( -type => 'orf', -loc  => $tmp_loc ))) {
		print STDERR ( qq(Added GLIMMER-).$self->{_glimmer_version}
			     , qq( ORF candidate $fid, locus=$locus, loc=)
			     , &flatten_dumper($tmp_loc)
			     , qq(\n)
			     )
		    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    }
	    else {
		warn ( qq(NewGenome::posibble_orf(): Could not add GLIMMER-).$self->{_glimmer_version}
		     , qq( ORF candidate at locus=$locus, loc=)
		     , &flatten_dumper($tmp_loc)
		     );
		next;
	    }
	}
	else {
	    confess "Could not parse ORF header: $locus";
	}
    }
    print STDERR "Completed call to GLIMMER-$self->{_glimmer_version} --- returning ORFs\n" if $ENV{VERBOSE};
    
    $self->export_features('all');
    $self->remove_overlaps(undef, $min_len);
    
    return { map { $_ => $self->{_features}->{$_} } $self->get_fids_for_type('orf') };
}

sub recall_orfs {
    my ($self, $closest_org, $min_len) = @_;
    my $class = ref($self);
    my $taxon = $self->get_taxid;
    
    if (not $min_len) {
	$min_len = 90;
#	cluck "Setting min_len = $min_len bp by default \n" if $ENV{VERBOSE};
    }
    
    $self->delete_features_of_type('orf') || confess "Could not delete existing ORFs";
    
    print STDERR "Begining call to GLIMMER-$self->{_glimmer_version}\n" if $ENV{VERBOSE};
    print STDERR ("pwd=", `pwd`) if $ENV{VERBOSE};
    
    my $org     = $self->get_taxid();
    my $dir     = $self->get_genome_dir();
    my $code    = $self->get_genetic_code_number();
    my $peg_tbl = "$dir/Features/peg/tbl";
    confess "Empty or non-existent training data $peg_tbl, size=", (-s $peg_tbl) 
	unless (-s "$dir/Features/peg/tbl");
    
    
    my $cmd  = qq();
    if    ($self->{_glimmer_version} == 2) {
	$cmd = "$FIG_Config::bin/run_glimmer2  $org  $dir/contigs  -train=$peg_tbl -code=$code";
    }
    elsif ($self->{_glimmer_version} == 3) {
	$cmd = "$FIG_Config::bin/run_glimmer3  -train=$peg_tbl -code=$code  $org  $dir/contigs";
    }
    else {
	confess "ERROR: GLIMMER-$self->{_glimmer_version} not supported";
    }
    
    my @tmp_tbl;
    if ($ENV{VERBOSE}) {
	(@tmp_tbl = `$cmd`)
	    || confess "GLIMMER-$self->{_glimmer_version} found no candidate ORFs in $dir/contigs";
    }
    else {
	(@tmp_tbl = `$cmd 2> /dev/null`)
	    || confess "GLIMMER-$self->{_glimmer_version} found no candidate ORFs in $dir/contigs";
    }
    
    my ($loc, $tmp_loc);
    foreach my $entry (@tmp_tbl) {
	chomp $entry;
	my (undef, $locus) = split /\t/, $entry;
	
	if ($locus =~ m/(\S+)_(\d+)_(\d+)/o) {
	    my ($contig_id, $beg, $end) = ($1, $2, $3);
	    my $len     = 1 + abs($end - $beg);
	    my $strand  = ($end > $beg) ? qq(+) : qq(-) ;
	    
	    $loc = $self->make_loc($contig_id, $end, $strand, $len)
		|| confess "Could not create loc=$contig_id:$end$strand$len";
	    print STDERR "Created loc=", &flatten_dumper($loc), "\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
		    
	    $tmp_loc = $self->search_for_upstream_stop($loc)
		|| confess "Could not find ORF boundary for loc=", &flatten_dumper($loc); 
	    print STDERR "ORF upstream STOP loc=", &flatten_dumper($tmp_loc), "\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    
# 	    my $orf_len = $self->get_orf_length($tmp_loc)
# 		|| confess "Could not extract ORF length from tmp_loc=", &flatten_dumper($tmp_loc);
#	    
# 	    $self->set_exon_length($tmp_loc, $orf_len)
# 		|| confess "Could not set length field to ORF length for loc=", &flatten_dumper($tmp_loc);
# 	    print STDERR "Reset len=$orf_len, tmp_loc=", &flatten_dumper($tmp_loc), "\n"
# 		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
#	    
# 	    $tmp_loc = $self->search_for_downstream_start($tmp_loc)
# 		|| confess "Could not find first START in ORF loc=", &flatten_dumper($tmp_loc);
# 	    print STDERR "First START is at tmp_loc=", &flatten_dumper($tmp_loc), "\n"
# 		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    
	    $self->add_feature( -type => 'orf', -loc  => $tmp_loc )
		|| confess "Could not add 'orf' feature at loc=", &flatten_dumper($tmp_loc);
	}
	else {
	    confess "Could not parse ORF header: $locus";
	}
    }
    print STDERR "Found ", (scalar $self->get_fids_for_type('orf')), " new ORFs\n" if $ENV{VERBOSE};
    
    print STDERR "Completed call to GLIMMER-$self->{_glimmer_version} --- removing overlaps\n" if $ENV{VERBOSE};
    
    $self->export_features('all');
    $self->remove_overlaps($closest_org, $min_len);
    
    return { map { $_ => $self->{_features}->{$_} } $self->get_fids_for_type('orf') };
}

sub pull_orfs {
    my ($self, $min_len) = @_;
    my $class = ref($self);
    my $taxon = $self->get_taxid;
    
    my $tmp_orfs = "$FIG_Config::temp/tmp$$\_$class.fasta";
    
    if (not $min_len) {
	$min_len = 90;
#	cluck "Setting min_len = $min_len bp by default \n" if $ENV{VERBOSE};
    }
    
    open(PULL, "| pull_orfs $min_len > $tmp_orfs") 
	|| die "Could not open pipe-out through pull_orfs $min_len > $tmp_orfs";
    
    my $contig_seqP;
    foreach my $contig_id ( $self->get_contig_ids ) {
	print STDERR "Pulling ORFs for contig $contig_id ...\n" if $ENV{VERBOSE};
	if (defined($contig_seqP = $self->get_contig_seqP($contig_id)))	{
	    print PULL ">$contig_id\n$$contig_seqP\n";
	}
    }
    close(PULL) || die "Could not close pipe-out through pull_orfs $min_len > $tmp_orfs";
    confess "No ORFs found for ".$self->get_genome_dir() if (not -s $tmp_orfs);

    open(ORFS, "<$tmp_orfs") || die "Could not read-open $tmp_orfs";
    while (my ($locus, $transP) = &FIG::read_fasta_record(\*ORFS)) {
	print STDERR "Adding ORF $locus\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	
	if ($locus =~ m/(\S+)_(\d+)_(\d+)/o) {
	    my ($contig_id, $beg, $end) = ($1, $2, $3);
	    my $contig_len = $self->get_contig_length($contig_id);
	    my $strand  = ($end > $beg) ? qq(+) : qq(-) ;
	    my $sign    = ($end > $beg) ?    +1 :    -1 ;
	    if ( (($end + $sign*3) > 0) && (($end + $sign*3) <= $contig_len) ) { $end += $sign*3; }
	    my $orf_len = 1 + abs($end - $beg);
	    
	    
	    my $codon = $self->get_dna_subseq([$contig_id, $end, $strand, 3]);
	    if (&FIG::translate($codon, $self->get_translation_table) ne '*') {
		print STDERR "   WARNING: $contig_id:$end$strand$orf_len does not end with STOP ($codon)\n"
		    if $ENV{VERBOSE};
	    }
	    
	    my $b;
	    if ( (($beg-$sign*3) > 0) && (($beg-$sign*3) <= $contig_len) ) {
		$b = $beg - $sign;
	    } else {
		$b = $beg + $sign*2;
	    }
	    $codon = $self->get_dna_subseq([$contig_id, $b, $strand, 3]);
	    if (&FIG::translate($codon, $self->get_translation_table) ne '*') {
		print STDERR "   WARNING: $contig_id:$end$strand$orf_len does not begin with STOP ($codon)\n"
		    if $ENV{VERBOSE};
	    }
	    
	    $self->add_feature( -type => 'orf'
			      , -loc  => [$contig_id, $end, $strand, $orf_len, $orf_len]
			      , -seq  => $$transP)
		|| confess "Could not add 'orf' feature at $contig_id:$end$strand$orf_len";
	}
	else {
	    confess "Could not parse ORF header: $locus";
	}
    }
    unlink $tmp_orfs or confess "Could not remove $tmp_orfs";
    
    return { map { $_ => $self->{_features}->{$_} } $self->get_fids_for_type('orf') };
}

#
# Blast the given query sequence against a database consisting of
# the ORFs or pegs of this genome.
#
sub candidate_orfs {
    my ($self, %args) = @_;
    
    my $query_id  = $args{-qid}      || 'query_seq';
    my $query_seq = $args{-seq}      || $fig->get_translation($args{-qid}) || confess "No query sequence provided";
    my $cutoff    = $args{-cutoff}   || 1.00e-10;
    my $maxhits   = $args{-maxhits}  || 99999999;
    
    my $use_pegs  = $args{-use_pegs} || '';
    
    print STDERR "Processing rep_seq $query_seq\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
    
    my $query_file = "$FIG_Config::temp/tmp_query.$$.fasta";
    open(TMP, ">$query_file") || confess "Could not write-open $query_file";
    &FIG::display_id_and_seq($query_id, \$query_seq, \*TMP); 
    close(TMP)
	|| confess "Could not close query-file $query_file --- args:\n" . &flatten_dumper(\%args) . "\n";
    (-s $query_file) 
	|| confess "Could not write query sequence to $query_file --- args:\n" . &flatten_dumper(\%args) . "\n";
    
    my $db = "$FIG_Config::temp/tmp_orfs.$$.fasta";
    if (!-s $db) {
	open(DB, ">$db") || confess "Could not write-open sequence file $db";
	
	my @fids;
	if ($use_pegs) {
	    @fids = $self->get_fids_for_type('peg');
	} else {
	    @fids = $self->get_fids_for_type('orf');
	}
	print STDERR "Writing ", (scalar @fids), " candidate ORFs to $db\n"
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	
    	foreach my $fid (@fids)	{
	    print STDERR "Writing $fid to $db\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 3));
	    &FIG::display_id_and_seq($fid, \$self->get_feature_sequence($fid), \*DB);
	}
	close(DB) || die "Could not close $db";

    }
    (-s $db) || confess "ORF file $db is empty";
    
    if ((!-s "$db.psq") || ((-M "$db.psq") > (-M $db))) {
	&FIG::run("formatdb -i $db -p T");
    }
    (-s "$db.psq") || confess "formatdb of $db failed";
    
    my @sims = `$FIG_Config::ext_bin/blastall -i $query_file -d $db -p blastp -m8 -e $cutoff`;
    
    if (@sims == 0) {
	print STDERR "No sims found for query $query_id against $db\n" if $ENV{VERBOSE}; 
    } else {
	my $num_sims = @sims;
	print STDERR "Found $num_sims sim".(($num_sims == 1) ? qq() : qq(s))
	    , " against candidate ",
	    , ($use_pegs ? qq(PEGs) : qq(ORFs))
	    , ":\n"
	    , join("", @sims)
	    if $ENV{VERBOSE};
    }
    chomp @sims;

    my %seen;
    my $sim;
    my @orfs;
    foreach $sim (@sims) {
	if ((@orfs < $maxhits) && ($sim =~ /^\S+\t(\S+)/o) && (! $seen{$1}) && $self->is_feature($1)) {
	    my $orf_id = $1;
	    $seen{$orf_id} = 1;
	    push @orfs, NewGenome::ORF->new($self, $orf_id);
	}
    }
    
    my $num_orfs = (scalar @orfs);
    print STDERR "Found $num_orfs candidate "
	, ($use_pegs ? qq(PEG) : qq(ORF)).(($num_orfs == 1) ? qq() : qq(s))
	, "\n"
	if $ENV{VERBOSE};
    
    return @orfs;
}

sub mark_overlapping_orfs {
    my ($self, $fid) = @_;
    
    return 1;
}

sub promote_remaining_orfs {
    my ($self, $called_by_fh) = @_;
    
    my @fids = $self->get_fids_for_type(qw(rna peg));
    
    my @existing_features = ();
    foreach my $fid (@fids) {
	my $loc     = $self->get_seed_loc($fid);
	confess "No loc for FID $fid:\n", &Dumper($self) if (not defined($loc));
	
	my ($contig, $beg, $end) = $fig->boundaries_of($loc);
	my $aliases = $self->get_feature_aliases($fid);
	my $entry   = [$fid, $loc, $aliases,
		       $contig, $beg, $end,
		       &FIG::min($beg,$end),
		       &FIG::max($beg,$end),
		       ($beg < $end) ? "+" : "-",
		       'peg'
		       ];
	push @existing_features, $entry;
    }
    
    my @orf_ids = sort { $self->get_feature_length($b) <=> $self->get_feature_length($a) } 
                  $self->get_fids_for_type('orf');
    
    my @new_orfs = ();
    foreach my $orf_id (@orf_ids) {
	my $loc     = $self->get_seed_loc($orf_id);
	confess "No loc for FID $orf_id:\n", &Dumper($self) if (not defined($loc));

	my ($contig, $beg, $end) = $fig->boundaries_of($loc);
	my $aliases = $self->get_feature_aliases($orf_id);
	my $entry   = [$orf_id, $loc, $aliases,
		       $contig, $beg, $end,
		       &FIG::min($beg,$end),
		       &FIG::max($beg,$end),
		       ($beg < $end) ? "+" : "-",
		       'peg'
		       ];
	
	push @new_orfs, $entry;
    }
    
    
    my $parms = { min_peg_ln                =>  90,
		  max_RNA_overlap           =>  20,
		  max_convergent_overlap    =>  50,
		  max_divergent_overlap     => 150,
		  max_same_strand_overlap   => 120
		  };
    
    my $keep = &update_features($self, \@existing_features, \@new_orfs, $parms,
				qq(promote_remaining_orfs (no sims)), $called_by_fh
				);
    
    my $fids;
    @$fids = map { $_->[0]
		   } map { @ { $keep->{$_} }
		       } (keys %$keep);
    return $fids;
}

sub update_features {
    my ($self, $tbl, $new_entries, $parms, $calling_method, $called_by_fh) = @_;
    
    print STDERR "\nEntered update_features\n" if $ENV{VERBOSE};
    
    # constants for positions in "keep" lists
    use constant UPD_FID     => 0;
    use constant UPD_LOC     => 1;
    use constant UPD_ALIASES => 2;
    use constant UPD_CONTIG  => 3;
    use constant UPD_START   => 4;
    use constant UPD_STOP    => 5;
    use constant UPD_LEFT    => 6;
    use constant UPD_RIGHT   => 7;
    use constant UPD_STRAND  => 8;
    use constant UPD_TYPE    => 9;

    if (not $calling_method) {
	$calling_method = "unspecified means";
    }
    
    my $keep = {};
    foreach my $entry (@$tbl) {
	my ($fid, $loc, $aliases) = @$entry;
	($fid =~ /^fig\|\d+\.\d+\.(\w+)\.\d+$/o) || confess "Could not parse FID=$fid";
	my $type = $1;
	
	($loc =~ m/^(\S+)_(\d+)_(\d+)$/o) || confess "Could not parse loc=$loc";
	my ($contig, $beg, $end) = ($1, $2, $3);
	
	push(@{$keep->{$contig}}, [$fid,
				   $loc,
				   $aliases,
				   $contig,
				   $beg,
				   $end,
				   &FIG::min($beg,$end),
				   &FIG::max($beg,$end),
				   ($beg < $end) ? "+" : "-",
				   $type,
				   ]);
    }
    
    foreach my $contig (keys %$keep) {
	my $x = $keep->{$contig};
	$keep->{$contig} = [sort { ($a->[UPD_LEFT]  <=> $b->[UPD_LEFT]) ||
				   ($b->[UPD_RIGHT] <=> $a->[UPD_RIGHT]) } @$x];
    }
    
    if ($ENV{VERBOSE}) {
	print STDERR "\nkeep:\n";
	foreach my $contig (sort keys %$keep) {
	    print STDERR ">$contig\n";
	    my $x = $keep->{$contig};
	    for (my $i=0; $i < @$x; ++$i) {
		my $y = &flatten_dumper($x->[$i]);  
		print STDERR "keep $i:\t$y\n";
	    }
	    print STDERR "\n";
	}
    }
    
    my $entry;
    print STDERR "\n" if $ENV{VERBOSE};
    foreach my $new_entry (@$new_entries) {
	my $orf = $new_entry->[UPD_FID];
	my $loc = $new_entry->[UPD_LOC];
	my ($contig, $beg, $end) = $fig->boundaries_of($loc);
	
	my $left   = $new_entry->[UPD_LEFT];
	my $right  = $new_entry->[UPD_RIGHT];
	my $strand = $new_entry->[UPD_STRAND];
	
	#...Unconditionally delete ORF object, regardless of whether it gets promoted...
	unless ($self->delete_feature($orf)) {
	    confess "Could not delete ORF $orf:\n"
		, Dumper($self->get_feature_object($orf));
	}
	
	my $peg;
	my $where;
	if (defined($where = &keep_this_one($parms, $keep, $contig, $beg, $end, $orf))) {
	    print STDERR "Inserting $contig\_$beg\_$end before keep[$where]\n" if $ENV{VERBOSE};
	    
	    if ($peg = $self->add_feature( -type  => 'peg',
					   -loc   => $self->from_seed_loc($loc),
					   -annot => [qq(RAST), qq(Called by $calling_method.)],
					   )
		) 
	    {
		if (defined($called_by_fh)) {
		    print $called_by_fh "$peg\t$calling_method\n";
		}
	    }
	    else {
		confess "Could not promote $orf to a PEG:\n"
		    , Dumper($self);
	    }
	    
	    $new_entry->[UPD_FID] = $peg;
	    splice(@ { $keep->{$contig} }, $where, 0, $new_entry);
	}
	else {
	    print STDERR "Not inserting feature $left$strand$right\n" if $ENV{VERBOSE};
	}
	print STDERR "\n" if $ENV{VERBOSE};
    }
#   print STDERR Dumper($keep);
    
    return $keep;
}

sub keep_this_one {
    my ($parms,$keep,$contig,$beg,$end,$fid) = @_;
    
    my ($ln, $x, @overlaps, $left, $right, $strand, $i);
    my 	$where = undef;
    
    my $min_peg_ln = $parms->{min_peg_ln};
    
    if (($ln = (abs($end-$beg)+1)) < $min_peg_ln) {
	print STDERR "FID failed length test: FID=$fid, beg=$beg, end=$end, len=$ln, min=$min_peg_ln\n"
	    , &Dumper($fid,$keep) if $ENV{VERBOSE};
	return undef;
    }
    
    $left   = &FIG::min($beg,$end);
    $right  = &FIG::max($beg,$end);
    $strand = ($beg < $end) ? "+" : "-";
    print STDERR "Processing $fid: $left$strand$right\n" if $ENV{VERBOSE};
    
    if (not defined($x = $keep->{$contig})) {
	print STDERR (qq(No pre-existing features on contig \'$contig\'\;),
		      qq( keeping new feature unconditionally\n)
		      ) if $ENV{VERBOSE};;
	$where = 0;
    }
    else {
	for ($i=0; ($i < @$x) && ($left > $x->[$i]->[UPD_RIGHT]); ++$i) {}
	print STDERR "Possible insertion before keep[$i] --- checking for overlaps\n" if $ENV{VERBOSE};
	
	@overlaps = ();
	while (($i < @$x) && ($right >= $x->[$i]->[UPD_LEFT])) {
	    print STDERR "keep[$i]: " , &flatten_dumper($x->[$i]), "\n" if $ENV{VERBOSE};
	    
	    if ($left <= $x->[$i]->[UPD_LEFT]) {
		print STDERR "Setting insertion point to before keep[$i]\n" if $ENV{VERBOSE};
		$where = $i;
	    }
	    
	    if ($ENV{VERBOSE}) {
		my $y = &flatten_dumper($x->[$i]);  
		print STDERR "   overlap = "
		    , &overlap($left, $right, $x->[$i]->[UPD_LEFT],  $x->[$i]->[UPD_RIGHT])
		    , ",\n   pushing feature\t$y\n"; 
	    }
	    
	    push(@overlaps,$x->[$i]);
	    ++$i;
	}
	
	if (not defined $where) {
	    $where = $i;
	    print STDERR "Insertion point defaults to before keep[$where]\n" if $ENV{VERBOSE};
	}
	
	my $serious = 0;
	for ($i=0; ($i < @overlaps); ++$i) {
	    my $y = &flatten_dumper($overlaps[$i]);
	    print STDERR "   overlap list[$i]:\t$y\n" if $ENV{VERBOSE};
	    if (&serious_overlap($parms,$left,$right,$strand,$overlaps[$i],$fid)) { ++$serious; }
#	    print STDERR "\n" if $ENV{VERBOSE};
	}
#	print STDERR "\n" if $ENV{VERBOSE};
	return undef if $serious;
    }
    
    return $where;
}

sub overlap {
    my ($min, $max, $minO, $maxO) = @_;
    my $olap = &FIG::max(0, (&FIG::min($max,$maxO) - &FIG::max($min,$minO) + 1));
#   warn "min=$min,\tmax=$max,\tminO=$minO,\tmaxO=$maxO,\tolap=$olap\n" if $ENV{VERBOSE};
    return $olap;
}

sub serious_overlap {
    my ($parms, $min, $max, $strand, $overlap, $fid) = @_;
    my $minO    = $overlap->[UPD_LEFT];
    my $maxO    = $overlap->[UPD_RIGHT];
    my $strandO = $overlap->[UPD_STRAND];
    my $typeO   = $overlap->[UPD_TYPE];
    my $fidO    = $overlap->[UPD_FID];
    
    my $olap = &overlap($min, $max, $minO, $maxO);
    print STDERR "olap=$olap\n" if $ENV{VERBOSE};
    
    if (&embedded($min,$max,$minO,$maxO))
    {
	print STDERR "$minO$strandO$maxO is embedded in $min$strand$max [kept]\n" if $ENV{VERBOSE};
#	die Dumper($overlap);
	return 1;
    }
    
    if (&embedded($minO,$maxO,$min,$max)) {
	print STDERR "$min$strand$max is embedded in $minO$strandO$maxO [kept]\n" if $ENV{VERBOSE};
#	die Dumper($overlap);
	return 1;
    }
    
    if (($typeO eq "rna") && ($olap > $parms->{max_RNA_overlap})) {
	print STDERR "too much RNA overlap: $min$strand$max overlaps $minO$strandO$maxO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO !~ /^rna/o) && ($olap > $parms->{max_convergent_overlap})
       && &convergent($min,$max,$strand,$minO,$maxO,$strandO))
    {
	print STDERR "too much convergent overlap: $min$strand$max overlaps $minO$strandO$maxO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO !~ /^rna/o) && ($olap > $parms->{max_divergent_overlap})
       && &divergent($min,$max,$strand,$minO,$maxO,$strandO))
    {
	print STDERR "too much divergent overlap: $min$strand$max overlaps $minO$strandO$maxO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    if (($typeO !~ /^rna/o) && ($strand eq $strandO)
       && ($olap > $parms->{max_same_strand_overlap}))
    {
	print STDERR "too much same_strand overlap: $min$strand$max overlaps $minO$strandO$maxO ($olap)\n" if $ENV{VERBOSE};
	return 1;
    }
    
    return 0;
}

sub embedded {
    my($min,$max, $minO,$maxO) = @_;

    if (($min <= $minO) && ($maxO <= $max)) {
	return 1;
    }
    return 0;
}

sub convergent {
    my($min,$max,$strand,$minO,$maxO,$strandO) = @_;

    if (($strand ne $strandO) && 
	((($min < $minO) && ($strand eq "+")) ||
	 (($minO < $min) && ($strandO eq "+"))))
    {
	return 1;
    }
    return 0;
}

sub divergent {
    my($min,$max,$strand,$minO,$maxO,$strandO) = @_;

    if (($strand ne $strandO) && 
	((($min < $minO) && ($strand eq "-")) ||
	 (($minO < $min) && ($strandO eq "-"))))
    {
	return 1;
    }
    return 0;
}



sub call_start {
    my ($self, $fid, $sims) = @_;
    my ($id2, $ln2, $b1, $b2, $iden, $bsc);
    my ($tmp_loc, $tmp_len, $loc_str);
    my (%votes_for, %codon_for, $codon);
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Temporarily disabled...
#=======================================================================
    return $self->get_feature_loc($fid);
#-----------------------------------------------------------------------
    
    my $num_sims = @$sims;
    if (defined($ENV{VERBOSE})) {
	my $s = ($num_sims == 1) ? qq() : qq(s);
	print STDERR "\nRe-calling START of $fid using $num_sims sim$s";
	if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2)) {
	    print STDERR ":\n";
	    foreach my $sim (@$sims) {
		print STDERR (&flatten_dumper($sim), "\n");
	    }
	}
	print STDERR "\n";
    }
    
    my $original_loc = $self->get_feature_loc($fid);
    if (@$original_loc > 1) {
	warn "Cannot recall START of multi-exon feature $fid";
	return $original_loc;
    }
    my $original_len = $self->get_exon_length($original_loc->[-1]);
    my $orf_len      = $self->get_orf_length($original_loc);
    my $original_start_codon  =  substr($self->get_dna_subseq($original_loc), 0, 3);
    if (defined $original_start_codon) {
	if ($self->is_valid_start_codon($original_start_codon)) {
	    print STDERR "FID $fid has original START=$original_start_codon,"
		, " original_len=$original_len,"
		, " orf_len=$orf_len,"
		, " original_loc = ", &flatten_dumper($original_loc), "\n"
		if $ENV{VERBOSE};
	}
	else {
	    print STDERR "Original START codon $original_start_codon is invalid --- setting undef\n"
		if $ENV{VERBOSE};
	    $original_start_codon = undef;
	}
    }
    else {
	confess "Could not get called START codon for FID $fid, loc="
	    , &flatten_dumper($original_loc);    
    }
    
    if (not defined($orf_len)) {
	warn "FID $fid has an undefined ORF-length; recomputing now...\n" if $ENV{VERBOSE};
	$original_loc = $self->search_for_upstream_stop($original_loc);
	$original_loc = $self->set_feature_loc($fid, $original_loc)
	    || confess "Could not set ORF-length for $fid";
	($orf_len = $self->get_orf_length($original_loc))
	    || confess "Setting recomputed ORF-length failed;"
	              , " original_loc=", &flatten_dumper($original_loc), "\n"
		      , " feature=", &flatten_dumper($self->get_feature($fid));
    }
    my $orf_loc = $self->copy_loc($original_loc->[-1]);
    
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Compute mean and variance of hit lengths ...
#-----------------------------------------------------------------------
    my $mean_len  =  $original_len;

#...Cheat to suppress divide-by-zero errors
    my $variance  = $original_len / ($num_sims+1);   
    my $std_dev   = sqrt($variance);
    
    my $begin_sim_region = 0;
    foreach my $sim (@$sims) {
	print STDERR &flatten_dumper($sim), "\n" 
	    if (defined($ENV{VERBOSE}) && (($num_sims <= 10) || ($ENV{VERBOSE} > 2)));
	
	$b1  = $sim->b1;
	$ln2 = 3 * ( 1 + $sim->ln2 );
	
	$mean_len +=  $ln2;
	$variance += ($ln2 - $original_len)**2;
	
	if ($ENV{VERBOSE}) {
	    if ($ENV{VERBOSE} > 2) {
		print STDERR "   b1=$b1,\tbegin=$begin_sim_region --> ";
		$begin_sim_region   = &FIG::max( $begin_sim_region, ($original_len - 3*($b1-1)) );
		print STDERR "begin=$begin_sim_region\n";
	    }
	    else {
		$tmp_len = ($original_len - 3*($b1-1));
		if ($tmp_len > $begin_sim_region) {
		    print STDERR "   b1=$b1,\tbegin=$begin_sim_region --> ";
		    $begin_sim_region = $tmp_len;
		    print STDERR "begin=$begin_sim_region\n";
		}
	    }
	}
    }
    
    if ($num_sims > 1) {
	$mean_len /= ($num_sims + 1);       #...Add one to acct for including the original length...
	$variance -= $num_sims * ($mean_len - $original_len)**2;   #...Correct for offset...
	$variance /= $num_sims;             #...Again, add one to "sample-variance" denominator...
	$std_dev = sqrt($variance);
	print STDERR "Setting num_sims=$num_sims, begin=$begin_sim_region, mean_len=$mean_len, std_dev=$std_dev\n"
	    if $ENV{VERBOSE};
    }
    else {
	$mean_len  = $original_len;
	$std_dev   = sqrt($original_len);
	print STDERR "Default num_sims=$num_sims, begin=$begin_sim_region, mean_len=$mean_len, std_dev=$std_dev\n"
	    if $ENV{VERBOSE};
    }
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Vote on possible START positions ...
#-----------------------------------------------------------------------
    
    my @tmp = $self->possible_starts($orf_loc);
    my @possible_starts   = map { $_->[0] } @tmp;
    %codon_for = map { $_->[0] => $_->[1] } @tmp;
    my $first_start_len   = $possible_starts[0];
    my $first_start_codon = $codon_for{$first_start_len};
    unless ($first_start_len && $first_start_codon) {
	cluck "Could not extract first START candidate for FID $fid, loc="
	    , &flatten_dumper($orf_loc);
	return undef;
    }
    
    print STDERR "Possible STARTs: "
	, join(", ", @possible_starts)
	, "\n"
	if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
    
    #...cast a nominal vote for the original call...
    $votes_for{$original_len} += &_score_len(10, 80, $original_start_codon, $original_len, $mean_len, $std_dev);
    
    my $estimate;
    for (my $i=0; $i < @$sims; ++$i) {
	last if ($i >= 10);
	
	my $sim = $sims->[$i];
	
	$id2  = $sim->id2;
	$ln2  = 3 * ( 1 + $sim->ln2 );
	
	$b1   = $sim->b1;
	$b2   = $sim->b2;
	$iden = $sim->iden;
	$bsc  = $sim->bsc;
	
	$estimate = 3 * ( int($orf_len/3) - $b1 + $b2 );
	
	if ($estimate > $orf_len) {
	    print STDERR "For sim \@ $id2: ln2=$ln2, b1=$b1, b2=$b2, estimated len=$estimate > orf_len=$orf_len"
		, " --- using len=$first_start_len\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    $votes_for{$first_start_len} += &_score_len($bsc, $iden, $first_start_codon, $first_start_len, $mean_len, $std_dev);
	}
	else {
	    print STDERR "For sim \@ $id2: ln2=$ln2, b1=$b1, b2=$b2, estimated len=$estimate\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	    
	    my $best_len = $first_start_len;
	    $codon       = $first_start_codon;
	    foreach my $start (@possible_starts) {
		if (abs($start - $estimate) < abs($best_len - $estimate)) {
		    $best_len = $start;
		    $codon = $codon_for{$best_len};
		}
	    }
	    
	    #...penalize best_len candidate if $best_len < $begin_sim_region...
	    my $weight = ($best_len <= $begin_sim_region) ? (0.5) : (1.0) ;
	    $votes_for{$best_len} +=  $weight * &_score_len($bsc, $iden, $codon, $best_len, $mean_len, $std_dev);
	    $codon_for{$best_len}  =  $codon;
	    
	    print STDERR "   Candidate is codon=$codon, len=$best_len,"
		, "\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
	}
    }
    print STDERR "Votes: ", &flatten_dumper(\%votes_for), "\n" if $ENV{VERBOSE};
    
    my $best_len  = $original_len;
    my $best_vote = $votes_for{$original_len};
    print STDERR "begin=$begin_sim_region\n" if $ENV{VERBOSE};
    foreach my $len (sort { $a <=> $b } keys %votes_for) {
	if ($votes_for{$len} > $best_vote) {
	    $best_len  = $len;
	    $best_vote = $votes_for{$len};
	    print STDERR "Best --> len=$best_len, codon=$codon_for{$best_len}, vote=$best_vote\n" if $ENV{VERBOSE};
	}
	else {
	    print STDERR "         len=$len, codon=$codon_for{$len}, vote=$votes_for{$len}"
		. " --- keeping best_len=$best_len, best_codon=$codon_for{$best_len}, best_vote=$best_vote\n"
		if $ENV{VERBOSE};
	}
    }
    print STDERR "Selected START codon=$codon_for{$best_len}, new_len=$best_len, original_len=$original_len, orf_len=$orf_len,"
	, " given mean_len=$mean_len, std_dev=$std_dev\n"
	if $ENV{VERBOSE};
    
    if (not $self->is_valid_start_codon($codon_for{$best_len})) {
	if ($ENV{VERBOSE}) {
	    print STDERR "Invalid START codon=$codon_for{$best_len} selected, len=$best_len, orf_len=$orf_len\n";
	    print STDERR "Attempting to default to first_start_len=$first_start_len, first_start_codon=$first_start_codon\n";
	}
	
	if (defined($first_start_codon)) {
	    $best_len = $first_start_len;
	    print STDERR "Default succeded\n" if $ENV{VERBOSE};
	}
	else {
	    $loc_str = &flatten_dumper($original_loc);
	    confess "Aborting ---something is seriously wrong with this ORF: $loc_str";
	}
    }
    
    $tmp_loc = $self->copy_loc($orf_loc);
    $self->set_exon_length($tmp_loc, $best_len)
	|| confess "Could not set recalled ORF length to loc=" . &flatten_dumper($tmp_loc);
     
    return $tmp_loc;
}

sub _score_len {
    my ($bsc, $iden, $codon, $len, $mean_len, $std_dev) = @_;
    
    return 0 if ($iden < 75.0);
    
    return ($bsc * (($iden - 75.0) / 100.0)
	    * (($codon eq 'atg') ? 5 : 1)
	    * exp(-(0.5) * (($len - $mean_len) / $std_dev)**2)
	    / $std_dev
	    / sqrt(2.0 * 3.14159265359)
	    );
}


sub possible_starts {
    my ($self, $loc, $maxlen) = @_;
    my @starts = ();
    
    if (ref($loc->[0]) ne 'ARRAY')  { $loc = [$loc]; }
    my ($contig_id, $end, $strand, $len, $orf_len) = @ { $loc->[0] };
    my $contig_len = $self->get_contig_length($contig_id);
    
    if (not defined($orf_len)) {
	print STDERR "loc=", &flatten_dumper($loc), " has an undefined ORF-length; recomputing now...\n"
	    if $ENV{VERBOSE};
	$loc = $self->search_for_upstream_stop($loc)
	    || confess "Could not find upstrem STOP for ", &flatten_dumper($loc);
	($orf_len = $self->get_orf_length($loc))
	    || confess "Could not find ORF-length for loc=", &flatten_dumper($loc);
    }
    
    my $sign = ($strand eq qq(+)) ? +1 : -1 ;
    
    my $beg  = $end - $sign*($orf_len-1);
    
    my $seq = $self->get_dna_subseq($loc);
    print STDERR "Searching for STARTs, contig=$contig_id ($contig_len),"
	. " beg=$beg, end=$end, strand=$strand, len=$len, orf_len=$orf_len\n"
	. (join(" ", unpack(("A3" x ((2+length($seq))/3)), $seq))) . "\n"
	if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
#   print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
    
    my $e = $end - $sign*($orf_len-3);
    my $codon = "";
    for (my $i=$orf_len; $i > 3; $i -= 3) {
        $e     = $end - $sign*($i-3);
	$codon = $self->get_dna_subseq([$contig_id, $e, $strand, 3]);
	
	print STDERR "PS\t--- $i\t$e\t$codon"
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	
	if ($self->is_valid_start_codon($codon)) {
	    $len = $i;
            push @starts, [$len, $codon];
	    print STDERR " <---" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	}
	
	print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	
	if ((not $codon) || (&FIG::translate($codon, $self->get_translation_table) eq '*')) {
	    confess "Found internal STOP at strand=$strand, len=$i, e=$e, end=$end, codon=$codon\n\n" 
	}
    }
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
    
    return @starts;
}

my %cache_downstream_start_loc;
my %cache_downstream_start_codon;
sub search_for_downstream_start {
    my ($self, $loc, $minlen) = @_;
    unless (defined($minlen)) { $minlen = 90; }
    my ($orf_loc, $codon);
    
    if (ref($loc->[0]) ne 'ARRAY')  { $loc = [$loc]; }
    my $x = &flatten_dumper($loc);
    if (defined($orf_loc = $cache_downstream_start_loc{$x})) {
	$codon = $cache_downstream_start_codon{$x};
	print STDERR "   Returning cached downstream START codon=$codon, loc="
	    , &flatten_dumper($orf_loc), "\n"
	    if $ENV{VERBOSE};
	if (wantarray)  { return ($orf_loc, $codon); }
	else            { return  $orf_loc;          }
    }
        
    my ($contig_id, $end, $strand, $len, $orf_len) = @ { $loc->[0] };
    confess "Bad loc=", &flatten_dumper($loc) unless (defined($contig_id) && $end && $strand && $len);
    
    my $sign = ($strand eq qq(+)) ? +1 : -1 ;
    my $beg  = $end - $sign*($len-1);
    
    print STDERR "Searching for downstream START, contig=$contig_id,"
	. " beg=$beg, end=$end, strand=$strand, len=$len, orf_len=$orf_len"
	if $ENV{VERBOSE};
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
    
    my $e;
    $codon = "";
    for (my $i=$len; $i >= $minlen; $i -= 3) {
	$e     = $end - $sign*($i-3);
	$codon = $self->get_dna_subseq([$contig_id, $e, $strand, 3]);
	print STDERR "SD^\t--- $i\t$e\t$codon\n"
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	
	if ($self->is_valid_start_codon($codon)) {
	    $len = $i;
            last; 
	}
	
	if ((not $codon) || (&FIG::translate($codon, $self->get_translation_table) eq '*')) {
	    cluck "Search failed ($i, $e, $end, $codon) --- going with default length\n" if $ENV{VERBOSE};
	    print STDERR "\n" if $ENV{VERBOSE};
	    
	    $len = $orf_len;
	    last;
	}
    }
    print STDERR " --> len=$len, codon=$codon\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} == 1));
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
    
    $orf_loc = [ $contig_id, $end, $strand, $len, $orf_len ];
    $cache_downstream_start_loc{$x}   = $orf_loc;
    $cache_downstream_start_codon{$x} = $codon;
    
    if (wantarray) {
	return ($orf_loc, $codon);
    }
    else {
	return  $orf_loc;
    }
}

my %cache_upstream_start_loc;
my %cache_upstream_start_codon;
sub search_for_upstream_start {
    my ($self, $loc, $maxlen) = @_;
    my ($orf_loc, $codon);
    
    if (ref($loc->[0]) ne 'ARRAY')  { $loc = [$loc]; }
    my $x = &flatten_dumper($loc);
    if (defined($orf_loc = $cache_upstream_start_loc{$x})) {
        $codon = $cache_upstream_start_codon{$x};
	print STDERR "   Returning cached upstream START codon=$codon, loc="
	    , &flatten_dumper($orf_loc), "\n"
	    if $ENV{VERBOSE};
        if (wantarray)  { return ($orf_loc, $codon); }
        else            { return  $orf_loc;          }
    }
    
    my ($contig_id, $end, $strand, $len, $orf_len) = @ { $loc->[-1] };
    if (not defined($orf_len)) {
	confess "Undefined ORF-length for loc:\n"
	    , &flatten_dumper($loc);
    }
    
    my $sign = ($strand eq qq(+)) ? +1 : -1 ;
    my $beg  = $end - $sign*($len-1);
    my $contig_len = $self->get_contig_length($contig_id);
    
    print STDERR "Searching for upstream START, contig=$contig_id ($contig_len),"
	. " beg=$beg, end=$end, strand=$strand, len=$len, orf_len=$orf_len"
	if $ENV{VERBOSE};
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
    
    my $e;
    $codon = "";
    for (my $i=$len; $i <= ($orf_len-3); $i += 3) {
	$e     = $end - $sign*($i-3);
	$codon = $self->get_dna_subseq([$contig_id, $e, $strand, 3]);
	print STDERR "SU^\t--- $i\t$e\t$codon\n"
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	
	if ($self->is_valid_start_codon($codon)) {
	    $len = $i;
	    last; 
	}
	
	if ((not $codon) || (&FIG::translate($codon, $self->get_translation_table) eq '*')) {
	    cluck "Search failed ($i, $e, $end, $codon) --- going with default length\n" if $ENV{VERBOSE};
	    print STDERR "\n" if $ENV{VERBOSE};
	    
	    $len = $orf_len;
	    last;
	}
    }
    print STDERR " --> len=$len, codon=$codon\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} == 1));
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
    
    $orf_loc = [ $contig_id, $end, $strand, $len, $orf_len ];
    $cache_upstream_start_loc{$x}   = $orf_loc;
    $cache_upstream_start_codon{$x} = $codon;
    
    if (wantarray) {
	return ($orf_loc, $codon);
    }
    else {
	return  $orf_loc;
    }
}

my %cache_upstream_stop_loc;
my %cache_upstream_stop_codon;
sub search_for_upstream_stop {
    my ($self, $loc, $maxlen) = @_;
    my ($orf_loc, $codon);
    
    my $failed    = 0;
    my $succeeded = 0;
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++    
# ... NOTE: Returns an ORF and a codon, not an exon ptr and a codon ...
#-----------------------------------------------------------------------    
    if (ref($loc->[0]) ne 'ARRAY')  { $loc = [$loc]; }
    my $x = &flatten_dumper($loc);
    if (defined($orf_loc = $cache_upstream_stop_loc{$x})) {
        $codon = $cache_upstream_stop_codon{$x};
	print STDERR "   Returning cached upstream STOP codon=$codon, loc="
	    , &flatten_dumper($orf_loc), "\n"
	    if $ENV{VERBOSE};
        if (wantarray)  { return ($orf_loc, $codon); }
        else            { return  $orf_loc;          }
    }
    
    my ($contig_id, $end, $strand, $len, $orf_len) = @ { $loc->[-1] };
    confess "Bad loc=", &flatten_dumper($loc) unless (defined($contig_id) && $end && $strand && $len);
    
    my $sign = ($strand eq qq(+)) ? +1 : -1 ;
    my $contig_len = $self->get_contig_length($contig_id);
    
    if (defined($orf_len)) {
	print STDERR "search_for_upstream_stop: ORF-length already defined for loc=\n"
	    , &flatten_dumper($loc)
	    if $ENV{VERBOSE};
	
	$codon = $self->get_dna_subseq([$contig_id, ($end - $sign*$orf_len), $strand, 3]);
    }
    else {
	$orf_len = $len;   #...default length...
	
	unless (defined($maxlen)) {
	    #...Check this for correctness...
	    if ($strand eq qq(+)) {
		$maxlen = $end; 
	    } else {
		$maxlen = $contig_len - $end + 1;
	    }
	}
	
	my ($beg, $minlen);
# 	if (defined($len)) { # Causes problems now that ambigs are accepted as valid STOPs.
	if (0) { 
 	    $minlen = $len;
 	    $beg  = $end - $sign*($len-1);
 	} else {
 	    $minlen = 6;
 	    $beg  = $end - $sign*($minlen-1);
 	}
	
	print STDERR "Searching for upstream STOP, contig=$contig_id ($contig_len),"
	    , " beg=$beg, end=$end, strand=$strand, len=$len, minlin=$minlen, maxlen=$maxlen\n"
	    if $ENV{VERBOSE};
	
	my $e;
	$codon = "";
	for (my $i=$minlen; $i <= $maxlen; $i += 3) {
	    $e     = $end - $sign*($i-3);
	    $codon = $self->get_dna_subseq([$contig_id, $e, $strand, 3]);
	    print STDERR "SU*\t--- $i\t$e\t$codon\n"
		if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	    
	    if ($codon) {
		$orf_len = $i;
		if (&FIG::translate($codon, $self->get_translation_table) eq '*') { 
		    $succeeded = 1;
		    $orf_len   = ($i-3);
		    last; 
		}
	    }
	    else {
		$failed = 1;
		print STDERR "Search failed ($i, $e, $end) --- going with last successful length, $orf_len\n";
		last;
	    }
	}
	print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	
	$codon = $self->get_dna_subseq([$contig_id, ($end - $sign*$orf_len), $strand, 3]);
	if ($codon
	    && (&FIG::translate($codon, $self->get_translation_table) ne '*')
	    && ($succeeded || (not $failed))
	    )
	{
	    confess "Something is wrong --- non-failed search yielded preceeding codon=$codon";
	}
    }
    
    $orf_loc = [ $contig_id, $end, $strand, $len, $orf_len ];
    $cache_upstream_stop_loc{$x}   = $orf_loc;
    $cache_upstream_stop_codon{$x} = $codon;
    
    if (wantarray)  {
	return ($orf_loc, $codon, $failed);
    }
    else {
	return  $orf_loc;
    }
}

my %cache_extend_to_downstream_stop_loc;
my %cache_extend_to_downstream_stop_codon;
sub extend_to_downstream_stop {
    my ($self, $loc, $minlen) = @_;
    unless (defined($minlen)) { $minlen = 90; }
    my ($orf_loc, $codon);
    
    my $failed    = 0;
    my $succeeded = 0;

    if (ref($loc->[0]) ne 'ARRAY')  { $loc = [$loc]; }
    my $x = &flatten_dumper($loc);
    if (defined($orf_loc = $cache_extend_to_downstream_stop_loc{$x})) {
	$codon = $cache_extend_to_downstream_stop_codon{$x};
	print STDERR "   Returning cached downstream START codon=$codon, loc="
	    , &flatten_dumper($orf_loc), "\n"
	    if $ENV{VERBOSE};
	if (wantarray)  { return ($orf_loc, $codon); }
	else            { return  $orf_loc;          }
    }
        
    my ($contig_id, $end, $strand, $len, $orf_len) = @ { $loc->[0] };
    confess "Bad loc=", &flatten_dumper($loc) unless (defined($contig_id) && $end && $strand && $len);
    
    my $sign = ($strand eq qq(+)) ? +1 : -1 ;
    my $beg  = $end - $sign*($len-1);
    
    print STDERR "Searching for downstream STOP, contig=$contig_id,"
	. " beg=$beg, end=$end, strand=$strand, len=$len, orf_len=$orf_len"
	if $ENV{VERBOSE};
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));
    
    my $e;
    $codon = "";
    for (my $i=0; $i < 9000; $i += 3) {
	$e = $end + $sign * $i;
	last unless $self->check_bounds([$contig_id, $e, $strand, 3]);
	
	$codon = $self->get_dna_subseq([$contig_id, $e, $strand, 3]);
	print STDERR "ED\*\t--- $i\t$e\t$codon\n"
	    if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
	
	if ($codon) {
	    if (&FIG::translate($codon, $self->get_translation_table) eq '*') {
		$succeeded = 1;
		last; 
	    }
	}
	else {
	    $failed = 1;
	    print STDERR "Search failed ($i, $e, $end) --- going with last successful length, $len\n";
	    last;
	}
	
	$end  = $e;
	$len += 3;
	if (defined($orf_len)) { $orf_len += 3; }
    }
    print STDERR " --> len=$len, codon=$codon\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} == 1));
    print STDERR "\n" if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 2));
    
    $orf_loc = [ $contig_id, $end, $strand, $len, $orf_len ];
    $cache_extend_to_downstream_stop_loc{$x}   = $orf_loc;
    $cache_extend_to_downstream_stop_codon{$x} = $codon;
    
    if (wantarray) {
	return ($orf_loc, $codon, $failed);
    }
    else {
	return  $orf_loc;
    }
}


sub kmer_counts {
    my ($self, $kmer_lens, $seqs ) = @_ ;
    
    $kmer_lens = [ sort {$b <=> $a} eval($kmer_lens) ];
    my $max_kmer_len = $kmer_lens->[0];
    
    my $table = {};
    foreach my $kmer_len ( @$kmer_lens )  {
	my $counts = $table->{$kmer_len} = {};
	
	#...initialize subtable 'totals' counters:  [ grand, frame1, frame2, frame3 ] 
	$counts->{0} = [ 0, 0, 0, 0 ];	
	
	foreach my $kmer ( &_generate_kmers($kmer_len) ) {
	    $counts->{$kmer} = [0,0,0,0];
	}
    }
    
    foreach my $seq ( @$seqs ) {
	$seq = lc( $seq );
	for ( my $i = 0, my $frame = 1;  
	      ( $i < length($seq) );
	      ++$i, $frame = (($frame % 3)+1) )
	{
	    foreach my $kmer_len ( @$kmer_lens )  {
		my $kmer = substr( $seq, $i, $kmer_len );
		next if ($kmer_len > length($kmer));   #...skip too-short entries at end of seq
		
		my $counts = $table->{$kmer_len};
		my $totals = $counts->{"0"};
		
		++ $totals->[    0   ];
		++ $totals->[ $frame ];
		
		my @kmers = &_expand_ambigs( $kmer );
#		print STDERR "Expanded $kmer to ", (scalar @kmers), " kmers\n" if ($ENV{VERBOSE} && (@kmers > 1));
		my $frac  = 1 / (scalar @kmers);
		
		foreach my $kmer ( @kmers )  {
		    my $count = $counts->{$kmer};
		    $count->[    0   ] += $frac;
		    $count->[ $frame ] += $frac;
		}
	    }
	}
    }
#   print STDERR "\n\n" if $ENV{VERBOSE};
    
    return $table;
}

sub _generate_kmers {
    my ($k) = @_;
    
    if ($k == 0)  {
	return ("");
    }
    else {
	my @kmers = ();
	foreach my $kmer ( &_generate_kmers($k-1) ) {
	    foreach my $base (qw(a c g t)) {
		push( @kmers, $base.$kmer);
	    }
	}
	return @kmers;
    }
}

sub _expand_ambigs {
    my (@stack) = @_;
    print STDERR "Expanding ", join(", ", @stack), "\n"
	if ($ENV{VERBOSE} && (@stack > 1));
    
    my @out;
    while (@stack > 0) {
	# m = (a|c)
	if ($stack[0] =~ m/^([^m]*)m(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ( "$1a$2", "$1c$2") );
	}
	
	# r = (a|g)
	if ($stack[0] =~ m/^([^r]*)r(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1a$2", "$1g$2") );
	}
	
	# w = (a|t)
	if ($stack[0] =~ m/^([^w]*)w(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1a$2", "$1t$2") );
	}
	
	# s = (c|g)
	if ($stack[0] =~ m/^([^s]*)s(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1c$2", "$1g$2") );
	}
	
	# y = (c|t)
	if ($stack[0] =~ m/^([^y]*)y(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1c$2", "$1t$2") );
	}
	
	# k = (g|t)
	if ($stack[0] =~ m/^([^k]*)k(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1g$2", "$1t$2") );
	}
	
	# v = (a|c|g)
	if ($stack[0] =~ m/^([^v]*)v(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1a$2", "$1c$2", "$1g$2") );
	}
	
	# h = (a|c|t)
	if ($stack[0] =~ m/^([^h]*)h(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1a$2", "$1c$2", "$1t$2") );
	}
	
	# d = (a|g|t)
	if ($stack[0] =~ m/^([^d]*)d(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1a$2", "$1g$2", "$1t$2") );
	}
	
	# b = (c|g|t)
	if ($stack[0] =~ m/^([^b]*)b(.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1c$2", "$1g$2", "$1t$2") );
	}
	
	# (n|x) = (a|c|g|t)
	if ($stack[0] =~ m/^([^xn]*)[xn](.*)$/) {
	    shift( @stack );
	    unshift( @stack, ("$1a$2", "$1c$2", "$1g$2", "$1t$2") );
	}
	
	while ( (@stack > 0) && ($stack[0] !~ m/[mrwsykvhdbxn]/)) {
	    push( @out, shift(@stack) );
	}
	
	last if (@stack == 0);
    }
    
    return @out;
}

sub print_kmer_table
{
    my ($self, $table) = @_;
    
    my @kmer_lens = ( sort {$a <=> $b} keys %$table );
    
    my $s = (@kmer_lens > 1) ? qq(s) : qq();
    print STDOUT "# kmer tables for length$s: ", join(qq(,), @kmer_lens), "\n";
    foreach my $kmer_len (@kmer_lens) {
	my $counts = $table->{$kmer_len};
	foreach my $kmer (sort keys %$counts) {
	    my $entry = $counts->{$kmer};
	    print STDOUT "$kmer\t", join("\t", @$entry), "\n";
	}
	print STDOUT "//\n";
    }
}
1;



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
package NewGenome::ORF;
#-----------------------------------------------------------------------

use ToCall;
use Data::Dumper;
use Carp qw(:DEFAULT cluck);

sub new {
    my($class, $newG, $fid) = @_;

    return bless [$newG, $fid], $class;
}

sub seq {
    my ($self) = @_;

#   confess Dumper($self);
    my ($newG, $fid) = @$self;
    
    my $seq;
    if (defined($seq = $newG->get_feature_sequence($fid)))
    {
	return $seq; 
    } else {
	cluck "!!! Could not get sequence for $fid";
	return undef;
    }
}

sub orf_seq {
    my ($self) = @_;

#   confess Dumper($self);
    my ($newG, $fid) = @$self;
    
    if ($newG->get_feature_type($fid) ne 'orf') {
	cluck "!!! Not an ORF: $fid";
	return undef;
    }
    
    my $seq;
    if (defined($seq = $newG->get_orf_sequence($fid)))
    {
	return $seq; 
    } else {
	cluck "!!! Could not get ORF sequence for $fid";
	return undef;
    }
}

sub get_fid
{
    my ($self) = @_;
    
    return $self->[1];
}

sub set_fid
{
    my ($self, $fid) = @_;
    
    return ($self->[1] = $fid);
}

sub call_start
{
    my ($self, $sims) = @_;
    my ($newG, $orf_id) = @$self;

    my $loc = $newG->call_start($orf_id, $sims);
    
    if (defined($loc)) {
	return $loc;
    }
    else {
	cluck "Could not call START for $orf_id", &Dumper($self, $sims);
	return undef;
    }
}

sub promote_to_peg {
    my ($self, $sims, $func, $annotation) = @_;
    my ($newG, $orf_id) = @$self;
    my ($loc, $new_peg);
    my $trouble = 0;
    
    if (defined($sims)) {
	$loc = $newG->call_start($orf_id, $sims);
    } else {
	$loc = $newG->get_feature_loc($orf_id);
    }

    if (defined $loc) {
	print STDERR "Attempting to promote $orf_id to a PEG\n" if $ENV{VERBOSE};
    }
    else {
	$trouble = 1;
	print STDERR ("Could not re-call START for $orf_id --- deleting ORF",
		      &flatten_dumper( $newG->get_feature_loc($orf_id) ),
		      qq(\n)
		      );
    }
    
    unless ($newG->delete_feature($orf_id)) 
    {
	confess "Could not delete ORF $orf_id:\n"
	    , Dumper($newG->get_feature_object($orf_id));
    }
    
    if ($trouble) {
	return undef;
    }
    
    unless ($new_peg = $newG->add_feature( -type => 'peg', -loc => $loc, -func => $func, -annot => $annotation ) )
    {
	confess "Could not promote $orf_id to a PEG:\n"
	    , Dumper($newG, $new_peg, $self);
    }
    
    unless ($self->set_fid($new_peg))
    {
	confess "Could not reset $orf_id to $new_peg";
    }
    
    print STDERR "Promoted $orf_id to $new_peg\n" if $ENV{VERBOSE};
    
    return $new_peg;
}

1;
