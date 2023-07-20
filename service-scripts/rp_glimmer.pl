
#
# Compute glimmer calls.
#

use Data::Dumper;
use Carp;
use strict;
use Job48;
use FIGV;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Sim;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $job = new Job48($jobdir);
$job or die "cannot create job for $jobdir";

my $hostname = `hostname`;
chomp $hostname;

my $genome = $job->genome_id();
my $meta = $job->meta();

$meta->add_log_entry($0, "start Glimmer processing on $hostname in $jobdir");

my $work = "$jobdir/glimmer_work";
my $orgdir = "$jobdir/rp/$genome";
my $contigs = "$orgdir/contigs";

$ENV{PATH} = join(":", $ENV{PATH}, $FIG_Config::bin, $FIG_Config::ext_bin);

&FIG::verify_dir($work);
chdir $work or &fatal("chdir $work failed: $!");

my $code = $meta->get_metadata("genome.genetic_code");
$code = 11 unless $code;

&run("$FIG_Config::bin/run_glimmer2 $genome $contigs -code=$code > $work/glimmer2.out 2> $work/glimmer2.err");

open(GLIM, "<$work/glimmer2.out") or &fatal("$work/glimmer2.out not readable: $!");

my $fdir = "$orgdir/Features/glimmer";
&FIG::verify_dir($fdir);

open(TBL, ">$fdir/tbl") or &fatal("Cannot open $fdir/tbl for writing: $!");
open(FA, ">$fdir/fasta") or &fatal("Cannot open $fdir/fasta for writing: $!");

my $next_id = 1;

my $figv = $job->get_figv();

my $code_table = &FIG::genetic_code($code);

while (<GLIM>)
{
    chomp;

    my($id, $loc) = split(/\t/);

    my $dna = $figv->dna_seq($genome, $loc);

    my $trans = &FIG::translate($dna, $code_table, 1);

    $trans =~ s/\*$//;

    my $cid = "fig|$genome.glimmer.$next_id";
    $next_id++;
    print TBL "$cid\t$loc\n";
    &FIG::display_id_and_seq($cid, \$trans, \*FA);
}

close(GLIM);
close(TBL);
close(FA);

$meta->add_log_entry($0, "finish glimmer computation on $jobdir");
$meta->set_metadata("status.glimmer", "complete");
$meta->set_metadata("glimmer.running", "no");
exit(0);

sub run
{
    my(@cmd) = @_;
    print "Run @cmd\n";
    my $rc = system(@cmd);
    $rc == 0 or &fatal("Cmd failed with rc=$rc: @cmd");
 }

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("status.glimmer", "error");
	$meta->set_metadata("glimmer.running", "no");
    }

    croak "$0: $msg";
}
    
