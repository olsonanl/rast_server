package RAST::Job;

use strict;
use warnings;
use FIG;
use GenomeMeta;
use Data::Dumper;

use DirHandle;
use File::Basename;
use IO::File;
use Fcntl ':flock';

1;

=pod

=head1 NAME

Job - RAST job wrapper which syncs directory to database

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<init> ()

Initialise a new instance of the Job object. This overwritten version of the 
method will sync the directory to the database if necessary

=cut

sub init {
  my $self = shift;

  # check if we are called properly
  unless (ref $self) {
    die "Not called as an object method.";
  }

  # parameters for the Job->init() call
  my $data = $_[0];
  unless (ref $data eq 'HASH') {
    die "Init without a parameters hash.";
  }

  # if called with id, immediately obtain a lock
  my $locked;
  if (exists($data->{id})) {

    # abort, if directory does not exist
    unless (-d $FIG_Config::rast_jobs.'/'.$data->{id}) {
      warn "No such job (id: ".$data->{id}.").\n";
      #
      # Try to init hte job from the db anyway, so we can delete
      # it & clean up the database for deleted jobdirs.
      #
      my $job = $self->SUPER::init(@_);
      if ($job)
      {
	  $job->delete();
      }
      return undef;
    }

    $locked = $self->lock_directory($data->{id});
  }

  my $job = $self->SUPER::init(@_);

  # the job does not exist in cache if true
  my $new = 0;
  unless (ref $job) {

    # fail, if there's no id
    unless (exists($data->{id})) {
      return undef;
      #die "Unable to auto synchronize job without job id.";
    }

    # abort, if scheduled for deletion
    if (-f $FIG_Config::rast_jobs.'/'.$data->{id}.'/DELETE') {
      warn "[SYNC] Job scheduled for deletion (id: ".$data->{id}.").\n";
      $self->unlock_directory();
      return undef;
    }

    # create it
    $job = $self->SUPER::create({ id => $data->{id} });
    unless (ref $job) {
      die "Failed to create job with id ".$data->{id};
    }
    $new = 1;
  }

  # if not locked by now, do it
  unless ($locked) {
    $locked = $self->lock_directory($job->id);
  }

  eval {
    $job->sync_from_directory();
  };
  if ($@) {
    $@ =~ /^(.+) at \//;
    my $err = $1 || $@;
    print STDERR "[SYNC] Error during job sync: $err\n";
    $job->delete if ($new);
    return undef;
  }
  
  # release job directory
  $self->unlock_directory();

  return $job;
}


=pod 

=item * B<directory> ()

Returns the full path the job directory (without a trailing slash).

=cut

sub directory {
  return $FIG_Config::rast_jobs.'/'.$_[0]->id;
}

# for backwards compatability:
sub dir {
  return $_[0]->directory;
}


=pod 

=item * B<org_dir> ()

Returns the full path the organism directory inside the job (without a trailing slash).

=cut

sub org_dir {
  return $_[0]->directory.'/rp/'.$_[0]->genome_id;
}


=pod 

=item * B<download_dir> ()

Returns the full path the download directory inside the job (without a trailing slash).

=cut

sub download_dir {
  return $_[0]->directory.'/download';
}


=pod 

=item * B<analysis_dir> ()

Returns the full path the analysis directory inside the job (without a trailing slash).

=cut

sub analysis_dir {
  unless (-d $_[0]->directory.'/analysis') {
    chdir($_[0]->directory) or 
      die("Unable to change directory to ".$_[0]->directory.": $!");
    mkdir "analysis", 0777 or 
      die("Unable to create directory analysis in ".$_[0]->directory.": $!");
  }
  return $_[0]->directory.'/analysis';
}



=pod

=item * B<sync_from_directory> ()

Checks the modification date of the database vs the directory. Re-reads the
directory content if necesssary.

=cut

