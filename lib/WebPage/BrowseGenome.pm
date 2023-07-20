package WebPage::BrowseGenome;

use WebApp::WebPage;

1;

our @ISA = qw ( WebApp::WebPage );

use Job48;

use RawOrganismGenomeBrowser;

=pod

=head1 NAME

BrowseGenome - displays a genome browser.

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the BrowseGenome page.

=cut

sub output {
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  my $session = $self->application->session;
  my $content = 'Unknown action';
  $self->title('Annotation Server - Browse Genome');

  my $action = 'default';
  if (defined($cgi->param('action'))) {
    $action = $cgi->param('action');
  }

  if ($action eq 'default') {
    $content = $self->genome_browser($session, $cgi);
  } 

  return $content;
}

sub genome_browser {
  my ($self, $session, $cgi) = @_;

  my $content = "";
  
  if ($self->application->authorized(1)) {

    # sanity check on job
    my $job = Job48->new( $cgi->param('job'), 
			  $self->application->session->user );
    unless ($job and $job->active) {
      my $id = $cgi->param('job') || '';
      $self->application->error("Invalid job id given (id='$id').");
      return $content;
    }
      
    my $js = '<script src="./Html/css/FIG.js" type="text/javascript"></script><script type="text/javascript" src="./Html/css/layout.js"></script>';
    
    # create title
    $content .= "<h1>Browsing Genome " . $job->genome_name . "</h1>";
    $content .= "<p><a href='".$self->application->url."?page=JobDetails&job=" . $job->id . 
      "'>&raquo;Back to Job Details</a></p>";
    $content .= $js . RawOrganismGenomeBrowser::new({ genome_directory => $job->orgdir,
						      genome_id        => $job->genome_id,
						      genome_name      => $job->genome_name });
  } 
  else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . 
      $self->application->url . "'>login page</a>.";
  }

  return $content;
}
