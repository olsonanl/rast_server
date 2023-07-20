#
# Check the status of the timelogic sims computation.
#
# We maintain a hash in the sims job dir that is a helper for looking
# up the various pieces of data. These include
#
# 'jobid',taskid: 	timelogic job identifier
# 'status',taskid:	current job status (unknown, queued, running, done, error).
#
# Job status is marked as done when the TL has finished, and we have performed
# the first stage of postprocessing and installed the postprocessed data
# into the job directory.
#
# This assumes we are running ON the timelogic machine. In the MCS installation
# this is acheived by submission of this job to the timelogic queue.
#
# For each job that we determine has completed since the last time we ran, we
# perform the per-sim-file processing that includes
#
#    reformat_timelogic_sims		Flip format to SEED style
#    reduce_sims peg.syn hits		Reduce to <hits> sims per id.
#    reformat_sims NR.btree		Add length fields, get rid of "garbage" sims
#
# We write the processed sim files into sims.job/sims.proc/proc.taskid
#
# We also copy the raw sim files into sims.job/sims.raw/raw.taskid
#

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;
use DB_File;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $max_hits = 300;

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'check_tl_sim_status', $jobdir);

$stage or die "$0: Could not create job object";

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

my $simdir = "$jobdir/sims.job";

my $rawdir = "$simdir/sims.raw";
&FIG::verify_dir($rawdir);

my $procdir = "$simdir/sims.proc";
&FIG::verify_dir($procdir);

my $status_file = "$simdir/status.btree";
my %status;
my $status_tie;
if (-f $status_file)
{
    $status_tie = tie %status, 'DB_File', $status_file, O_RDWR, 0, $DB_BTREE;
    $status_tie or $stage->fatal("Cannot open status file $status_file: $!");
}
else
{
    $status_tie = tie %status, 'DB_File', $status_file, O_RDWR | O_CREAT, 0777, $DB_BTREE;
    $status_tie or $stage->fatal("Cannot create status file $status_file: $!");
}

#
# Walk the task list, checking for tasks that
#  a. have no timelogic identifier
#  b. have a job status of unknown, queued, or busy.
#

#
# Scan the search dir. we need this sooner or later.
#
# construct $search_status{id} => [(queued|running|done), ctl-filename]]
#
# ID here is the timelogic job identifier.
#

my(%search_status, @ctl_files, %ids_of_type );
opendir(D, "/decypher/search") or $stage->fatal("cannot opendir /decypher/search: $!");

while (my $f = readdir(D))
{
    my $path = "/decypher/search/$f";
    next unless -f $path;
    next unless $f =~ /^(.*)\.(dne|bsy|tl.*)$/;
    my $tlid = $1;
    my $suffix = $2;

    my $status;
    if ($suffix eq 'dne')
    {
	$status = "done";
    }
    elsif ($suffix eq 'bsy')
    {
	$status = "running";
    }
    else
    {
	$status = "queued";
    }
    push(@{$ids_of_type{$status}}, $tlid);

    $search_status{$tlid} = [$status, $f];
}
closedir(D);

$status_tie->sync();

open(TASK, "<$simdir/task.list") or $stage->fatal("Cannot open task list $simdir/task.list: $!");

my $tasks_done_count = 0;
my $tasks_error_count = 0;
my $tasks_count= 0;

while (<TASK>)
{
    chomp;
    my($id, $in, $nr, $args, $out, $err) = split(/\t/);

    $tasks_count++;

    #
    # See if this task is already done.
    #

    my $task_status = $status{'status', $id};
    if ($task_status eq 'done')
    {
	$tasks_done_count++;
	next;
    }
    elsif ($task_status eq 'error')
    {
	print "Task $id is in error\n";
	$tasks_error_count++;
	next;
    }

    my $tl_id = $status{'jobid', $id};
    if (!defined($tl_id))
    {
	$tl_id = find_tl_id($id, $in, \%status);
	$status{'jobid', $id} = $tl_id;
	$status_tie->sync();
    }

    my $search_rec = $search_status{$tl_id};
    if (!$search_rec)
    {
	warn "Could not find search status for task $id $tl_id\n";
	next;
    }

    my($search_status, $ctl_file) =  @$search_rec;
    print "$id $tl_id Search status=$search_status\n";

    #
    # If this task is now done, do postprocessing
    #
    if ($search_status eq 'done')
    {
	eval {
	    postprocess_task($id, $tl_id, $out);
	};
	if ($@)
	{
	    print "postproc for $id gets error: '$@'\n";
	    $stage->warning("Postprocess failed for id=$id tl_id=$tl_id: $@");
	    $tasks_error_count++;
	    $status{'status', $id} = 'error';
	}
	else
	{
	    $tasks_done_count++;
	    $status{'status', $id} = 'done';
	}
	$status_tie->sync();
    }
}

if (($tasks_done_count + $tasks_error_count) >= $tasks_count)
{
    if ($tasks_error_count > 0)
    {
	$stage->fatal("$tasks_error_count tasks returned with fatal errors");
    }
    else
    {
	$stage->log("completed");
	$stage->set_running("no");
	$stage->set_status("complete");
    }
}
else
{
    #
    # We want to rerun this stage again next time thru.
    #
    $stage->set_status("not_started");
    $stage->set_running("no");
}

sub postprocess_task
{
    my($id, $tl_id, $raw_out) = @_;

    my $tl_file = "/decypher/output/$tl_id.out";
    open(TL, "<$tl_file") or die "Cannot open TL sims file $tl_file: $!";

    my $pegsyn = "$jobdir/peg.synonyms.reduce_sims_index.btree";
    if (! -f $pegsyn)
    {
	$pegsyn = "$jobdir/peg.synonyms";
    }

    my $stage1 = "$FIG_Config::bin/reformat_timelogic_sims";
    my $stage2 = "$FIG_Config::bin/reduce_sims $pegsyn $max_hits";
    my $stage3 = "$FIG_Config::bin/reformat_sims $jobdir/nr-len.btree";

    my $proc_out = "$procdir/proc.$id";

    print "Run pipeline $stage1 | $stage2 | $stage3 > $proc_out (raw out to $raw_out)\n";

    open(PROC, "| $stage1 | $stage2 | $stage3 > $proc_out") or die "Cannot open pipeline: $! ($stage1 | $stage2 | $stage3 > $proc_out)";

    open(RAW, ">$raw_out") or die "Cannot open raw output $raw_out: $!";

    my $buf;
    while (read(TL, $buf, 4096))
    {
	print PROC $buf;
	print RAW $buf;
    }
    close(TL);
    close(PROC);
    close(RAW);
}


#
# Determine the timelogic identifier for this file.
# We do this by scanning the files in /decypher/search (caching the
# output in $status->{query_file, $id} = file).
#
sub find_tl_id
{
    my($id, $file, $status) = @_;

    my $base = basename($file);

    my $tl_id = $status->{'query_id', $base};
    if (!defined($tl_id))
    {
	warn "$tl_id not found\n";
	for my $tlid (keys %search_status)
	{
	    my($fstatus, $file) = @{$search_status{$tlid}};
	    my $path = "/decypher/search/$file";

	    warn "Search $path\n";
	    open(F, "<$path") or $stage->fatal("cannot open $path: $!");
	    
	    while (<F>)
	    {
		chomp;
		if (/Query file on client:\s*(.*)\s*$/)
		{
		    $status->{'query_id', basename($1)} = $tlid;
		    last;
		}
	    }
	    close(F);
	}
	$status_tie->sync();
	$tl_id = $status->{'query_id', $base};
    }

    return $tl_id;
}