sub sync_from_directory {
  my ($self) = @_;

  # check for deletion
  if ($self->to_be_deleted) {
    return $self->delete;
  }

  # check if meta.xml got updated
  my $mod = (stat($self->directory.'/meta.xml'))[9];
  unless ($mod) {
    die "Unable to read modification time of meta.xml in ".$self->directory."\n";
  }
  my $mod_str = &mysql_date($mod);

  unless ($self->last_modified and $self->last_modified eq $mod_str) {
 
    my $dir = $self->directory;

    if (-f "$dir/METAGENOME")
    {
	$self->type('Metagenome');
	eval {
	    $self->server_version($self->mgrast2() ? 2 : 1);
	};
    }
    else
    {
	$self->type('Genome');
	if (my($version) = $self->directory() =~ m,/vol/rast-([^/]+),)
	{
	    eval {
		$self->server_version($version);
	    };
	}
    }
	
    my $active = -f "$dir/ACTIVE" || 0;
    $self->active($active);

    $self->last_modified($mod_str);

    my $genome_id = &FIG::file_head("$dir/GENOME_ID", 1);
    chomp $genome_id;
    # put a test for duplicate genome_id id here
    $self->genome_id($genome_id); 

    my $genome_name = &FIG::file_head("$dir/GENOME", 1);
    chomp $genome_name;
    $self->genome_name($genome_name);

    my $project_name = &FIG::file_head("$dir/PROJECT", 1);
    chomp $project_name;
    $self->project_name($project_name);

    my $creation = $self->metaxml->get_metadata('upload.timestamp');
    if ($creation) {
      $self->created_on(&mysql_date($creation));
    }

    my $viewable = ($self->ready_for_browsing) ? 1 : 0;
    $self->viewable($viewable);

    #
    # Eval for backward compatbility with older job db.
    #
    eval {
	$self->genome_bp_count($self->metaxml->get_metadata('genome.bp_count'));
	$self->genome_contig_count($self->metaxml->get_metadata('genome.contig_count'));
    };

    # get owner
    my $login = &FIG::file_head("$dir/USER", 1);
    chomp $login;

    #
    # Check for a remapped user name; this s used for the set of user names
    # that were changed during the mgrast 1->2 transition.
    #
    my $new;
    if (defined($new = $FIG_Config::user_remap{$login}) and $new ne '')
    {
	$login = $new;
    }
    
    my $dbm = DBMaster->new(-database => $FIG_Config::webapplication_db,
			    -backend => $FIG_Config::webapplication_backend,
			    -host => $FIG_Config::webapplication_host,
			    -user => $FIG_Config::webapplication_user,
			    -password => $FIG_Config::webapplication_password,
			   );
    my $user = $dbm->User->init({ login => $login });
    if (ref $user) {
      
      # check rights
      my $rights = [ 'view', 'edit', 'delete' ];
      foreach my $right_name (@$rights) {
	unless(scalar(@{$dbm->Rights->get_objects({ scope       => $user->get_user_scope,
						    data_type   => 'genome',
						    data_id     => $genome_id,
						    name        => $right_name,
						    granted     => 1,
						  }) })
	      ) {
	  my $right = $dbm->Rights->create({ scope       => $user->get_user_scope,
					     data_type   => 'genome',
					     data_id     => $genome_id,
					     name        => $right_name,
					     granted     => 1,
					   });
	  unless (ref $right) {
	    die "Unable to create Right $right_name - genome - $genome_id.";
	  }
	}
	if ($self->type eq 'Metagenome') {
	  unless(scalar(@{$dbm->Rights->get_objects({ scope       => $user->get_user_scope,
						      data_type   => 'metagenome',
						      data_id     => $genome_id,
						      name        => $right_name,
						      granted     => 1,
						    }) })
		) {
	    my $right = $dbm->Rights->create({ scope       => $user->get_user_scope,
					       data_type   => 'metagenome',
					       data_id     => $genome_id,
					       name        => $right_name,
					       granted     => 1,
					     });
	    unless (ref $right) {
	      die "Unable to create Right $right_name - metagenome - $genome_id.";
	    }
	  }
	}
      }
					  
      $self->owner($user);
    }
    else {
      die "Unable to find user in database: $login";
    }

    
    # load import keys if the job was suggested for import
    my $suggested = $self->metaxml->get_metadata('import.candidate');
    if ($suggested) {

      # try to fetch from database or create
      my $import = $self->_master->Import->init({ job => $self });
      unless (ref $import) {
	$import = $self->_master->Import->create({ job => $self });
      }

      # update import values from meta.xml
      if (ref $import) {
	$import->update();
      }
      else {
	die "Unable to create import object.";
      }
    }


    # update stages
    foreach my $stage (@{$self->stages}) {
      my $status = $self->metaxml->get_metadata($stage);
      if ($status) {
	my $s = $self->_master->Status->init({ stage => $stage, job => $self });
	if (ref $s) { 
	  $s->status($status);
	}
	else {
	  $s = $self->_master->Status->create({ job => $self,
						stage => $stage, 
						status => $status,
					      });
	  unless (ref $s) {
	    die "Unable to create stage $stage: $status.";
	  }
	}
      }
    }      
 
  }
  
  return $self;
}


