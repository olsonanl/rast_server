package WebPage::Download;

use warnings;
use strict;

use base qw( WebApp::WebPage );

use File::Basename qw(basename);
use Job48;

sub output {
  my ($self) = @_;

  $self->title('Annotation Server - Download File');
  
  my $content = '';

  # sanity check on job
  my $id = $self->application->cgi->param('job');
  my $job = Job48->new( $id, $self->application->session->user );
  unless ($job) {
    $self->application->error("Invalid job id given (id='$id').");
    return $content;
  }

  my $file = $self->application->cgi->param('file');	
  unless ($file) {
    $self->application->error("No file given.");
    return $content;
  }
  
  # check if a user is logged in
  if ($self->application->authorized(1)) {

    my @data;

    my $base = basename($file);
    my $path = $job->orgdir."/".$file;
    open(FILE, "<$path") || 
      $self->application->error("Unable to open file $base.");
    binmode(FILE) if ($self->application->cgi->param('binary')); 
    @data = <FILE>;  
    close (FILE) ;

    unless ($self->application->error) {

      print "Content-Type:application/x-download\n";  
      print "Content-Disposition:attachment;filename=$base\n\n";
      print @data;
      
      exit 1;
    }
  }
  
  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error().
      "<br/>Please return to the <a href='".$self->application->url."?page=Login'>login page</a>.</p>";
  }
  
  return $content;
}

1;
