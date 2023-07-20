#!/disks/patric-common/runtime/bin/perl

#
# Standalone sims computation tool.
#
# This is invoked by a cluster scheduler and is given two parameters:
#
# Index of sim to compute
# Job number
#
# From these, it can determine the task list by downloading
# http://rast.nmpdr.org/jobs/JOB/sims.job/task.list
#
# From the task list, it can determine the input and output files,
# blast parameters, and output destinations
#
# The task list columns are
#
# 1. Task index.
# 2. Input file
# 3. Database file
# 4. BLAST parameters
# 5. Output file
# 6. Error file
#
# The outputs are written using the RAST CGI rast_save_sim_output with the form variables
# job_id set to the job id, tag set to "output" or "error"
#
# The RAST task list entries will have filenames prefixed with /vol/rastsomething; that
# prefix will be stripped.
#
# We cache the NR used, along with a file named by the NR file and a .etag suffix; this is used
# to detect changes to the cached NR.
#

use strict;
use Data::Dumper;
use Getopt::Long::Descriptive;
use File::Path 'make_path';
use LWP::UserAgent;
use File::Temp;
use Carp;
use IPC::Run;
use POSIX;

$ENV{PATH} .= ":/disks/patric-common/runtime/bin";

my $url_base = "http://rast.nmpdr.org";
my $upload_url = "http://rast.nmpdr.org/rast_save_sim_output.cgi";
my $nr_cache = "/tmp/nr-cache";
make_path($nr_cache);

