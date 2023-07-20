
#
# Compute Pchs from expanded sims.
#

use DB_File;

use Data::Dumper;
use Carp;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Sim;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

$meta->set_metadata("status.pchs", "in_progress");

my $genome_dir = "$jobdir/rp/$genome";

my $sims_file = "$jobdir/rp/$genome/expanded_similarities";
my $raw_pch_file = "$jobdir/rp/$genome/pchs.raw";
my $proc_pch_file = "$jobdir/rp/$genome/pchs";
my $pch_btree_file = "$jobdir/rp/$genome/pchs.btree";
my $pch_ev_btree_file = "$jobdir/rp/$genome/pchs.evidence.btree";
my $scored_pch_file = "$jobdir/rp/$genome/pchs.scored";
my $compute_pch_err_file = "$jobdir/rp.errors/compute_pchs.stderr";
my $filter_pch_err_file = "$jobdir/rp.errors/remove_clustered_pchs.stderr";
my $score_pch_err_file = "$jobdir/rp.errors/score_pchs.stderr";

my $cluster_cutoff = 70;

my $genome_sim_cache_file = "$FIG_Config::fortyeight_data/genome_similarity.cache";
my $genome_sim_cache;
if (-f $genome_sim_cache_file)
{
    $genome_sim_cache = "-cache $genome_sim_cache_file";
}
else
{
    $meta->add_log_entry($0, "warning: missing genome sim cache $genome_sim_cache_file");
}

#
# Compute PCHs
#

$meta->add_log_entry($0, "start PCH processing on $hostname in $jobdir");

my $cmd = "$FIG_Config::bin/compute_pchs_from_sims $sims_file $raw_pch_file 2>&1 >$compute_pch_err_file";
warn "Compute: $cmd\n";
my $rc = system($cmd);
if ($rc != 0)
{
    &fatal("pchs computation failed with rc=$rc");
}

#
# Remove clustered PCHs.
#

my $cmd = "$FIG_Config::bin/remove_clustered_pchs3 -orgdir $genome_dir $genome_sim_cache $cluster_cutoff ";
$cmd .= " < $raw_pch_file > $proc_pch_file 2>$filter_pch_err_file";

$meta->add_log_entry($0, "remove PCH clusters: $cmd");

my $rc = system($cmd);
if ($rc != 0)
{
    &fatal("remove_clustered_pchs3 computation failed with rc=$rc");
}
#
# compute simple scores
#

my $cmd = "$FIG_Config::bin/compute_simple_scores 4  < $proc_pch_file > $scored_pch_file 2>$score_pch_err_file";

$meta->add_log_entry($0, "score PCHs: $cmd");

my $rc = system($cmd);
if ($rc != 0)
{
    &fatal("compute_simple_scores computation failed with rc=$rc");
}

#
# And create btree database file.
#

$DB_BTREE->{flags} = R_DUP;
my %index;
unlink($pch_btree_file);
my $tied = tie %index, 'DB_File', $pch_btree_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;

if (!$tied)
{
    &fatal("cannot create $pch_btree_file: $!");
}

if (open(SC, "<$scored_pch_file"))
{
    while (<SC>)
    {
	chomp;
	my($p1, $p2, $sc) = split(/\t/);
	$index{$p1, $p2} = $sc;
	$index{$p1} = join($;, $p2, $sc);
    }
}
untie $tied;
#
# Coupling evidence. This one requires duplicate keys.
#

$DB_BTREE->{flags} = R_DUP;
my %index;
unlink($pch_ev_btree_file);
my $tied = tie %index, 'DB_File', $pch_ev_btree_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;

if (!$tied)
{
    &fatal("cannot create $pch_ev_btree_file: $!");
}

if (open(PCH, "<$proc_pch_file"))
{
    while (<PCH>)
    {
	chomp;
	my($p1, $p2, $p3, $p4, $iden3, $iden4, undef, undef, $rep) = split(/\t/);
	$index{$p1, $p2} = join($;, $p3, $p4, $iden3, $iden4, $rep);
    }
}
untie $tied;

$meta->add_log_entry($0, "finish PCH computation on $jobdir");
$meta->set_metadata("status.pchs", "complete");
$meta->set_metadata("pchs.running", "no");
exit(0);

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("status.pchs", "error");
	$meta->set_metadata("pchs.running", "no");
    }

    croak "$0: $msg";
}
    
