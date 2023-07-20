use strict;
use DBMaster;
use FIG_Config;
use Data::Dumper;
use FIG;

my $user;
my $job;
my $stages;
my $sge_status;
my $running_only;

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

my $all = $d->Job->get_objects($job_spec);

for my $j (sort { $b->id <=> $a->id } @$all)
{
    my $n = $j->genome_name;
    my $gid = $j->genome_id;
    my $id = $j->id;
    my $dir = $j->dir;
    my $created = $j->created_on();

    my $user = $j->owner->login;

    my $final = $d->Status->get_objects({ job => $j, stage => "status.final" });
    print join("\t", $id, $created, $gid, $n, $user, $dir, (ref($final->[0]) ? $final->[0]->status : 'incomplete')), "\n";
}