=pod

=item * B<metamxl> ()

Returns access to the meta xml file in the job directory

=cut

sub metaxml {
  my $key = ($_[0]->metagenome) ? 'metagenome_'.$_[0]->id : $_[0]->genome_id;
  unless(exists($_[0]->{_metaxml})) {
    $_[0]->{_metaxml} = GenomeMeta->new($key, $_[0]->directory.'/meta.xml');
  }
  return $_[0]->{_metaxml};
}


=pod

=item * B<metagenome> ()

Returns true if the job is of type 'Metagenome'

=cut

sub metagenome {
  return $_[0]->type eq 'Metagenome';
}

=pod

=item * B<mgrast2>()

Returns true if the job is in the MGRAST 2.0 server. 

=cut

sub mgrast2
{
    my($self) = @_;

    my $dir = $self->directory();

    my $ret = (-f "$dir/MGRAST2") || (-f "$dir/errors/reformat_contigs.stderr");
    return $ret;
}

=pod

=item * B<priority> ()

Returns the priority of the job

=cut

sub priority {
  my ($self, $prio) = @_;

  my $p = $self->metaxml->get_metadata('option.priority') | 'medium';

  if ($prio) {
    unless ($self->is_valid_priority($prio)) {
      die "Invalid job priority '$prio' (low|medium|high).";
    }
    if ($p ne $prio) {
      $self->metaxml->set_metadata('option.priority', $prio);
      $p = $prio;
    }
  }

  return $p;
}


=pod

=item * B<is_valid_priority> (I<value>)

Returns 1 if I<value> is a valid priority setting for RAST jobs. This has been cast into 
a separate method to allow the frontend to check values.

=cut

sub is_valid_priority {
  return ($_[1] and ($_[1] eq 'low' or $_[1] eq 'medium' or $_[1] eq 'high'));
}
  

=pod

=item * B<to_be_deleted> ()

Returns true if the job is flagged as to be deleted.

=cut

sub to_be_deleted {
  unless(exists($_[0]->{_to_be_deleted})) {
    $_[0]->{_to_be_deleted} = -f $_[0]->directory.'/DELETE' || 0;
  }
  return $_[0]->{_to_be_deleted};
}


=pod

=item * B<mark_for_deletion> (I<user>)

This method will mark a job for deletion and add a log message into the
meta xml file. If I<user> contains the object reference to a user object
the log method will contain the login name.
On directory level this will create the file DELETE and unlink ACTIVE.

=cut

sub mark_for_deletion {
  my ($self, $user) = @_;

  # delete it
  open(DEL, '>'.$self->directory.'/DELETE')
    or die "Cannot create file in ".$self->directory;
  close(DEL);
  unlink ($self->directory.'/ACTIVE');
    
  # add log message
  if (ref $user and $user->isa("WebServerBackend::User")) {
    $_[0]->metaxml->add_log_entry('genome', 'Job scheduled for deletion by user '.$user->login.'.');
  }
  else {
    $_[0]->metaxml->add_log_entry('genome', 'Job scheduled for deletion. No user given.');
  }
  
  # delete entry from the job cache
  return $self->delete;

}


=pod

=item * B<project> ()

Returns the name of the project

=cut

sub project {
  unless(exists($_[0]->{_project})) {
    $_[0]->{_project} = &FIG::file_head($_[0]->directory.'/PROJECT', 1);
  }
  return $_[0]->{_project};
}


=pod

=item * B<public> ()

Checks if the job is public. 

=cut

sub public {
  (-f $_[0]->directory.'/PUBLIC') ? return 1 : return 0;
}

sub stages_for_prast
{
    return [ 'status.uploaded', 'status.rp', 'status.qc', 'status.correction',
	     'status.sims', 'status.auto_assign', 'status.final' ];

}

sub stages_for_rast
{
    return [ 'status.uploaded', 'status.rp', 'status.qc', 'status.correction',
	     'status.sims', 'status.bbhs', 'status.auto_assign', 
	     'status.pchs', 'status.scenario', 'status.export', 'status.final' ];
}

sub stages_for_mgrast_1
{
    return [ 'status.uploaded', 'status.preprocess',
	    'status.sims', 'status.sims_postprocess',
	    'status.final' ];
}

sub stages_for_mgrast_2
{
    return [qw(status.uploaded
	       status.preprocess
	       status.sims
	       status.check_sims
	       status.create_seed_org
	       status.export
	       status.final)];
}

=pod

=item * B<stages> ()

