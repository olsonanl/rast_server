#!/usr/bin/env perl

use strict;
use IPC::Run 'run';
use Data::Dumper;
use GenomeMeta;
use Getopt::Long::Descriptive;
use Module::Metadata;
use File::Basename;
use POSIX;

my($opt, $usage) = describe_options("%c %o container jobid",
				    ['template=s' => "Override default submission template"],
				    ['replicate=s' => "Submit a replication job. Value is the source job"],
				    ['skip-sims' => "Skip similarity computation"],
				    ['sims-cpus=i' => "Number of cpus for sims computation", { default => 4 }],
				    ['dry-run' => "Do a dry run"],
				    ["output-directory|o=s" => "Slurm output directory"],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit if $opt->help;
die($usage->text) if @ARGV < 2;

my $container = shift;
my $job = shift;

my $skip = $opt->skip_sims;

if (-f $container)
{
    my $info;
    my $ok = run(['singularity', 'inspect', $container], '>', \$info);
    if (!$ok)
    {
	die "Failed to inspect container $container\n";
    }
    print "Submitting job $job to container $container with metadata:\n$info\n";
}
else
{
    die "Container $container not present\n";
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
    $template = "$lib/rast-slurm-template.tt";
}

#
# Determine our output directory. If we didn't specify, we will
# write output to slurm-output in the job directory.
#

my $output_dir = $opt->output_directory;
if (!$output_dir)
{
    $output_dir = "/vol/rast-prod/jobs/$job/slurm-output";
    -d $output_dir or mkdir($output_dir) or die "Cannot create output directory $output_dir: $!";
}

open(LOG, ">>", "/vol/rast-prod/jobs/$job/slurm-submit.log");
    
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
    my $meta = GenomeMeta->new(undef, "/vol/rast-prod/jobs/$job/meta.xml");
    if (lc($meta->get_metadata("annotation_scheme")) eq 'rasttk')
    {
	print "Skipping sims for rasttk\n";
	$meta->set_metadata("skip_sims", 1);
	$skip = 1;
    }
    
    #
    # If we are skipping sims, we can submit a single job.
    # Otherwise we submit three with dependencies.
    #
    
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--container", $container,
		       "--template", $template,
		       "--output-directory", $output_dir);
    
    
    if ($skip)
    {
	my $out;
	my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
	my $ok = run([@submit_prog, "--phase", "1", "--phase", "2", "--phase", "4", $job], ">", \$out);
	print $out if ($opt->dry_run);
	$ok or die  "phase 124 submit failed with $?";
	my($p1) = $out =~ /(\d+)/;
	print "Submitted phase 124 job $p1\n";
	print LOG "$now: Submitted phase 124 job $p1\n";
    }
    else
    {
	my $out;
	my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
	my $ok = run([@submit_prog, "--phase", "1", "--phase", "2", $job], ">", \$out);
	print $out if ($opt->dry_run);
	$ok or die  "phase 12 submit failed with $?";
	my($p1) = $out =~ /(\d+)/;
	print "Submitted phase 12 job $p1\n";
	print LOG "$now: Submitted phase 12 job $p1\n";
	
	$out = '';
	$now = strftime('%Y-%m-%d %H:%M:%S', localtime);
	$ok = run([@submit_prog, "--phase", "3", "--cpus", 4, "--tasks", $opt->sims_cpus, "--depend", $p1, $job], ">", \$out);
	print $out if ($opt->dry_run);
	$ok or die  "phase 3 submit failed with $?";
	my($p3) = $out =~ /(\d+)/;
	print "Submitted phase 3 job $p3\n";
	print LOG "$now: Submitted phase 3 job $p3\n";
	
	$out = '';
	$now = strftime('%Y-%m-%d %H:%M:%S', localtime);
	$ok = run([@submit_prog, "--phase", "4", "--depend", $p3, $job], ">", \$out);
	print $out if ($opt->dry_run);
	$ok or die  "phase 4 submit failed with $?";
	my($p4) = $out =~ /(\d+)/;
	print "Submitted phase 4 job $p4\n";
	print LOG "$now: Submitted phase 4 job $p4\n";
    }
}

sub submit_replicate
{
    my @submit_prog = ("rast-submit-rast-job-phase",
		       ($opt->dry_run ? ("--dry-run") : ()),
		       "--replicate", $opt->replicate,
		       "--container", $container,
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


