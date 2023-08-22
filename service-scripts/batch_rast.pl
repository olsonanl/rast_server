
use strict;
use Data::Dumper;

use Carp;
use Job48;
use FIG_Config;
use FIG;
use Getopt::Long;
use File::Basename;
use JobError qw(flag_error);
#
# Run a jobdirectory in one shot. For batch offload to a remote cluster that
# doesn't have our scheduler, etc available.
#

#
# Stages are as follows; for now this is a copy and paste exercise from
# FortyEight/check_jobs.pl. Use caution, don't run with scissors.
#

#
# upload
# rp
# Check status of keep_genecalls, then qc
# Check status of correction, then correction
# preprocess_sims
# sims
# bbhs
# auto_assign
# glue_contigs
# pchs
# scenario
# export
#

my $parallel = 1;
my @phase;
my $skip_sims;

my $usage = "Usage: $0 [--parallel N] -phase N [--phase N ..] jobdir\n";

if (!GetOptions("parallel=i" => \$parallel,
		"skip-sims" => \$skip_sims,
		"phase=s" => \@phase))
{
    die $usage;
}
    
@ARGV == 1 or die $usage;

@phase > 0 or die $usage;
my %phase = map { $_ => 1 } @phase;

my $job_dir = shift;
-d $job_dir or die "$0: Job dir $job_dir does not exist\n";

my $job_id = basename($job_dir);

sub sync_job
{
    system("rast_sync", "-job", $job_id);
}

#
# Only write process startup log if we're not doing sims
# or we're not in the SGE context. Otherwise we are
# flaying the NFS locking system badly.
#
my $log_subprocesses;
if (!$phase{3} || ($ENV{SGE_TASK_ID} eq '' || $ENV{SGE_TASK_ID} < 2))
{
    $log_subprocesses++;
}

if (-f "$job_dir/CANCEL")
{
    die "Job exiting due to earlier CANCEL\n";
}

my $job = new Job48($job_dir);

my $sims_data_dir = $FIG_Config::rast_sims_data;

if (!defined($sims_data_dir))
{
    $sims_data_dir = $FIG_Config::fortyeight_data;
}

my $sims_nr = "$sims_data_dir/nr";
my $sims_peg_synonyms = "$sims_data_dir/peg.synonyms";
my $sims_keep_count = 300;

my $job48 = new Job48($job_dir);
my $meta = $job48->meta;

if ($skip_sims)
{
    $meta->set_metadata("skip_sims", 1);
}

my $host = `hostname`;
chomp $host;
$meta->add_log_entry($0, "Running phases @phase on $host") if $log_subprocesses;

#
# Emulate execution of SGE parallel environment via the
# --parallel N argument.
#
if ($parallel > 1)
{
    $ENV{PE} = 'cluster';
    $ENV{NSLOTS} = $parallel;
}

if ($phase{1})
{
    &do_upload($job);
    sync_job();
    &do_rp($job);
    sync_job();
}

if ($phase{2})
{
    &do_qc($job);
    sync_job();
    &do_correction($job);
    sync_job();
    &do_sims_preprocess($job);
    sync_job();
    #
    # After we've preprocessed we know how many tasks we actually need.
    # If our SGE job has more than that, we can prune it away.
    #
    # We can determine that because the metadata flag
    # sge_job.p_3_<jobid>.tasks will be set to the number of tasks.
    #
}

if ($phase{3})
{
    #
    # If running inside a SGE task array job, execute
    # our task. Otherwise run all of them.
    #
    if ($ENV{SGE_TASK_ID})
    {
	&run("$FIG_Config::bin/rp_compute_sims", $job->dir);
    }
    else
    {
	&do_sims_diamond($job);
    }
    sync_job();
}

