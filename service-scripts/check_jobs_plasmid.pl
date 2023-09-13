

=head1 check_jobs.pl

Check the status of the jobs in the 48-hour run queue to see if any 
action should be taken.

Actions taken are determined based on the metadata kept in meta.xml.

We do a quick check by looking for the file ACTIVE in the job directory.
If this file does not exist, the job should not be considered.

=cut

    
use strict;
use FIG;
use FIG_Config;
use GenomeMeta;
use Data::Dumper;
use POSIX;
use Tracer;
use Job48;
use Mail::Mailer;
use Mantis;
#use Filesys::DfPortable;
use JobError 'flag_error';
#use ImportJob;

die "Check jobs plasmid disabled here";

TSetup("2 main FIG", "TEXT");

my $job_spool_dir = $FIG_Config::rast_jobs;

my $usage = "check_jobs [-flush-pipeline]";

my $flush_pipeline;
while (@ARGV > 0 and $ARGV[0] =~ /^-/)
{
    my $arg = shift @ARGV;
    if ($arg eq '-flush-pipeline')
    {
	$flush_pipeline++;
    }
    else
    {
	die "Unknown argument $arg. Usage: $usage\n";
    }
}

#
# Verify we have at least 10G of space left.
#

#my $df = dfportable($job_spool_dir, 1024*1024*1024);
#if (!defined($df))
#{
#    die "dfportable call failed on $job_spool_dir: $!";
#}
#if ($df->{bavail} < 10)
#{
#    die sprintf "Not enough free space available (%.1f GB) in $job_spool_dir", $df->{bavail};
#}

#my $sims_data_dir = "/scratch/48-hour/Data";
#my $sims_data_dir = "/vol/48-hour/Data";

my $sims_data_dir = $FIG_Config::fortyeight_data;

my $sims_nr = "$sims_data_dir/nr";
my $sims_peg_synonyms = "$sims_data_dir/peg.synonyms";
my $sims_keep_count = 300;

opendir(D, $job_spool_dir) or  die "Cannot open job directory $job_spool_dir: $!\n";

my $qstat = read_qstat();
#print Dumper($qstat);
#exit;

#my @jobs = ImportJob::all_jobs();

#print "Jobs=" . Dumper(\@jobs);
#@jobs = grep { -f $_->dir . "/ACTIVE" } @jobs;

my @jobs = sort { $a <=> $b } grep { /^\d+$/ and -d "$job_spool_dir/$_" } readdir(D);

for my $job (@jobs)
{
#    check_job($job, $job->dir);
    check_job($job, "$job_spool_dir/$job");
}

