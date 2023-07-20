
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Carp 'croak';

@ARGV == 6 or die "Usage: $0 job-dir task-start task-end NR peg.synonyms keep-count\n";

my $job_dir = shift;
my $task_start = shift;
my $task_end = shift;
my $sims_nr = shift;
my $sims_peg_synonyms = shift;
my $sims_keep_count = shift;

#
# See if we have the id-length btree.
#
my $sims_nr_len = $sims_nr;
if (-f "$sims_nr-len.btree")
{
    $sims_nr_len = "$sims_nr-len.btree";
}
    

-d $job_dir or die "$0: job dir $job_dir does not exist\n";

my $job = basename($job_dir);

my $genome = &FIG::file_head("$job_dir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $job_dir\n";

my $meta = new GenomeMeta($genome, "$job_dir/meta.xml");

#
# Submit a prepared sims job.
#
    
my $sge_job_id;

eval {
    $sge_job_id = sge_submit($meta,
			     "-e $job_dir/sge_output -o $job_dir/sge_output " .
			     "-N rp_s_$job -v PATH -b yes -t $task_start-$task_end -pe smp 2",
			     "$FIG_Config::bin/rp_compute_sims $job_dir");
};
if ($@)
{
    my $err = $@;
    $meta->set_metadata("sims.running", "no");
    $meta->set_metadata("status.sims", "error");
    $meta->add_log_entry($0, ["sge submit failed", $err]);
    warn "submit failed: $err\n";
    exit 1;
}

#
# Also submit the postprocessing job, held on the sims run.
#

my $pp_sge_id;
eval {
    
    $pp_sge_id = sge_submit($meta,
			    "-e $job_dir/sge_output -o $job_dir/sge_output " .
			    "-N rp_ps_$job -v PATH -b yes -hold_jid $sge_job_id -l bigdisk -l high -l localdb",
			    "$FIG_Config::bin/rp_postproc_sims $job_dir $sims_nr_len $sims_peg_synonyms $sims_keep_count");
};

if ($@)
{
    my $err = $@;
    $meta->set_metadata("sims.running", "no");
    $meta->set_metadata("status.sims", "error");
    $meta->add_log_entry($0, ["sge postprocess submit failed", $err]);
    warn "submit failed: $err\n";
    system("qdel", $sge_job_id);
    exit 1;
}
$meta->set_metadata("sims.running", "yes");
$meta->set_metadata("status.sims", "queued");

$meta->set_metadata("sims.sge_job_id", $sge_job_id);
$meta->set_metadata("sims.sge_postproc_job_id", $pp_sge_id);
$meta->add_log_entry($0, ["submitted sims job", $sge_job_id]);
$meta->add_log_entry($0, ["submitted postprocess job", $pp_sge_id]);
print STDERR "Submitted, job id is $sge_job_id\n";

#
# stolen from check_jobs.pl.
#
sub sge_submit
{
    my($meta, $sge_args, $cmd) = @_;

    my @sge_opts;
    if (my $res = $meta->get_metadata("lustre_resource"))
    {
	push @sge_opts, -l => $res;
    }
    push(@sge_opts, get_sge_deadline_arg($meta));
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
}

