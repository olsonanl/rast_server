package RAST::WebPage::JobShare;

use base qw( WebPage );

1;

use strict;
use warnings;
use WebConfig;
use RAST::RASTShared qw( get_menu_job );

=pod

=head1 NAME

JobShare - an instance of WebPage to allow users to grant access to their genomes to others

=head1 DESCRIPTION

Offers the user the ability to grant access to his genomes

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my ($self) = @_;

  $self->title('Share a job');
  $self->application->register_action($self, 'share_job', 'share_job');
  $self->application->register_action($self, 'revoke_job', 'revoke_job');
  $self->application->register_action($self, 'share_with_guest', 'share_with_guest');
  $self->application->register_component('FilterSelect', 'Scopes');

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  $self->data('job', $job);

  # add links
  &get_menu_job($self->app->menu, $job);
  
  return 1;
}

=item * B<output> ()

Returns the html output of the DelegateRights page.

=cut

sub output {
  my ($self) = @_;

  my $job = $self->data('job');

  my $content = "<h1>Share a job</h1>";

  # short job info
  $content .= "<p> &raquo <a href='?page=JobDetails&job=".$job->id."'>Back to the Job Details</a></p>";
  $content .= "<p> &raquo <a href='?page=Jobs'>Back to the Jobs Overview</a></p>";
  
  $content .= "<p id='section_bar'><img src='".IMAGES."rast-info.png'/>Job Information</p>";
  $content .= "<table>";
  $content .= "<tr><th>Name - ID:</th><td>".$job->genome_id." - ".$job->genome_name."</td></tr>";
  $content .= "<tr><th>Type:</th><td>".$job->type."</td></tr>";
  $content .= "<tr><th>Job:</th><td> #".$job->id."</td></tr>";    
  $content .= "<tr><th>User:</th><td>".$job->owner->login."</td></tr>";
  $content .= "</table>";


  # short help text
  $content .= '<p style="width: 70%;">'
      .'To share the above job and its data with another user or user-group,'
      .' please enter the email address of the user, or name of the user-group.'
      .' Please note that you have to enter the email address that this person used to register at the RAST service.'
      .' The user will receive an email that notifies him how to access the data.'
      .' Once you have granted the right to view one of your RAST jobs to another user or group,'
      .' the name will appear at the bottom of the page with the option to revoke it.'
      .'</p>';

  # select user or group
  $content .= "<p id='section_bar'><img src='".IMAGES."rast-info.png'/>Enter an email address or group name</p>";
  $content .= $self->start_form('share_job', { job => $job->id,
					       action => 'share_job' });
  my $email = $self->app->cgi->param('email') || '';
  $content .= "<p><strong>Enter an email address or group name:</strong> <input name='email' type='textbox' value='$email'></p>";
  $content .= "<p><input type='submit' name='share_job' value=' Share job with this user or group '></p>";
  $content .= $self->end_form;

  # allow guest sharing
  $content .= "<p id='section_bar'><img src='".IMAGES."rast-info.png'/>Share with guest account</p>";
  $content .= '<p style="width: 70%;">You have the option to share your genome with the guest account. If you choose to do so, anyone logging in with the guest account will be able to view your genome. Guests will never be able to edit your genome.</p>';

  $content .= $self->start_form('share_job_with_guest', { job => $job->id,
							  action => 'share_with_guest' });
  $content .= "<p><input type='submit' value='Share job with guest'></p>";
  $content .= $self->end_form;
  
  # show people who can see this job at the moment
  $content .= "<p id='section_bar'><img src='".IMAGES."rast-info.png'/>This job is currently available to:</p>";
  my $rights = $self->application->dbmaster->Rights->get_objects( { name => 'view',
								    data_type => 'genome',
								    data_id => $job->genome_id
								  });
  my $found_one = 0;
  $content .= '<table>';
  foreach my $r (@$rights) {
    next if ($self->app->session->user->get_user_scope->_id eq $r->scope->_id);
    $content .= "<tr><td>".$r->scope->name_readable."</td>";
    if($r->delegated) {
      $content .= "<td>".$self->start_form('revoke_job', { job => $job->id, 
							   action => 'revoke_job',
							   scope => $r->scope->_id,
							 });
      $content .= "<input type='submit' name='revoke_job' value=' Revoke '>";
      $content .= "</td>";
    }
    else {
      $content .= "<td></td>";
    }
    $content .= '</tr>';
    $found_one = 1;
  }
  
  unless($found_one) {
    $content .= "<tr><td>This job is not shared with anyone at the moment.</td></tr>";
  }
  $content .= '</table>';

  return $content;


}

=pod

=item * B<share_with_guest>()

Action method to grant the right to view a genome to the guest user

=cut

sub share_with_guest {
  my ($self) = @_;

  my $application = $self->application;
  my $master = $application->dbmaster;

  # get some info
  my $genome_id = $self->data('job')->genome_id;
  my $guest = $master->User->get_objects( { login => 'guest' } );
  if (scalar(@$guest)) {
    $guest = $guest->[0]->get_user_scope;
    my $existing = $master->Rights->get_objects( { scope => $guest,
						   name => 'view',
						   data_type => 'genome',
						   data_id => $genome_id } );
    if (scalar(@$existing)) {
      $application->add_message('warning', "this genome is already shared with the guest account");
    } else {
      $master->Rights->create( { delegated => 1,
				 scope => $guest,
				 name => 'view',
				 data_type => 'genome',
				 data_id => $genome_id,
				 granted => 1 } );
      $application->add_message('info', "genome $genome_id shared with guest");
    }
  } else {
    $application->add_message('warning', 'Guest user not found, aborting');
  }
  
}

