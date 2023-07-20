package WebPage::CheckJob;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );

use GenomeMeta;
use GD;
use MIME::Base64;
use Table;

use FIG_Config;

use Job48;
use CheckGenome;
use GenomeBrowser;

1;

=pod

=head1 NAME

Genomes - an instance of WebPage which displays the list of genomes currently in pipeline and their status

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;
  
  $self->title('Annotation Server - Import Jobs into SEED');
  
  my $content = '';
  
  # check if a user is logged in and admin
  if ($self->application->authorized(2)) {
    
    if ($self->application->cgi->param('job')) {
      $content = $self->check_genome_from_job( $self->application->cgi->param('job') );
    }
    else{
      $content = "<h1>JOB ".$self->application->cgi->param('job')."</h1>";
      
      print STDERR " No accept \n";
    }
    
    return $content;;
  }
  
  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error().
      "<br/>Please return to the <a href='".$self->application->url."?page=Login'>login page</a>.</p>";
  }
  
  return $content;
}


=pod

=item * B<find_related> ()

Find similar genomes and present them in a table.

=cut

sub check_genome_from_job {
  my $self = shift;


 
  my $job_id = $self->application->cgi->param('job');
  my $job = Job48->new($job_id);
  my $fig = FIGV->new($job->dir);
  my $cgi = $self->application->cgi;
  my $check = CheckGenome->new( $job_id ); 
 

  my $id = $job->genome_id;
  my $name = $job->genome_name;

  # build search term
  my @terms = split(' ',$name);
  my $search = $terms[0];

  my $content = " <h1> Genome Info </h1>  <p>Overview for <b>$name</b>($id) from user ". $job->user . ".</p>";
  
  $content .= '<p>';
  $content .= $self->start_form("", { job => $job_id });
  #$self->application->cgi->param('job',"$job_id");
 
  $content .= $check->create_html_output;

  #$content .= $cgi->submit(-name => ' ', -value => 'Accept new name');
  $content .= $self->end_form.'</p>';

  return $content;
}



