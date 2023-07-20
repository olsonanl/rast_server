
#
# Write the export files for this completed job.
#

use Data::Dumper;
use Carp;
use strict;
use FIG;
use FIG_Config;
use FileHandle;
use File::Basename;
use GenomeMeta;
use SeedExport;
use Job48;

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

my @idx;
open(I, "<", "$export_dir/index");
while (<I>)
{
    chomp;
    if (!/spreadsheet/i)
    {
	push(@idx, $_);
    }
}
close(I);

my $ss_txt = "$export_dir/$genome.txt";
my $ss_xls = "$export_dir/$genome.xls";
my $rc = system("$FIG_Config::bin/seed2txt", "--out", $ss_txt, "--orgdir", $genome_dir, $genome);
if ($rc == 0)
{
    push(@idx, "$genome.txt\tSpreadsheet (tab-separated text format)");

    my $url = "$FIG_Config::cgi_url/seedviewer.cgi?page=Annotation&feature=PEG";
    $rc = system("$FIG_Config::bin/svr_file_to_spreadsheet -u '$url' -f $ss_xls < $ss_txt");
    if ($rc == 0)
    {
	push(@idx, "$genome.xls\tSpreadsheet (Excel XLS format)");
    }
    else
    {
	warn "error $rc writing XLS\n";
    }
}
else
{
    warn "error $rc writing txt spreadsheet\n";
}

if (open(I, ">", "$export_dir/index"))
{
    print I "$_\n" foreach @idx;
    close(I);
}

exit(0);

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("export.running", "no");
	$meta->set_metadata("status.export", "error");
    }
    croak "$0: $msg";
}
    
