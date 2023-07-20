#
# Create a SEED-import job.
#
# The job initially has a listing of SEED fasta sources, NR fasta sources, and
# RAST fasta sources. The new NR will not have been built - it will be the first stage
# in the pipeline.
#
# For now we need to pass in the path to the NR and peg.synonyms files we are building from.
#
# We create the following files:
#
#    nr.dirs
#	Tab-delimited data of db-name, source path, size of fasta file
#
#    nr.sources
#	Listing of all fasta source files from which the nr is to be built
#
# We hardcode in the script, for now, the source locations of things. This is an ANL internal
# application at this point.
#
# 
#

use strict;
use Data::Dumper;
use DirHandle;
use ImportJob;
use Job48;
use NRTools;

my $usage = "create_import_job [-new-nr-data dir] [-import-biodb] [-from-job jobnum] [prev-nr prev-syn prev-sims]";

#
# Incoming NR data.
#
my $dir_biodb = "/vol/biodb";
my $dir_biodb_nr_input = "$dir_biodb/processed_data/for_build_nr";

#
# Existing SEED data
#

my $dir_reference_seed_data = "/vol/seed-data-anno-mirror/Data.Jan3";
#my $dir_reference_seed_data = "/local/FIGdisk/FIG/Data";

#
# RAST server from which to pull genomes to import.
#

my $dir_rast_jobs = "/vol/48-hour/Jobs.prod.2007-0601";

#
# Startup.
#

my $do_biodb_import;
my $from_job_id;

while ((@ARGV > 0) && ($ARGV[0] =~ /^-/))
{
    my $arg = shift @ARGV;
    if ($arg =~ /^-import-biodb/i)
    {
	$do_biodb_import++;
    }
    elsif ($arg =~ /^-new-nr-data/)
    {
	$dir_biodb_nr_input = shift @ARGV;
	$do_biodb_import++;
    }
    elsif ($arg =~ /^-from-job/)
    {
	$from_job_id = shift @ARGV;
    }
    else
    {
	die $usage;
    }
}

my $prev_nr_src;
my $prev_syn_src;
my $prev_sim_dir;
my $from_job;

if (defined($from_job_id))
{
    @ARGV == 0 or die $usage;
    
    $from_job = ImportJob->new($from_job_id);
    $from_job or die "From-job id $from_job_id does not exist";

    my $dir = $from_job->dir();
    $prev_nr_src = "$dir/nr";
    $prev_syn_src = "$dir/peg.synonyms";
    $prev_sim_dir = sprintf("$dir/Sims.%03d", $from_job_id);
}
else
{
    @ARGV == 3 or die $usage;

    $prev_nr_src = shift;
    $prev_syn_src = shift;
    $prev_sim_dir = shift;
}

#
# Validate
#
if (open(F, "<$prev_nr_src"))
{
    $_ = <F>;
    if (! /^>/)
    {
	die "$prev_nr_src does not look like a fasta file\n";
    }
    close(F);
}
else
{
    die "Cannot open previous NR file $prev_nr_src: $!\n";
}

if (open(F, "<$prev_syn_src"))
{
    $_ = <F>;
    if (!/^xxx\d+,\d+\t/)
    {
	die "$prev_syn_src does not look like a peg.synonyms file\n";
    }
    close(F);
}
else
{
    die "Cannot open previous synonyms file $prev_syn_src: $!\n";
}

my @sfiles = <$prev_sim_dir/sims*>;
if (not(-d $prev_sim_dir and @sfiles > 0))
{
    die "previous sim dir $prev_sim_dir does not appear to contain sims\n";
}


print "Creating import job\n";
print "\tprev_nr=$prev_nr_src\n";
print "\tprev_syn=$prev_syn_src\n";
print "\tprev_sim=$prev_sim_dir\n";

#
# Initial validation.
#
&validate_dirs($dir_reference_seed_data, $dir_rast_jobs);

if ($do_biodb_import)
{
    &validate_dirs($dir_biodb_nr_input);
}

#
# Create our jobdir.
#

my ($jobnum, $err) = ImportJob->create_new_job();
#my ($jobnum, $err) = ('002', undef);

