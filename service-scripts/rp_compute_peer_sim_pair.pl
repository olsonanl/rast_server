#
# Compute the sims for a pair of peer organism dirs.
#
# Sims are stored in the RAST organism directory, in a directory named
# by the target genome ID:
#	 jobdir/rp/XXXXXX.YY/sims/QQQQQ.RR
#
# Within that directory the forward sims (from XXXXXX.YY => QQQQQ.RR) are in a file sims,
# with a btree index sims.index.
#

use strict;
use Data::Dumper;
use Carp;
use DB_File;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use FileHandle;
use Sim;
use FileLocking qw(lock_file unlock_file);

my $meta;

@ARGV == 3 or die "Usage: $0 work-dir job-1 job-2\n";

my $workdir = shift;
my @job_ids = @ARGV;

if (! -d $workdir)
{
    mkdir($workdir) or &fatal("mkdir $workdir failed: $!\n");
}

my @blast_args = qw(-p blastp -m 8 -e 1.0e-5);

#
# Map the job ids to org dirs, and collect a fasta file.
#

my $info = new FileHandle "$workdir/INFO", "w";

my @org_dirs;
my @fasta_files;
my @genomes;
my %genome_to_dir;

for my $job_id (@job_ids)
{
    my $org_dir;
    my $genome;
    if ($job_id =~ /^\d+$/)
    {
	my $job_dir = "$FIG_Config::rast_jobs/$job_id";
	$genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
	chomp $genome;
	$genome or &fatal("cannot find genome id for job $job_dir\n");

	$org_dir = "$job_dir/rp/$genome";
    }
    elsif ($job_id =~ m,^/,)
    {
	# Handle the case where we pass job directories or org dirs.

	if (-f "$job_id/GENOME_ID" and -d "$job_id/rp")
	{
	    my $job_dir = $job_id;
	    $genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
	    chomp $genome;
	    $genome or &fatal("cannot find genome id for job $job_dir\n");
	    
	    $org_dir = "$job_dir/rp/$genome";
	}
	elsif (-f "$job_id/GENOME" and -d "$job_id/Features" and $job_id =~ m,/^(\d+\.\d+)$,)
	{
	    $org_dir = $job_id;
	    $genome = $1;
	}
	else
	{
	    &fatal("Unknown jobid $job_id\n");
	}
    }
    else
    {
	&fatal("Unknown jobid $job_id\n");
    }
    -d $org_dir or &fatal("org_dir $org_dir does not exist\n");

    my $fasta_file = "$org_dir/Features/peg/fasta";
    if (! -f $fasta_file)
    {
	warn "No fasta found for $org_dir\n";
	next;
    }

    push(@fasta_files, $fasta_file);
    push(@genomes, $genome);
    
    print $info join("\t", $genome, $org_dir, $fasta_file), "\n";
    push(@org_dirs, $org_dir);

    -d "$org_dir/sims" or mkdir "$org_dir/sims" or die "Cannot mkdir $org_dir/sims: $!";
    if (! -f "$org_dir/sims/lock")
    {
	open(LF, ">", "$org_dir/sims/lock") or die "Cannot create $org_dir/sims/lock: $!";
	close(LF);
    }
    
    
    $genome_to_dir{$genome} = $org_dir;
}

update_state(0, 1);
update_state(1, 0);


#
# We copy the job1 fasta to workdir/fasta, the job2 fasta to workdir/db,
# formatdb workdir/db, and blast into workder/sims.
#

&run("/bin/cp", $fasta_files[0], "$workdir/fasta");
&run("/bin/cp", $fasta_files[1], "$workdir/db");
&run("diamond", "makedb", "--in", "$workdir/db", "--db", "$workdir/db.dmnd");
#&run("$FIG_Config::ext_bin/formatdb", "-p", "t", "-i", "$workdir/db");

my $threads = $ENV{P3_ALLOCATED_CPU} // 2;

&run("diamond", "blastp",
     "--threads", $threads,
     "--query", "$workdir/fasta",
     "--db", "$workdir/db.dmnd",
     "-o", "$workdir/sims.raw");
#&run("$FIG_Config::ext_bin/blastall", @blast_args, "-i", "$workdir/fasta", "-d", "$workdir/db",
#     "-o", "$workdir/sims.raw");

&run("$FIG_Config::bin/reformat_sims $workdir/fasta $workdir/db < $workdir/sims.raw > $workdir/sims.fwd");
&run("$FIG_Config::bin/flip_sims", "$workdir/sims.fwd", "$workdir/sims.rev");
&index_sims("$workdir/sims.fwd", "$workdir/sims.fwd.index");
&index_sims("$workdir/sims.rev", "$workdir/sims.rev.index");

#
# Sims are computed & formatted. We copy the fwd sims to
# job1/sims/job2, and rev sims to job2/sims/job1.
#
xx:
copy_sims("$workdir/sims.fwd", 0, 1);
copy_sims("$workdir/sims.rev", 1, 0);

exit(0);

sub update_state
{
    my($from, $to) = @_;

    my $g1 = $genomes[$from];
    my $g2 = $genomes[$to];

    my $d1 = $org_dirs[$from];
    my $d2 = $org_dirs[$to];

    if (!open(LF, "+<", "$d1/sims/lock"))
    {
	open(LF, "+>", "$d1/sims/lock") or die
	    "Cannot open lockfile $d1/sims/lock: $!";
    }
    lock_file(\*LF);

    if (-f "$d1/sims/$g2.queued")
    {
	unlink("$d1/sims/$g2.queued");
    }
    open(S, ">", "$d1/sims/$g2.in_progress");
    close(S);
    close(LF);
}

sub copy_sims
{
    my($file, $from, $to) = @_;

    my $g1 = $genomes[$from];
    my $g2 = $genomes[$to];

    my $d1 = $org_dirs[$from];
    my $d2 = $org_dirs[$to];

    if (!open(LF, "+<", "$d1/sims/lock"))
    {
	open(LF, "+>", "$d1/sims/lock") or die
	    "Cannot open lockfile $d1/sims/lock: $!";
    }
    lock_file(\*LF);

    for my $prior (<$d1/sims/$g2.*>, "$d1/sims/$g2")
    {
	if (-f $prior)
	{
	    print "Remove old $prior\n";
	    unlink($prior);
	}
    }
    &run("/bin/cp", $file, "$d1/sims/$g2");
    &run("/bin/cp", "$file.index", "$d1/sims/$g2.index");

    close(LF);
}


#
# Use the C index_sims_file app to create a berkeley db index
# of the sims file.
#

sub index_sims
{
    my($sims, $index_file) = @_;

    my $path = &FIG::find_fig_executable("index_sims_file");

    open(IDX, "$path 0 < $sims |") or &fatal("Cannot open index_sims_file pipe: $!\n");

    my %index;
    my $tied = tie %index, 'DB_File', $index_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;

    $tied or &fatal("Creation of hash $index_file failed: $!\n");

    while (<IDX>)
    {
	chomp;
	my($peg, undef, $seek, $len) = split(/\t/);
	
	$index{$peg} = "$seek,$len";
    }
    close(IDX);
    
    $tied->sync();
    untie %index;
}

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("scenario.running", "no");
	$meta->set_metadata("status.scenario", "error");
    }

    croak "$0: $msg";
}
    
sub run
{
    my(@cmd) = @_;
    print "Run @cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	&fatal("error $rc running @cmd\n");
    }
}