my($opt, $usage) = describe_options("%c %o task-index job-number",
				    ["parallel=i" => "Number of processors to use", { default => 1 }],
				    ["help|h" => "Show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 2;

my $task_id = shift;
my $job_number = shift;

if ($task_id < 0)
{
    #
    # Take from environment.
    #
    $task_id = $ENV{SLURM_ARRAY_TASK_ID};
    defined($task_id) or die "Can't find task id\n";
}

my $parallel = $ENV{SLURM_JOB_CPUS_PER_NODE};
$parallel //= $opt->parallel;


my $ua = LWP::UserAgent->new;

my $task_list_url = "$url_base/jobs/$job_number/sims.job/task.list";

my $res = $ua->get($task_list_url);

if (!$res->is_success)
{
    die "Cannot get $task_list_url: " . $res->status_line;
}

my $tl_txt = $res->content;
open(TL, "<", \$tl_txt) or die;
my($in, $db, $params, $out, $err);
while (<TL>)
{
    chomp;
    my @a = split(/\t/);
    if ($a[0] == $task_id)
    {
	(undef, $in, $db, $params, $out, $err) = @a;
	last;
    }
}
die "could not find task $task_id in job $job_number\n" unless defined($in);

my $work = File::Temp->newdir(CLEANUP => 1);

my $nr = get_nr($db, $work);

#
# We have our formatted NR. Now retrieve our input. Create a temp dir to work in.
#
print "workdir=$work\n";

my $query_file = "$work/query";
my $in_path = transform_path($in);
die "Invalid input $in" unless $in_path;
$res = $ua->get("$url_base/$in_path", ":content_file" => $query_file);
if (!$res->is_success)
{
    die "Could not download $url_base/$in_path to $query_file: " . $res->status_line;
}

#
# We can blast.
#
my @cmd = ("blastall",
	   "-a", $parallel,
	   split(/\s+/, $params),
	   "-i", $query_file,
	   "-o", "$work/stdout",
	   "-d", $nr);

my $t1 = time;
my $ok = IPC::Run::run(\@cmd, "2>", "$work/stderr");
my $t2 = time;
my $elap = $t2 - $t1;

my $min = int($elap / 60);
my $sec = $elap % 60;

open(X, ">>", "$work/stderr");
printf "%d:%02d $t1 $t2 $elap\n", $min, $sec;
printf X "%d:%02d $t1 $t2 $elap\n", $min, $sec;

if ($ok)
{
    print X "SUCCESS\n";
}
else
{
    my $err = $?;
    
    print X "Nonzero exit status $err from blastall\n";
    print STDERR "Nonzero exit status $err from blastall\n";
}
close(X);

#
# Push stdout/stderr to the server.
#

send_output($upload_url, 'output', $job_number, $task_id, "$work/stdout");
send_output($upload_url, 'error', $job_number, $task_id, "$work/stderr");

exit($ok ? 0 : 1);

sub send_output
{
    my($url, $key, $job_number, $task_id, $file) = @_;

    my @retries = (1, 2, 5, 10, 20, 60, 60, 60, 60, 60, 60, 600, 600);
    my %codes_to_retry =  map { $_ => 1 } qw(110 408 502 503 504 200) ;
    my $response;

    while (1) {
	$response = $ua->post($url, Content_Type => 'multipart/form-data',
			      Content => [key => $key,
					  job => $job_number,
					  task => $task_id,
					  file => [$file]
					  ]);
	
        if ($response->is_success) {
	    return;
        }

        #
        # If this is not one of the error codes we retry for, or if we
        # are out of retries, fail immediately
        #

        my $code = $response->code;
	my $msg = $response->message;
	my $want_retry = 0;
	if ($codes_to_retry{$code})
	{
	    $want_retry = 1;
	}
	elsif ($code eq 500 && defined( $response->header('client-warning') )
	                    && $response->header('client-warning') eq 'Internal response')
	{
	    #
	    # Handle errors that were not thrown by the web
	    # server but rather picked up by the client library.
	    #
	    # If we got a client timeout or connection refused, let us retry.
	    #

	    if ($msg =~ /timeout|connection refused|Can't connect/i)
	    {
		$want_retry = 1;
	    }

	}

        if (!$want_retry || @retries == 0) {
	    my $content = $response->content;
	    if (! $content) {
		$content = "Unknown error from server.";
	    }
	    confess $response->status_line . "\n" . $content;
        }

        #
        # otherwise, sleep & loop.
        #
        my $retry_time = shift(@retries);
        print STDERR strftime("%F %T", localtime), ": Request failed with code=$code msg=$msg, sleeping $retry_time and retrying\n";
        sleep($retry_time);

    }

    #
    # Should never get here.
    #
}

sub transform_path
{
    my($path) = @_;
    if ($path =~ m,^/vol/rast-prod[^/]*/([^/]+/.*)$,)
    {
	return $1;
    }
    return undef;
}

sub get_nr
{
    my($db, $work) = @_;

    if ($db =~ m,^/vol/rast-[^/]+(/.*peg/fasta)$,)
    {
	my $nr_file = "$work/self.fasta";
	my $url = "$url_base/$1";
	# special case of self vs self
	my $res = $ua->get($url, ":content_file" => $nr_file);
	if (!$res->is_success)
	{
	    die "Failure downloading $url to $nr_file: " . $res->status_line;
	}
	#
	# Need to format.
	#
	my $rc = system("formatdb", "-p", "t", "-i", $nr_file, "-l", "/dev/null");
	die "Formatdb on $nr_file failed with $rc" unless $rc == 0;
	return $nr_file;
	
    }
    my $path = transform_path($db);
    if ($path)
    {
	my $url = "$url_base/$path";
	my $file = $path;
	$file =~ s,/,_,g;
	
	my $res = $ua->head($url);
	if (!$res->is_success)
	{
	    die "Failed to get NR at url $url: " . $res->status_line;
	}
	my $etag = $res->header('etag');
	if ($etag !~ /^"(.+)"$/)
	{
	    die "Invalid etag '$etag'\n";
	}
	$etag = $1;
	my $dir = "$nr_cache/$etag";
	my $nr_file = "$dir/$file";
	if (! -d $dir || ! -s $nr_file)
	{
	    make_path($dir);
	    my $res = $ua->get($url, ":content_file" => $nr_file);
	    if (!$res->is_success)
	    {
		die "Failure downloading $url to $nr_file: " . $res->status_line;
	    }

	    #
	    # Need to format.
	    #
	    my $rc = system("formatdb", "-p", "t", "-i", $nr_file, "-l", "/dev/null");
	    die "Formatdb on $nr_file failed with $rc" unless $rc == 0;
	    return $nr_file;
	}

	return $nr_file;
    }
    die "Invalid db specification $db\n";
}
    
