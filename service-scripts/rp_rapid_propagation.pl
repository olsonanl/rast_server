
#
# Perform rapid propagation.
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Carp 'croak';
use POSIX;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $hostname = `hostname`;
chomp $hostname;

my $user = &FIG::file_head("$jobdir/USER");
chomp $user;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $job = basename($jobdir);

my $meta_file = "$jobdir/meta.xml";
my $meta = new GenomeMeta($genome, $meta_file);

my $scheme = $meta->get_metadata("annotation_scheme");

my $prog;
if ($scheme eq "RASTtk")
{

    if ($FIG_Config::rast_use_patric{$user})
    {
	$prog = "rp_rapid_propagation_patric";
	$meta->add_log_entry($0, "Using RASTtk/PATRIC annotation scheme");
    }
    else
    {
	$prog = "rp_rapid_propagation_rasttk";
	$meta->add_log_entry($0, "Using RASTtk annotation scheme");
    }
}
else
{
    $meta->add_log_entry($0, "Using ClassicRAST annotation scheme");
    $prog = "rp_rapid_propagation_classic";
}

my @cmd = ($prog, $jobdir);

print "Run @cmd\n";

$meta->add_log_entry($0, ['running', @cmd]);

my $rc = system(@cmd);
if ($rc != 0)
{
    &fatal("$prog command failed with rc=$rc: @cmd\n");
}

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
    