sub check_job
{
    my($job_id, $job_dir) = @_;

    #my $job_id = $job->id;
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

    if (! -d "$job_dir/sge_output")
    {
	mkdir "$job_dir/sge_output";
    }

    my $genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
    if (!$genome)
    {
	Trace("Skipping job $job_id: no GENOME_ID\n");
	return;
    }
    chomp $genome;
    print "Genome is $genome\n";

    #my $meta = $job->meta;
    my $meta = new GenomeMeta($genome, "$job_dir/meta.xml");

    if (!$meta)
    {
	Confess("Could not create meta for $genome $job_dir/meta.xml");
	return;
    }

    #
    # Now go through the stages of life for a genome dir.
    #

    if ($meta->get_metadata("status.uploaded") ne "complete")
    {
	process_upload();
	return;
    }

    #
    # Determine if we have computed our target completion time. This will
    # be used to submit deadline schedule requests.
    #

    if ($FIG_Config::use_deadline_scheduling)
    {
	my $dl = $meta->get_metadata("sge_deadline");
	my $upload = $meta->get_metadata("upload.timestamp");
	if ($upload eq '')
	{
	    $upload = time;
	    $meta->set_metadata("upload.timestamp", $upload);
	}
	
	if ($dl eq '')
	{
	    #
	    # Compute our deadline.
	    #
	    my $dltime = $upload + $FIG_Config::deadline_interval;
	    my $dlstr = strftime("%Y%m%d%H%M", localtime($dltime));
	    $meta->set_metadata("sge_deadline", $dlstr);
	}
    }

    #
    # If we are to be copying work directories to the Lustre parallel
    # filesystem, do that here based on the status.lustre_spool_job flag.
    #

    if ($FIG_Config::spool_onto_lustre)
    {
	

	if ($meta->get_metadata("status.lustre_spool_out") ne "complete")
	{
	    lustre_spool_out($genome, $job_id, $job_dir, $meta);
	    #
	    # whether it failed or not, mark complete. if it didn't fail
	    # we just run from the non-lustre disk.
	    #

	    $meta->set_metadata("status.lustre_spool_out", "complete");
	}
    }

    #
    # If rapid progation is not complete, schedule it, unless it
    # had errored. In any event, if it's not complete, do not proceed.
    #
    if ($meta->get_metadata("status.rp") ne "complete")
    {
	#
	# If we are flushing the pipeline, return here. This keeps new jobs from
	# starting up rapid propagation.
	#
	if ($flush_pipeline)
	{
	    return;
	}
	
	if ($meta->get_metadata("status.rp") ne "error")
	{
	    process_rp($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "rp");
	}

	return;
    }

    #
    # We do not touch the QC or correction phases if keep_genecalls is enabled.
    #
    my $keep_genecalls = $meta->get_metadata("keep_genecalls");

    if ($meta->get_metadata("status.qc") ne "complete")
    {
        if ($keep_genecalls)
        {
            $meta->add_log_entry($0, "keep_genecalls is enabled: marking qc as complete");
            $meta->set_metadata("status.qc", "complete");
        }
        elsif ($meta->get_metadata("status.qc") ne "error")
        {
            process_qc($genome, $job_id, $job_dir, $meta);
        }
        else
        {
            flag_error($genome, $job_id, $job_dir, $meta, "qc");
        }

        return;
    }

    if ((my $sim_status = $meta->get_metadata("status.sims")) ne "complete")
    {
	if ($sim_status ne "error")
	{
	    process_sims($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "sims");
	}
	return;
    }

    if ((my $aa_status = $meta->get_metadata("status.auto_assign")) ne "complete")
    {
	if ($aa_status ne "error")
	{
	    process_auto_assign($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "auto_assign");
	}
	return;
    }

    if ((my $subsystem_status = $meta->get_metadata("status.subsystem_coverage")) ne "complete")
    {
	if ($subsystem_status ne "error")
	{
	    process_subsystem_coverage($genome,$job_id,$job_dir,$meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "subsystem_coverage");
	}
	return;
    }

    if ((my $export_status = $meta->get_metadata("status.export")) ne "complete")
    {
	if ($export_status ne "error")
	{
	    process_export($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "export");
	}
	return;
    }

    #
    # Here marks the end of the stock processing stages. Anything beyond is triggered
    # only if this genome is marked for inclusion into the SEED.
    #

    if ($meta->get_metadata("status.final") ne "complete")
    {
	mark_job_user_complete($genome, $job_id, $job_dir, $meta);
    }

    #
    # This job is done.
    #

    mark_job_done($genome, $job_id, $job_dir, $meta);
}


#
# Hm, probably nothing we can really do here.
#
sub process_upload
{
    return;
}

#
# Set up the rp and sims.job directories to be over on the lustre space.
# Symlink back to the job dir.
#
sub lustre_spool_out
{
    my($genome, $job, $job_dir, $meta) = @_;

    -d $FIG_Config::lustre_spool_dir or return;
    
    my $ljobdir = "$FIG_Config::lustre_spool_dir/$job";

    if (-d $ljobdir)
    {
	warn "How very odd, $ljobdir already exists\n";
    }
    else
    {
	if (!mkdir $ljobdir)
	{
	    warn "mkdir $ljobdir failed: $!";
	    return;
	}
	chmod 0777, $ljobdir;
    }
    for my $p ("rp", "sims.job")
    {
	my $path = "$ljobdir/$p";
	if (-d $path)
	{
	    if (!rmdir($path))
	    {
		warn "Nonempty directory in $path when trying to set up lustre spool\n";
		next;
	    }
	}
	&FIG::verify_dir($path);
	if (!symlink($path, "$job_dir/$p"))
	{
	    warn "symlink $path $job_dir/$p failed; $!";
	}
    }
    $meta->set_metadata("lustre_required", 1);
}

=head2 process_rp 

Start or check status on the rapid propagation.

=cut

