
#
# Perform rapid propagation via RASTtk.
#
# At the time this is invoked, the job directory will contain the raw unpacked
# input data. It may or may not have features. The initial RASTk annotator will not
# support keep-genecalls as this requires changes to the default pipeline. This should
# only be a short-term issue, however.
#
# Plan:
#
# Create a GTO from the raw directory using FIG::genome_id_to_genome_object
# Annotate the GTO.
# Write an initial rp directory from the GTO via rast-export-SEED.
#


use strict;
use FIG;
use FIGV;
use FIG_Config;
use File::Basename;
use File::Path 'make_path';
use File::Copy;
use GenomeMeta;
use Carp 'croak';
use POSIX;
use Bio::KBase::GenomeAnnotation::Client;
use JSON::XS;
use Data::Dumper;

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

my $raw_dir = "$jobdir/raw/$genome";
my $rp_dir = "$jobdir/rp/$genome";

my $errdir = "$jobdir/rp.errors";
&FIG::verify_dir($errdir);

if (! -d $raw_dir)
{
    &fatal("raw genome directory $raw_dir does not exist");
}

make_path($rp_dir);


$meta->set_metadata("rp.hostname", $hostname);

$meta->set_metadata("rp.running", "yes");
$meta->set_metadata("status.rp", "in_progress");

my $json = JSON::XS->new->pretty(1);

my $figv = FIGV->new($raw_dir);
my $obj = &FIG::genome_id_to_genome_object($figv, $genome);

#
# Set KB metadata environment variable for relating any calls
# made on this job's behalf back to the job.
#

{
    my $m = $FIG_Config::mantis_info;
    my $sys = "RAST";
    if (ref($m))
    {
	$sys .= "-$m->{server_value}";
    }

    $ENV{KBRPC_METADATA} = "$sys:$job:$errdir";
    $ENV{KBRPC_ERROR_DEST} = $errdir;
}

#
# Clear existing features.
# We don't support keep-genecalls here yet; need to better support this operation.
#
if ($FIG_Config::rasttk_retain_feature_user && 
    $FIG_Config::rasttk_retain_feature_user->{$user})
{
    print STDERR "retaining features for rasttk for user $user\n";
}
else
{
    print STDERR "clearing features for rasttk for user $user\n";
    if (ref($obj->{features}))
    {
	@{$obj->{features}} = ();
    }
}

open(F, ">", "$raw_dir/raw_genome.gto") or fatal("Cannot write $raw_dir/raw_genome.gto: $!");
print F $json->encode($obj);
close(F);

my $client = Bio::KBase::GenomeAnnotation::Client->new($FIG_Config::genome_annotation_service);

#
# FOR TESTING: if proc genome exists, don't rerun.
#

my $proc;

if (-s "$raw_dir/proc_genome.gto")
{
    $proc = $json->decode(scalar `cat $raw_dir/proc_genome.gto`);
}
else
{
    #
    # If we have set a workflow in our metadata, use it. Otherwise
    # look up the default RASTtk workflow.
    #
    my $workflow = $meta->get_metadata('rasttk_workflow');
    if (!$workflow)
    {
	$workflow = $client->default_workflow();
	$meta->set_metadata('rasttk_workflow', $workflow);
    }

    $proc = $client->run_pipeline($obj, $workflow);
    
    open(F, ">", "$raw_dir/proc_genome.gto") or fatal("Cannot write $raw_dir/proc_genome.gto: $!");
    print F $json->encode($proc);
    close(F);
}

#
# Write the processed genome to the RP dir.
#

$proc = GenomeTypeObject->initialize($proc);
$proc->write_seed_dir($rp_dir, { map_CDS_to_peg => 1,
				 correct_fig_id => 1,
				 assigned_functions_file => 'proposed_functions'});

#
# Propagate the rest of the toplevel files from the raw
# directory to the new rp directory.
#

for my $f (<$raw_dir/*>)
{
    my $b = basename($f);
    my $n = "$rp_dir/$b";
    if (-f $f && ! -f $n)
    {
	print STDERR "Copy $f => $n\n";
	copy($f, $n) or &fatal("Error copying $f to $n: $!");
    }
}

#
# Renumber features.
#

my $cmd = "renumber_features -print_map $rp_dir > $errdir/renumber_features.map 2> $errdir/renumber_features.stderr";
my $rc = system($cmd);
if ($rc != 0)
{
    &fatal("failed with rc=$rc: $cmd\n");
}

#
# We also renumber the gto file; we do it here since renumber_features assumes tabular data.
#

my %map;
open(MAP, "<", "$errdir/renumber_features.map") or die "Cannot open $errdir/renumber_features.map: $!";
while (<MAP>)
{
    chomp;
    my($from, $to) = split(/\t/);
    $map{$from} = $to;
}
close(MAP);
my $proc = "$rp_dir/proc_genome.gto";
my $proc_bak = $proc . "~";
rename($proc, $proc_bak) or die "Cannot rename $proc $proc_bak: $!";
open(OLD, "<", $proc_bak) or die "Cannot open $proc_bak for reading: $!";
open(NEW, ">", $proc) or die "Cannot open $proc for writing: $!";
while (<OLD>)
{
    s/"([^"]+)"/'"' . (exists $map{$1} ? $map{$1} : $1) . '"'/eg;
    print NEW $_;
}
close(OLD);
close(NEW);

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
    
