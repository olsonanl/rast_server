# -*- perl -*-
#
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
#

use strict;
use GenomeMeta;
use FIG;
use FIG_Config;
use strict;
use File::Basename;
use Carp 'croak';

@ARGV == 2 or die "Usage: $0 job-dir request\n";

my $jobdir = shift;
my $request = shift;

#
# Valid requests.
#
my @valid_requests = qw(remove_embedded_pegs remove_rna_overlaps);
my %valid_requests = map { $_ => 1 } @valid_requests;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta_file = "$jobdir/meta.xml";
my $meta = new GenomeMeta($genome, $meta_file);

my $genome_dir = "$jobdir/rp/$genome";

-d $genome_dir or &fatal("genome directory $genome_dir not found");

$meta->set_metadata("status.correction", "in_progress");

#
# Determine request from the req argument.
# Comma sep list, possibly with spaces.
#

my @reqs = split(/,\s*/, $request);

#
# Ensure we have valid requests.
#
for my $req (@reqs)
{
    if (!$valid_requests{$req})
    {
	&fatal("Invalid correction \"$req\" requested");
    }
    my $cmd = "$FIG_Config::bin/$req";
    if (! -x $cmd)
    {
	&fatal("Correction command $cmd for request $req does not exist");
    }
}

#
# Process requests.
#

for my $req (@reqs)
{
    my $cmd = "$FIG_Config::bin/$req -meta=$meta_file $genome_dir";

    my $err = "$jobdir/rp.errors/$req.stderr";
    $meta->add_log_entry($0, ['start', $cmd]);
    my $rc = system("$cmd >$err 2>&1");
    $meta->add_log_entry($0, ["finish rc=$rc", $cmd]);
    if ($rc != 0)
    {
	&fatal("Correction $cmd failed with rc=$rc");
    }
    
}

#
# And rerun the quality check.
#

my $cmd = "$FIG_Config::bin/assess_gene_call_quality --no_fatal --meta=$meta_file $genome_dir > $genome_dir/quality.report 2>&1";

$meta->add_log_entry($0, ['start', $cmd]);
my $rc = system($cmd);
$meta->add_log_entry($0, ["finish rc=$rc", $cmd]);
if ($rc != 0)
{
    &fatal("Post-correction assessment $cmd failed with rc=$rc");
}

$meta->set_metadata("status.correction", "complete");
$meta->set_metadata("correction.running", "no");

sub fatal
{
    my($msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status.correction", "error");
    $meta->set_metadata("correction.running", "no");

    croak "$0: $msg";
}
    
