
#
# Compute pfam domians and create attributes data.
#

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

my $genome_dir = "$jobdir/rp/$genome";

my @apps = qw(rp_HMM_PFAM_search_on_timelogic
	      rp_make_PFAM_HMM_derived_attributes
	      rp_index_attributes
	     );

$meta->set_metadata("pfam.hostname", $hostname);

for my $app (@apps)
{
    $meta->add_log_entry($0, "start $app on $hostname in $jobdir");
    
    my $cmd = "$FIG_Config::bin/$app $jobdir $genome > $jobdir/rp.errors/$app.stderr 2>&1";
    warn "Compute: $cmd\n";
    my $rc = system($cmd);
    if ($rc != 0)
    {
	&fatal("$app computation failed with rc=$rc");
    }
}

$meta->add_log_entry($0, "finish pfam computation on $jobdir");
$meta->set_metadata("status.pfam", "complete");
exit(0);

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("status.pfam", "error");
    }

    croak "$0: $msg";
}
    
