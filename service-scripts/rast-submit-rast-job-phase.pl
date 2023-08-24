#!/vol/patric3/cli/runtime/bin/perl

#
# Submit a phase or set of phases of one or more RAST jobs to slurm. This is the lower level script
# used by rast-submit-rast-job to do the actual submissions.
#
# If we are invoked with --replicate old-dir, run a replication job. In this case, no phase
# may be specified, and only one jobid may be provided.
#

use Data::Dumper;
use Getopt::Long::Descriptive;
use strict;
use Template;
use File::Slurp;
use File::Basename;
use IPC::Run qw(run);

my($opt, $usage) = describe_options("%c %o jobdir [jobdir...]",
				    ['container=s' => "Container to use for job execution"],
				    ['template=s' => "Job submission template"],
				    ['replicate=s' => "Run a replication job. Parameter is the job to replicate from"],
				    ['close-strains=s' => "Submit a close-strains computation job. Value is close strains dir" ],
				    ['phase=s@' => "Job phase to run"],
				    ['depend=i' => "Job number to depend on before this can run"],
				    ['tasks=i' => "Run task array job with this many tasks"],
				    ['cpus=i' => "Number of cpus", { default => 1 }],
				    ['dry-run' => "Do a dry run (don't submit)"],
				    ['partition=s' => "Use this partition", { default => 'rast' }],
				    ["output-directory|o=s" => "Slurm output directory", { default => "/vol/rast-prod/slurm-output" }],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit if $opt->help;
die($usage->text) if @ARGV < 1;

my $app;

my @job_dirs = @ARGV;

my %what;
$what{phase}++ if $opt->phase;
$what{replicate}++ if $opt->replicate;
$what{close_strains}++ if $opt->close_strains;

if (keys %what > 1)
{
    die "Only one of --phase, --replicate, and --close-strains may be specified";
}

if ($opt->phase)
{
    $app = "annotate";
}
elsif ($opt->close_strains)
{
    $app = "close_strains";
}
else
{
    if (@job_dirs > 1)
    {
	die "Only one job id may be specified for replication";
    }
    $app = "replicate";

    if (! -d $opt->replicate)
    {
	die "Replication source job does not exist: " . $opt->replicate;
    }
}

my $container = $opt->container;

if ($container)
{
    -f $container or die "Container $container is not present\n";
}

my $template = $opt->template;
$template or die "Template parameter is required\n";
-f $template or die "Template $template is not present\n";

my @jobs;

my %vars = (container_repo_url => 'https://p3.theseed.org/containers',
	    cluster_temp => '/disks/tmp',
	    close_strains_dir => $opt->close_strains,
	    container_filename => '',
	    container_cache_dir => '',
	    container_image => $container,
	    jobs => \@jobs,
	    n_cpus => $opt->cpus,
	    phases => $opt->phase,
	    application => $app,
	    partition => $opt->partition,
	    rast_installation => $ENV{KB_TOP},
	   );

my $account;

my @job_ids;
for my $dir (@job_dirs)
{
    my $user = read_file("$dir/USER");
    chomp $user;
    $user .= '@rast.nmpdr.org';

    if ($account && $account ne $user)
    {
	die "All jobs submitted must have the same owner\n";
    }
    $account = $user;

    my $job_id = basename($dir);
    push(@job_ids, $job_id);
    -d $dir or die "Job directory $dir does not exist\n";
    my $job = { id => $job_id,
		directory => $dir,
	       };

    if ($opt->replicate)
    {
	$job->{old_directory} = $opt->replicate;
    }
    push(@jobs, $job);
}

$vars{sbatch_account} = $account;
if ($opt->phase)
{
    $vars{sbatch_job_name} = "R" . join("", @{$opt->phase}) . "-" . join(",", @job_ids);
}
elsif ($opt->close_strains)
{
    $vars{sbatch_job_name} = "CS" . "-" . join(",", @job_ids);
}
else
{
    $vars{sbatch_job_name} = "Rpl" . "-" . join(",", @job_ids);
}
$vars{sbatch_job_mem} = "16G";
$vars{sbatch_output} = $opt->output_directory . "/slurm-%j.out";
$vars{sbatch_error} = $opt->output_directory . "/slurm-%j.err";
$vars{sbatch_time} = "8:00:00";

my $template = Template->new(ABSOLUTE => 1);
my $batch;
my $ok = $template->process($opt->template, \%vars, \$batch);
$ok or die "Error processing template: " . $template->error() . "\n" .  Dumper(\%vars);

my @params;

if ($opt->tasks)
{
    push(@params, "-a", "1-" . $opt->tasks);
}

if ($opt->depend)
{
    push(@params, "-d", "afterany:" . $opt->depend);
}

push(@params, "--parsable");

my @cmd = ("sbatch", @params);
if ($opt->dry_run)
{
    print "Would run: @cmd\n";
    print $batch;
}
else
{
    my($output, $error);

    my $ok = run(\@cmd, 
		 '<', \$batch,
		 '>', \$output,
		 '2>', \$error);
    if (!$ok)
    {
	if ($error =~ /Invalid account/)
	{
	    create_account($account);
	    my $ok = run(\@cmd, 
			 '<', \$batch,
			 '>', \$output,
			 '2>', \$error);

	    if (!$ok)
	    {
		die "Submission failed after creating account: $error\n";
	    }
	}
	else
	{
	    die "Submission failed: $error\n";
	}
    }
    print "$output\n";
}


sub create_account
{
    my($account) = @_;

    #
    # Attempt to add the account.
    #
    my @cmd = ("sacctmgr", "-i",
	       "create", "account",
	       "name=$account",
	       "fairshare=1",
	       "cluster=patric",
	       "parent=rast",
	       );
    my($stderr, $stdout);
    print STDERR "@cmd\n";
    my $ok = run(\@cmd, ">", \$stderr, "2>", \$stdout);
    if ($ok)
    {
	print STDERR "Account created: $stdout\n";
    }
    elsif ($stderr =~ /Nothing new added/)
    {
	print STDERR "Account $account apparently already present\n";
    }
    else
    {
	warn "Failed to add account $account: $stderr\n";
    }
	
    #
    # Ensure the current user has access to this new account.
    #
    @cmd = ("sacctmgr", "-i",
	    "add", "user", "rastprod",
	    "cluster=patric",
	    "Account=$account");
    $ok = run(\@cmd,
	      "2>", \$stderr);
    if (!$ok)
    {
	warn "Error $? adding account $account to user rastprod via @cmd\n$stderr\n";
    }
    
}