Returns a reference to an array of the status keys for the stages of this 
type of job.

This is hacked a bit to support the difference between MGRAST 1 & 2.   

=cut

sub stages {
    my ($self) = @_;
    if ($self->metagenome)
    {
      if ($self->mgrast2())
      {
	  return &stages_for_mgrast_2();
      }
      else
      {
	  return &stages_for_mgrast_1();
      }
  }
  else {
	  return &stages_for_rast();
  }
}


=pod

=item * B<status_all> ()

Returns a reference to an array of the all know stages and their status.
Each array entry is a Status object;

=cut

sub status_all {
  return $_[0]->_master->Status->get_objects({ job => $_[0] });
}


=pod

=item * B<status> (I<stage_name>)

Returns the Status object for the stage I<stage_name> or undef if that stage
isnt stored for the job

=cut

sub status {
  return $_[0]->_master->Status->init({ job => $_[0], stage => $_[1] });
}



=pod 

=item * B<downloads> ()

Returns a list of available downloads for this job (from the download directory)

=cut

sub downloads {
  my $self = shift;
  my $downloads = [];
  
  # check for download directory
  if (-d $self->download_dir) {
    
    # try to read index
    my $index = {};
    if (-f $self->download_dir.'/index') {
      open(INDEX, '<'.$self->download_dir.'/index')
	or die "Unable to read download index of job ".$self->id.".";
      while(<INDEX>) {
	chomp;
	/^(\S+)\s+(.+)$/;
	$index->{$1} = $2 if ($1 and $2);
	#my ($fn, $desc) = split("\t", $_);
	#$index->{$fn} = $desc if ($fn and $desc);
      }
    }

    # read files from download dir
    my $dh = DirHandle->new($self->download_dir);
    while (defined($_ = $dh->read())) {
      next if ($_ =~ /^\./);
      next if ($_ =~ /^index$/);
      push @$downloads, [ $_, $index->{$_} || '' ];
    }

  }

  #
  # Also check for old-style .gbk.gz files in the job dir.
  #

  for my $gz (glob($self->directory() . "/*.gbk.gz"))
  {
      push(@$downloads, [ basename($gz), "Genbank export"]);
  }
  

  return $downloads;
}



=pod

=item * B<get_jobs_for_user> (I<user_or_scope>, I<right>, I<viewable>)

Returns the Jobs objects the user I<user> has access to. Access to a job is defined
by the right to edit a genome of a certain genome_id. In the context of the RAST
server this method checks the 'edit - genome' rights of a user. Optionally, you can
change this by providing the parameter I<right> and setting it to eg. 'view'.
If present and true, the parameter I<viewable> restricts the query to jobs marked 
as viewable.

Additionally, you may give a scope object instead of a user to get all Job objects
that scope would habe access to. This should be used for informational output,
never as authorization.

=cut

sub get_jobs_for_user {
  my ($self, $user_or_scope, $right, $viewable) = @_;

  unless (ref $self) {
    die "Call method via the DBMaster.\n";
  }
  
  unless (ref $user_or_scope and 
	  ( $user_or_scope->isa("WebServerBackend::User") or
	    $user_or_scope->isa("WebServerBackend::Scope"))
	 ) {
    print STDERR "No user or scope given in method get_jobs_for_user.\n";
    die "No user or scope given in method get_jobs_for_user.\n";
  }

  my $get_options = {};
  $get_options->{viewable} = 1 if ($viewable);
  my $jobs = $self->_master->Job->get_objects($get_options);
  my $right_to = $user_or_scope->has_right_to(undef, $right || 'edit', 'genome');

  # check if first right_to is place holder
  if (scalar(@$right_to) and $right_to->[0] eq '*') {
    return $jobs;
  }
  
  # create hash from ids, filter jobs 
  my %ids = map { $_ => 1 } @$right_to;
  my $results = [];
  foreach my $job (@$jobs) {
      if ($job->genome_id ) { #or ($user_or_scope->isa('WebServerBackend::User') and  $job->owner->login eq $user_or_scope->login) ){
	  push @$results, $job if ($ids{$job->genome_id});
	  # print STDERR "Here Job " . $job->id  . " Genome ID:" . $job->genome_id . " Owner: " . $job->owner->lastname . " User:  " . $user_or_scope->lastname . "\n";
      }
  }

  return $results;
  
}

