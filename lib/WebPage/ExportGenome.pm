package WebPage::ExportGenome;

use warnings;
use strict;

use Carp qw( confess );

use File::Basename;

use WebApp::WebPage;
our @ISA = qw ( WebApp::WebPage );

use SeedExport;
use FIG_Config;
use Job48;


1;

=pod

=head1 NAME

Genomes - an instance of WebPage which export the annotated raw organism directory to different formats

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->title('Annotation Server - Export Genome');

  my $cgi = $self->application->cgi;
  my $session = $self->application->session;
  my $content = '';

  # get the format
  my $format = 'genbank';
  if (defined($cgi->param('format'))) {
    $format = $cgi->param('format');
  }

  my $strip_ec = ($cgi->param('strip_ec')) ? 1 : 0;
  
  # sanity check on job
  my $job = Job48->new( $cgi->param('job'),
			$self->application->session->user );
  unless ($job and not $job->to_be_deleted()) {
    my $id = $cgi->param('job') || '';
    $self->application->error("Invalid job id given (id='$id').");
    return $content;
  }

  # check authorization
  if ($self->application->authorized(1)) {

    my $user = $job->getUserObject();
    die "Could not get user for job ".$job->id.".\n" unless ($user);

    my $job_organization = $user->organisation->name;
   
    # is admin or owns job
    unless ($self->application->authorized(2) or
	    $self->application->session->user->organisation->name eq $job_organization) {
      $self->application->error('User '.$self->application->session->user->login.
				' not authorized to export job "'.$job->id.'".');
      return $content;
    }

    # export
    my ($output, $msg) = SeedExport::export( { 'virtual_genome_directory' => $job->orgdir,
					       'genome' => $job->genome_id, 
					       'directory' => $FIG_Config::temp . "/", #"/tmp/export/",
					       'export_format' => $format,
					       'strip_ec' => $strip_ec 
					     } );

    if (-f $output) {
      open(FILE, $output) or confess "Cannot open file $output.";
      my @export = <FILE>;
      close(FILE);
      print "Content-Type:application/x-download\n";  
      print "Content-Disposition:attachment;filename=".basename($output)."\n\n";
      print @export; 
      exit;
    }
  }
  else {
    $self->application->error('You are not logged in.');
    return $content;
  }
  
  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error()."</p>";
  }
  
  return $content;
}