=pod

=item * B<share_job>()

Action method to grant the right to view and edit a genome to the selected scope

=cut

sub share_job {
  my ($self) = @_;
  
  # get some info
  my $job_id = $self->data('job')->id;
  my $genome_id = $self->data('job')->genome_id;
  my $genome_name = $self->data('job')->genome_name;
  my $application = $self->application;

  my $email = $self->app->cgi->param('email');

  my $master = $self->application->dbmaster;
  my $scope = $master->Scope->get_objects( { name => $email } );
  my $display_name = "";
  if (scalar(@$scope)) {
    $scope = $scope->[0];
    $display_name = $scope->name;
  } else {
    
    # check email format
    unless ($email =~ /^[\w\-\.]+\@[\.a-zA-Z\-0-9]+\.[a-zA-Z]+$/) {
      $self->application->add_message('warning', 'Please enter a valid email address.');
      return 0;
    }
    
    # check if have a user with that email
    my $user = $master->User->init({ email => $email });
    if (ref $user) {
      
      # send email
      my $ubody = HTML::Template->new(filename => TMPL_PATH.'EmailSharedJobGranted.tmpl',
				      die_on_bad_params => 0);
      $ubody->param('FIRSTNAME', $user->firstname);
      $ubody->param('LASTNAME', $user->lastname);
      $ubody->param('WHAT', "$genome_name ($genome_id)");
      $ubody->param('WHOM', $self->app->session->user->firstname.' '.$self->app->session->user->lastname);
      $ubody->param('LINK', $WebConfig::APPLICATION_URL."?page=JobDetails&job=$job_id");
      $ubody->param('APPLICATION_NAME', $WebConfig::APPLICATION_NAME);
      
      $user->send_email( $WebConfig::ADMIN_EMAIL,
			 $WebConfig::APPLICATION_NAME.' - new data available',
			 $ubody->output
		       );

      $scope = $user->get_user_scope;
      $display_name = $user->firstname." ".$user->lastname;
    } else {
      $application->add_message('warning', "User or group not found, aborting.");
      return 0;
    }
  }

  # grant rights if necessary
  my $rights = [ 'view', 'edit' ];
  foreach my $name (@$rights) {
    unless(scalar(@{$master->Rights->get_objects( { name => $name,
						    data_type => 'genome',
						    data_id => $genome_id,
						    scope => $scope } )})) {
      my $right = $master->Rights->create( { granted => 1,
					     name => $name,
					     data_type => 'genome',
					     data_id => $genome_id,
					     scope => $scope,
					     delegated => 1, } );
      unless (ref $right) {
	$self->app->add_message('warning', 'Failed to create the right in the user database, aborting.');
	return 0;
      }
    }
    if ($self->data('job')->type eq 'Metagenome') {
      unless(scalar(@{$master->Rights->get_objects( { name => $name,
						      data_type => 'metagenome',
						      data_id => $genome_id,
						      scope => $scope } )})) {
	my $right = $master->Rights->create( { granted => 1,
					       name => $name,
					       data_type => 'metagenome',
					       data_id => $genome_id,
					       scope => $scope,
					       delegated => 1, } );
	unless (ref $right) {
	  $self->app->add_message('warning', 'Failed to create the right in the user database, aborting.');
	  return 0;
	}
      }
    }
  }

  $self->app->add_message('info', "Granted the right to view this job to $display_name.");
  return 1;
}


=pod

=item * B<revoke_job>()

Action method to revoke the right to view and edit a genome to the selected scope

=cut

sub revoke_job {
  my ($self) = @_;

  my $master = $self->application->dbmaster;

  # get the scope
  my $s_id = $self->app->cgi->param('scope');
  my $scope = $master->Scope->get_objects({ _id => $s_id });
  unless(@$scope) {
    $self->app->add_message('warning', 'There has been an error: missing a scope to revoke right on., aborting.');
    return 0;
  }
  $scope = $scope->[0];

  # get genome id
  my $genome_id = $self->data('job')->genome_id;

  # delete the rights, double check delegated
  my $rights = [ 'view', 'edit' ];
  foreach my $name (@$rights) {
    foreach my $r (@{$master->Rights->get_objects( { name => $name,
						     data_type => 'genome',
						     data_id => $genome_id,
						     scope => $scope,
						     delegated => 1,
						   })}) {
      $r->delete;
    }
    if ($self->data('job')->type eq 'Metagenome') {
      foreach my $r (@{$master->Rights->get_objects( { name => $name,
						       data_type => 'metagenome',
						       data_id => $genome_id,
						       scope => $scope,
						       delegated => 1,
						     })}) {
	$r->delete;
      }
    }
  }

  $self->app->add_message('info', "Revoked the right to view this job from ".$scope->name_readable.".");

  return 1;

}


=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], ];
  if ($_[0]->data('job')) {
    push @$rights, [ 'edit', 'genome', $_[0]->data('job')->genome_id, 1 ];
    push @$rights, [ 'view', 'genome', $_[0]->data('job')->genome_id, 1 ];
  }
      
  return $rights;
}

