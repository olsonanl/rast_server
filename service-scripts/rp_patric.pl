
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Write the PATRIC files for this completed job.
#-----------------------------------------------------------------------

use Data::Dumper;
use Carp;
use strict;
use FIGV;
use FIG;
use FIG_Config;
use FileHandle;
use File::Basename;
use GenomeMeta;
use GenomeTypeObject;
use SeedExport;
use Job48;
use JSON::XS;
use IPC::Run;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $job = new Job48($jobdir);
$job or die "cannot create job for $jobdir";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

my $genome_dir = "$jobdir/rp/$genome";

my $export_dir = "$jobdir/download";
&FIG::verify_dir($export_dir);

$meta->set_metadata("patric.hostname", $hostname);
$meta->set_metadata("patric.running", "yes");
$meta->set_metadata("status.patric", "in_progress");

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Calculate the PATRIC-specific annotations (based on Kmers V59 plus
# identical proteins from FIGfams plus proteins similar to
# the FIGfam members).
#
# We also compute the GO and EC mappings as well as the short-form
# of the assigned functions, via the write_go_mappings script.
#-----------------------------------------------------------------------

my $patric_anno = "$genome_dir/patric_annotations";

my $fasta = "$genome_dir/Features/peg/fasta";

if (! -s $patric_anno)
{
    my $md5_base = "md5.to.fam.rel61";
    my $md5;
    my @paths = ("/scratch/olson", "/vol/figfam-prod/Release61");
    for my $p (@paths)
    {
	if (-s "$p/$md5_base")
	{
	    $md5 = "$p/$md5_base";
	    last;
	}
    }
    if (! $md5)
    {
	fatal("MD5 figfam mapping file $md5_base not found in @paths");
    }
    else
    {
	my @call = ("$FIG_Config::bin/patric_call_proteins");
	@call = ("perl", "/home/olson/FIGdisk/dist/releases/current/FigKernelScripts/patric_call_proteins.pl");
	my @cmd = (@call, "-ff", "/vol/figfam-prod/Release59",
		   "--md5-to-fam", $md5, "--out", $patric_anno, $fasta);
	print "@cmd\n";
	my $rc = system(@cmd);
	if ($rc != 0)
	{
	    fatal("Patric annotation failed with rc=$rc: @cmd");
	}

	my $ok = IPC::Run::run(['cut', '-f1,3', $patric_anno], '>', "$genome_dir/patric_assignments");
	$ok or die "cut failed writing to $genome_dir/patric_assignments: $?";
	
	my $ok = IPC::Run::run(['cut', '-f1,2', $patric_anno], '>', "$genome_dir/patric_figfams");
	$ok or die "cut failed writing to $genome_dir/patric_figfams: $?";
	

	@cmd = ("$FIG_Config::bin/write_go_mappings",
		"-pegs", "$genome_dir/patric_assignments",
		"-ec", "$genome_dir/patric_ec",
		"-go", "$genome_dir/patric_go");
	$rc = system(@cmd);
	if ($rc != 0)
	{
	    fatal("Patric go mappings failed with rc=$rc: @cmd");
	}
    }
}

my $rc = system("rast_compute_specialty_genes",
		"--in", $fasta,
		"--out", "$genome_dir/specialty_genes",
		"--db-dir", "/home/olson/VBI/Virulence");
if ($rc != 0)
{
    fatal("rast_compute_specialty_genes failed: $rc");
}
		

$meta->set_metadata("patric.running", "no");
$meta->set_metadata("status.patric", "complete");

exit(0);



sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("patric.running", "no");
	$meta->set_metadata("status.patric", "error");
    }
    croak "$0: $msg";
}
    
