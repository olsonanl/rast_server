use strict;
use DBMaster;
use FIG_Config;
use Data::Dumper;
use FIG;
use PipelineUtils;

my $user;
my $job;
my $stages;
my $sge_status;
my $running_only;

use Getopt::Long;

if (!GetOptions("user=s" => \$user,
		"job=i" => \$job,
		"stages" => \$stages,
		"running" => \$running_only,
		"sge-status=s" => \$sge_status,
	       ))
{
    die "Usage: $0 [--user login] [--job email]\n";
}

my $qstat = PipelineUtils::read_qstat();

my      $dbmaster = DBMaster->new(-database => $FIG_Config::webapplication_db || "WebAppBackend",
				-host     => $FIG_Config::webapplication_host || "localhost",
				-user     => $FIG_Config::webapplication_user || "root",
				-password => $FIG_Config::webapplication_password || "");

my $user_obj;

if ($user)
{
    $user_obj = $dbmaster->User->init({ login => $user });
}

my $d = DBMaster->new(-database => $FIG_Config::rast_jobcache_db,
		      -backend => 'MySQL',
		      -host => $FIG_Config::rast_jobcache_host,
		      -user => $FIG_Config::rast_jobcache_user);

my $job_spec = {};

$job_spec->{owner} = $user_obj if ($user_obj);
$job_spec->{id} = $job if $job;

my $all = $d->Job->get_objects($job_spec);

for my $j (sort { $b->id <=> $a->id } @$all)
{
    my $n = $j->genome_name;
    my $id = $j->id;
    my $dir = $j->dir;

    next unless -d $dir;

    my $done = -f $j->dir . '/DONE' ? 'DONE' : '';
    next if $running_only && $done;
    
    my $err = -f $j->dir . '/ERROR' ? 'ERROR' : '';
    next if $running_only && $err;
    
    my $act = -f $j->dir . '/ACTIVE' ? 'ACTIVE' : '';
    my $user = $j->owner->login;

    my $status_txt;
    my $keep;

    if ($j->metaxml)
    {
	for my $key ( grep { /sge_job_id/ } $j->metaxml->get_metadata_keys())
	{
	    my $sge_id = $j->metaxml->get_metadata($key);
	    my $stat = $qstat->{$sge_id};
	    
	    $key =~ s/\.sge_job_id//;

	    $keep++ if $sge_status && $stat->{status} eq $sge_status;

	    if ($stat)
	    {
		undef $stat->{host} unless $stat->{status} eq 'r';
		$status_txt .= "\t$key\t$sge_id\t$stat->{status}\t$stat->{host}\n";
	    }
	}
    }

    next unless $keep or !$sge_status;

    print "$id\t$user\t$n\t$act\t$done\t$err\n";

    if ($stages)
    {
	for my $stage (@{$j->stages})
	{
	    my $d = $j->metaxml->get_metadata($stage);
	    print "\t$stage\t$d\n";
	}
    }

    print $status_txt;

    my @ids;
}
