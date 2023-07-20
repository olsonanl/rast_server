
#
# Perform rapid propagation via RASTtk via the PATRIC application interface.
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
use File::Slurp;
use File::Copy;
use GenomeMeta;
use Carp 'croak';
use POSIX;
use lib '/vol/patric3/production/P3Slurm2/deployment-2019-1210-01/lib';
use Bio::KBase::AppService::ClientExt;
use Bio::P3::Workspace::WorkspaceClientExt;
use P3AuthToken;
use P3AuthLogin;
use JSON::XS;
use Data::Dumper;

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

make_path($rp_dir);


$meta->set_metadata("rp.hostname", $hostname);

$meta->set_metadata("rp.running", "yes");
$meta->set_metadata("status.rp", "in_progress");

my $json = JSON::XS->new->pretty(1);

my $figv = FIGV->new($raw_dir);
my $obj = &FIG::genome_id_to_genome_object($figv, $genome);

my $keep_genecalls = $meta->get_metadata("keep_genecalls");

if (!$keep_genecalls && ref($obj->{features}))
{
    @{$obj->{features}} = ();
}

open(F, ">", "$raw_dir/raw_genome.gto") or fatal("Cannot write $raw_dir/raw_genome.gto: $!");
print F $json->encode($obj);
close(F);

#
# FOR TESTING: if proc genome exists, don't rerun.
#

if (! -s "$raw_dir/proc_genome.gto")
{
    process_genome($obj);
}

my $proc = $json->decode(scalar read_file("$raw_dir/proc_genome.gto"));

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

# 
# Process our genome in RASTtk at PATRIC via the App-RASTJob application
# interface. We will do this as user RAST, and write our input and output into a
# jobs folder in the PATRIC workspace.
# 
sub process_genome
{
    my($obj) = @_;

    if (!$FIG_Config::PATRIC_user || !$FIG_Config::PATRIC_password)
    {
	die "PATRIC username and password must be set in \$FIG_Config\n";
    }
    my $token = P3AuthLogin::login_patric($FIG_Config::PATRIC_user, $FIG_Config::PATRIC_password);
    $token or die "RASTtk could not log in to PATRIC\n";

    $ENV{KB_AUTH_TOKEN} = $token;
    
    my $job_base = sprintf("%03d", $job % 1000);
    my $output_folder = "$FIG_Config::PATRIC_job_folder/$job_base/$job";

    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();
    my $app_service = Bio::KBase::AppService::ClientExt->new();

    #
    # Create a job folder.
    #

    $ws->create({objects => [[$output_folder, 'folder']]});

    #
    # Genome object patches. Ensure we have a ncbi_taxonomy_id.
    #
    if (!$obj->{ncbi_taxonomy_id})
    {
	my($t) = $obj->{id} =~ /^(\d+)/;
	$t //= 6666666;
	$obj->{ncbi_taxonomy_id} = $t;
    }
    
    #
    # Upload our genome to the workspace.
    #
    my $genome_path = "$output_folder/raw_genome.gto";
    $ws->save_data_to_file($json->encode($obj), { rast_job => $job, rast_genome => $genome },
			   $genome_path, 'genome', 1, 1, $token);

    #
    # If we have set a workflow in our metadata, use it. Otherwise
    # use the default PATRIC workflow.
    #
    my $workflow = $meta->get_metadata('rasttk_workflow');

    if ($workflow)
    {
	#
	# PATRIC has disabled kmer v1, so mark as failure-not-fatal if present.
	#
	for my $ent (@{$workflow->{stages}})
	{
	    if ($ent->{name} =~ /kmer_v1/)
	    {
		$ent->{failure_is_not_fatal} = 1;
	    }
	}
    }
    print Dumper($workflow);

    my $app_params = {
	genome_object => $genome_path,
	output_file => $genome,
	output_path => $output_folder,
	($workflow ? (workflow => $json->encode($workflow)) : ()),
    };

    write_file("$raw_dir/app_submission.json", $json->encode($app_params));

    my $start_params = { workspace => $output_folder };
    my $submitted = $app_service->start_app2("RASTJob", $app_params, $start_params);

    print STDERR Dumper(SUBMITTED => $submitted);
    if (open(J, ">", "$jobdir/PATRIC_JOB"))
    {
	print J "PATRIC job\t$submitted\nWorkspace folder\t$output_folder\n";
	close(J);
    }
    else
    {
	warn "Could not open $jobdir/PATRIC_JOB: $!";
    }

    print STDERR "Awaiting completion\n";
    my $finished = $app_service->await_task_completion([$submitted], 10, 0);

    my $res = $finished->[0];
    if ($res->{status} ne 'completed')
    {
	die "Error running job: " . Dumper($res);
    }

    #
    # Copy data back. The output is in $genome. We may also have quality
    # data in GenomeReport.html and genome_quality_details.txt
    #
    $ws->download_file("$output_folder/.$genome/$genome", "$raw_dir/proc_genome.gto", 1, $token);
    make_path("$jobdir/download");
    eval { $ws->download_file("$output_folder/.$genome/GenomeReport.html", "$jobdir/download/GenomeReport.html", 1, $token); };
    eval { $ws->download_file("$output_folder/.$genome/genome_quality_details.txt", "$jobdir/download/genome_quality_details.txt", 1, $token); } ;

}
