
package PipelineUtils;
use strict;

use base 'Exporter';

our @EXPORT = qw(sge_submit get_sge_deadline_arg find_fs_resource get_sge_priority);

sub sge_submit
{
    my($meta, $sge_args, $cmd) = @_;

    my @sge_opts;
    if (my $res = $meta->get_metadata("lustre_resource"))
    {
	push @sge_opts, -l => $res;
    }
    #
    # Require any node we run on to have the rast_qualified attribute.
    # This makes sure the operating environment on the node
    # has everything we need.
    #
    push(@sge_opts, -l => "rast_qualified");
    push(@sge_opts, get_sge_deadline_arg($meta));
    push(@sge_opts, get_sge_user_priority($meta));
    if (my $res = $meta->get_metadata("sge_priority"))
    {
	if (ref($res) eq 'ARRAY')
	{
	    push @sge_opts, @$res;
	}
	elsif (!ref($res))
	{
	    push @sge_opts, split(/\s+/, $res);
	}
    }

    my $sge_cmd = "qsub @sge_opts $sge_args $cmd";
    
    $meta->add_log_entry($0, $sge_cmd);

    if (!open(Q, "$sge_cmd 2>&1 |"))
    {
	die "Qsub failed: $!";
    }
    my $sge_job_id;
    my $submit_output;
    while (<Q>)
    {
	$submit_output .= $_;
	print "Qsub: $_";
	if (/Your\s+job\s+(\d+)/)
	{
	    $sge_job_id = $1;
	}
	elsif (/Your\s+job-array\s+(\d+)/)
	{
	    $sge_job_id = $1;
	}
    }
    $meta->add_log_entry($0, ["qsub_output", $submit_output]);
    if (!close(Q))
    {
	die "Qsub close failed: $!";
    }

    if (!$sge_job_id)
    {
	die "did not get job id from qsub";
    }

    return $sge_job_id;
}

sub get_sge_deadline_arg
{
    my($meta) = @_;
    if ($FIG_Config::use_deadline_scheduling)
    {
	my $dl = $meta->get_metadata("sge_deadline");
	if ($dl ne '')
	{
	    if (wantarray)
	    {
		return("-dl",  $dl);
	    }
	    else
	    {
		return "-dl $dl";
	    }
	}
    }
    return;
}

sub get_sge_user_priority
{
    my($meta) = @_;
    if ($FIG_Config::use_priority_scheduling)
    {
	my $prio = $meta->get_metadata("sge_priority");
	if (defined($prio))
	{
	    return $prio;
	}
	else
	{
	    return;
	}
    }
}

sub find_fs_resource
{
    my($job) = @_;
    my $fs_resource;
    if (my $fileserver = $job->find_job_fileserver())
    {
	if ($fileserver eq 'rast.mcs.anl.gov')
	{
	    $fs_resource = "-l local_rast";
	}
	elsif ($fileserver eq 'cgat.mcs.anl.gov')
	{
	    $fs_resource = "-l local_cgat";
	}
	elsif ($fileserver eq 'lustre')
	{
	    $fs_resource = "-l lustre_lustre1";
	}
    }

    return $fs_resource;
}

sub read_qstat
{
    if (!open(Q, "qstat  -f -s prs -u rastprod |"))
    {
	warn "Could not read queue status: $!\n";
	return;
    }

    my $qstat = {};
    my $finished;
    my $queue;
    my $host;
    while (<Q>)
    {
	
	if (/FINISHED JOBS/)
	{
	    $finished++;
	    undef $queue;
	    undef $host;
	    next;
	}
	if (/^([^@]+)@(\S+)/)
	{
	    $queue = $1;
	    $host = $2;
	}
	elsif (/^----/)
	{
	    undef $queue;
	    undef $host;
	}

	if (/^(\d+)\s+(.*)/)
	{
	    my $jobid = $1;
	    my $rest = $2;
	    my($uptime, $job, $user, $status, $date, $time, $slots) = split(/\s+/, $rest);
#	    print "Got job=$jobid status=$status user=$user date=$date time=$time finished=$finished\n";
	    $status = "done" if $finished;
	    my $ent = { id => $jobid, status => $status, user => $user, date => $date, time => $time, name => $job };

	    $ent->{queue} = $queue if $queue;
	    $ent->{host} = $host if $host;

	    $qstat->{$jobid} = $ent;
	}
    }
    return $qstat;
}

1;
