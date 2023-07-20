# -*- perl -*-
#########################################################################
# Copyright (c) 2003-2008 University of Chicago and Fellowship
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
#########################################################################

#
# Perform auto-assignment on unassigned pegs.
#

use strict;

use FIG;
use FIG_Config;
use SeedUtils;

use Job48;
use GenomeMeta;

use File::Basename;
use Carp qw(croak confess);

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";
my $genome_dir = "$jobdir/rp/$genome";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

my %done;

my $tbl = "$jobdir/rp/$genome/Features/peg/tbl";
(-f $tbl) || die "$0: Cannot find tbl file $tbl\n";
open(TBL, "<$tbl") or &fatal("Cannot open tbl file $tbl: $!");

my $proposed = "$jobdir/rp/$genome/proposed_functions";
if (!open(PROP, "<$proposed")) {
    warn "could not  open proposed functions $proposed: $!";
    $meta->add_log_entry($0, "could not open proposed fucntions $proposed");
}
else {
    while (<PROP>) {
	chomp;
	my($peg, $assign) = split;
	$done{$peg} = $assign;
    }
    close(PROP);
}

my $simfile = "$jobdir/rp/$genome/expanded_similarities";
my $cmd = "$FIG_Config::bin/auto_assign -orgdir $jobdir/rp/$genome > $jobdir/rp/$genome/proposed_non_ff_functions";
print "running $cmd\n";
open(AA, "| $cmd")
    or &fatal("aa failed: $!");

my $peg_count = 0;
while (<TBL>) {
    chomp;
    my($peg, @rest) = split(/\t/);
    if (!$done{$peg}) {
	++$peg_count;
	print AA "$peg\n";
    }
}
close(TBL);

$meta->add_log_entry($0, "computing auto_assign on $peg_count pegs");

if (!close(AA)) {
    &fatal("error on close of pipe-cmd=\'$cmd\': \$?=$? \$!=$!");
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Call of `rapid_subsystem_inference` removed from `rapid_propagation`
#  to here. -- /gdp
#-----------------------------------------------------------------------
my %func_of;
foreach my $file (map { $genome_dir . q(/) . $_
			} qw(assigned_functions proposed_non_ff_functions proposed_functions)) {
    if (-s $file) {
	map { chomp; m/^(\S+)\t(.*)$/o ? ($func_of{$1} = $2) : () } &SeedUtils::file_read($file);
    }
}

open(METAB, qq(| rapid_subsystem_inference $genome_dir/Subsystems))
    || die qq(Could not pipe-open rapid_subsystem_inference);
print METAB map { $_ . qq(\t) . $func_of{$_} . qq(\n) } (sort keys %func_of);
close(METAB);



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# When auto assign is complete, we are able to submit the model computation.
#-----------------------------------------------------------------------
if ($meta->get_metadata("model_build.enabled")) {
    my $userid;
    my $link;
    eval {
	my $job = Job48->new($jobdir);
	my $uo = $job->getUserObject;
	if ($uo) {
	    $userid = $uo->_id;
	}
    };

    if (defined($userid))
    {
	$link = "http://seed-viewer.theseed.org/seedviewer.cgi?model=Seed${genome}.${userid}&page=ModelView";
#	$link = "http://rast.nmpdr.org/seedviewer.cgi?model=Seed${genome}.${userid}&page=ModelView";
    }
    else {
	$meta->add_log_entry($0, "Could not get user id");
    }
    
    
    my $user = &FIG::file_head("$jobdir/USER", 1);
    chomp $user;
    my $cmd = ("/vol/model-prod/FIGdisk/bin/ModelDriver.sh 'createmodelfile?$genome?1?$user' > $jobdir/rp.errors/create_model.stderr 2>&1");
    my $rc = system($cmd);
    if ($rc != 0) {
	$meta->add_log_entry($0, ['error creating model', $rc]);
    }
    else {
	$meta->add_log_entry($0, ['model submitted']);
	
	if (defined($link)) {
	    $meta->set_metadata("model_build.viewing_link", $link) ;
	    $meta->set_metadata("model_build.user_id", $userid) ;
	    $meta->set_metadata("model_build.model_id", "Seed{$genome}") ;
	}
    }
}


$meta->add_log_entry($0, "auto_assign completed\n");
$meta->set_metadata("status.auto_assign", "complete");
$meta->set_metadata("auto_assign.running", "no");

sub fatal {
    my ($msg) = @_;
    
    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status.auto_assign", "error");
    
    confess "$0: $msg";
}
    
