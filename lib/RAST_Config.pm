package FIG_Config;

$fortyeight_jobs = "/scratch/olson/RAST/jobs";
$rast_jobs = "/scratch/olson/RAST/jobs";

$rast_sims_data = '/vol/rast-prod/NR-SEED/nr.with.phages';

$sim_chunk_size = 4_000_000;
$rapid_propagation_script = "rapid_propagation4";

$clearinghouse_url = 'http://clearinghouse.theseed.org/Clearinghouse/clearinghouse_services.cgi';

$FigfamsData = "/vol/figfam-prod/Default";

$try_sim_server = 1;
my $shost = "gum.mcs.anl.gov";
$sim_server_url = "http://$shost/simserver/perl/sims.pl";

$daily_statistics_dir = "/vol/public-pseed/SharedData/DailyStatistics";

1;

