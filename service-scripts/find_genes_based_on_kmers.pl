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
use SeedEnv;
use gjoseqlib;

use FIG;
my $fig = new FIG;

use NewGenome;
use ToCall;

$0 =~ m/([^\/]+)$/o;
my $self  = $1;
my $usage = "usage: find_genes_based_on_kmers  [-kmerDataset=ReleaseID] [-determineFamily] To_Call_Dir FoundFamilies [old]";

my $determine_family = 0;
my $trouble = 0;
my @kmerDataset = ();
while (@ARGV) {
    if ($ARGV[0] !~ m/^-/o) {
	last;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}h(elp)?/o) {
	print STDERR "\n   $usage\n\n";
	exit (0);
    }
    elsif ($ARGV[0] =~ m/^-{1,2}kmerDataset=(\S+)/o) {
	@kmerDataset = (q(-kmerDataset), $1);
	print STDERR qq(-kmerDataset= $1\n) if $ENV{VERBOSE};
    }
    elsif ($ARGV[0] =~ m/^-{1,2}determineFamily/o) {
	$determine_family = 1;
    }
    else {
	$trouble = 1;
	warn "Unrecognized argument: $ARGV[0]\n";
    }
    shift @ARGV;
}
die "\n   $usage\n\n" if $trouble;


my ($i, $to_call_dir, $N, $foundF);

(
 ($to_call_dir = shift @ARGV) &&
 ($foundF      = shift @ARGV) 
)
    || die $usage;


open(my $found_fh,">>$foundF")
    || die "could not append-open $foundF";

my $called_by_file = "$to_call_dir/called_by";
open(my $called_by_fh, ">>$called_by_file")
    || die "Could not append-open $called_by_file";

my $to_call;
my $keep_original_calls = 0;
if ((@ARGV > 0) && ($ARGV[0] =~ /^old/i)) {
    $keep_original_calls = 1;
    $to_call = ToCall->new($to_call_dir);
}
else {
    $to_call = NewGenome->new($to_call_dir);
}

if (not $to_call->get_fids_for_type('orf')) {
    print STDERR "calling ORFs\n"    if $ENV{VERBOSE};
    $to_call->possible_orfs();
    my $num_called = (@_ = $to_call->get_fids_for_type('orf'));
    print STDERR "Found $num_called\n" if $ENV{VERBOSE};
    $to_call->export_features("orf");
}

use ANNOserver;
my $annoO = ANNOserver->new();

my $orfs_file = $keep_original_calls 
    ? qq($to_call_dir/Features/peg/fasta)
    : qq($to_call_dir/Features/orf/fasta);

my @seq_triples = &gjoseqlib::read_fasta($orfs_file);
my %seqH = map { $_->[0] => $_->[2] } @seq_triples;
print STDERR (q(Read ), (scalar keys %seqH), qq( sequences from \'$orfs_file\'\n)) if $ENV{VERBOSE};

my $annoO_handle = $annoO->assign_function_to_prot(-input => \@seq_triples,
						   -kmer => 8,
						   -assignToAll => 0,
						   -seqHitThreshold => 2,
						   -scoreThreshold =>  3,
						   @kmerDataset,
						   -determineFamily => $determine_family,
						   );
print STDERR Dumper($annoO_handle) if (defined($ENV{VERBOSE}) && ($ENV{VERBOSE} > 1));

my $found_kmer_hit = 0;
while (my $result = $annoO_handle->get_next()) {
    my($orf_id, $function, $otu, $score, $nonoverlap_hits, $overlap_hits, undef, $fam_id) = @$result;

    $fam_id = '' unless defined($fam_id);
    print STDERR (join(qq(\t), (q(ORF=)   . ($orf_id || q(undef)) . q(,),
				q(OTU=)   . ($otu    || q(undef)) . q(,),
				q(Score=) . ($score  || q(undef)) . q(,),
				q(NOLH=)  . ($nonoverlap_hits || q(undef)) . q(,),
				q(OLH=)   . ($overlap_hits    || q(undef)) . q(,),
				q(func=)  . ($function || q(undef)) . q(,),
				q(family=)  . ($fam_id || q(undef)) . q(,),
				)
		       ),
		  qq(\n),
		  ) if $ENV{VERBOSE};
    
    next if (! $function);

    my $annot = [ qq(RAST),
		  qq($function\nCalled by find_genes_based_on_kmers.)
		];

    my $orf;
    if ($keep_original_calls) {
	$orf = &ToCall::PEG::new(   'ToCall::PEG',    $to_call, $orf_id, $seqH{$orf_id});
    }
    else {
	$orf = &NewGenome::ORF::new('NewGenome::ORF', $to_call, $orf_id);
    }
    
    my $fid = $orf->promote_to_peg(undef, $function, $annot);
    if ($fid) {
	if (defined($function) && defined($score) && defined($nonoverlap_hits) && defined($overlap_hits)) {
	    $found_kmer_hit = 1;
	    print $found_fh join("\t",($fid,
				       $fam_id,
				       $function,
				       $score, 
				       $nonoverlap_hits, 
				       $overlap_hits)),"\n";

	    my $with_fam = defined($fam_id) ? " using family $fam_id" : "";
	    print $called_by_fh "$fid\tfind_genes_based_on_kmers$with_fam\n";
	}
	else {
	    $function        ||= q(undef);
	    $score           ||= q(undef);
	    $nonoverlap_hits ||= q(undef);
	    $overlap_hits    ||= q(undef);
	    
	    warn qq(Problem promoting fid=$fid, function=$function, score=$score, nonoverlap_hits=$nonoverlap_hits, overlap_hits=$overlap_hits);
	}
    }
    else {
	print STDERR &Dumper(["failed to promote ORF", $result]);
	die "aborted";
    }
}
close($found_fh);
close($called_by_fh);


if ($found_kmer_hit) {
    $to_call->export_features();
    $to_call->recall_orfs();
    $to_call->export_features();
}
else {
    print STDERR (q(No ORFS had Kmer hits), qq(\n)) if $ENV{VERBOSE};
}

exit(0);

