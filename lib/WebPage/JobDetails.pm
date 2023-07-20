package WebPage::JobDetails;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );
use WebPage::Genome;
use WebPage::MetaGenome;

use Job48;

1;

=pod

=head1 NAME

JobDetails - a factory that loads either the Genome or MetaGenome variant of the JobDetails page

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<new> ()

Creates a new instance of the WebPage object.

=cut

sub new {
  my ($class, $application) = @_;

  # sanity check on job
  my $id = $application->cgi->param('job');
  my $job = Job48->new( $id, $application->session->user );
  unless ($job) {
    $application->error("Invalid job id given (id='$id').");
  }
  
  my $self;
  if (ref $job and $job->metagenome) {
    $self = WebPage::MetaGenome->new($application);
  }
  else {
    $self = WebPage::Genome->new($application);
  }

  # add the admin menu
  if ($application->authorized(2)) {
    $application->menu->add_category("Admin");
    $application->menu->add_entry("Admin", "Debug Job", $self->application->url."?page=JobDebugger&job=$id");
  }
  
  return $self;
}


=pod

=item * B<get_image_and_text_for_status> (I<status>)

Returns the an image filename and text message which describe the I<status> entry.

=cut

sub get_image_and_text_for_status {
  my ($self, $status, $phase) = @_;

  $status = $status || 'not_started';
  unless ($status and $phase) {
    die "Incomplete parameters.\n";
  }

  my $img_path = "./Html/";

  if ($status eq 'not_started') {
    return ( $img_path."48-not_started.png", "$phase has not yet started.");
  }
  elsif ($status eq 'queued') {
    return ( $img_path."48-queued.png", "$phase is queued for computation.");
  }
  elsif ($status eq 'in_progress') {
    return ( $img_path."48-in_progress.png", "$phase is currently in progress.");
  }
  elsif ($status eq 'complete') {
    return ( $img_path."48-complete.png", "$phase has been successfully completed.");
  }
  elsif ($status eq 'error') {
    return ( $img_path."48-error.png", "$phase has returned an error.");
  }
  elsif ($status eq 'requires_intervention') {
    return ( $img_path."48-error.png", "$phase needs user input!");
  }
  else {
    die "Found unknown status '$status'.\n";
  }
}