sub get_jobs_for_user_fast {
    my ($self, $user_or_scope, $right, $viewable) = @_;
    
    unless (ref $self) {
	die "Call method via the DBMaster.\n";
    }
    
    unless (ref $user_or_scope and 
	    ( $user_or_scope->isa("WebServerBackend::User") or
	     $user_or_scope->isa("WebServerBackend::Scope"))
	   ) {
	print STDERR "No user or scope given in method get_jobs_for_user.\n";
	die "No user or scope given in method get_jobs_for_user.\n";
    }
    
    my $right_to = $user_or_scope->has_right_to(undef, $right || 'edit', 'genome');
    # print Dumper($right_to);

    my $job_cond = "true";

    if ($viewable)
    {
	$job_cond .= " AND viewable = 1";
    }
    my $want_all_jobs = @$right_to && $right_to->[0] eq '*';
    if ($user_or_scope->isa("WebServerBackend::User") && !$user_or_scope->wants_all_rast_jobs())
    {
	$want_all_jobs = 0;
    }

    my $first_job = $user_or_scope->wants_rast_jobs_starting_with() || 1;
    print STDERR Dumper($first_job, $want_all_jobs);
    if ($first_job =~ /(\d+)/)
    {
	$job_cond .= " AND j.id >= $1";
    }
    if (!$want_all_jobs)
    {
	my @g = grep { $_ ne '*' } @$right_to;
	if (@g == 0)
	{
	    return ();
	}
	$job_cond .= " AND genome_id IN ( " . join(", ", map { "'$_'" } @g) . ")";
    }
    
    my $dbh = $self->_master()->db_handle();

    my %job_stages;
    my $sth = $dbh->prepare(qq(SELECT SQL_NO_CACHE j.id, s.stage, s.status
					  FROM Job j JOIN Status s ON s.job = j._id
					  WHERE $job_cond
					 ), { mysql_use_result => 1 });
    $sth->execute();

    while (my $ent = $sth->fetchrow_arrayref())
    {
	my($id, $stage, $stat) = @$ent;

	$job_stages{$id}->{$stage} = $stat;
    }

    $sth = $dbh->prepare(qq(SELECT SQL_NO_CACHE j.id, j.type, j.genome_id, j.genome_name, j.project_name,
					  	j.genome_bp_count, j.genome_contig_count, j.server_version,
					  	j.last_modified, j.created_on, j.owner, j._owner_db
			    FROM Job j 
			    WHERE $job_cond
			    ORDER BY j.id DESC
		), { mysql_use_result => 1 });
    $sth->execute();

    my @out;
    while (my $ent = $sth->fetchrow_arrayref())
    {
	my($cur, $cur_type, $cur_genome, $cur_name, $cur_proj, $cur_bp_count, $cur_contig_count, $cur_server_version, $cur_last_mod, $cur_created, $cur_owner, $cur_owner_db) = @$ent;
	my $stages = $job_stages{$cur};

	push(@out, {
	    id => $cur,
	    type => $cur_type,
	    genome_id => $cur_genome,
	    genome_name => $cur_name,
	    project_name => $cur_proj,
	    last_modified => $cur_last_mod,
	    created_on => $cur_created,
	    status => $stages,
	    owner => $cur_owner,
	    owner_db => $cur_owner_db,
	    bp_count => $cur_bp_count,
	    contig_count => $cur_contig_count,
	    server_version => $cur_server_version,
	});
    }
    return @out;
}

