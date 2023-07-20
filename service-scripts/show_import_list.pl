#
# Show the list of genomes to be imported. Double check
# they are not already in the seed.
#

use FIG_Config;
use strict;
use Job48;

@ARGV == 1 or @ARGV == 2 or die "Usage: $0 import-jobdir [jobfile]\n";

my $idir = shift;
my $file = shift;
$file = "$idir/rast.jobs" unless $file;

open(R, "<", $file) or die "cannot open rast joblist $file: $!";

my($f_job, $f_user, $f_gc, $f_gid, $f_genome, $f_replaces);
format STDOUT_TOP =
RAST   Submitting       GC   Genome ID    Replacment   Organism
Job      User           %                   for
------ ---------------- ---- ------------ ------------ --------------
.
format STDOUT =
@<<<<< @<<<<<<<<<<<<<<< @#.# @<<<<<<<<<<< @<<<<<<<<<<< @*
$f_job, $f_user,        $f_gc, $f_gid,    $f_replaces     $f_genome
.

my @out;
while (my $jobdir = <R>)
{
    chomp $jobdir;
    my $job = new Job48($jobdir);

    my $cand = $job->meta->get_metadata('import.candidate');
    my $action = $job->meta->get_metadata('import.action');
    my $replaces = $job->meta->get_metadata('import.replace');

    my $genome = $job->genome_name;
    my $gid = $job->genome_id;
    $gid = sprintf("%9s", $gid);
#    print "$jobdir:\t$cand\t$action\t$gid\t$genome\n";
    my $seed_dir = "$FIG_Config::organisms/$genome";

    if (0 && -d $seed_dir)
    {
	print "$jobdir exists in seed\n";
    }
    else
    {

	my $fasta = $job->orgdir . "/contigs";
	open(SL, "$FIG_Config::bin/sequence_length_histogram -null -get_gc < $fasta 2>&1 |") or
	    die "sequence_length_histogram pipe failed: $!";
	my $gc;
	while (<SL>)
	{
	    if (/G\+C\s*=\s*([^%]+)/)
	    {
		$gc = $1;
		last;
	    }
	}
	close(SL);
	
	push(@out, [$jobdir,$job, $cand, $action, $genome, $gid, $gc, $replaces]);
    }
}

for my $ent (sort { defined($b->[7]) <=> defined($a->[7]) or $a->[4] cmp $b->[4] } @out)
#for my $ent (sort { (($a->[6] > 60) <=> ($b->[6] > 60)) or  $a->[4] cmp $b->[4] } @out)
{
    my($jobdir,$job, $cand, $action, $genome, $gid, $gc, $replaces) = @$ent;
    $f_user = $job->user;
    $f_job = $job->id;
    $f_gid = $gid;
    $f_gc = $gc;
    $f_genome = $genome;
    $f_replaces = $replaces;

    write;
    #print "$jid\t$user\t$gc\t$gid\t$genome\n";
}