if (!$jobnum)
{
    die "Create failed with error: $err\n";
}

my $job = ImportJob->new($jobnum);
my $jobdir = $job->dir;

$job->meta->add_log_entry($0, "creating new job");

#
# Symlink to prev_nr and prev_syn in the job directory.
#

my $prev_nr = "$jobdir/prev_nr";
my $prev_syn = "$jobdir/prev_syn";
my $prev_sims = "$jobdir/prev_sims";

unlink($prev_nr, $prev_syn, $prev_sims);

symlink($prev_nr_src, $prev_nr) or die "symlimk $prev_nr_src $prev_nr failed: $!";
symlink($prev_syn_src, $prev_syn) or die "symlimk $prev_syn_src $prev_syn failed: $!";
symlink($prev_sim_dir, $prev_sims) or die "symlimk $prev_sim_dir $prev_sims failed: $!";

#
# Build list of NR sources. We start with the directories in the reference
# SEED's NR dir, and override with anything in the biodb NR dir.
#

my %NR_dirs;

scan_NR_dir(\%NR_dirs, "$dir_reference_seed_data/NR");

if ($do_biodb_import)
{
    scan_NR_dir(\%NR_dirs, "$dir_biodb_nr_input");
}

#scan_NR_dir(\%NR_dirs, "$dir_biodb_nr_input", { skip => qr(^(SwissProt|.*\.bak)) });

#
# And write to job dir.
#
open(F, ">$jobdir/nr.dirs");
for my $d (keys %NR_dirs)
{
    print F join("\t", $d, @{$NR_dirs{$d}}{'path', 'size'}), "\n";
}
close(F);

#
# Scan for SEED organisms.
#

scan_seed_dir(\%NR_dirs, "$dir_reference_seed_data/Organisms");

#
# Scan for RAST jobs to import.
#
# We update our NR component list with the peg features from the job,
# and we add the job directory of each to the rast.jobs file. This
# will be used later during the installation of these jobs into the SEED.
#

open(JOBS, ">$jobdir/rast.jobs") or die "Cannot create $jobdir/rast.jobs: $!";

my @rast_jobs;
scan_rast_jobs(\@rast_jobs, $dir_rast_jobs);

my @new_rast_jobs;
for my $job (@rast_jobs)
{
    my $gid = $job->genome_id;
    my $gname = $job->genome_name;
    my $j = $job->id;
    
    print "RAST job #$j: $gid $gname\n";

    if (exists($NR_dirs{$gid}))
    {
	warn "Rast job $j already exists in SEED server\n";
	next;
    }
    push(@new_rast_jobs, $job);

    print JOBS $job->dir(), "\n";

    my $fasta = $job->orgdir() . "/Features/peg/fasta";
    -f $fasta or die "Job $j has no fasta file in $fasta\n";
    $NR_dirs{$gid} = {type => "rast_job", name => $gname, path => $job->orgdir,
			    fasta_path => $fasta, size => -s _ };
}
close(JOBS);
@rast_jobs = @new_rast_jobs;

open(F, ">$jobdir/all.nr.dirs");
open(F2, ">$jobdir/nr.sources");
for my $d (sort bydb keys %NR_dirs)
{
    print F join("\t", $d, @{$NR_dirs{$d}}{'path', 'size'}), "\n";
    print F2 $NR_dirs{$d}->{fasta_path} . "\n";
}
close(F);
close(F2);

sub bydb
{
    if ($a =~ /^(\d+)\.(\d+)$/)
    {
	my($ga, $ia) = ($1, $2);
	if ($b =~ /^(\d+)\.(\d+)$/)
	{
	    my($gb, $ib) = ($1, $2);
	    return $ga <=> $gb or $ia <=> $ib;
	}
	else
	{
	    return 1;
	}
    }
    elsif ($b =~ /^\d+\.\d+$/)
    {
	return -1;
    }
    else
    {
	return $a cmp $b;
    }
}


sub validate_dirs
{
    my(@dirs) = @_;

    my $err;
    for my $dir (@dirs)
    {
	if (! -d $dir)
	{
	    warn "Required directory $dir is not present\n";
	    $err++;
	}
    }
    exit(1) if $err;
}