if ($phase{S})
{
    #
    # We are to submit a slurm batch job to compute the sims
    # and await its completion.
    #
    # Read the task list to determine the number of tasks to submit.
    #

    my $ntasks = 0;
    if (open(TL, "<", "$job_dir/sims.job/task.list"))
    {
	while (<TL>)
	{
	    $ntasks++;
	}
	close(TL);
    }
    else
    {
	fail($job_dir, "Cannot open sims task list $job_dir/sims.job/task.list: $!");
    }
    my @cmd = ("/disks/patric-common/slurm/bin/sbatch",
	       "--parsable",
	       "-M", "maas",
	       "-C", "sim",
	       "-D", "/tmp",
	       "--export", "NONE,PATH=/disks/rast/bin:/vol/rast-prod/FIGdisk/FIG/bin:/bin:/usr/bin",
	       "--job-name", "R-" . $job->id,
	       "-a", "1-$ntasks",
	       "-A", "rast",
	       "--mem", "6G",
	       "--wrap", "standalone-sims -- -1 " . $job->id,
	       "--cpus-per-task", 4,
	       "-n", 1);
    print STDERR "Submit with @cmd\n";
    open(SUB, "-|", @cmd) or fail($job_dir, "Cannot run submit @cmd: $!");
    my $batch_job;
    my $cluster;
    while (<SUB>)
    {
	print STDERR "Submit output: $_";
	if (/^(\d+)(;(\S+))?/)
	{
	    $batch_job = $1;
	    $cluster = $3;
	}
    }
    close(SUB);
    if (!$batch_job)
    {
	fail($job_dir, "Unable to get batch job id from @cmd");
    }

    #
    # Await completion.
    #
    my @cluster = ("-M", $cluster) if $cluster;
    while (1)
    {
	my $n = 0;
	print STERR "Check queue for $batch_job\n";
	open(QCHK, "-|", "/disks/patric-common/slurm/bin/squeue", "--noheader", "-j", $batch_job, @cluster) or fail($job_dir, "Cannot run squeue --noheader: $!");
	while (<QCHK>)
	{
	    print STDERR $_;
	    if (/^\s+\d/)
	    {
		$n++;
	    }
	}
	my $rc = close(QCHK);

	if (!$rc)
	{
	    print STDERR "squeue close failed: rc=$rc child_error=$?\n";
	}
	elsif ($n == 0)
	{
	    print STDERR "Job $batch_job complete\n";
	    last;
	}
	sleep(60);
    }
}

if ($phase{4})
{
    &do_sims_postprocess($job);
    sync_job();
    &do_bbhs($job);
    sync_job();
    &do_auto_assign($job);
    sync_job();
    &do_glue_contigs($job);
    sync_job();
    &do_pchs($job);
    sync_job();
    # &do_scenario($job);
    &do_export($job);
    sync_job();
    &mark_job_user_complete($job);
    sync_job();
}

sub do_upload
{
    my($job) = @_;
    return;
}

sub do_rp
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_rapid_propagation", $job->dir);
}

sub do_qc
{
    my($job) = @_;

    if ($job->meta->get_metadata("keep_genecalls"))
    {
	$job->meta->add_log_entry($0, "keep_genecalls is enabled: marking qc as complete");
	$job->meta->set_metadata("status.qc", "complete");
	return;
    }

    &run("$FIG_Config::bin/rp_quality_check", $job->dir);
}

sub do_correction
{
    my($job) = @_;

    if ($job->meta->get_metadata("keep_genecalls"))
    {
	$job->meta->add_log_entry($0, "keep_genecalls is enabled: marking correction as complete");
	$job->meta->set_metadata("status.correction", "complete");
	return;
    }

    my $correction_list = $job->meta->get_metadata("correction.request");

    if (ref($correction_list))
    {
	my $correction_str = join(",", @$correction_list);
	&run("$FIG_Config::bin/rp_correction", $job->dir, $correction_str);
    }
}

sub do_sims_preprocess
{
    my($job) = @_;

    &run("$FIG_Config::bin/rp_preprocess_sims", $job->dir, $sims_nr, $sims_peg_synonyms);
    
}

sub do_sims_diamond
{
    my($job) = @_;

    &run("$FIG_Config::bin/rp_compute_sims_diamond", $job->dir);
}

sub do_sims
{
    my($job) = @_;

    if (!open(CHUNK, "<", $job->dir.  "/sims.job/chunk.out"))
    {
	fail($job_dir, "Error opening $job_dir/sims.job/chunk.out: $!");
    }
	
    #
    # Extract created task ids
    #
    
    my($task_start, $task_end);
    while (<CHUNK>)
    {
	print;
	chomp;
	if (/^tasks\s+(\d+)\s+(\d+)/)
	{
	    $task_start = $1;
	    $task_end = $2;
	}
    }
    close(CHUNK);
    
    if (!defined($task_start))
    {
	fail($job_dir, "Tasks not found");
    }

    for my $task ($task_start .. $task_end)
    {
	$ENV{SGE_TASK_ID} = $task;
	&run("$FIG_Config::bin/rp_compute_sims", $job->dir);
    }
}

sub do_sims_postprocess
{
    my($job) = @_;
    
    my $sims_nr_len = $sims_nr;
    if (-f "$sims_nr-len.btree")
    {
	$sims_nr_len = "$sims_nr-len.btree";
    }

    &run("$FIG_Config::bin/rp_postproc_sims", $job->dir, $sims_nr_len, $sims_peg_synonyms, $sims_keep_count);
}

