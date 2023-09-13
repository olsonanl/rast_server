package FIG_Config;

$fortyeight_jobs = "/vol/rast-prod/jobs";
$rast_jobs = $fortyeight_jobs;
$general_jobdir = "/vol/rast-prod/global/jobs";

$rast_job_floor= 1357867;
$rast_sims_data = '/vol/rast-prod/NR-SEED/nr.with.phages';

$sim_chunk_size = 4_000_000;
$rapid_propagation_script = "rapid_propagation4";

$clearinghouse_url = 'http://clearinghouse.theseed.org/Clearinghouse/clearinghouse_services.cgi';

$FigfamsData = "/vol/figfam-prod/Default";

$try_sim_server = 1;
my $shost = "aspen.cels.anl.gov:7121";
$sim_server_url = "http://$shost/simserver/perl/sims.pl";

$daily_statistics_dir = "/vol/public-pseed/SharedData/DailyStatistics";

1;
