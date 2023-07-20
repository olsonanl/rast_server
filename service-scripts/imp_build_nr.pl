
#
# Build an NR.
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'build_nr', $jobdir);

$stage or die "$0: Could not create job object";

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

my @cmd = ("$FIG_Config::bin/build_nr",
	   "-sort-size", "10G",
	   "-emit-singleton-sets",
	   "-skip-duplicates",
	   "$jobdir/nr.sources",
	   "$jobdir/prev_nr",
	   "$jobdir/prev_syn",
	   "$jobdir/nr",
	   "$jobdir/peg.synonyms");

$stage->run_process("build_nr", @cmd);

#
# Index the created NR.
#

$stage->run_process("make_fasta_btree", "$FIG_Config::bin/make_fasta_btree",
		    "$jobdir/nr",
		    "$jobdir/nr.btree",
		    "$jobdir/nr-len.btree");

#
# And the pegsyn, for reduce_sims use.
#
$stage->run_process("make_reduce_sims_index", "$FIG_Config::bin/make_reduce_sims_index",
		    "$jobdir/peg.synonyms",
		    "$jobdir/peg.synonyms.reduce_sims_index.btree");

$stage->log("completed");
$stage->set_running("no");
$stage->set_status("complete");

