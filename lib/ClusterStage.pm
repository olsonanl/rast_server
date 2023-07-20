package ClusterStage;

use FIG;
use FIG_Config;
use strict;
use Carp 'croak';
use Data::Dumper;
#
# Processing stage for check_jobs that performs a SGE submission to
# the cluster.
#
# The jobname passed in is the name of the executable to be executed
# on the cluster to handel this stage of the pipeline.
#

sub new
{
    my($class, $jobname, %opts) = @_;

    my $self = {
	jobname => $jobname,
	opts => {%opts}
    };

    return bless $self, $class;
}

#
# Process this stage via a cluster run.
#
# We will land here if the job has not started OR it has started
# but not finished. We use this opportunity to see if the job
# has vanished from the cluster. If it is not on the cluster, and
# we don't have an exit status written to the metadata, it is likely
# that the job crashed on the cluster and the exit status will
# never be set. In this event, mark the job as being in error.
#
# A job may consist of multiple SGE jobs. (a single large sims run
# may have a preprocess step, large fanout compute, and a single postprocess,
# all linked with SGE holds).
#
# In this case the stagename.sge_id vector will contain multiple
# job ids.
#
sub process
{
    my($self, $name, $job_id, $job_dir, $meta, $sge) = @_;

    my $mf_running = "${name}.running";
    my $is_running = $meta->get_metadata($mf_running);
    my $state = $meta->get_metadata("status.$name");

    print "state=$state is_running=$is_running\n";

    $self->{name} = $name;

    &FIG::verify_dir("$job_dir/sge_output");

    if ($is_running eq 'yes')
    {
	#
	# Check to see if any of the SGE job ids still exist.
	#

	my $ids = $meta->get_metadata("${name}.sge_id");
	if (!$ids)
	{
	    $self->fatal($meta, "Job is marked running, but no SGE ids have been registered");
	}

	my $running = 0;
	my $pending = 0;
	for my $id (@$ids)
	{
	    my @l = $sge->job_running($id);
	    $running += @l;
	    print Dumper(\@l);
	    my @l = $sge->job_queued($id);
	    $pending += @l;
	    print Dumper(\@l);
	}

	if ($state eq "queued")
	{
	    if ($running == 0 && $pending == 0)
	    {
		#
		# Nothing running, nothing pending. We must have croaked.
		#
		print "Job is queued, but no SGE jobs are either running or pending\n";
		$meta->set_metadata("status.$name", "error");
		$meta->set_metadata("${name}.running", "no");
		
		$self->fatal($meta, "Job is marked queued, but no SGE jobs running or pending");
	    }
	    else
	    {
		print "Job queued. Running=$running pending=$pending\n";
	    }
	}
	elsif ($state eq "running")
	{	    
	    if ($running == 0)
	    {
		#
		# If there is nothing running, and we think we should be running, it is an error.
		#
		# If there is nothing running, 
		#

		print "Job marked running, but no SGE jobs running\n";
		$meta->set_metadata("status.$name", "error");
		$meta->set_metadata("${name}.running", "no");
		$self->fatal($meta, "Job is marked running, but no SGE jobs are around any more (@$ids)");
	    }
	    else
	    {
		print "Job running. Running=$running pending=$pending\n";
	    }
	}

	#
	# Otherwise, we are okay. Just return and go about your business.
	#

	return;
    }

    #
    # Not running yet. Start up the job.
    #

    if ($self->{opts}->{start_locally})
    {
	$self->start_job_local($name, $job_id, $job_dir, $meta, $sge);
    }
    else
    {
	$self->start_job_sge($name, $job_id, $job_dir, $meta, $sge);
    }
}


#
# Start the job via an SGE submission
#
# This is for tasks that are themselves expensive
#
# Some tasks do a small amount of processing then submit jobs. Those
# should be run with start_job_local.
#
sub start_job_sge
{
    my($self, $name, $job_id, $job_dir, $meta, $sge) = @_;

    my @sge_args;

    push(@sge_args, "-N ${name}_$job_id");
    push(@sge_args, "-v PATH");
    push(@sge_args, "-e $job_dir/sge_output");
    push(@sge_args, "-o $job_dir/sge_output");
    push(@sge_args, "-b yes");

    #
    # If the user specified queue_flags, use those, and don't try to be
    # clever here.
    #

    my $opts = $self->{opts};
    print Dumper($opts);

    if (exists($opts->{sge_flag}))
    {
	my $f = $opts->{sge_flag};
	if (ref($f) eq 'ARRAY')
	{
	    push(@sge_args, @$f);
	}
	else
	{
	    push(@sge_args, $f);
	}
    }
    else
    {
	#
	# 48hr jobs get high priority
	#
	#push(@sge_args, "-l high");
	
	#
	# Pick a queue.
	#
	if (my $q = $opts->{queue})
	{
	    push(@sge_args, "-q $q");
	}
    }


    #
    # Unless the options disable it, require db.
    #

    if (not $opts->{no_localdb})
    {
	push(@sge_args, "-l localdb");
    }

    my $sge_args = join(" ", @sge_args);

    #
    # Executable is to be in the FIGdisk bin dir.
    my $exe = "$FIG_Config::bin/$self->{jobname}";
    if (! -x $exe)
    {
	$self->fatal($meta, "Executable $exe not found");
    }

    #
    # We're good to go.
    #

    my $sge_id;

    eval {
	$sge_id = $sge->submit_job($meta, $sge_args, "$exe $job_dir");
    };

    if ($@)
    {
	$self->fatal($meta, "error starting SGE job $exe $job_dir: $@\n");
    }

    #
    # OK, cool.
    #

    $meta->set_metadata("${name}.sge_id", [$sge_id]);
    $meta->set_metadata("${name}.running", "yes");
    $meta->set_metadata("status.$name", "queued");
}

#
# Start the job via a local process invocation.
#
sub start_job_local
{
    my($self, $name, $job_id, $job_dir, $meta, $sge) = @_;

    #
    # Executable is to be in the FIGdisk bin dir.
    my $exe = "$FIG_Config::bin/$self->{jobname}";
    if (! -x $exe)
    {
	$self->fatal($meta, "Executable $exe not found");
    }

    #
    # We're good to go.
    #

    my $pid = fork();

    if ($pid == 0)
    {
	my $stdout = "$job_dir/sge_output/immediate.$$.stdout";
	my $stderr = "$job_dir/sge_output/immediate.$$.stderr";

	my $cmd = "$exe $job_dir > $stdout 2> $stderr";
	print "$cmd\n";

	exec($cmd);
	die "Exec failed: $!";
    }

    my $stdout = "$job_dir/sge_output/immediate.$pid.stdout";
    my $stderr = "$job_dir/sge_output/immediate.$pid.stderr";

    my $cmd = "$exe $job_dir > $stdout 2> $stderr";
    print "$cmd\n";

    print "Waiting for $pid\n";
    waitpid($pid, 0);
    
    if ($? != 0)
    {
	$self->fatal($meta, "Cmd failed with \$?=$?: $cmd");
    }

    system("cat", $stdout);
}

sub fatal
{
    my($self, $meta, $msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status." . $self->{name}, "error");

    croak "$0: $msg";
}


1;
