

#
# Pipeline for processing RAST -> SEED import jobs
#


use strict;
use Job48;
use ClusterStage;
use ImportJob;
use SGE;
use Tracer;

TSetup("2 main FIG", "TEXT");

my $job_spool_dir = $FIG_Config::import_jobs;
if ($job_spool_dir eq '' or ! -d $job_spool_dir)
{
    die "Job directory not defined or missing\n";
}

my @jobs = ImportJob::all_jobs();

print "Jobs=" . Dumper(\@jobs);
@jobs = grep { -f $_->dir . "/ACTIVE" } @jobs;
if (@jobs > 1)
{
    die "there shoudl only be one active job\n";
}

my @stages = ([build_nr => ClusterStage->new('imp_build_nr',
					     no_localdb => 1,
					     sge_flag => ["-l", "smp"],
					    )],
	      [prepare_sims => ClusterStage->new('imp_prepare_sims',
						 #no_localdb => 1,
						 start_locally => 1,
						)],
	      [submit_tl_sims => ClusterStage->new('imp_submit_tl_sims',
						   no_localdb => 1,
						   sge_flag => ["-l", "timelogic"])],
	      [check_tl_sim_status => ClusterStage->new('imp_check_tl_sim_status',
							no_localdb => 1,
							sge_flag => ["-l", "timelogic"])],
	      [finish_tl_sims => ClusterStage->new('imp_finish_tl_sims',
						   start_locally => 1)],
	       
	      );

my $sge = new SGE;

for my $job (@jobs)
{
    check_job($job, $job->dir, \@stages, $sge);
}

sub check_job
{
    my($job, $job_dir, $stages, $sge) = @_;

    my $job_id = $job->id;
    
    Trace("Checking $job_id at $job_dir\n") if T(1);

    if (! -f "$job_dir/ACTIVE")
    {
	Trace("Skipping job $job_id as not active\n") if T(2);
	return;
    }

    if (-f "$job_dir/DONE")
    {
	Trace("Skipping job $job_id as done\n") if T(2);
	return;
    }

    my $meta = $job->meta;

    if (!$meta)
    {
	Confess("Could not create meta for $job_dir/meta.xml");
	return;
    }

    for my $stage (@stages)
    {
	my($name, $processor) = @$stage;

	my $status = $meta->get_metadata("status.$name");

	next if $status eq "complete";
	return if $status eq "error";

	#
	# Stage is not complete and not in error. Process it.
	#
	# Note that if the stage is marked as queued or running, we will
	# invoke the processor. This as designed, so that an
	# SGE-aware processor can ensure the task is still queued
	# and hasn't failed in a way that it did not get marked
	# as running.
	#

	eval {
	    if (ref($processor) eq 'CODE')
	    {
		&$processor($name, $job_id, $job_dir, $meta, $sge);
	    }
	    elsif (ref($processor))
	    {
		print Dumper($processor);
		$processor->process($name, $job_id, $job_dir, $meta, $sge);
	    }
	    else
	    {
		warn "Unknown processor " . Dumper($processor);
	    }
	};
	if ($@)
	{
	    print "Error processing job $job_id\n$@\n";
	}
	return;
    }

    #
    # This job is done.
    #

    mark_job_done( $job_id, $job_dir, $meta);
}

sub mark_job_done
{
    my($job_id, $job_dir, $meta, $req) = @_;

    if (open(D, ">$job_dir/DONE"))
    {
	print D time . "\n";
	close(D);
    }
    else
    {
	warn "Error opening $job_dir/DONE: $!\n";
    }

    my $job = new ImportJob($job_id);

    print "setting meta $meta\n";
    $meta->set_metadata("status.final","complete");
    print "setting meta $meta .. done\n";
}
