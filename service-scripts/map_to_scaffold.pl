# -*- perl -*-
########################################################################
# Copyright (c) 2003-2007 University of Chicago and Fellowship
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


=pod

=head1 map_to_scaffold  scaffold.map OrgDir

=over 5

=item Usage:     map_to_scaffold  scaffold.map OrgDir

=item Function:  Maps feature tbl files from "contig coordinates" back to "scaffold coordinates,"
using the 'scaffold.map' file output by `reformat_contigs -split`.

The tbl files are mapped "in place" for each feature subdirectory of "OrgDir";
each original tbl file "OrgDir/Features/type/tbl" will be backed up to 
"OrgDir/Features/type/tbl~".

=back

=cut

$0 =~ m/([^\/]+)$/;
my $self  = $1;
my $usage = "$self  scaffold_map OrgDir";

if (@ARGV && ($ARGV[0] =~ m/^-{1,2}h(elp)?$/)) {
    die "\n   usage:  $usage\n\n";
}

my ($scaffold_map, $org_dir);
(  ($scaffold_map = shift @ARGV) && (-s $scaffold_map)
&& ($org_dir      = shift @ARGV) && (-d $org_dir)
)  || die "\nInvalid args.\n\n   usage:  $usage\n\n";



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Load scaffold map ...
#-----------------------------------------------------------------------
open(SCAFFOLD_MAP, "<$scaffold_map") or die "could not open $scaffold_map: $!";

my $old_eof;
($old_eof, $/) = ($/, "\n//\n");

my $record;
my (%is_scaffold, %offset);
while (defined($record = <SCAFFOLD_MAP>))
{
    chomp $record;
    my @lines = split /\n/, $record;
    
    my $scaffold_id = shift @lines;
    $is_scaffold{$scaffold_id} = 1;
    
    if (@lines) {
	foreach my $line (@lines) {
	    my ($contig, $offset) = split /\t/, $line;
	    $offset{$contig}   = $offset;
	}
    }
    else {
	$offset{$scaffold_id} = 0;
    }
}
close(SCAFFOLD_MAP) or die "could not close $scaffold_map: $!";
$/ = $old_eof;


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Adjust feature coordinates ...
#-----------------------------------------------------------------------
my @features;
opendir(FEATURES, "$org_dir/Features")
    || die "Could not opendir $org_dir/Features: $!";
(@features = grep { !/^\./ } readdir(FEATURES))
    || die "Could not read features from $org_dir/Features";
closedir(FEATURES)
    || die "Could not closedir $org_dir/Features: $!";
print STDERR "Features are: \'", join("\', \'", @features), "\'\n" if $ENV{VERBOSE};

foreach my $feature (@features) {
    my $feature_dir = "$org_dir/Features/$feature";
    print STDERR "Mapping features in $feature_dir\n" if $ENV{VERBOSE};
    
    my $tbl_file    = "$feature_dir/tbl";
    rename($tbl_file, "$tbl_file~") or die "could not rename $tbl_file to $tbl_file~: $!";
    
    open(TBL_IN,  "<$tbl_file~") or die "could not open $tbl_file~: $!";
    open(TBL_OUT, ">$tbl_file")  or die "could not open $tbl_file: $!";
    
    my $line;
    while (defined($line = <TBL_IN>)) {
	chomp $line;
	my ($fid, $locus, @rest) = split /\t/, $line;
	
	my @exons = split /,/, $locus;
	my @new_exons;
	foreach my $exon (@exons) {
	    my ($contig, $beg, $end) = $fig->boundaries_of($exon);

	    unless($is_scaffold{$contig}) {
		if (exists($offset{$contig})) {
		    if (defined($offset{$contig})) {
			if ($contig =~ m/^(\S+)\.\d+$/) {
			    my $scaffold_id = $1;
			    $beg    += $offset{$contig};
			    $end    += $offset{$contig};
			    $exon    = "$scaffold_id\_$beg\_$end";
			}
			else {
			    print STDERR " could not handle $line\n";
			}
		    }
		}
		else {
		    print STDERR "Skipping undefined contig ID $contig in $line\n";
		    next;
		}
	    }
	    push(@new_exons, $exon);
	}
	$locus = join(",",  @new_exons);
	
	if (@rest) {
	    print TBL_OUT join("\t", ($fid, $locus, @rest)), "\n";
	}
	else {
	    print TBL_OUT join("\t", ($fid, $locus)), "\t\n";
	}
    }
    close(TBL_OUT) or die "could not close $tbl_file: $!";
    close(TBL_IN)  or die "could not close $tbl_file~: $!";
}
