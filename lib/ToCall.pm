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

package ToCall;

# This package supports the recall of existing genomes.  The output of 
# find_neighbors and find_genes_based_on_neighbors is a "found" file
# listing the families and genes that have been found.  The original
# directory is not altered (in this package; in NewGenomes.pm side-effects
# alter the Feature subdirectories.
# 
use strict;
use FIG;
use FIGV;

use Carp;
use Data::Dumper;


sub new {
    my ($class, $GenomeDir) = @_;
    
    my $to_call = {};
    
    my $fig = FIGV->new($GenomeDir);
    $to_call->{_fig} = $fig;
    
    $to_call->{_dir} = $GenomeDir;
    
    my $taxon_ID;
    if ($GenomeDir =~ m/(\d+\.\d+)$/) {
	$to_call->{_taxon_ID} = $1;
    }
    else {
	confess qq(GenomeDir does not end in a valid Taxon-ID);
    }
    
    $to_call->{_found} = {};
    if (-s "$GenomeDir/found") {
	my @entries = $fig->file_read("$GenomeDir/found");
	foreach my $entry (@entries) {
	    chomp $entry;
	    if ($entry =~ m/^(fig\|\d+\.\d+\.peg\.\d+)\t(FIG\d+)/) {
		$to_call->{_found}->{$1} = $2;
	    }
	    elsif ($entry =~ m/^(fig\|\d+\.\d+\.peg\.\d+)\t\t\S+/) {
		$to_call->{_found}->{$1} = q(FIG00000000);      #...Kmers could not assign a FIGfam; use Dummy ID as placeholder.
	    }
	    else {
		confess qq(Malformed entry in \'$GenomeDir/found\': $entry);
	    } 
	}
    }
    
    if (! -s "$GenomeDir/Features/peg/fasta") {
	confess "Zero-size or non-existent FASTA file: $GenomeDir/Features/peg/fasta";
    }
    
    if ((! -s "$GenomeDir/Features/peg/fasta.psq") || 
	((-M  "$GenomeDir/Features/peg/fasta") < (-M "$GenomeDir/Features/peg/fasta.psq"))
	) {
	system "formatdb -i $GenomeDir/Features/peg/fasta -p T";
    }
    
    bless $to_call,$class;
    return $to_call;
}

sub get_feature_object {
    my($self,$peg) = @_;

    my $fig = $self->{_fig};
    my $seq = $fig->get_translation($peg);
    return ToCall::PEG->new($self, $peg, $seq);
}

sub get_fids_for_type {
    my($self, $type) = @_;
    if ($type eq qq(all)) { $type = qq(); }
    
    my $fig       = $self->{_fig};
    my $GenomeDir = $self->{_dir};
    my $taxon_ID  = $self->{_taxon_ID};
    
    my @features = ();
    if ((not $type) || ($type eq qq(peg)) || ($type eq qq(rna))) {
	@features = $fig->all_features($taxon_ID, $type);
    }
    elsif ($type eq qq(orf)) {
	@features = grep { not $self->{_found}->{$_} 
		       } $fig->all_features($taxon_ID,"peg");
    }
    else {
	confess qq(Cannot handle feature-type \'$type\');
    }
    
    return @features;
}

sub get_feature_length {
    my($self,$peg) = @_;
    
    $self->load_lens_and_seqs;
    my $lenH = $self->{peg_lengths};
    return $lenH->{$peg};
}

sub load_lens_and_seqs {
    my($self) = @_;
    
    my $lenH = $self->{peg_lengths};
    if (! $lenH)
    {
	$lenH = {};
	my $seqH = {};
	my $fig = $self->{_fig};
	my $dir = $self->{_dir};
	open(SEQS,"<$dir/Features/peg/fasta") || die "could not open $dir/Features/peg/fasta";
	my($fid,$seqP);
	while (($fid,$seqP) = $fig->read_fasta_record(\*SEQS))
	{
	    $lenH->{$fid} = length($$seqP) * 3;
	    $seqH->{$fid} = $$seqP;
	}
	close(SEQS);
	$self->{peg_lengths} = $lenH;
	$self->{peg_seqs} = $seqH;
    }
}

sub get_feature_sequence {
    my($self,$peg) = @_;
    
    $self->load_lens_and_seqs;
    my $seqH = $self->{peg_seqs};
    return $seqH->{$peg};
}

sub candidate_orfs {
    my($self,%args) = @_;
    
    my $fig = $self->{_fig};
    my $query_seq = $args{-seq};
    
    if ((not defined($query_seq)) || (length($query_seq) == 0)) {
	print STDERR "Undefined or zero-length query-sequence\n";
	return ();
    }
    
    my $query_file = "$FIG_Config::temp/tmp_query.$$.fasta";
    open(TMP, ">$query_file") || confess "Could not write-open $query_file";
    &FIG::display_id_and_seq('query_seq', \$query_seq, \*TMP); 
    close(TMP)
	|| confess "Could not close query-file $query_file --- args:\n", Dumper(\%args);
    (-s $query_file) 
	|| confess "Could not write query sequence to $query_file --- args:\n", Dumper(\%args);

    my $GenomeDir = $self->{_dir};
    my $db = "$GenomeDir/Features/peg/fasta";
    
    my @sims = `$FIG_Config::ext_bin/blastall -i $query_file -d $db -p blastp -m8 -FF -e 1.0e-10`;
    unlink($query_file);
    
    my @hits = ();
    my($sim,%seen);
    foreach $sim (@sims)
    {
	if (($sim =~ /^\S+\t(\S+)/) && (not $seen{$1}) && (not $self->{_found}->{$1}))
	{
	    my $peg = $1;
	    my $seq = $fig->get_translation($peg);
	    push(@hits,ToCall::PEG->new($self, $peg, $seq));
	    $seen{$peg} = 1;
	}
    }
    print STDERR "No hits for query $query_seq\n" if ($ENV{VERBOSE} && (@hits == 0));
    
    return @hits;
}

sub possible_orfs {
}

sub export_features {
    my ($self) = @_;
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Filter out dupliucated 'called_BY' entries...
#-----------------------------------------------------------------------
    my %called_by;
    my $called_by_file = qq($self->{_dir}/called_by);
    if (-s $called_by_file) {
	map { chomp; 
	      m/^(\S+)\t(.*)$/ ? ($called_by{$1} = $2) : ()
	      } &FIG::file_read($called_by_file);
    }
    
    open(TMP, qq(>$called_by_file))
	|| confess qq(Could not write-open calling-method file \'$called_by_file\');
    print TMP map { ($_, qq(\t), $called_by{$_}, qq(\n))
		    } sort { &FIG::by_fig_id($a, $b)
			     } (keys %called_by);
    close(TMP);
}

sub recall_orfs {
}

sub make_annotation {
    my ($self, $fid, $annot) = @_;
    
    if (defined($annot)) {
	if (ref($annot) eq 'ARRAY') {
	    my $timestamp = time();
	    my $annot_file = $self->{_dir} . qq(/annotations);
	    my $annot_user = $annot->[0];
	    my $annot_text = $annot->[1];
	    
	    open( ANNOT, ">>$annot_file")
		|| confess "Could not append-open $annot_file";
	    
	    print ANNOT "$fid\n$timestamp\n$annot_user\n$annot_text\n//\n";
	    
	    close(ANNOT)
		|| confess "Could not close $annot_file";
	}
	else {
	    confess (qq(Annotation arg is not an ARRAY-ref for feature $fid: ),
		     &FIG::flatten_dumper($annot, $self),
		     qq(\n)
		     );
	}
    }
}

sub append_to_file {
    my ($self, $filename, $linesP) = @_;
    
    print STDERR (qq(Appending to file \'$filename\': ),
		  &FIG::flatten_dumper($linesP),
		  qq(\n)
		  );
    
    open( TMP, qq(>>$filename))
	|| confess qq(Could not append-open file \'$filename\');
    print TMP join(qq(), @$linesP);
    close(TMP);
    
    return 1;
}

1;



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
package ToCall::PEG;
#-----------------------------------------------------------------------
use strict;
use Carp;
use Data::Dumper;

use constant PEG_PARENT => 0;
use constant PEG_FID    => 1;
use constant PEG_SEQ    => 2;

sub new {
    my ($class, $tocall, $peg, $seq) = @_;
    
    return bless [$tocall, $peg, $seq], $class;
}

sub seq {
    my($self) = @_;
    
    return $self->[PEG_SEQ];
}

sub get_fid {
    my($self) = @_;
    
    return $self->[PEG_FID];
}

sub call_start {
    my($self) = @_;
}

sub promote_to_peg {
    my ($self, $sims, $func, $annot) = @_;
    
    my $fid     = $self->[PEG_FID];
    my $to_call = $self->[PEG_PARENT];
    
#   die Dumper($self, $sims, $func, $annot);
    
    if (defined($func)) {
	$to_call->append_to_file($to_call->{_dir}.q(/assigned_functions), [qq($fid\t$func\n)]);
    }
    
    if (defined($annot)) {
	$to_call->make_annotation($fid, $annot);
    }
    
    if (not defined($to_call->{_found}->{$fid})) {
	#...Set to something that evaluates to TRUE; handle correctly by passing in FIGfam later...
	$to_call->{_found}->{$fid} = 1;
    }
    
    return $fid;
}

1;
