

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
use Tracer;
use Job48;
use Mail::Mailer;
use Mantis;
use Filesys::DfPortable;

TSetup("2 main FIG", "TEXT");

my $job_spool_dir = $FIG_Config::rast_jobs;

#
# Verify we have at least 10G of space left.
#

my $df = dfportable($job_spool_dir, 1024*1024*1024);
if (!defined($df))
{
    die "dfportable call failed on $job_spool_dir: $!";
}
if ($df->{bavail} < 10)
{
    die sprintf "Not enough free space available (%.1f GB) in $job_spool_dir", $df->{bavail};
}

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

my @jobs = sort { $a <=> $b } grep { /^\d+$/ and -d "$job_spool_dir/$_" } readdir(D);

for my $job (@jobs)
{
    check_job($job, "$job_spool_dir/$job");
}

sub check_job
{
    my($job_id, $job_dir) = @_;
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
    # If rapid progation is not complete, schedule it, unless it
    # had errored. In any event, if it's not complete, do not proceed.
    #
    if ($meta->get_metadata("status.rp") ne "complete")
    {
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

    #
    # See if we need to perform correction.
    #

    my $cor_status = $meta->get_metadata("status.correction");

    if ($cor_status ne 'complete')
    {
	if ($keep_genecalls)
	{
	    $meta->add_log_entry($0, "keep_genecalls is enabled: marking correction as complete");
	    $meta->set_metadata("status.correction", "complete");
	}
	elsif ($cor_status ne "error" and $cor_status ne 'requires_intervention')
	{
	    my $req = $meta->get_metadata("correction.request");
	    process_correction($genome, $job_id, $job_dir, $meta, $req);
	}
	elsif ($cor_status eq 'error')
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "correction");
	}
	return;
    }

    #
    # Determine if we have no errors that require user intervention.
    #

#    if ($meta->get_metadata("status.stoplight") ne "complete")
#    {
#	check_qc_status_for_intervention($genome, $job_id, $job_dir, $meta, $req);
#    }

    #
    # User interaction stoplight stuff must have completed for us to proceed.
    #
