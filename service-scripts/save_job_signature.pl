#
# Compute the job's signature and save the original
# annotations, subsystems, and features to original_state.tgz.
#

use strict;
use FIG_Config;
use Job48;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $dir = shift;

my $id;
if ($dir !~ m,/(\d+)$,)
{
    die "Job directory does not end with a number\n";
}

$id = $1;

#
# Compute the signature, save to JOB_SIGNATURE.
#
# The first line of the signature file is the signature itself.
#

my $rc = system("$FIG_Config::bin/compute_job_signature", $dir, "$dir/JOB_SIGNATURE");
$rc == 0 or die "compute_job_signature failed with rc=$rc\n";

my $sig = &FIG::file_head("$dir/JOB_SIGNATURE", 1);
chomp $sig;

my $db = DBMaster->new(-database => $FIG_Config::rast_jobcache_db,
		       -backend => 'MySQL',
		       -host => $FIG_Config::rast_jobcache_host,
		       -user => $FIG_Config::rast_jobcache_user);

#
# retrieve the job to make sure the directory matches the directory
# we were given.
#

my $job = $db->Job->init({ id => $id } );
$job or die "job $id does not exist\n";

my $jdir = $job->dir;
if ($jdir ne $dir)
{
    die "Directory for job $id is $jdir which does not match given directory $dir\n";
}

$job->job_signature($sig);


#
# Save a tarfile of the original annotations, subsystem analysis,
# and feaures.
#

my $org_dir = $job->org_dir;

opendir(D, $org_dir) or die "Cannot opendir $org_dir: $!";
my @fn_files = grep { $_ ne 'proposed_user_functions' && -f "$org_dir/$_" && /functions/ } readdir(D);

system("tar", "-c", "-z", "-f", "$jdir/pristine_annotations.tgz", "-C", $job->org_dir,
       @fn_files, "Features", "Subsystems", "annotations", "evidence.codes");
