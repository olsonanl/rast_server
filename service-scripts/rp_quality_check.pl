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
use Job48;
use Carp 'croak';

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $jobid = basename($jobdir);

my $job = new Job48($jobid);

my $meta_file = "$jobdir/meta.xml";
my $meta = new GenomeMeta($genome, $meta_file);

my $newD = "$jobdir/rp/$genome";

-d $newD or &fatal("genome directory $newD not found");

$meta->set_metadata("status.qc", "in_progress");

# The following was in Bob's version of this; he's not sure why. &run not defined here.
# &run("verify_genome_directory $tmpD > $errD/verify_genome_directory.report 2>&1");

my $cmd = "$FIG_Config::bin/assess_gene_call_quality --meta=$meta_file $newD > $newD/quality.report 2>&1";
$meta->add_log_entry($0, $cmd);
my $rc = system($cmd);

$rc == 0 or &fatal("system $cmd failed with rc=$rc");

#
# Based on the results of the quality check, set up for user intervention.
#

my @corrections;

if ($meta->get_metadata('qc.RNA_overlaps') and
    $meta->get_metadata('qc.RNA_overlaps')->[1])
{
    push(@corrections, 'remove_rna_overlaps');
}      
# remove_embedded_pegs
if ($meta->get_metadata('qc.Embedded') and
    $meta->get_metadata('qc.Embedded')->[1])
{
    push(@corrections, 'remove_embedded_pegs')
}

#
# If corrections are necessary, set up the status on the correction phase.
#


if (@corrections)
{
    #
    # If we are automatically accepting corrections, set up for them to be executed.
    #

    $meta->set_metadata("correction.possible", [@corrections]);

    my $automated_correction = $meta->get_metadata("correction.automatic");
    if ($automated_correction)
    {
	$meta->set_metadata('correction.request', \@corrections);
	$meta->set_metadata('correction.acceptedby',
				 "automatic for " . $job->user());
	$meta->set_metadata('correction.timestamp', time());
	$meta->set_metadata("status.correction", 'not_started');
    }
    else
    {
	$meta->set_metadata("status.correction", 'requires_intervention');

	#
	# Construct & send email.
	#
	
	my $subject = "RAST annotation server job needs attention";
	
	my $gname = $job->genome_name;
	my $entry = $FIG_Config::fortyeight_home;
	$entry = "http://www.nmpdr.org/anno-server/" if $entry eq '';
	my $msg = <<END;
The annotation job that you submitted for $gname needs user input before it can proceed further.
You may query its status at $entry as job number $jobid
END
        $job->send_email_to_owner("qc.email_notification_sent", $subject, $msg);
    }
}
else
{
    $meta->set_metadata("status.correction", "complete");
}

$meta->set_metadata("status.qc", "complete");
$meta->set_metadata("qc.running", "no");

sub fatal
{
    my($msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status.qc", "error");
    $meta->set_metadata("qc.running", "no");

    croak "$0: $msg";
}
    
