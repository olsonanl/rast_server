

=head1 check_jobs.pl

Check the status of the jobs in the 48-hour run queue to see if any 
action should be taken.

Actions taken are determined based on the metadata kept in meta.xml.

We do a quick check by looking for the file ACTIVE in the job directory.
If this file does not exist, the job should not be considered.

=cut

    
use strict;
use FIG;
use FIG_Config;
use GenomeMeta;
use Data::Dumper;
use Tracer;
use Job48;
use Mail::Mailer;

print "Jobs: ",$FIG_Config::rast_jobs , "\n";

my @jobs = Job48::all_jobs();
print "Jobs: ",$FIG_Config::rast_jobs , "\n";
my $exclude = { batch => 1 ,
		olson => 1 ,
		mkubal => 1 ,
		paczian => 1 ,
		dbartels => 1 ,
		tdisz => 1 ,
		paarmann => 1 ,
		mdsouza => 1 ,
		mcohoon => 1 ,
		arodriguez => 1 ,
		fmeyer => 1 , 
		gdpusch => 1 ,
		awilke => 1 ,
		vvons  => 1,
	      };

my %overview;

for my $job (@jobs)  {
  my $jobuser = $job->getUserObject();
  unless ($jobuser and ref $jobuser){
	print STDERR "No user for $job\n";
	next;
	}	
   print $jobuser->login."\t".$job->genome_name."\n";
  if ( $overview{ $jobuser->login }->{ $job->genome_name } ){ 
    my $nr = $overview{ $jobuser->login }->{ $job->genome_name };
    $nr++;
    $overview{ $jobuser->login }->{ $job->genome_name } = $nr;
  }
  else{
    $overview{ $jobuser->login }->{ $job->genome_name } = 1;
  }
}
  

my $nr_excluded = 0;
my $nr_external = 0;
foreach my $user ( keys %overview ){
  foreach my $genome ( keys %{ $overview{ $user } } ){
    if ( $exclude->{ $user } ){
      $nr_excluded++;
    }
    else{
      print $user , "\t" , $genome ,"\t", $overview{ $user }->{ $genome }, "\n";
      $nr_external++;
    }
  }
}

print "Jobs in current job directory = ". scalar @jobs ."\n";
print "Excluded jobs = $nr_excluded\n";
print "External jobs = $nr_external\n";

my $dbm = get_dbm();
#print scalar @{ get_user($dbm , "awilke") } , "\n";
print scalar @{ get_user($dbm) } , " Users\n";
print scalar @{ get_organisations($dbm) } , " Organisations\n";

sub get_user
{
    my($dbm, $user) = @_;
   
   
	
    my $users;
    if ( $user ){
      $users = $dbm->User->get_objects({ login => $user });
    }
    else{
      $users = $dbm->User->get_objects();
    }
    if ($users && @$users)
    {
	return $users;
    }
}
	     
 
sub get_organisations{
  my ($dbm, $org) = @_;
  my $organisations = $dbm->Organisation->get_objects();
  return $organisations;
}

sub get_dbm{

  my $old_env = $ENV{DBHOST};
  $ENV{DBHOST} = 'bioseed.mcs.anl.gov';
  my $dbm;
  eval {
    $dbm = DBMaster->new('FortyEight_WebApplication');
  };
  if ($@)
    {
      if ($@ =~ /No database name given/)
	{
	  $dbm = DBMaster->new(-database => 'FortyEight_WebApplication');
	}
      else
	{
	  die $@;
	}
    }
  return undef unless $dbm;
  $ENV{DBHOST} = $old_env;
  
  return $dbm;
}
