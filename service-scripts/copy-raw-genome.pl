
#
# Copy the base parts of genome directory into a new job directory in the 48hr server.
#
# Used for test/debugging.
#

use strict;
use FIG_Config;
use File::Copy;
use GenomeMeta;

@ARGV > 0 or die "usage: $0 genome [...]\n";

my $job_spool_dir = $FIG_Config::rast_jobs;

opendir(D, $job_spool_dir) or  die "Cannot open job directory $job_spool_dir: $!\n";

my @jobs = sort { $b <=> $a } grep { /^\d+$/ and -d "$job_spool_dir/$_" } readdir(D);

my $next_job;
if (@jobs)
{
    $next_job = $jobs[0] + 1;
}
else
{
    $next_job = 1;
}


my %info;
for my $genome (@ARGV)
{
    my $gp = "$FIG_Config::organisms/$genome";
    -d $gp or die "Genome directory for $genome not found\n";

    my $job = $next_job++;
    my $jobdir = sprintf("$job_spool_dir/%04d", $job);
    -d $jobdir and die "Job directory $jobdir already exists\n";
    $info{$genome} = [$gp, $job, $jobdir];
}

my @files_to_copy = qw(GENOME PROJECT TAXONOMY);
for my $genome (@ARGV)
{
    my($gpath, $job, $jobdir) = @{$info{$genome}};

    print "Copy $jobdir from $gpath\n";

    mkdir $jobdir or die "mkdir $jobdir failed: $!\n";
    mkdir "$jobdir/raw" or die "mkdir $jobdir/raw failed: $!\n";
    mkdir "$jobdir/raw/$genome" or die "mkdir $jobdir/raw/$genome failed: $!\n";

    for my $f (@files_to_copy)
    {
	copy("$gpath/$f", "$jobdir/raw/$genome/$f") or die "Cannot copy $gpath/$f to $jobdir/raw/$genome/$f: $!\n";
	copy("$gpath/$f", "$jobdir/$f") or die "Cannot copy $gpath/$f to $jobdir/$f: $!\n";
    }
    system("cp $gpath/contig* $jobdir/raw/$genome/.");
    open(U, ">$jobdir/GENOME_ID") or die "cannot open $jobdir/GENOME_ID: $!\n";
    print U "$genome\n";
    close(U);
    
    open(U, ">$jobdir/USER") or die "cannot open $jobdir/USER: $!\n";
    print U (getpwuid($>))[0], "\n";
    close(U);

    my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");
    $meta->add_log_entry("genome", "Created $jobdir from $gpath");
    $meta->set_metadata("status.uploaded", "complete");

    open(A, ">$jobdir/ACTIVE") or die "cannot open $jobdir/ACTIVE: $!\n";
    close(A);
}