sub do_bbhs
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_compute_bbhs", $job->dir);
}

sub do_auto_assign
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_auto_assign", $job->dir);
}

sub do_glue_contigs
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_glue_contigs", $job->dir);
}

sub do_pchs
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_compute_pchs", $job->dir);
}

sub do_scenario
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_scenarios", $job->dir);
}

sub do_export
{
    my($job) = @_;
    &run("$FIG_Config::bin/rp_write_exports", $job->dir);
}

sub mark_job_user_complete
{
    my($job) = @_;

    my $job_dir = $job->dir;
    my $meta = $job->meta;
    my $job_id = $job->id;

    system("$FIG_Config::bin/send_job_completion_email", $job_dir);

    $meta->set_metadata("status.final", "complete");

    #
    # If the job is a SEED candidate, send VV email.
    #

    if ($meta->get_metadata("import.suggested") or
	$meta->get_metadata("import.candidate"))
    {
	my $gname = $job->genome_name;
	my $mail = Mail::Mailer->new();
	$mail->open({
	    To => 'Veronika Vonstein <veronika@thefig.info>, Robert Olson<olson@mcs.anl.gov>, Andreas Wilke<wilke@mcs.anl.gov>',
	    From => 'Annotation Server <rast@mcs.anl.gov>',
	    Subject => "RAST job $job_id marked for SEED inclusion",
	});

	print $mail <<END;
RAST job #$job_id ($gname) was submitted for inclusion into the SEED, and has finished its processing.
END
    	$mail->close();

	#
	# We also mark the job as ACTIVE again so that the
	# normal post-seed-acceptance pipeline stages may execute.
	#
	open(F, ">$job_dir/ACTIVE");
	close(F);
    }
    else
    {
	#
	# Otherwise it is completely done.
	#
	&mark_job_done($job);
    }
}

sub mark_job_done
{
    my($job) = @_;

    #
    # If we spooled the job out onto the lustre disk, we need to
    # spool it back. 
    #

    my $meta = $job->meta;
    my $job_dir = $job->dir;
    
    if ($meta->get_metadata("lustre_required"))
    {
	&run("$FIG_Config::bin/rp_lustre_finish", $job_dir);
    }
    if (open(D, ">$job_dir/DONE"))
    {
	print D time . "\n";
	close(D);
    }
    else
    {
	warn "Error opening $job_dir/DONE: $!\n";
    }
    
    unlink("$job_dir/ACTIVE");
}

sub run
{
    my(@cmd) = @_;

    my $cmd_str = join(" ", @cmd);
    print "Start: $cmd_str\n";
    $meta->add_log_entry($0, ['Start', $cmd_str]) if $log_subprocesses;
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	$meta->add_log_entry($0, ['Failed', $rc, $cmd_str]);
	print STDERR "Failed: $rc $cmd_str\n";
	if (open(FH, ">", "$job_dir/CANCEL"))
	{
	    print FH "Cancel job due to error in $0 @cmd\n";
	    close(FH);
	}
	#
	# Attempt to qdel any other parts of this job that are queued or running.
	# Only if we are running in the SGE environment.
	#
	if ($ENV{SGE_ARCH} ne '')
	{
	    my @jobs;
	
	    for my $k ($meta->get_metadata_keys())
	    {
		if ($k  =~ /p_.*\.sge_job_id/)
		{
		    my $job_id = $meta->get_metadata($k);
		    #
		    # Don't qdel this job.
		    #
		    if ($job_id =~ /^\d+$/ && $job_id != $ENV{JOB_ID})
		    {
			push(@jobs, $job_id);
		    }
		    
		}
	    }
	    if (@jobs)
	    {
		my $rc2 = system("qdel", @jobs);
		print "qdel @jobs returned $rc2\n";
		$meta->add_log_entry($0, "Qdel @jobs due to failure returned status $rc2") if $log_subprocesses;
	    }
	}
	
	confess "Cmd failed with rc=$rc: $cmd_str\n";
    }
    $meta->add_log_entry($0, ['Done', $cmd_str]) if $log_subprocesses;
    print "Done: $cmd_str\n";
}

#
# Use JobError to mark error and quit.
#
sub fail
{
    my($job_dir, $msg) = @_;

    my $job_id = basename($job_dir);
    my $genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
    chomp $genome;

    my $meta = GenomeMeta->new($genome, "$job_dir/meta.xml");
    flag_error($genome, $job_id, $job_dir, $meta, undef, $msg);
    die "Failing with error: $msg";
}