sub read_qstat
{
    if (!open(Q, "qstat  -f -s prs |"))
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

	if (/^\s+(\d+)\s+(.*)/)
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

#
# Process the sim calculation.
#
# Invoke rp_chunk_sims to create the input job
# Queue a task-array job of rp_compute_sims.
# Queue a job rp_postproc_sims that is held on the taskarray job. This does
# the post-computation concatenation of the generated sims data when the sims
# have completed.
#
sub process_sims
{
    my($genome, $job, $job_dir, $meta) = @_;

    if ($meta->get_metadata("sims.running") eq 'yes')
    {
	#
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
	#
	return;
    }
    my $cmd = "$FIG_Config::bin/rp_chunk_sims -include-self $job_dir/rp/$genome/Features/peg/fasta " .
	        "$sims_nr $sims_peg_synonyms $job_dir/sims.job";


    #
    # Create chunked input.
    #
    
    $meta->add_log_entry($0, ["chunk", $cmd]);
    if (!open(CHUNK, "$cmd |"))
    {
	warn "$cmd failed: $!\n";
	$meta->add_log_entry($0, ["chunk_failed", $!]);
	$meta->set_metadata("sims.running", "no");
	$meta->set_metadata("status.sims", "error");
	return;
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
	warn "$cmd did not return a task";
	$meta->add_log_entry($0, "chunk_no_task");
	$meta->set_metadata("sims.running", "no");
	$meta->set_metadata("status.sims", "error");
	return;
    }

    #
    # Submit.
    #
    
    my $sge_job_id;

    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-N rp_s_$job -v PATH -b yes -t $task_start-$task_end",
				 "$FIG_Config::bin/rp_compute_sims $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("sims.running", "no");
	$meta->set_metadata("status.sims", "error");
	$meta->add_log_entry($0, ["sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }

    #
    # Also submit the postprocessing job, held on the sims run.
    #

    my $pp_sge_id;
    eval {
	
	$pp_sge_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				"-N rp_ps_$job -v PATH -b yes -hold_jid $sge_job_id -l bigdisk -l high -l localdb",
				"$FIG_Config::bin/rp_postproc_sims $job_dir $sims_nr $sims_peg_synonyms $sims_keep_count");
    };

    if ($@)
    {
	$meta->set_metadata("sims.running", "no");
	$meta->set_metadata("status.sims", "error");
	$meta->add_log_entry($0, ["sge postprocess submit failed", $@]);
	warn "submit failed: $@\n";
	system("qdel", $sge_job_id);
	return;
    }

    $meta->set_metadata("sims.running", "yes");
    $meta->set_metadata("status.sims", "queued");

    $meta->set_metadata("sims.sge_job_id", $sge_job_id);
    $meta->set_metadata("sims.sge_postproc_job_id", $pp_sge_id);
    $meta->add_log_entry($0, ["submitted sims job", $sge_job_id]);
    $meta->add_log_entry($0, ["submitted postprocess job", $pp_sge_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_auto_assign
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("auto_assign.running") eq 'yes')
    {
	#
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
	#
	return;
    }
    
    #
    # Submit.
    #
    
    my $sge_job_id;
    
    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-N rp_aa_$job -v PATH -b yes -l high -l local_cgat -l arch='*amd64*'",
				 "$FIG_Config::bin/rp_auto_assign $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("auto_assign.running", "no");
	$meta->set_metadata("status.auto_assign", "error");
	$meta->add_log_entry($0, ["auto_assign sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("auto_assign.running", "yes");
    $meta->set_metadata("status.auto_assign", "queued");
    
    $meta->set_metadata("auto_assign.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted auto_assign job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_subsystem_coverage
{
    my($genome, $job, $job_dir, $meta) = @_;

    if ($meta->get_metadata("subsystem_coverage.running") eq 'yes')
    {
        #
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
        #
        return;
    }

    #
    # Submit.
    #
    my $sge_job_id;

    eval {
        $sge_job_id = sge_submit($meta,
                                 "-e $job_dir/sge_output -o $job_dir/sge_output " .
                                 "-N rp_sc_$job -v PATH -b yes -l high",
                                 "$FIG_Config::bin/rp_subsystem_coverage_plasmid $job_dir");
    };
    if ($@)
    {
        $meta->set_metadata("subsystem_coverage.running", "no");
        $meta->set_metadata("status.subsystem_coverage", "error");
        $meta->add_log_entry($0, ["subsystem_coverage sge submit failed", $@]);
        warn "submit failed: $@\n";
        return;
    }

    $meta->set_metadata("subsystem_coverage.running", "yes");
    $meta->set_metadata("status.subsystem_coverage", "queued");

    $meta->set_metadata("subsystem_coverage.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted subsystem_coverage job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}



sub process_export
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("export.running") eq 'yes')
    {
	#
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
	#
	return;
    }
    
    #
    # Submit.
    #
    
    my $sge_job_id;
    
    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-N rp_xp_$job -v PATH -b yes -l high -l local_cgat",
				 "$FIG_Config::bin/rp_write_exports $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("export.running", "no");
	$meta->set_metadata("status.export", "error");
	$meta->add_log_entry($0, ["export sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("export.running", "yes");
    $meta->set_metadata("status.export", "queued");
    
    $meta->set_metadata("export.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted export job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

=head2 process_rp 

Start or check status on the rapid propagation.

=cut

sub process_rp
{
    my($genome, $job, $job_dir, $meta) = @_;

    if ($meta->get_metadata("rp.running") eq 'yes')
    {
	#
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
	#
	return;
    }

    #
    # Submit.
    #
    
    my $sge_job_id;

    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-N rp_$job -v PATH -b yes -l high -l bigdisk -l localdb -l arch='*amd64*'",
				 "$FIG_Config::bin/rp_rapid_propagation_plasmid $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("rp.running", "no");
	$meta->set_metadata("status.rp", "error");
	$meta->add_log_entry($0, ["rp sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }

    $meta->set_metadata("rp.running", "yes");
    $meta->set_metadata("status.rp", "queued");

    $meta->set_metadata("rp.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted rp job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

#
# Mark the job as complete as far as the user is concerned.
#
# It is still active in the pipeline until it either is processed for
# SEED inclusion, or marked to not be included.
#
sub mark_job_user_complete
{
    my($genome, $job_id, $job_dir, $meta, $req) = @_;

    my $job = new Job48($job_id);

    my $userobj = $job->getUserObject();

    if ($userobj)
    {
	my($email, $name);
	if ($FIG_Config::rast_jobs eq '')
	{
	    $email = $userobj->eMail();
	    $name = join(" " , $userobj->firstName(), $userobj->lastName());
	}
	else
	{
	    $email = $userobj->email();
	    $name = join(" " , $userobj->firstname(), $userobj->lastname());
	}

	my $full = $name ? "$name <$email>" : $email;
	print "send email to $full\n";
    
	my $mail = Mail::Mailer->new();
	$mail->open({
	    To => $full,
	    From => 'Annotation Server <rast@mcs.anl.gov>',
	    Subject => "RAST annotation server job completed"
	    });

	my $gname = $job->genome_name;
	my $entry = $FIG_Config::fortyeight_home;
	$entry = "http://www.nmpdr.org/anno-server/" if $entry eq '';
	print $mail "The annotation job that you submitted for $gname has completed.\n";
	print $mail "It is available for browsing at $entry as job number $job_id.\n";
	$mail->close();
    }

    $meta->set_metadata("status.final", "complete");

    #
    # If the job is a SEED candidate, send VV email.
    #

    if ($meta->get_metadata("submit.suggested") or
	$meta->get_metadata("submit.candidate"))
    {
	my $gname = $job->genome_name;
	my $mail = Mail::Mailer->new();
	$mail->open({
	    To => 'Veronika Vonstein <veronika@thefig.info>, Robert Olson<olson@mcs.anl.gov>',
	    From => 'Annotation Server <rast@mcs.anl.gov>',
	    Subject => "RAST job $job_id marked for SEED inclusion",
	});

	print $mail <<END;
RAST job #$job_id ($gname) was submitted for inclusion into the SEED, and has finished its processing.
END
    	$mail->close();
    }
}

#
# Mark the job as utterly done.
#
sub mark_job_done
{
    my($genome, $job_id, $job_dir, $meta, $req) = @_;

    #
    # If we spooled the job out onto the lustre disk, we need to
    # spool it back. Do this via a sge-submitted job as it may
    # be time consuming.
    #

    if ($meta->get_metadata("lustre_required"))
    {
	my @sge_opts = (
			-e => "$job_dir/sge_output",
			-o => "$job_dir/sge_output",
			-l => 'lustre_ppcfs',
			-N => "rp_lus_$job_id",
			-v => 'PATH',
			-b => 'yes',
			-l => 'high',
			-l => 'bigdisk',
			-l => "localdb",
			);
	eval {
	    my $sge_job_id = sge_submit($meta,
				     join(" ", @sge_opts),
				     "$FIG_Config::bin/rp_lustre_finish $job_dir");
	};
    }
    else
    {
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
}

sub sge_submit
{
    my($meta, $sge_args, $cmd) = @_;

    my @sge_opts;
    if ($meta->get_metadata("lustre_required"))
    {
	push @sge_opts, -l => 'lustre_ppcfs';
    }
    push(@sge_opts, get_sge_deadline_arg($meta));

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
}

sub process_qc
{
    my($genome, $job, $job_dir, $meta) = @_;

    if ($meta->get_metadata("qc.running") eq 'yes')
    {
        #
        # We're already running. we might should check for dead SGE jobs,
        # but I am going to skip that for now.
	#
        return;
    }

    #
    # Submit.
    #

    my $sge_job_id;

    eval {
        $sge_job_id = sge_submit($meta,
                                 "-e $job_dir/sge_output -o $job_dir/sge_output " .
                                 "-N rp_qc_$job -v PATH -b yes -l high -l local_cgat",
                                 "$FIG_Config::bin/rp_quality_check $job_dir");
    };
    if ($@)
    {
        $meta->set_metadata("qc.running", "no");
        $meta->set_metadata("status.qc", "error");
        $meta->add_log_entry($0, ["qc sge submit failed", $@]);
        warn "submit failed: $@\n";
        return;
    }

    $meta->set_metadata("qc.running", "yes");
    $meta->set_metadata("status.qc", "queued");

    $meta->set_metadata("qc.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted qc job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

#
# Determine if we can set the stoplight value to complete. This is the case
# if qc.embedded and qc.RNA_overlaps are both zero.
#
# If we don't automatically set the stoplight to complete, and we
# haven't done so yet, send notification email to the user.
#
sub check_qc_status_for_intervention
{
    my($genome, $job_id, $job_dir, $meta) = @_;

    my $val = $meta->get_metadata('qc.Embedded');
    my $num_embed =  $val ? $val->[1]  : 0;

    $val = $meta->get_metadata('qc.RNA_overlaps');
    my $num_overlaps =  $val ? $val->[1]  : 0;

    if ($num_embed == 0 && $num_overlaps == 0)
    {
        $meta->set_metadata("stoplight.acceptedby", "pipeline_automatic");
        $meta->set_metadata("stoplight.timestamp", time);
        $meta->set_metadata("status.stoplight", "complete");
        print "Automatically accepting quality on $job_id $genome\n";
        return;
    }

    if ($meta->get_metadata("qc.email_notification_sent") ne "yes")
    {
        my $job = new Job48($job_id);
        my $userobj = $job->getUserObject();

        if ($userobj)
        {
            my($email, $name);
            if ($FIG_Config::rast_jobs eq '')
            {
                $email = $userobj->eMail();
                $name = join(" " , $userobj->firstName(), $userobj->lastName());
            }
            else
            {
                $email = $userobj->email();
                $name = join(" " , $userobj->firstname(), $userobj->lastname());
            }

            my $full = $name ? "$name <$email>" : $email;
            print "send notification email to $full\n";

            my $mail = Mail::Mailer->new();
            $mail->open({
                To => $full,
                From => 'Annotation Server <rast@mcs.anl.gov>',
                Subject => "RAST annotation server job needs attention"
                });

            my $gname = $job->genome_name;
            my $entry = $FIG_Config::fortyeight_home;
            $entry = "http://www.nmpdr.org/anno-server/" if $entry eq '';
            print $mail "The annotation job that you submitted for $gname needs user input before it can proceed further.\n";
            print $mail "You may query its status at $entry as job number $job_id.\n";
            $mail->close();
            $meta->set_metadata("qc.email_notification_sent", "yes");
            $meta->set_metadata("qc.email_notification_sent_address", $email);
        }
    }
}