#    if ($meta->get_metadata("status.stoplight") ne "complete")
#    {
#	return;
#    }

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

    if ((my $sim_status = $meta->get_metadata("status.bbhs")) ne "complete")
    {
	if ($sim_status ne "error")
	{
	    process_bbhs($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "bbhs");
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

    if ((my $aa_status = $meta->get_metadata("status.glue_contigs")) ne "complete")
    {
	if ($aa_status ne "error")
	{
	    process_glue_contigs($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "glue_contigs");
	}
	return;
    }

    if ((my $pch_status = $meta->get_metadata("status.pchs")) ne "complete")
    {
	if ($pch_status ne "error")
	{
	    process_pchs($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "pchs");
	}
	return;
    }

    if ((my $scenario_status = $meta->get_metadata("status.scenario")) ne "complete")
    {
	if ($scenario_status ne "error")
	{
	    process_scenario($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "scenario");
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
    # If the job is marked as a JGI candidate, let it flow past. If not, we need
    # to do more thorough checks on seed submission status.
    #

    if (not $meta->get_metadata("submit.JGI"))
    {

	#
	# If this job is not even a candidate for seed inclusion, mark it as completely done.
	#

	if (not ($meta->get_metadata("submit.suggested") or $meta->get_metadata("submit.candidate")))
	{
	    print "Job not a candidate, marking as done\n";
	    mark_job_done($genome, $job_id, $job_dir, $meta);
	    return;
	}

	#
	# The job was a candidate. If it has been rejected (submit.never is set), mark it completely done.
	#

	if ($meta->get_metadata("submit.never"))
	{
	    print "Job rejected, marking as done\n";
	    mark_job_done($genome, $job_id, $job_dir, $meta);
	    return;
	}
	    

	#
	# If the job has not yet been approved, just return and check again later.
	#
	
	if (not($meta->get_metadata("submit.seed") or $meta->get_metadata("submit.nmpdr")))
	{
	    print "Job not yet checked, returning\n";
	    return;
	}

	#
	# Otherwise, it's an approved candidate, and we can go ahead and process.
	#
	print "Continuing\n";
    }

    #
    # Perform Glimmer and Critica calls if marked for JGI-teach inclusion.
    #

    if ($meta->get_metadata("submit.JGI"))
    {
	if ((my $glimmer_status = $meta->get_metadata("status.glimmer")) ne "complete")
	{
	    if ($glimmer_status ne "error")
	    {
		process_glimmer($genome, $job_id, $job_dir, $meta);
	    }
	    else
	    {
		flag_error($genome, $job_id, $job_dir, $meta, "glimmer");
	    }
	    return;
	}
	if ((my $critica_status = $meta->get_metadata("status.critica")) ne "complete")
	{
	    if ($critica_status ne "error")
	    {
		process_critica($genome, $job_id, $job_dir, $meta);
	    }
	    else
	    {
		flag_error($genome, $job_id, $job_dir, $meta, "critica");
	    }
	    return;
	}
    }

    if ((my $pfam_status = $meta->get_metadata("status.pfam")) ne "complete")
    {
	if ($pfam_status ne "error")
	{
	    process_pfam($genome, $job_id, $job_dir, $meta);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "pfam");
	}
	return;
    }

#     if ((my $cello_status = $meta->get_metadata("status.cello")) ne "complete")
#     {
# 	if ($cello_status ne "error")
# 	{
# 	    process_cello($genome, $job_id, $job_dir, $meta);
# 	}
# 	else
# 	{
# 	    flag_error($genome, $job_id, $job_dir, $meta, "cello");
# 	}
# 	return;
#     }

#     if ((my $phobius_status = $meta->get_metadata("status.phobius")) ne "complete")
#     {
# 	if ($phobius_status ne "error")
# 	{
# 	    process_phobius($genome, $job_id, $job_dir, $meta);
# 	}
# 	else
# 	{
# 	    flag_error($genome, $job_id, $job_dir, $meta, "phobius");
# 	}
# 	return;
#     }


    #
    # This job is done.
    #

    mark_job_done($genome, $job_id, $job_dir, $meta);
}

#
# Flag an error.
#
# This will send an email to the user notifying them that their job had
# an error; it copies the rast list in order to alert them that
# such an error occurred.
#
sub flag_error
{
    my($genome, $job_id, $job_dir, $meta, $stage) = @_;

    my $msg;
    if ($stage eq 'rp')
    {
	#
	# Hunt down some more details on the error.
	#

	my $err = $meta->get_metadata("rp.error");

	if ($err =~ /raw genome directory.*does not exist/ or
	    $err =~ /Unformatted contigs file.*does not exists/)
	{
	    $msg = "An error occurred during the upload of your data.";
	}
	elsif ($err =~ /reformat command failed/)
	{
	    my $f = &FIG::file_read("$job_dir/rp.errors/reformat_contigs_split.stderr");
	    if ($f =~ /File does not appear to be in FASTA/)
	    {
		$msg = "An error occurred during the parsing of your input file.";
	    }
	    else
	    {
		$msg = "An error occurred during the upload of your data.";
	    }
	}
	elsif ($err =~ /rapid_propagation command failed/ or
	       $err =~ /rapid_propagation did not create any features/)
	{
	    $msg = "An error occurred during the annotation of your data.";
	}
	elsif (-f "$job_dir/rp.errors/find_neighbors_using_figfams.stderr")
	{
	    my $ff = &FIG::file_read("$job_dir/rp.errors/find_neighbors_using_figfams.stderr");
	    if ($ff =~ /Could not find any features of sufficient length/)
	    {
		$msg = "RAST processing could not determine the phylogenetic neighborhood of your genome.\n";
		$msg .= "This may mean the genome was a fragment too small for RAST processing to be effective.";
	    }
	}
    }
    elsif ($stage eq 'qc')
    {
	$msg = "An error occurred during the quality check phase of your genome's analysis.";
    }
    elsif ($stage eq 'sims')
    {
	$msg = "An error occurred during the similarity computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'bbhs')
    {
	$msg = "An error occurred during the BBH computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'auto_assign')
    {
	$msg = "An error occurred during the automated assignment phase of your genome's analysis.";
    }
    elsif ($stage eq 'glue_contings')
    {
	$msg = "An error occurred during the postprocessing phase of your genome's analysis.";
    }
    elsif ($stage eq 'pchs')
    {
	$msg = "An error occurred during the coupling computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'scenario')
    {
	$msg = "An error occurred during the scenario computation phase of your genome's analysis.";
    }

    if (!$msg)
    {
	$msg = "An error occurred during the analysis of your genome.";
    }

    #
    # Use the mantis info if there to figure out what server this is.
    #

    my $server_info;
    if (my $mi = $FIG_Config::mantis_info)
    {
	my $system = $mi->{system};
	my $server = $mi->{server_value};
	$server_info = " in the $system $server server"
    }
    else
    {
	$server_info = "";
    }
    
    my $genome_name = &FIG::file_head("$job_dir/GENOME", 1);
    chomp $genome_name;
    my $body = <<END;
This message is regarding the RAST processing of your genome $genome_name, job number $job_id$server_info.

$msg

RAST developers will be investigating the cause of the error and possbily contacting
you for more information. 
END

    if (open(E, ">$job_dir/ERROR"))
    {
	print E "$msg\n";
	close(E);
    }
    $meta->set_metadata("genome.error", $msg);

    unlink("$job_dir/ACTIVE");

    my $job = new Job48($job_id);
    my $userobj = $job->getUserObject();
    my($email, $name);
    
    if ($userobj)
    {
	$email = $userobj->eMail();
	$name = join(" " , $userobj->firstName(), $userobj->lastName());
    }

    #
    # if we are configured for Mantis integration, notify Mantis.
    # But only if we are not the batch user.
    #

    my($bug_id, $bug_url);
    if ($FIG_Config::mantis_info and $job->user() ne 'batch')
    {
	eval {
	    my $mantis = Mantis->new($FIG_Config::mantis_info);
	    
	    ($bug_id, $bug_url) = $mantis->report_bug(stage => $stage,
						     genome => $genome,
						     genome_name => $genome_name,
						     job_id => $job_id,
						     job_dir => $job_dir,
						     user_email => $email,
						     user_name => $name,
						     meta => $meta,
						     msg => $msg);

	    $body .= "\nBug report number $bug_id has been filed in the RAST bugtracking system for this error.\n";
	    $body .= "It may be viewed at the url $bug_url\n";
	};
	if ($@)
	{
	    warn "Exception while reporting Mantis bug:\n$@\n";
	}
    }

    if ($meta->get_metadata("genome.error_notification_sent") ne "yes")
    {
	if ($email)
	{
	    my $full = $name ? "$name <$email>" : $email;
	    
	    my $mail = Mail::Mailer->new();
	    $mail->open({
		To => $full,
		Cc => 'Annotation Server <rast@mcs.anl.gov>',
		From => 'Annotation Server <rast@mcs.anl.gov>',
		Subject => "RAST annotation server error on job $job_id",
		});

	    print $mail $body;
	    $mail->close();
	    $meta->set_metadata("genome.error_notification_sent", "yes");
	    $meta->set_metadata("genome.error_notification_time", time);
	    $meta->set_metadata("genome.error_notification_sent_address", $email);
	}
    }
}

    


#
# Hm, probably nothing we can really do here.
#
sub process_upload
{
    return;
}

=head2 process_rp 

Start or check status on the rapid propagation.

=cut

sub process_rp_old
{
    my($genome, $job, $job_dir, $meta) = @_;

    #
    # See if we have started running RP here.
    #

    if ($meta->get_metadata("rp.running") eq 'yes')
    {
	Trace("RP is running for $job") if T(1);

	#
	# Is the job now done?
	#
	my $sge_id = $meta->get_metadata("rp.sge_job_id");
	my $status;
	
	if ($sge_id)
	{
	    my $stat = $qstat->{$sge_id};
	    if ($stat)
	    {
		for my $k (keys %$stat)
		{
		    my $mdk = "rp.sge_status.$k";
		    my $cur = $meta->get_metadata($mdk);
		    if ($stat->{$k} ne $cur)
		    {
			$meta->set_metadata($mdk, $stat->{$k});
		    }
		}
	    }
	    else
	    {
		$stat = { status => 'missing' };
	    }
		
	    if ($stat->{status} eq 'r')
	    {
		#
		# see if queue or host has changed
		#
		my $q = $meta->get_metadata("rp.sge_status.queue");
		my $h = $meta->get_metadata("rp.sge_status.host");
	    }
	    elsif ($stat->{status} eq 'qw')
	    {
		$meta->set_metadata('status.rp', 'queued');
	    }
	    else
	    {
		Trace("RP is done") if T(1);
		
		$meta->set_metadata("rp.running", "no");

		#
		# Need to determine if run succeeded. We say it did if a
		# genome dir got copied.
		#


		if (-d "$job_dir/rp/$genome")
		{
		    $meta->set_metadata("status.rp", "complete");
		}
		else
		{
		    $meta->set_metadata("status.rp", "error");
		}
	    }
	}
	
	return;
    }
    elsif ($meta->get_metadata('status.rp') eq 'queued')
    {
	Trace("RP queued") if T(1);
    }
	

    #
    # Otherwise, set up for run and submit.
    #

    my $tmp = "tmprp.$$";
    my $tmpdir;

    $tmpdir = "/scratch/$tmp";
    my $meta_file = $meta->get_file();

    my $errdir = "$job_dir/rp.errors";
    &FIG::verify_dir($errdir);

    &FIG::verify_dir("$job_dir/rp");
    my $cmd = "qsub -N rp_$job -e $job_dir/sge_output -o $job_dir/sge_output -v PATH -l fig_resource -b yes $FIG_Config::bin/rapid_propagation --errdir $errdir --meta $meta_file --tmpdir $tmpdir $job_dir/raw/$genome $job_dir/rp/$genome";
    $meta->add_log_entry($0, $cmd);
    if (!open(Q, "$cmd|"))
    {
	Confess("Qsub failed for job $job genome $genome in $job_dir: $!");
	$meta->add_log_entry($0, "Qsub failed for job $job genome $genome in $job_dir: $!");
	return;
    }
    my $sge_job_id;
    while (<Q>)
    {
	if (/Your\s+job\s+(\d+)/)
	{
	    $sge_job_id = $1;
	}
    }
    if (!close(Q))
    {
	$meta->add_log_entry($0, "Qsub close failed: $!");
	Confess("Qsub close failed: $!");
    }

    if (!$sge_job_id)
    {
	$meta->add_log_entry($0, "did not get job id from qsub");
	Confess("did not get job id from qsub");
    }

    Trace("Submitted, job id is $sge_job_id") if T(1);

    $meta->set_metadata("rp.sge_job_id", $sge_job_id);
    $meta->set_metadata("rp.start_time", time);
    $meta->set_metadata("rp.running", "yes");
    $meta->set_metadata("status.rp", "queued");
}
    
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
    my $cmd = "$FIG_Config::bin/rp_chunk_sims $job_dir/rp/$genome/Features/peg/fasta " .
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
				"-N rp_ps_$job -v PATH -b yes -hold_jid $sge_job_id -l fig_resource",
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

sub process_bbhs
{
    my($genome, $job, $job_dir, $meta) = @_;

    if ($meta->get_metadata("bbhs.running") eq 'yes')
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
				 "-N rp_bbh_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_compute_bbhs $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("bbhs.running", "no");
	$meta->set_metadata("status.bbhs", "error");
	$meta->add_log_entry($0, ["bbhs sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }

    $meta->set_metadata("bbhs.running", "yes");
    $meta->set_metadata("status.bbhs", "queued");

    $meta->set_metadata("bbhs.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted bbhs job", $sge_job_id]);
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
				 "-N rp_aa_$job -v PATH -b yes -l fig_resource",
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

sub process_glue_contigs
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("glue_contigs.running") eq 'yes')
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
				 "-N rp_glue_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_glue_contigs $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("glue_contigs.running", "no");
	$meta->set_metadata("status.glue_contigs", "error");
	$meta->add_log_entry($0, ["glue_contigs sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("glue_contigs.running", "yes");
    $meta->set_metadata("status.glue_contigs", "queued");
    
    $meta->set_metadata("glue_contigs.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted glue_contigs job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_pchs
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("pchs.running") eq 'yes')
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
				 "-N rp_pch_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_compute_pchs $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("pchs.running", "no");
	$meta->set_metadata("status.pchs", "error");
	$meta->add_log_entry($0, ["pchs sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("pchs.running", "yes");
    $meta->set_metadata("status.pchs", "queued");
    
    $meta->set_metadata("pchs.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted pchs job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_scenario
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("scenario.running") eq 'yes')
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
				 "-N rp_sc_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_scenarios $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("scenario.running", "no");
	$meta->set_metadata("status.scenario", "error");
	$meta->add_log_entry($0, ["scenario sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("scenario.running", "yes");
    $meta->set_metadata("status.scenario", "queued");
    
    $meta->set_metadata("scenario.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted scenario job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_glimmer
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("glimmer.running") eq 'yes')
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
				 "-N rp_gl_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_glimmer $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("glimmer.running", "no");
	$meta->set_metadata("status.glimmer", "error");
	$meta->add_log_entry($0, ["glimmer sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("glimmer.running", "yes");
    $meta->set_metadata("status.glimmer", "queued");
    
    $meta->set_metadata("glimmer.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted glimmer job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_critica
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("critica.running") eq 'yes')
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
				 "-N rp_cr_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_critica $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("critica.running", "no");
	$meta->set_metadata("status.critica", "error");
	$meta->add_log_entry($0, ["critica sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("critica.running", "yes");
    $meta->set_metadata("status.critica", "queued");
    
    $meta->set_metadata("critica.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted critica job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_pfam
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("pfam.running") eq 'yes')
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
				 "-N rp_pf_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_PFAM_attribute_generation $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("pfam.running", "no");
	$meta->set_metadata("status.pfam", "error");
	$meta->add_log_entry($0, ["pfam sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("pfam.running", "yes");
    $meta->set_metadata("status.pfam", "queued");
    
    $meta->set_metadata("pfam.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted pfam job", $sge_job_id]);
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
				 "-N rp_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_rapid_propagation $job_dir");
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
	    my $email = $userobj->eMail();
	    my $name = join(" " , $userobj->firstName(), $userobj->lastName());
	    
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
				 "-N rp_qc_$job -v PATH -b yes -l fig_resource",
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

sub process_correction
{
    my($genome, $job, $job_dir, $meta, $req) = @_;

    my $sge_job_id;

    if ($meta->get_metadata("correction.running") eq 'yes')
    {
	#
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
	#
	return;
    }

    my $req_str = join(",", @$req);

    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-N rp_cor_$job -v PATH -b yes -l fig_resource",
				 "$FIG_Config::bin/rp_correction $job_dir '$req_str'");
    };
    if ($@)
    {
	$meta->set_metadata("correction.running", "no");
	$meta->set_metadata("status.correction", "error");
	$meta->add_log_entry($0, ["correction sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }

    $meta->set_metadata("correction.running", "yes");
    $meta->set_metadata("status.correction", "queued");

    $meta->set_metadata("correction.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted correction job", $sge_job_id]);
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
	my $email = $userobj->eMail();
	my $name = join(" " , $userobj->firstName(), $userobj->lastName());

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

sub sge_submit
{
    my($meta, $sge_args, $cmd) = @_;
    
    my $sge_cmd = "qsub $sge_args $cmd";
    
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

sub process_cello
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("cello.running") eq 'yes')
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
				 "-N rp_cl_$job -v PATH -b yes",
				 "$FIG_Config::bin/rp_CELLO_attribute_generation $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("cello.running", "no");
	$meta->set_metadata("status.cello", "error");
	$meta->add_log_entry($0, ["cello sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("cello.running", "yes");
    $meta->set_metadata("status.cello", "queued");
    
    $meta->set_metadata("cello.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted cello job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}

sub process_phobius
{
    my($genome, $job, $job_dir, $meta) = @_;
    
    if ($meta->get_metadata("phobius.running") eq 'yes')
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
				 "-N rp_ph_$job -v PATH -b yes",
				 "$FIG_Config::bin/rp_PHOBIUS_attribute_generation $job_dir");
    };
    if ($@)
    {
	$meta->set_metadata("phobius.running", "no");
	$meta->set_metadata("status.phobius", "error");
	$meta->add_log_entry($0, ["phobius sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    
    $meta->set_metadata("phobius.running", "yes");
    $meta->set_metadata("status.phobius", "queued");
    
    $meta->set_metadata("phobius.sge_job_id", $sge_job_id);
    $meta->add_log_entry($0, ["submitted phobius job", $sge_job_id]);
    Trace("Submitted, job id is $sge_job_id") if T(1);
}
