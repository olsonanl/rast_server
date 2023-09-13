

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
use File::Basename;
use Tracer;
use Job48;
use Mail::Mailer;
use Mantis;
use Filesys::DfPortable;
use JobError qw(find_and_flag_error flag_error);
use PipelineUtils;
use ANNOserver;
use Cache::Memcached::Fast;
use File::Slurp;
use IPC::Run;

die "SGE check-jobs disabled here\n";


TSetup("2 main FIG", "TEXT");

my $job_spool_dir = $FIG_Config::rast_active_jobs;
$job_spool_dir = $FIG_Config::rast_jobs if $job_spool_dir eq '';

my $usage = "check_jobs [-flush-pipeline]";

my $cache = Cache::Memcached::Fast->new({ servers => ['localhost:11212'], namespace => 'rastprod'});

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

my $sims_data_dir = $FIG_Config::rast_sims_data;

if (!defined($sims_data_dir))
{
    $sims_data_dir = $FIG_Config::fortyeight_data;
}

my $sims_nr = "$sims_data_dir/nr";
my $sims_peg_synonyms = "$sims_data_dir/peg.synonyms";
my $sims_keep_count = 300;

my $qstat = read_qstat();
#print Dumper($qstat);
#exit;

my $job_floor = 50_000;
if ($FIG_Config::rast_job_floor =~ /^\d+$/)
{
    $job_floor  = $FIG_Config::rast_job_floor;
}

my @jobs;
if (@ARGV)
{
    @jobs = grep { /^\d+$/ } @ARGV;
    print "Processing explicitly specified jobs @jobs\n";
}
else
{
    #
    # Don't read spool dir any more (too many files)
    #
    # Count from job_floor to current value of jobcounter.
    #
    my $last_job = read_file("$job_spool_dir/JOBCOUNTER");
    chomp $last_job;

    # opendir(D, $job_spool_dir) or  die "Cannot open job directory $job_spool_dir: $!\n";

    my %active_volume;

    #    for my $jid (sort { $a <=> $b } grep { /^\d+$/ } readdir(D))
    
    for my $jid ($job_floor .. $last_job)
    {
	next if $jid < $job_floor;
	my $isdir;
	$isdir = $cache->get("isdir_$jid");
	if (!defined($isdir))
	{
	    my $jpath = "$job_spool_dir/$jid";
	    my $targ = readlink($jpath);
	    print "$jpath $targ\n";
	    if ($targ)
	    {
		#
		# If we have a symbolic link, this job is in a job volume
		# that is not in the main current one. If that is the case,
		# check the job volume to see if it has an ACTIVE flag. If so,
		# we will consider this job to be a candidate for queue checking.
		#
		my $dir = dirname($targ);
		if (defined($active_volume{$dir}))
		{
		    $isdir = $active_volume{$dir};
		    print "Vol $dir already checked: $isdir\n";
		}
		else
		{
		    $isdir = -f "$dir/ACTIVE" ? 1 : 0;
		    $active_volume{$dir} = $isdir;
		    print "Vol $dir check: $isdir\n";
		}
	    }
	    else
	    {
		# Not a symlink, thus active.
		$isdir = 1;
	    }
		
	    #$isdir = (lstat "$job_spool_dir/$jid" && -d _) ? 1 : 0;
	    $cache->set("isdir_$jid", $isdir, 86400);
	}
	    
	next unless $isdir;
	push(@jobs, $jid);
    }

    # @jobs = sort { $a <=> $b } grep { /^\d+$/ and lstat "$job_spool_dir/$_" and -d _ } readdir(D);
    # closedir(D);
}
#print "@jobs\n";
#exit;

#
# Retrieve account job counts from Slurm.
#
my %acct_job_count;
my $slurm_ok;
if (open(SL, "-|", "/disks/patric-common/slurm/bin/squeue", "--noheader", "-o", "%a"))
{
    while (<SL>)
    {
	chomp;
	$acct_job_count{$_}++;
    }
    close(SL);
    $slurm_ok = 1;
}
else
{
    warn "Cannot open squeue; disabling slurm scheduling: $!\n";
}
#
# Check for our container.
#
my $rast_container = $FIG_Config::rast_container;
if (!$rast_container || ! -f $rast_container)
{
    $slurm_ok = 0;
    warn "No rast container found\n";
}

