
#
# Perform subsystem coverage.
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
# Do the subsytem coverage.
#

my $tmp = "tmprp.job$job.$$";
my $tmpdir = "/scratch/$tmp";

&FIG::verify_dir("$jobdir/rp");

#my $reformat_log = "$errdir/subsytem_coverage.stderr";



my $cmd = "cat $rp_dir/proposed*functions | $FIG_Config::bin/rapid_subsystem_inference $rp_dir/Subsystems 2> $errdir/rapid_subsystem_inference.stderr";



print "Run $cmd\n";
$meta->add_log_entry($0, ['running', $cmd]);

$rc = system($cmd);
	     
if ($rc != 0)
{
    &fatal("rapid_propagation_plasmid command failed with rc=$rc: $cmd\n");
}


$meta->add_log_entry($0, "rapid_subsystem_coverage completed\n");
$meta->set_metadata("rp.subsystem_coverage", "no");
$meta->set_metadata("status.subsystem_coverage", "complete");

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
    
