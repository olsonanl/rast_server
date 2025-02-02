#!/usr/bin/env perl

use strict;
use IPC::Run 'run';
use Data::Dumper;
use GenomeMeta;
use Getopt::Long::Descriptive;
use Module::Metadata;
use File::Basename;
use POSIX;
use FIG_Config;

my($opt, $usage) = describe_options("%c %o jobdir",
				    ['container=s' => "Container to use "],
				    ['template=s' => "Override default submission template"],
				    ['replicate=s' => "Submit a replication job. Value is the source job"],
				    ['write-exports' => "Submit a job to recompute exports for given job dir"],
				    ['close-strains=s' => "Submit a close-strains computation job. Value is close strains dir" ],
				    ['peer-sims' => "Submit a peer-sims job."],
				    ['skip-sims' => "Skip similarity computation"],
				    ['cpus=i' => "Number of cpus", { default => 4 }],
				    ['dry-run' => "Do a dry run"],
				    ['partition=s' => "Use this partition", { default => 'rast' }],
				    ["output-directory|o=s" => "Slurm output directory"],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit if $opt->help;
die($usage->text) if @ARGV != 1;

my $jobdir = shift;

-d $jobdir or die "Job directory $jobdir does not exist\n";
my $job = basename($jobdir);

my $skip = $opt->skip_sims;

my @container_param;
if ($opt->container)
{
    if (-f $opt->container)
    {
	my $info;
	my $ok = run(['singularity', 'inspect', $opt->container], '>', \$info);
	if (!$ok)
	{
	    die "Failed to inspect container " . $opt->container . " \n";
	}
	print STDERR "Submitting job $job to container " . $opt->container . " with metadata:\n$info\n";
	@container_param = ("--container", $opt->container);
    }
    else
    {
	die "Container " . $opt->container . " not present\n";
    }
}

#
# Find our submission template.
#
my $template; 
if ($opt->template)
{
    $template = $opt->template;
}
else
{
    #
    # Assume it's in the same libdir as ClusterStage.pm, another module installed
    # in the FortyEight directory.
    #
    my $mpath = Module::Metadata->find_module_by_name("ClusterStage");
    my $lib = dirname($mpath);
    $template = "$lib/rast-slurm-template-nfs.tt";
}

#
# Determine our output directory. If we didn't specify, we will
# write output to slurm-output in the job directory.
#

my $output_dir = $opt->output_directory;
if (!$output_dir)
{
    $output_dir = "$jobdir/slurm-output";
    -d $output_dir or mkdir($output_dir) or die "Cannot create output directory $output_dir: $!";
}

open(LOG, ">>", "$jobdir/slurm-submit.log");
    
if ($opt->replicate)
{
    submit_replicate();
}
elsif ($opt->close_strains)
{
    submit_close_strains();
}
elsif ($opt->peer_sims)
{
    submit_peer_sims();
}
elsif ($opt->write_exports)
{
    submit_write_exports();
}
else
{
    submit_annotate();
}

close(LOG);

sub submit_annotate
{
    my $meta = GenomeMeta->new(undef, "$jobdir/meta.xml");

    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       @container_param,
		       "--partition" => $opt->partition,
		       "--template", $template,
		       "--cpus", $opt->cpus,
		       "--output-directory", $output_dir);

    my $jobid = basename($jobdir);

    my @sim_phase;
    if ($opt->skip_sims)
    {
	print STDERR "Skipping sims\n";
	$meta->set_metadata("skip_sims", 1);
	$skip = 1;
    }
    elsif ($meta->get_metadata("skip_sims"))
    {
	$skip = 1;
    }
    elsif ($meta->get_metadata('annotation_scheme') eq 'RASTtk' && !defined($meta->get_metadata('skip_sims')))
    {
	#
	# Hack to disable sims for rasttk (the behavior prior to the slurm update)
	#
	print STDERR "Skipping sims for rasttk job\n";
	$meta->set_metadata("skip_sims", 1);
	$skip = 1;
    }
    else
    {
	push(@sim_phase, "--phase", "3");
    }
    
    my $out;
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $ok = run([@submit_prog, "--phase", "1", "--phase", "2", @sim_phase, "--phase", "4", $jobdir], ">", \$out);
    print $out if ($opt->dry_run);
    $ok or die  "Submit failed with $?";
    my($p1) = $out =~ /(\d+)/;
    print STDERR "Submitted job $p1\n";
    print LOG "$now: Submitted job $p1\n";
}

sub submit_replicate
{
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--replicate", $opt->replicate,
		       @container_param,
		       "--partition" => $opt->partition,
		       "--template", $template,
		       "--output-directory", $output_dir);
    
    
    my $out;
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $ok = run([@submit_prog, $jobdir], ">", \$out);

    print $out if ($opt->dry_run);
	
    $ok or die  "replicate submit failed with $?";
    my($p1) = $out =~ /(\d+)/;

    print LOG "Submitted replication from " . $opt->replicate . " job $p1\n";
}


sub submit_close_strains
{
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--close-strains", $opt->close_strains,
		       @container_param,
		       "--partition" => $opt->partition,
		       "--template", $template,
		       "--cpus", $opt->cpus,
		       "--output-directory", $output_dir);
    
    
    my $out;
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $ok = run([@submit_prog, $jobdir], ">", \$out);

    print $out if ($opt->dry_run);
	
    $ok or die  "Close strains submit failed with $?";
    my($p1) = $out =~ /(\d+)/;
    print LOG "Submitted close strains job $p1\n";
}


sub submit_peer_sims
{
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--peer-sims", 
		       @container_param,
		       "--partition" => $opt->partition,
		       "--template", $template,
		       "--cpus", $opt->cpus,
		       "--output-directory", $output_dir);
    
    
    my $out;
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $ok = run([@submit_prog, $jobdir], ">", \$out);

    print $out if ($opt->dry_run);
	
    $ok or die  "Peer sims submit failed with $?";
    my($p1) = $out =~ /(\d+)/;
    print LOG "Submitted peer sims job $p1\n";
}

sub submit_write_exports
{
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--write-exports", 
		       @container_param,
		       "--partition" => $opt->partition,
		       "--template", $template,
		       "--cpus", 1,
		       "--output-directory", $output_dir);
    
    
    my $out;
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $ok = run([@submit_prog, $jobdir], ">", \$out);

    print $out if ($opt->dry_run);
	
    $ok or die  "Peer sims submit failed with $?";
    my($p1) = $out =~ /(\d+)/;
    print LOG "Submitted exports job $p1\n";
}


