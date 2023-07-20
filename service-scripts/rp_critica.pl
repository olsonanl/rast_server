
#
# Compute critica calls.
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

$meta->add_log_entry($0, "start Critica processing on $hostname in $jobdir");

my $nt = "/vol/critica/seed-features.nt";

my $crit_bin = "/vol/critica/bin";
my $crit_scripts = "/vol/critica/scripts";

#
# need to set up the PERL5LIB for our children so critica can find stuff
# installed in the perl environment.
#

$ENV{PERL5LIB} = join(":", @INC);
$ENV{PATH} = join(":", $ENV{PATH}, $FIG_Config::bin, $FIG_Config::ext_bin);

$ENV{CRITICA_BLASTN} = "$FIG_Config::ext_bin/blastall -p blastn";
$ENV{CRITICA_BLASTPARM} = "-gF -e1e-4";
$ENV{CRITICA_BLASTDB} = "-d $nt -i";

$ENV{PATH} = join(":", $ENV{PATH}, $crit_bin, $crit_scripts);

my $work = "$jobdir/critica_work";
my $orgdir = "$jobdir/rp/$genome";
my $contigs = "$orgdir/contigs";

&FIG::verify_dir($work);
chdir $work or &fatal("chdir $work failed: $!");

my $code = $meta->get_metadata("genome.genetic_code");
$code = 11 unless $code;

if (0 or (not -s "$work/orfs3.cds"))
{
    &run("$crit_scripts/blast-contigs $contigs > $work/contigs.blast");
    
    &run("$crit_scripts/make-blastpairs $work/contigs.blast > $work/contigs.blast.pairs");
    &run("$crit_bin/scanblastpairs $contigs $work/contigs.blast.pairs $work/contigs.triplets");
    &run("$crit_scripts/iterate-critica -genetic-code=$code $work/orfs $contigs $work/contigs.triplets");
}

#
# We should have our orfs finished in orfs3.cds now. Parse that and create
# critica features.
#

open(CRIT, "<$work/orfs3.cds") or &fatal("$work/orfs3.cds not readable: $!");

my $fdir = "$orgdir/Features/critica";
&FIG::verify_dir($fdir);

open(TBL, ">$fdir/tbl") or &fatal("Cannot open $fdir/tbl for writing: $!");
open(FA, ">$fdir/fasta") or &fatal("Cannot open $fdir/fasta for writing: $!");

my $id = 1;

my $figv = $job->get_figv();

my $code_table = &FIG::genetic_code($code);

while (<CRIT>)
{
    chomp;

    my($contig, $start, $stop, $pval, $mval, $comp, $dicod, $init_score,
       $init_seq, $sd1, $sd2, $sd3) = split(/\s+/);

    my $loc = join("_", $contig, $start, $stop);
    my $dna = $figv->dna_seq($genome, $loc);

    my $trans = &FIG::translate($dna, $code_table, 1);
    $trans =~ s/\*$//;

    my $cid = "fig|$genome.critica.$id";
    $id++;
    print TBL "$cid\t$loc\n";
    &FIG::display_id_and_seq($cid, \$trans, \*FA);
}

close(CRIT);
close(TBL);
close(FA);

$meta->add_log_entry($0, "finish critica computation on $jobdir");
$meta->set_metadata("status.critica", "complete");
$meta->set_metadata("critica.running", "no");
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
	$meta->set_metadata("status.critica", "error");
	$meta->set_metadata("critica.running", "no");
    }

    croak "$0: $msg";
}
    
