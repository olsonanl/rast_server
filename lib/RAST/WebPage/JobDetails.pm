package RAST::WebPage::JobDetails;

use strict;
use warnings;

use POSIX;

use base qw( WebPage );
use WebConfig;

1;


=pod

=head1 NAME

JobDetails - an instance of WebPage which displays detailed information about a job

=head1 DESCRIPTION

Job Details page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Jobs Details");

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  $id =~ s/\s+$//;
  $id =~ s/^\s+$//;
  if ($id =~ /^(\d+)\.?$/)
  {
      $id = $1;
      $self->application->cgi->param('job', $id);
  }
  else
  {
      $self->app->error("Invalid job '$id'.");
      return;
  }
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  if ($job) {
    # redirect to details page for that type
    if ($job->type eq 'Genome') {
      $self->application->redirect('Genome');
    }
    elsif ($job->type eq 'Metagenome') {
      $self->application->redirect('Metagenome');
    }
    else {
      $self->application->error('Unknown job type. Unable to display JobDetails for it.');
    }
  }
  else {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  
  $self->data('job', $job);

}


=pod

=item * B<get_image_and_text_for_status> (I<status>, I<stage_name>)

Returns the an image filename and text message which describe the I<status> entry.

=cut

sub get_image_and_text_for_status {
  my ($self, $status, $stage) = @_;

  $status = $status || 'not_started';
  unless ($status and $stage) {
    die "Incomplete parameters.\n";
  }

  if ($status eq 'not_started') {
    return ( IMAGES."rast-not_started.png", "$stage has not yet started.");
  }
  elsif ($status eq 'queued') {
    return ( IMAGES."rast-queued.png", "$stage is queued for computation.");
  }
  elsif ($status eq 'in_progress') {
    return ( IMAGES."rast-in_progress.png", "$stage is currently in progress.");
  }
  elsif ($status eq 'complete') {
    return ( IMAGES."rast-complete.png", "$stage has been successfully completed.");
  }
  elsif ($status eq 'error') {
    return ( IMAGES."rast-error.png", "$stage has returned an error.");
  }
  elsif ($status eq 'requires_intervention') {
    return ( IMAGES."rast-error.png", "$stage needs user input!");
  }
  else {
    die "Found unknown status '$status'.\n";
  }
}


=pod

=item * B<get_section_bar>(I<status>, I<stage_name>)

Returns the html for a Details page section bar, displaying the name of
stage I<stage> and the status I<status>

=cut

sub get_section_bar {
  my ($self, $status, $stage) = @_;
  my ($img, $text) = $self->get_image_and_text_for_status($status, $stage);
  return "<p id='section_bar'><img src='$img'>$text</p>";
}


=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], ];
  push @$rights, [ 'view', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}