for my $job (@jobs)
{
    eval {
	check_job($job, "$job_spool_dir/$job");
    };
    if ($@)
    {
	warn "check of job $job returned error: $@";
    }
}

sub check_job
{
    my($job_id, $job_dir) = @_;
    Trace("Checking $job_id at $job_dir\n") if T(1);

    my $del = $cache->get("del_$job_id");

    if ($del)
    {
	Trace("Skipping job $job_id as queued for deletion (cached)\n") if T(2);
	return;
    }
    if (-f "$job_dir/DELETE")
    {
	Trace("Skipping job $job_id as queued for deletion\n") if T(2);
	$cache->set("del_$job_id", 1);
	return;
    }

    my $genome = $cache->get("genome_$job_id");
    if (!$genome)
    {
	$genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
	if (!$genome)
	{
	    Trace("Skipping job $job_id: no GENOME_ID\n");
	    return;
	}
	chomp $genome;
	$cache->set("genome_$job_id", $genome);
    }
    print "Genome is $genome\n";

    #
    # We need to see if the job is cancelled but we haven't done error processing yet.
    #

    if (-f "$job_dir/CANCEL" && ! -f "$job_dir/ERROR")
    {
	my $meta = new GenomeMeta($genome, "$job_dir/meta.xml");
	find_and_flag_error($genome, $job_id, $job_dir, $meta);
	return;
    }

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

    my $job48 = new Job48($job_dir);

    if (! -d "$job_dir/sge_output")
    {
	mkdir "$job_dir/sge_output";
    }

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
	#
	# See if we are a high-priority user.
	#

	my $interval = $FIG_Config::deadline_interval;
	if ($FIG_Config::high_priority_users{$job48->user})
	{
	    if ($FIG_Config::high_priority_deadline_interval > 0)
	    {
		$interval = $FIG_Config::high_priority_deadline_interval;
	    }
	}
	
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
	    my $dltime = $upload + $interval;
	    my $dlstr = strftime("%Y%m%d%H%M", localtime($dltime));
	    $meta->set_metadata("sge_deadline", $dlstr);
	}
    }

    #
    # Determine the SGE priority for this job. In the absence of other factors,
    # base it on the $FIG_Config::high_priority_users hash.
    #
    if ($FIG_Config::use_priority_scheduling)
    {
	#
	# See if we are a high-priority user.
	#

	if ($FIG_Config::high_priority_users{$job48->user} &&
	    defined(my $prio = $FIG_Config::high_priority_value))
	{
	    $meta->set_metadata("sge_priority", $prio);
	}
    }
	

    #
    # pre-pipeline processing. We decide here whether this
    # is a replicate-an-existing genome job, a job that can
    # be run in a batch of end-to-end schedule jobs,
    # or if it requires the classic pipeline to run.
    #

    if ((my $status = $meta->get_metadata("status.pre_pipeline")) ne "complete")
    {
	if ($flush_pipeline && (! -f "$job_dir/RUN_DURING_FLUSH"))
	{
	    return;
	}

	if ($status ne "error")
	{
	    process_pre_pipeline($genome, $job_id, $job_dir, $meta, $job48);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "pre_pipeline");
	}
	return;
    }

    #
    # If we are to be copying work directories to the Lustre parallel
    # filesystem, do that here based on the status.lustre_spool_job flag.
    #
    
    if ($FIG_Config::spool_onto_lustre)
    {
	if ($meta->get_metadata("status.lustre_spool_out") ne "complete")
	{
	    lustre_spool_out($genome, $job_id, $job_dir, $meta, $job48);
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
	if ($flush_pipeline && (! -f "$job_dir/RUN_DURING_FLUSH"))
	{
	    return;
	}
	
	if ($meta->get_metadata("status.rp") ne "error")
	{
	    process_rp($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_qc($genome, $job_id, $job_dir, $meta, $job48);
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
	if ($meta->get_metadata("correction.disabled"))
	{
	    $meta->add_log_entry($0, "correction.disabled is set: marking correction as complete");
	    $meta->set_metadata("status.correction", "complete");
	}
	elsif ($keep_genecalls)
	{
	    $meta->add_log_entry($0, "keep_genecalls is enabled: marking correction as complete");
	    $meta->set_metadata("status.correction", "complete");
	}
	elsif ($cor_status ne "error" and $cor_status ne 'requires_intervention')
	{
	    my $req = $meta->get_metadata("correction.request");
	    process_correction($genome, $job_id, $job_dir, $meta, $job48, $req);
	}
	elsif ($cor_status eq 'error')
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "correction");
	}
	return;
    }
    
    my $sim_status = $meta->get_metadata("status.sims");
    my $sim_preprocess_status = $meta->get_metadata("status.sims_preprocess");

    #
    # Check for sims here so we don't resubmit preprocess for everything.
    #
    if ($sim_status ne 'complete' && $sim_preprocess_status ne 'complete')
    {
	if ($sim_preprocess_status ne "error")
	{
	    preprocess_sims($genome, $job_id, $job_dir, $meta, $job48);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "sims_preprocess");
	}
	return;
    }
    
    if ((my $sim_status = $meta->get_metadata("status.sims")) ne "complete")
    {
	if ($sim_status ne "error")
	{
	    process_sims($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_bbhs($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_auto_assign($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_glue_contigs($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_pchs($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_scenario($genome, $job_id, $job_dir, $meta, $job48);
	}
	else
	{
	    flag_error($genome, $job_id, $job_dir, $meta, "scenario");
	}
	return;
    }
    
    if ((my $export_status = $meta->get_metadata("status.export")) ne "complete")
    {
	if ($export_status ne "error")
	{
	    process_export($genome, $job_id, $job_dir, $meta, $job48);
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
	mark_job_user_complete($genome, $job_id, $job_dir, $meta, $job48);
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
	
	if (not ($meta->get_metadata("import.candidate")))
	{
	    print "Job not a candidate, marking as done\n";
	    mark_job_done($genome, $job_id, $job_dir, $meta, $job48);
	    return;
	}
	
	#
	# The job was a candidate. If it has been rejected (submit.never is set), mark it completely done.
	#
	
	my $action = $meta->get_metadata("import.action");
	
	if ($action eq 'rejected')
	{
	    print "Job rejected, marking as done\n";
	    mark_job_done($genome, $job_id, $job_dir, $meta, $job48);
	    return;
	}
	
	
	#
	# If the job has not yet been approved, just return and check again later.
	#
	
	if ($action ne 'import')
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
		process_glimmer($genome, $job_id, $job_dir, $meta, $job48);
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
		process_critica($genome, $job_id, $job_dir, $meta, $job48);
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
	    process_pfam($genome, $job_id, $job_dir, $meta, $job48);
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
    
    mark_job_done($genome, $job_id, $job_dir, $meta, $job48);
}

#
# Very first stage.
#
sub process_upload
{
    return;
}

#
# Determine what we are doing with this job.
#
# We first see if status.rp has any value set. If it does, that means
# the classic pipeline has already started handling this job, and we
# should just set status.pre_pipeline to complete and stay hands off.
#
# Compute its signature and look up in the job database. If it exists there,
# note the fact and determine if there are RNA overlaps or embedded genes
# (the quality-check errors that trigger manual intervention, if
# manual intervention is requested).
#
# If there is a matching signature, AND (
#   if the user either requested automated corrections OR
#   there were no RNA overlaps or embedded genes )
# then submit a replicate-job run.
#
# Else, if the user has requested automated corrections
# then submit an end-to-end SGE batch run.
#
# Else, fall thru and let the classic pipeline run.
#

sub process_pre_pipeline
{
    my($genome, $job_id, $job_dir, $meta, $job48) = @_;

    if ($meta->get_metadata('status.rp') ne '')
    {
	$meta->set_metadata('status.pre_pipeline', 'complete');
	return;
    }

    #
    # Check to see if a Kmer version was selected. If it was not, determine the current
    # default and set the option to that version.
    #

    my $cur_ds = $meta->get_metadata("options.figfam_version");
    if ($cur_ds eq '')
    {
	my $anno = ANNOserver->new();
	my $ds_info = $anno->get_active_datasets();
	if (ref($ds_info))
	{
	    my $def = $ds_info->[0];
	    $meta->set_metadata("options.figfam_version", $def);
	    $meta->add_log_entry($0, ["setting default figfam version to $def"]);
	}
    }
	    
    my $db = DBMaster->new(-database => $FIG_Config::rast_jobcache_db,
			   -backend => 'MySQL',
			   -host => $FIG_Config::rast_jobcache_host,
			   -user => $FIG_Config::rast_jobcache_user,
			   -password => $FIG_Config::rast_jobcache_password);
    $db or warn "Cannot open job cache db, will not be able to replicate cached job";

    my $sig_fh;
    my $sig;
    if (open($sig_fh, "-|", "$FIG_Config::bin/compute_job_signature", $job_dir))
    {
	$sig = <$sig_fh>;
	chomp $sig;
	# sig needs to be a hex string
	if ($sig !~ /^[0-9a-f]+$/i)
	{
	    warn "compute_job_signature returned bad first line $sig\n";
	    undef $sig;
	}
	close($sig_fh);

	print "Got sig=$sig\n";
    }
    else
    {
	warn "compute_job_signature failed, cannot reuse precomputed job";
    }

    my $old_job;
    my $embedded;
    my $overlaps;
    
    if ($sig && $db)
    {
	my $jlist = $db->Job->get_objects( { job_signature => $sig } );
	#
	# Prefer the earliest job in the list. Also bag the should-be-bogus
	# case where this job's signature is already in the database; we
	# can't replicate onto ourself.
	#
	my @jlist = sort { $a->id <=> $b->id } grep { $_->id != $job_id } @$jlist;
	my $n = @jlist;

	if ($n)
	{
	    print STDERR "Found $n identical jobs:\n";
	    for my $j (@jlist)
	    {
		print STDERR join("\t", $j->id, $j->genome_id, $j->genome_name, $j->owner->login), "\n";
	    }

	    $old_job= $jlist[0];
	    eval {
		my $em = $old_job->metaxml->get_metadata("qc.Embedded");
		$embedded = ref($em) ? $em->[2] : 0;
		my $ov = $old_job->metaxml->get_metadata("qc.RNA_overlaps");
		$overlaps = ref($ov) ? $ov->[1] : 0;
		print "Embedded=$embedded overlaps=$overlaps\n";
	    };
	    if ($@)
	    {
		warn "Old job metadata retrieval failed: $@";
		undef $old_job;
	    }
	}
    }

    my $auto_corrections = $meta->get_metadata("correction.automatic");
    my $corrections_disabled = $meta->get_metadata("correction.disabled");
    my $no_cache = $meta->get_metadata("disable_cache");

    #
    # We have our data, now make our decision.
    #

    if ($old_job && (!$no_cache) && ($corrections_disabled || $auto_corrections || ($embedded == 0 && $overlaps == 0)))
    {
	my $old_dir = $old_job->dir;
	print STDERR "Replicating from job " . $old_job->id . "\n";

	if ($slurm_ok && $FIG_Config::slurm_user{$job48->user})
	{
	    my $output;
	    $meta->add_log_entry($0, "submitting slurm replication request for $old_dir $job_dir");
	    my $ok = IPC::Run::run(["rast-submit-rast-job", "--replicate", $old_dir, $rast_container, $job_id],
				   ">", \$output);
	    $meta->add_log_entry($0, ["rast-submit-rast-job", $output]);
	}
	else
	{
	    #
	    # Submit into the "rast" queue since that is where the disk is; this is
	    # disk-intensive.
	    #
	    my @queue = (-q => "rast");
	    @queue = ();	# until rast reboot let go anywhere
	    @queue = (-q => 'compute.q');
	    my @sge_opts = (@queue,
			    -e => "$job_dir/sge_output",
			    -o => "$job_dir/sge_output",
			    -N => "rplc_$job_id",
			    -v => "PATH",
			    -b => "yes");
	    
	    my $sge_job_id = sge_submit($meta, join(" ", @sge_opts),
					"$FIG_Config::bin/replicate_job $old_dir $job_dir");
	    $meta->set_metadata("replicate.sge_id", $sge_job_id);
	    unlink("$job_dir/ACTIVE");
	}
    }
    elsif ($auto_corrections || $corrections_disabled)
    {
	print STDERR "Running end-to-end batch job\n";
	
	if ($FIG_Config::spool_onto_lustre)
	{
	    if ($meta->get_metadata("status.lustre_spool_out") ne "complete")
	    {
		lustre_spool_out($genome, $job_id, $job_dir, $meta, $job48);
		#
		# whether it failed or not, mark complete. if it didn't fail
		# we just run from the non-lustre disk.
		#
		
		$meta->set_metadata("status.lustre_spool_out", "complete");
	    }
	}

	if ($slurm_ok && $FIG_Config::slurm_user{$job48->user})
	{
	    my $output;
	    $meta->add_log_entry($0, "submitting slurm annotation request for $job_id");
	    my $ok = IPC::Run::run(["rast-submit-rast-job", $rast_container, $job_id],
				   ">", \$output);
	    $meta->add_log_entry($0, ["rast-submit-rast-job", $output]);
	}
	else
	{
	    #
	    # We submit three jobs.
	    #
	    # Estimate the number of sims tasks for worst-case -
	    # this is the size of the contigs / 3 / 10,000.
	    # 3 to get protein char count, 10K to use the scaling factor
	    # used by rp_chunk_sims. This is likely to be a large overestimate;
	    # we may address this further as we see how it behaves. The extra tasks
	    # should just start and complete immediately. The only downside
	    # is the scheduling latency on them.
	    #
	    my $chunks;
	    my $contig_sz;
	    if (-f "$job_dir/raw/$genome/contigs")
	    {
		$contig_sz = -s _;
	    }
	    elsif (-f "$job_dir/raw/$genome/unformatted_contigs")
	    {
		$contig_sz = -s _;
	    }
	    
	    if ($contig_sz)
	    {
		$chunks = int($contig_sz / 30_000);
		$chunks = 1 if $chunks == 0;
	    }
	    else
	    {
		# guess at a default
		$chunks = 100;
	    }
	    
	    #
	    # Write the script wrappers.
	    #
	    # Adding code here to use new alternate sims computation on the Slurm cluster.
	    # Keyed on username for now.
	    #
	    
	    my $user = &FIG::file_head("$job_dir/USER", 1);
	    chomp $user;
	    
	    my @phases;
	    my $rp_resource = $FIG_Config::sge_rp_resource;
	    if ($rp_resource)
	    {
		$rp_resource = "-l $rp_resource";
	    }
	    else
	    {
		$rp_resource = "-l localdb -l bigdisk -l arch='*amd64*'";
	    }
	    $rp_resource .= " -l sapling_ok";
	    $rp_resource .= " -l anno_ok";
	    $rp_resource .= " -l fs_scratch=50000";
	    
	    my @phase_spec = (['12', 1, $rp_resource]);
	    
	    #
	    # If we are running RASTtk, skip sims.
	    #
	    if (lc($meta->get_metadata("annotation_scheme")) eq 'rasttk')
	    {
		$meta->set_metadata("skip_sims", 1);
	    }
	    
	    if (! $meta->get_metadata("skip_sims"))
	    {
		if ($FIG_Config::enable_slurm)
		{
		    push(@phase_spec, ['S', 1, "-l slurm"]);
		}
		else
		{
		    push(@phase_spec, [3, $chunks]);
		}
	    }
	    push(@phase_spec, [4, 1, "-q rast,compute.q -l mem_free=8G"]);
	    
	    for my $pent (@phase_spec)
	    {
		my($phase, $tasks, $flags) = @$pent;
		my $fh;
		my @pharg = map { "--phase $_" } split(//, $phase);
		
		my $script = "$job_dir/phase.$phase";
		open($fh, ">", $script);
		print $fh "#!/bin/sh\n";
		print $fh ". $FIG_Config::fig_disk/config/fig-user-env.sh\n";
		print $fh "$FIG_Config::bin/batch_rast @pharg $job_dir\n";
		close($fh);
		chmod(0755, $script);
		push(@phases, [$phase, $script, $tasks, $flags]);
	    }
	    
	    #
	    # common options
	    # 
	    my @sge_opts = (-e => "$job_dir/sge_output",
			    -o => "$job_dir/sge_output",
			    -v => 'PATH',
			    -b => 'yes');
	    
	    my $last_sge;
	    for my $pent (@phases)
	    {
		my($phase, $script, $tasks, $flags) = @$pent;
		
		my $name = "p${phase}_${job_id}";
		#my $name = join("_", "p", $phase, $job_id);
		my @opts = @sge_opts;
		push(@opts, -N => $name);
		push(@opts, -t => "1-$tasks") if defined($tasks);
		push(@opts, -hold_jid => $last_sge) if defined($last_sge);
		push(@opts, $flags) if defined($flags);
		
		if ($tasks)
		{
		    $meta->set_metadata("sge_job.$name.tasks", $tasks);
		}
		
		my $sge_job_id;
		eval {
		    $sge_job_id = sge_submit($meta, join(" ", @opts), $script);
		};
		if ($@)
		{
		    $meta->set_metadata("status.pre_pipeline", "error");
		    $meta->add_log_entry($0, ["pre_pipeline sge submit failed", $@]);
		    warn "Submit failed: $@\n";
		    return;
		}
		$meta->set_metadata("$name.sge_job_id", $sge_job_id);
		$last_sge = $sge_job_id;
	    }
	}
	$meta->set_metadata("status.pre_pipeline", "complete");
	#
	# Remove the ACTIVE flag, since we don't want the pipeline
	# to touch this job any more.
	#
	unlink("$job_dir/ACTIVE");
    }
    else
    {
	print STDERR "Running classic pipeline\n";
    }
    $meta->set_metadata("status.pre_pipeline", "complete");
}

#
# Set up the rp and sims.job directories to be over on the lustre space.
# Symlink back to the job dir.
#
sub lustre_spool_out
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
    for my $p ("rp", "sims.job", "rp.errors", "sge_output")
    {
	my $jpath = "$job_dir/$p";
	if (-d $jpath)
	{
	    if (!rmdir($jpath))
	    {
		warn "Nonempty directory $jpath; skipping lustre push";
		next;
	    }
	}
	elsif (-e _)
	{
	    warn "Non-directory $jpath exists; skipping lustre push";
	    next;
	}
		
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
    if ($FIG_Config::lustre_spool_dir =~ m,^/disks/([^/]+),)
    {
	$meta->set_metadata("lustre_resource", "lustre_$1");
    }
}

=head2 process_rp 

Start or check status on the rapid propagation.

=cut

sub process_rp_old
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;

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

    my @sge_opts = (-N => "rp_$job",
		    -e => "$job_dir/sge_output",
		    -o => "$job_dir/sge_output",
		    -v => 'PATH',
		    -l => 'bigdisk',
		    -l => 'localdb',
		    -b => 'yes',
		    get_sge_deadline_arg($meta),
		    );
	       
    if (my $res = $meta->get_metadata("lustre_resource"))
    {
	push @sge_opts, -l => $res;
    }

    my $cmd = "qsub  @sge_opts $FIG_Config::bin/rapid_propagation --errdir $errdir --meta $meta_file --tmpdir $tmpdir $job_dir/raw/$genome $job_dir/rp/$genome";
    
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
# Submit a job to pull sims from the sim server and otherwise
# preprocess for a sims run.
#
sub preprocess_sims
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;

    if ($meta->get_metadata("sims_preprocess.running") eq 'yes')
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
				 "-N rp_Ps_$job -v PATH -b yes -q compute.q ",
				 "$FIG_Config::bin/rp_preprocess_sims $job_dir $sims_nr $sims_peg_synonyms");
    };
    if ($@)
    {
	$meta->set_metadata("sims_preprocess.running", "no");
	$meta->set_metadata("status.sims_preprocess", "error");
	$meta->add_log_entry($0, ["sge submit failed", $@]);
	warn "submit failed: $@\n";
	return;
    }
    $meta->set_metadata("sims_preprocess.running", "yes");
    $meta->set_metadata("status.sims_preprocess", "queued");
}

#
# Process the sim calculation.
#
# Invoke rp_chunk_sims to create the input job
# REV july 09 - sims_preprocess does the chunk
# Queue a task-array job of rp_compute_sims.
# Queue a job rp_postproc_sims that is held on the taskarray job. This does
# the post-computation concatenation of the generated sims data when the sims
# have completed.
#
sub process_sims
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;

    if ($meta->get_metadata("sims.running") eq 'yes')
    {
	#
	# We're already running. we might should check for dead SGE jobs,
	# but I am going to skip that for now.
	#
	return;
    }
#     my $cmd = "$FIG_Config::bin/rp_chunk_sims -include-self $job_dir/rp/$genome/Features/peg/fasta " .
# 	        "$sims_nr $sims_peg_synonyms $job_dir/sims.job";


#     #
#     # Create chunked input.
#     #
    
#     $meta->add_log_entry($0, ["chunk", $cmd]);
#     if (!open(CHUNK, "$cmd |"))
#     {
# 	warn "$cmd failed: $!\n";
# 	$meta->add_log_entry($0, ["chunk_failed", $!]);
# 	$meta->set_metadata("sims.running", "no");
# 	$meta->set_metadata("status.sims", "error");
# 	return;
#     }

    if (!open(CHUNK, "<", "$job_dir/sims.job/chunk.out"))
    {
 	$meta->add_log_entry($0, ["error opening $job_dir/sims.job/chunk.out", $!]);
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
	warn "Tasks not found";
	$meta->add_log_entry($0, "chunk_no_task");
	$meta->set_metadata("sims.running", "no");
	$meta->set_metadata("status.sims", "error");
	return;
    }

    my @cmd = ("$FIG_Config::bin/rp_submit_sims", $job_dir, $task_start, $task_end,
	       $sims_nr, $sims_peg_synonyms, $sims_keep_count);
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	$meta->set_metadata("sims.running", "no");
	$meta->set_metadata("status.sims", "error");
	$meta->add_log_entry($0, ["sims_submit_failed", $rc, @cmd]);
	warn "Submit failed with rc=$rc: @cmd\n";
    }	
}

sub process_bbhs
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;

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
				 "-q compute.q " .
				 "-N rp_bbh_$job -v PATH -b yes -l bigdisk",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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

    #
    # Determine the fileserver the job is on for this task, and attempt to
    # schedule to the local queue for that server.
    #
    
    my $fs_resource = $meta->get_metadata("lustre_resource");

    if ($fs_resource)
    {
	$fs_resource = "-l $fs_resource";
    }
    else
    {
	# $fs_resource = &find_fs_resource($job48);
    }
    
    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-q compute.q " .
				 "-N rp_aa_$job -v PATH -b yes $fs_resource -l arch='*amd64*'",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
				 "-q compute.q " .
				 "-N rp_glue_$job -v PATH -b yes -l bigdisk",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
				 "-q compute.q " .
				 "-N rp_pch_$job -v PATH -b yes -l bigdisk",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
				 "-q compute.q " .
				 "-N rp_sc_$job -v PATH -b yes -l bigdisk",
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

sub process_export
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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

    my $fs_resource = $meta->get_metadata("lustre_resource");

    if ($fs_resource)
    {
	$fs_resource = "-l $fs_resource";
    }
    else
    {
	#$fs_resource = &find_fs_resource($job48);
    }

    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-q compute.q " .
				 "-N rp_xp_$job -v PATH -b yes $fs_resource ",
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

sub process_glimmer
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
				 "-q compute.q " .
				 "-N rp_gl_$job -v PATH -b yes -l bigdisk",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
				 "-N rp_cr_$job -v PATH -b yes -l bigdisk",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
				 "-N rp_pf_$job -v PATH -b yes -l timelogic_g3",
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;

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
    my $rp_resource = $FIG_Config::sge_rp_resource;
    if ($rp_resource)
    {
	$rp_resource = "-l $rp_resource";
    }
    else
    {
	$rp_resource = "-l localdb -l bigdisk -l arch='*amd64*'";
    }

    $rp_resource .= " -l sapling_ok";
    $rp_resource .= " -l anno_ok";
    $rp_resource .= " -l fs_scratch=50000";

    eval {
	$sge_job_id = sge_submit($meta,
				 "-e $job_dir/sge_output -o $job_dir/sge_output " .
				 "-q compute.q " .
				 "-N rp_$job -v PATH -b yes $rp_resource ",
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
    my($genome, $job_id, $job_dir, $meta, $job48) = @_;

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
sub process_qc
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;

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
				 "-q compute.q " .
				 "-N rp_qc_$job -v PATH -b yes -l bigdisk -l localdb",
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
    my($genome, $job, $job_dir, $meta, $job48, $req) = @_;

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
				 "-q compute.q " .
				 "-N rp_cor_$job -v PATH -b yes -l bigdisk -l localdb",
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
    my($genome, $job_id, $job_dir, $meta, $job48, $req) = @_;

    system("$FIG_Config::bin/send_job_completion_email", $job_dir);

    my $job = new Job48($job_id);

#     my $userobj = $job->getUserObject();

#     if ($userobj)
#     {
# 	my($email, $name);
# 	if ($FIG_Config::rast_jobs eq '')
# 	{
# 	    $email = $userobj->eMail();
# 	    $name = join(" " , $userobj->firstName(), $userobj->lastName());
# 	}
# 	else
# 	{
# 	    $email = $userobj->email();
# 	    $name = join(" " , $userobj->firstname(), $userobj->lastname());
# 	}

# 	my $full = $name ? "$name <$email>" : $email;
# 	print "send email to $full\n";
    
# 	my $mail = Mail::Mailer->new();
# 	$mail->open({
# 	    To => $full,
# 	    From => 'Annotation Server <rast@mcs.anl.gov>',
# 	    Subject => "RAST annotation server job completed"
# 	    });

# 	my $gname = $job->genome_name;
# 	my $entry = $FIG_Config::fortyeight_home;
# 	$entry = "http://www.nmpdr.org/anno-server/" if $entry eq '';
# 	print $mail "The annotation job that you submitted for $gname has completed.\n";
# 	print $mail "It is available for browsing at $entry as job number $job_id.\n";
# 	$mail->close();
#     }

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
    }
}

#
# Mark the job as utterly done.
#
sub mark_job_done
{
    my($genome, $job_id, $job_dir, $meta, $job48, $req) = @_;

    #
    # If we spooled the job out onto the lustre disk, we need to
    # spool it back. Do this via a sge-submitted job as it may
    # be time consuming.
    #

    if ($meta->get_metadata("lustre_required"))
    {
	#
	# For now mark the lustre stageback to run on the rast queue for NFS
	# loading issues.
	#
	my @sge_opts = (
			-e => "$job_dir/sge_output",
			-o => "$job_dir/sge_output",
			-N => "rp_lus_$job_id",
			-v => 'PATH',
			-b => 'yes',
			-q => 'rast',
			);
	
	if (my $res = $meta->get_metadata("lustre_resource"))
	{
	    push @sge_opts, -l => $res;
	}
	
	eval {
	    my $sge_job_id = sge_submit($meta,
				     join(" ", @sge_opts),
				     "$FIG_Config::bin/rp_lustre_finish $job_dir");
	};
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


sub process_cello
{
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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
    my($genome, $job, $job_dir, $meta, $job48) = @_;
    
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

