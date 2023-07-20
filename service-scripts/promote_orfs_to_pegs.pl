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

use FIG;
my $fig = FIG->new();

use NewGenome;
use ToCall;

$0 =~ m/([^\/]+)$/o;
my $self  = $1;
my $usage = "usage: promote_orfs_to_pegs To_Call_Dir FoundFamiliesFile";

if (@ARGV && ($ARGV[0] =~ m/-h(elp)?/)) {
    print STDERR "\n   $usage\n\n";
    exit (0);
}

my ($to_call_dir, $found_file);

(
 ($to_call_dir = shift @ARGV)
&&
 ($found_file  = shift @ARGV)
)
    || die "\n   $usage\n\n";

$to_call_dir =~ s/\/$//o;

my $to_call;
$to_call = NewGenome->new($to_call_dir, "all");


my @neighbors = ();
my $neighbors_file;
if ((-s ($neighbors_file = "$to_call_dir/closest.genomes")) ||
    (-s ($neighbors_file = "$to_call_dir/neighbors"))
    ) {
    @neighbors = map { m/^(\d+\.\d+)/o ? ($1) : () } &FIG::file_read($neighbors_file);
}
else {
    warn qq(WARNING: $self could not read either nearest neighbors file\n);
}

open(CALLED_BY, ">>$to_call_dir/called_by")
    || die "could not open $to_call_dir/called_by";

#...Build file of "nearby" PEGs
if (@neighbors == 0) {
    warn qq($self: No nearby genomes found --- Skipping promotion based on sims\n);
}
else {
    my $tmp_close = "$FIG_Config::temp/tmp_close_$$.fasta";
    system("/bin/rm -f $tmp_close*");
    
    foreach my $org (@neighbors) {
	print STDERR "Appending $org to $tmp_close\n" if $ENV{VERBOSE};
	system("cat $FIG_Config::organisms/$org/Features/peg/fasta >> $tmp_close");
    }
    
    if (!-s $tmp_close) {
	warn qq($self: Something is wrong --- Could not find any PEG sequences for nearby genomes);
    }
    else {
	&FIG::run("formatdb -i$tmp_close -pT");
	
	my @promoted_fids;
	my $tmp_sims = "$FIG_Config::temp/tmp_sims.$$";
	open(TMP_SIMS, ">$tmp_sims")
	    || die "Could not write-open $tmp_sims";
	foreach my $orf_id ($to_call->get_fids_for_type('orf')) {
	    my $sims = &blast_against($to_call->get_feature_sequence($orf_id), $tmp_close);
	    
	    if (@$sims) {
		my $num_sims = (scalar @$sims);
		print STDERR "Promoting $orf_id based on $num_sims sims\n" if $ENV{VERBOSE};
		
		my $orf = &NewGenome::ORF::new('NewGenome::ORF', $to_call, $orf_id);
		my $annot  = [ qq(RAST), 
			       qq(Called by "$self" based on $num_sims sims.)
			       ];
		my $fid = $orf->promote_to_peg($sims, undef, $annot);
		if ($fid) {
		    push @promoted_fids, $fid;
		    @$sims = map { $_->[0] = $fid; $_ } @$sims;
		    print TMP_SIMS map { join("\t", @$_) . qq(\n) } @$sims;
		    
		    print CALLED_BY "$fid\tpromote_remaining_orfs (with sims)\n";
		    
		    print STDERR "Succeeded:\t$orf_id --> $fid\n";
		}
		else {
		    print STDERR "Could not promote ORF $orf_id to a PEG\n";
		}
	    }
	    else {
		print STDERR "No sims for $orf_id\n" if $ENV{VERBOSE};
	    }
	}
	
	if (not $ENV{DEBUG}) {
	    #...Clean up...
	    close(TMP_SIMS)    || die "Could not close $tmp_sims";
	    unlink($tmp_sims)  || die "Could not remove $tmp_sims";
	    unlink($tmp_close) || die "Could not remove $tmp_close";
	}
    }
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Disable the old auto assignment of the fids we just called.
#=======================================================================
#     if (0)
#     {
# 	my $tmp_seqs = "$FIG_Config::temp/tmp_seqs.$$";
# 	open(TMP_SEQS, ">$tmp_seqs")
# 	    || die "Could not write-open $tmp_seqs";
# 	print TMP_SEQS map { join("\t", ($_, $to_call->get_feature_sequence($_))) . qq(\n) } @promoted_fids;
# 	close(TMP_SEQS) || die "Could not close $tmp_seqs";
# 	my @auto_assigns = `cat $tmp_seqs | auto_assign sims=$tmp_sims`;
#	
# 	open(FOUND, ">>$found_file")
# 	    || die "Could not append-open FoundFamiliesFile $found_file";
# 	foreach my $entry (@auto_assigns) {
# 	    if ($entry =~ m/^(\S+)\t(.*)$/o) {
# 		if ($to_call->set_function($1, $2)) {
# 		    print FOUND "$1\tCLOSE_SIMS\t$2\n";
# 		}
# 		else {
# 		    die "Could not set function of $1 to $2";
# 		}
# 	    }
# 	    else {
# 		die "Could not parse auto-assignment: $entry";
# 	    }
# 	}
# 	close(FOUND) || die "Could not close $found_file";
# 	unlink($tmp_seqs)  || die "Could not remove $tmp_seqs";
#     }
#-----------------------------------------------------------------------

}



#...Promote any remaining unpromoted ORFs...
$to_call->promote_remaining_orfs(\*CALLED_BY);

close(CALLED_BY);

#...NOTE: export_features also writes assigned_functions
$to_call->export_features;


if (! -s "$to_call_dir/Features/orf/tbl") {
    # Hrm, weird NFS effects here. There was a failure of this even though the directory
    # was indeed empty.
    if (system("/bin/rm -fRv $to_call_dir/Features/orf")) {
	warn "First remove did not work; sleeping and trying again";
	sleep(30);
	system("/bin/rm -fRv $to_call_dir/Features/orf");
    }
}
else {
    die "Something is wrong --- $to_call_dir/Features/orf/tbl is non-empty";
}
exit(0);



sub blast_against {
    my ($seq, $db) = @_;
    my $seq_len = length($seq);
    
    my $tmp_seq = "$FIG_Config::temp/tmp_seq.$$";
    open( TMP, ">$tmp_seq" ) || die "Could not write-open $tmp_seq";
    print TMP  ">query\n$seq\n";
    close(TMP) || die "Could not close $tmp_seq";
    
    my $sims = [];
    @$sims = map { chomp $_;
		   my @x = split(/\t/, $_);
		   push @x, ($seq_len, $fig->translation_length($x[1]));
		   bless( [@x], "Sim" )
		   } `blastall -i $tmp_seq -d $db -p blastp -m8 -e1.0e-10`;
    
    unlink($tmp_seq) || die "Could not unlink $tmp_seq";
    return $sims;
}