sub get_jobs_for_user_fast_no_status {
    my ($self, $user_or_scope, $right, $viewable) = @_;
    
    unless (ref $self) {
	die "Call method via the DBMaster.\n";
    }
    
    unless (ref $user_or_scope and 
	    ( $user_or_scope->isa("WebServerBackend::User") or
	     $user_or_scope->isa("WebServerBackend::Scope"))
	   ) {
	print STDERR "No user or scope given in method get_jobs_for_user.\n";
	die "No user or scope given in method get_jobs_for_user.\n";
    }
    
    my $right_to = $user_or_scope->has_right_to(undef, $right || 'edit', 'genome');
    # print Dumper($right_to);

    my $job_cond = "true";

    my $want_all_jobs = @$right_to && $right_to->[0] eq '*';
    if ($user_or_scope->isa("WebServerBackend::User") && !$user_or_scope->wants_all_rast_jobs())
    {
	$want_all_jobs = 0;
    }

    if ($viewable)
    {
	$job_cond .= " AND viewable = 1";
    }
    if (!$want_all_jobs)
    {
	my @g = grep { $_ ne '*' } @$right_to;
	if (@g == 0)
	{
	    return ();
	}
	$job_cond .= " AND genome_id IN ( " . join(", ", map { "'$_'" } @g) . ")";
    }

    my $dbh = $self->_master()->db_handle();

    my $sth = $dbh->prepare(qq(SELECT j.id, j.type, j.genome_id, j.genome_name, j.project_name,
			 	j.genome_bp_count, j.genome_contig_count, j.server_version,
			 	j.last_modified, j.created_on, j.owner, j._owner_db
			 FROM Job j 
			 WHERE $job_cond
			 ORDER BY j.id DESC), { mysql_use_result => 1 });

    $sth->execute();
    my @out;
    while (my $ent = $sth->fetchrow_arrayref())
    {
	my($cur, $cur_type, $cur_genome, $cur_name, $cur_proj,
	   $cur_bp_count, $cur_contig_count, $cur_server_version,
	   $cur_last_mod, $cur_created, $cur_owner, $cur_owner_db) = @$ent;

	push(@out, {
	    id => $cur,
	    type => $cur_type,
	    genome_id => $cur_genome,
	    genome_name => $cur_name,
	    project_name => $cur_proj,
	    last_modified => $cur_last_mod,
	    created_on => $cur_created,
	    owner => $cur_owner,
	    owner_db => $cur_owner_db,
	    bp_count => $cur_bp_count,
	    contig_count => $cur_contig_count,
	    server_version => $cur_server_version,
	});
    }
    return @out;
}



=pod

=item * B<ready_for_browsing> ()

Returns true if the job processing has reached a stage that it is 
available for browsing in the SEED Viewer. Note, this reads from the
meta.xml file instead of taking the attribute I<viewable>. 
This method is called from I<sync_from_directory> to determine
wether a job is ready for viewing or not.

=cut

sub ready_for_browsing {
  return ($_[0]->metaxml->get_metadata('status.final') and 
	  $_[0]->metaxml->get_metadata('status.final') eq 'complete');
}


=pod

=item * B<get_mg_database> ()

If the job is a metagenome, this method tries to initialise the DBMaster
on the metagenomics analysis database in the job directory. Returns undef
in all other cases.

=cut
					  
sub get_mg_database {

  if ($_[0]->metagenome) {
    
    unless (exists $_[0]->{__mg_db}) {
      eval {

	use DBI;
	my $host     = 'bio-macpro-2.mcs.anl.gov';
	my $database = 'bobtest';
	my $user     = 'mgrast';
	my $password = '';
	
	# initialize database handle
	$_[0]->{__mg_db} = DBI->connect("DBI:mysql:database=$database;host=$host", $user, $password, 
					{ RaiseError => 1, AutoCommit => 0, PrintError => 0 }) ||
					  die "database connect error.";
      };
      if ($@) {
	warn "Unable to connect to metagenomics database: $@\n";
	$_[0]->{__mg_db} = undef;
      }
    }
    
    return $_[0]->{__mg_db};
    
  }
  
  return undef;
}


=pod

=item * B<delete> ()

This method overloads the default delete method from DBObject. It performs
some necessary clean up steps when a Job is removed from the database.

=cut

sub delete {
  my $self = shift;
  
  # delete all stages
  foreach my $s (@{$self->status_all}) {
    $s->delete;
  }

  return $self->SUPER::delete(@_);
  
}


=pod

=item * B<lock_directory> ()

Uses flock to lock this job directory for the purpose of syncing it with the
job cache. Also see unlock_directory.
 
=cut

sub lock_directory {
    my($self, $id) = @_;

    return if $self->{_master}->backend() ne 'SQLite';
    unless ($self->{__lock}) {
	$self->{__lock} = IO::File->new(">".$FIG_Config::rast_jobs."/$id/SYNC")
	    or die "Unable to open SYNC file in job ".($id||'undef').".";
    }
    flock($self->{__lock},LOCK_EX);
    return $self;
}


=pod

=item * B<unlock_directory> ()

Releases the lock on this job directory for the purpose of syncing it with the
job cache. Also see lock_directory.
 
=cut

sub unlock_directory {
    my($self) = @_;
    return if $self->{_master}->backend() ne 'SQLite';
    if ($self->{__lock}) {
	flock($self->{__lock},LOCK_UN);
    }
    return $self;
}

sub mysql_date {
  my ($date) = @_;

  my ($s, $m, $h, $d, $mon, $yr) = localtime($date);
  my $stamp = sprintf("%4d-%02d-%02d %02d:%02d:%02d", $yr+1900, $mon+1, $d, $h, $m, $s);

  return $stamp;
}
