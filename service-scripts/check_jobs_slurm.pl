

=head1 check_jobs.pl

Check the status of the jobs in the 48-hour run queue to see if any 
action should be taken.

Actions taken are determined based on the metadata kept in meta.xml.

We do a quick check by looking for the file ACTIVE in the job directory.
If this file does not exist, the job should not be considered.

This version submits to the BV-BRC slurm scheduler.

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

TSetup("2 main FIG", "TEXT");

my $job_spool_dir = $FIG_Config::rast_active_jobs;
$job_spool_dir = $FIG_Config::rast_jobs if $job_spool_dir eq '';

my $usage = "check_jobs [-flush-pipeline]";

my $cache = Cache::Memcached::Fast->new({ servers => ['localhost:11211'], namespace => 'rastprod'});

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

my $job_floor = 0;

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

    my %active_volume;

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
}
#print "@jobs\n";
#exit;

#
# Check for our container.
#
my $rast_container = $FIG_Config::rast_container;
if (!$rast_container || ! -f $rast_container)
{
#    warn "No rast container found\n";
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

    #
    # pre-pipeline processing. We decide here whether this
    # is a replicate-an-existing genome job, a job that can
    # be run in a batch of end-to-end schedule jobs,
    # or if it requires the classic pipeline to run.
    #


    #
    # The Slurm pipeline only does the following:
    #
    # Ignore a job if we are flushing and it's not marked as running during flush
    # Runs the job
    #
    
    if ($flush_pipeline && (! -f "$job_dir/RUN_DURING_FLUSH"))
    {
	return;
    }

    process_pre_pipeline($genome, $job_id, $job_dir, $meta, $job48);
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

    #
    # We assume we always have auto corrections.
    #
    my $auto_corrections = $meta->get_metadata("correction.automatic");
    $auto_corrections = 1;
    
    my $corrections_disabled = $meta->get_metadata("correction.disabled");
    my $no_cache = $meta->get_metadata("disable_cache");

    #
    # We have our data, now make our decision. Either run a replication job
    # or an annotation job.
    #

    my @container;
    if ($rast_container)
    {
	@container = ("--container", $rast_container);
    }

    if ($old_job && (!$no_cache) && ($corrections_disabled || $auto_corrections || ($embedded == 0 && $overlaps == 0)))
    {
	my $old_dir = $old_job->dir;
	print STDERR "Replicating from job " . $old_job->id . "\n";

	my $output;
	$meta->add_log_entry($0, "submitting slurm replication request for $old_dir $job_dir");
	my $ok = IPC::Run::run(["rast-submit-rast-job", "--replicate", $old_dir, @container, $job_dir],
			       ">", \$output);
	$meta->add_log_entry($0, ["rast-submit-rast-job", $output]);
    }
    else
    {
	print STDERR "Running end-to-end batch job\n";
	
	my $output;
	$meta->add_log_entry($0, "submitting slurm annotation request for $job_id");
	my $ok = IPC::Run::run(["rast-submit-rast-job", @container, $job_dir],
			       ">", \$output);
	$meta->add_log_entry($0, ["rast-submit-rast-job", $output]);
    }
    $meta->set_metadata("status.pre_pipeline", "complete");
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

