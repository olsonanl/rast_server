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
				    ['skip-sims' => "Skip similarity computation"],
				    ['cpus=i' => "Number of cpus", { default => 4 }],
				    ['dry-run' => "Do a dry run"],
				    ['partition=s' => "Use this partition", { default => 'shared' }],
				    ["output-directory|o=s" => "Slurm output directory"],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit if $opt->help;
die($usage->text) if @ARGV != 1;

my $jobdir = shift;

-d $jobdir or die "Job directory $jobdir does not exist\n";
my $job = basename($jobdir);

my $skip = $opt->skip_sims;

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
	print "Submitting job $job to container " . $opt->container . " with metadata:\n$info\n";
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
		       ($opt->container ? ("--container", $opt->container) : ()),
		       "--partition" => $opt->partition,
		       "--template", $template,
		       "--cpus", $opt->cpus,
		       "--output-directory", $output_dir);

    my @sim_phase;
    if ($opt->skip_sims)
    {
	print "Skipping sims\n";
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
    print "Submitted job $p1\n";
    print LOG "$now: Submitted job $p1\n";
}

sub submit_replicate
{
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--replicate", $opt->replicate,
		       "--container", $opt->container,
		       "--template", $template,
		       "--output-directory", $output_dir);
    
    
    my $out;
    my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $ok = run([@submit_prog, $job], ">", \$out);

    print $out if ($opt->dry_run);
	
    $ok or die  "replicate submit failed with $?";
    my($p1) = $out =~ /(\d+)/;
    print "Submitted replication from " . $opt->replicate . " job $p1\n";
    print LOG "Submitted replication from " . $opt->replicate . " job $p1\n";
}


