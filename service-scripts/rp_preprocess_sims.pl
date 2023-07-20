

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Carp 'croak';

@ARGV == 3 or die "Usage: $0 job-dir NR peg.synonyms\n";

my $jobdir = shift;
my $sims_nr = shift;
my $sims_peg_synonyms = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

#
# Use pull_sims_from_server to extract sims for the fasta file we have,
# writing them to jobdir/sims.job/sims.server. Write the sequences that did not
# have sims to jobdir/sims.job/seqs_needing_sims.
#
# Use rp_chunk_sims to chunk the remaining sims, setting up for the main
# pipeline script to submit them.
#

my $fasta = "$jobdir/rp/$genome/Features/peg/fasta";
if (! -f $fasta)
{
    &fatal("Fasta file $fasta is not present");
}
system("diamond", "makedb", "--db", "$fasta.dmnd", "--in", $fasta);

-d "$jobdir/sims.job" or mkdir "$jobdir/sims.job" or die "mkdir $jobdir/sims.job failed: $!";

my $server_sims = "$jobdir/sims.job/sims.server";
my $seqs_needing_sims = "$jobdir/sims.job/seqs_needing_sims";
my $ids_needing_sims = "$jobdir/sims.job/ids_needing_sims";

my $cmd;
if ($FIG_Config::rast_sims_database)
{
    my($dsn, $user, $pw, $tbl) = @$FIG_Config::rast_sims_database;
    $cmd = "$FIG_Config::bin/pull_sims_from_database '$dsn' '$user' '$pw' '$tbl' < $fasta > $server_sims 2> $ids_needing_sims";
}
else
{
    $cmd = "$FIG_Config::bin/pull_sims_from_server < $fasta > $server_sims 2> $ids_needing_sims";
}
$meta->add_log_entry($0, $cmd);
my $rc = system($cmd);
if ($rc != 0)
{
    &fatal("pull_sims_from_server failed with rc=$rc: $cmd");
}

#
# Reinflate the ids to a fasta.
#

$cmd = "$FIG_Config::bin/pull_fasta_entries $fasta < $ids_needing_sims > $seqs_needing_sims";
$rc = system($cmd);
if ($rc != 0)
{
    &fatal("pull_fasta_entries failed with rc=$rc: $cmd");
}

#
# And chunk.
#

my @size;
@size = ("-size", $FIG_Config::sim_chunk_size) if $FIG_Config::sim_chunk_size;
$cmd = "$FIG_Config::bin/rp_chunk_sims @size -include-self -self-fasta $fasta $seqs_needing_sims $sims_nr $sims_peg_synonyms $jobdir/sims.job > $jobdir/sims.job/chunk.out";
$rc = system($cmd);
if ($rc != 0)
{
    &fatal("rp_chunk_sims failed with rc=$rc: $cmd");
}


$meta->add_log_entry($0, "sims_preprocess completed\n");
$meta->set_metadata("status.sims_preprocess", "complete");
$meta->set_metadata("sims_preprocess.running", "no");

sub fatal
{
    my($msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status.sims_preprocess", "error");

    croak "$0: $msg";
}
    
