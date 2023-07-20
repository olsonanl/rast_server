
#
# Perform rapid propagation.
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Carp 'croak';

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $job = basename($jobdir);

my $meta_file = "$jobdir/meta.xml";
my $meta = new GenomeMeta($genome, $meta_file);

my $raw_dir = "$jobdir/raw/$genome";
my $rp_dir = "$jobdir/rp/$genome";

my $errdir = "$jobdir/rp.errors";
&FIG::verify_dir($errdir);

if (! -d $raw_dir)
{
    &fatal("raw genome directory $raw_dir does not exist");
}

$meta->set_metadata("rp.hostname", $hostname);

#
# Perform the rapid propagation.
#
# We work from the raw genome directory. We assume the incoming contigs
# are present in raw/genome-id/unformatted_contigs. We run
# reformat_contigs -split before the actual rapid propagation to
# split any scaffolds present in the contigs.
#
# When the rp is finished, we move the split contigs out of the way
# and rerun reformat_contigs without the split option in order
# to recover the original contig coordinates.
#
# If keep_genecalls is enabled, we do not split the contigs.
#

my $keep_genecalls = $meta->get_metadata("keep_genecalls");
my $unformatted = "$raw_dir/unformatted_contigs";

if (! -f $unformatted)
{
    &fatal("Unformatted contigs file $unformatted does not exist\n");
}

#
# Determine genetic code.
#

my $genetic_code = $meta->get_metadata("genome.genetic_code");
if (!defined($genetic_code))
{
    $meta->add_log_entry("Genetic code not defined; defaulting to 11");
    $genetic_code = 11;
}

#
# Reformat and split.
#
# Only do this if we are doing gene calling.
#

my $formatted = "$raw_dir/contigs";
my @cmd;

my $split_size = 3;
if ($FIG_Config::rast_contig_ambig_split_size =~ /^\d+$/)
{
    $split_size = $FIG_Config::rast_contig_ambig_split_size;
}

if ($keep_genecalls)
{
    my $reformat_log = "$errdir/reformat_contigs.stderr";
    
    @cmd = ("$FIG_Config::bin/reformat_contigs", "-v", "-logfile=$reformat_log", $unformatted, $formatted);
}
else
{
    my $reformat_split_log = "$errdir/reformat_contigs_split.stderr";
    
    @cmd = ("$FIG_Config::bin/reformat_contigs", "-v", "-logfile=$reformat_split_log", "-split=$split_size", $unformatted, $formatted);
}

print "Run @cmd\n";

$meta->add_log_entry($0, ['running', @cmd]);

my $rc = system(@cmd);
if ($rc != 0)
{
    &fatal("reformat command failed with rc=$rc: @cmd\n");
}

#
# Do the rapid propagation itself.
#

my $tmp = "tmprp.job$job.$$";
my $tmpdir = "/scratch/$tmp";

&FIG::verify_dir("$jobdir/rp");

#
# Determine if we are keeping the original gene calls.
#

my @keep_genecalls_flag;

if ($keep_genecalls)
{
    $meta->add_log_entry($0, "Keeping original gene calls");
    @keep_genecalls_flag = ("--keep");
}

@cmd = ("$FIG_Config::bin/rapid_propagation_plasmid", "--errdir", $errdir,
	@keep_genecalls_flag,
	"--code", $genetic_code,
	"--meta", $meta_file,
	"--tmpdir", $tmpdir,
	$raw_dir, $rp_dir);
print "Run @cmd\n";
$meta->add_log_entry($0, ['running', @cmd]);

$rc = system(@cmd);
	     
if ($rc != 0)
{
    &fatal("rapid_propagation_plasmid command failed with rc=$rc: @cmd\n");
}

#
# RP should be done. Check to see that we at least had a features directory created.
#

if (! -d "$rp_dir/Features/peg")
{
    &fatal("rapid_propagation did not create any features");
}

$meta->add_log_entry($0, "rapid_propagation completed\n");
$meta->set_metadata("rp.running", "no");
$meta->set_metadata("status.rp", "complete");

exit;

sub fatal
{
    my($msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("rp.error", $msg);
    $meta->set_metadata("rp.running", "no");
    $meta->set_metadata("status.rp", "error");

    croak "$0: $msg";
}
    
