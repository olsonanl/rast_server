package RAST::RASTShared;

use strict;
use warnings;

use base qw( Exporter );
our @EXPORT = qw ( get_menu_job );

1;


sub get_menu_job {
  my ($menu, $job) = @_;
 
  if ($job) {
    my $jobmenu = 'Manage Job #'.$job->id;
    $menu->add_category($jobmenu, "?page=JobDetails&job=".$job->id);
    $menu->add_entry($jobmenu, 'Debug this job', 
      'rast.cgi?page=JobDebugger&job='.$job->id, undef, [ 'debug' ]);
    $menu->add_entry($jobmenu, 'Change job priority', 
      'rast.cgi?page=JobPriority&job='.$job->id, undef, [ 'debug' ]);
    $menu->add_entry($jobmenu, 'Delete this job', 
      'rast.cgi?page=JobDelete&job='.$job->id, undef, ['delete', 'genome', $job->genome_id ]);
    $menu->add_entry($jobmenu, 'Compare this job', 'rast.cgi?page=GenomeStatistics&job='.$job->id, undef, [ 'debug' ]);
  }

  return 1;

}
