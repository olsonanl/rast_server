package WebPage::ModifyJob;

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

    if ($self->application->cgi->param('change_name')) {
      $content = $self->change_name();
    }
    elsif ($self->application->cgi->param('accept_new_name')) {
      $content = $self->new_name();
    }
    else{
      $content = "<h1>JOB ".$self->application->cgi->param('job')."</h1>";
 
      print STDERR " No accept \n";
    }

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

sub change_name {
  my $self = shift;

  my $job_id = $self->application->cgi->param('change_name');
  my $job = Job48->new($job_id);
  my $fig = FIGV->new($job->dir);
  my $cgi = $self->application->cgi;
  
 

  my $id = $job->genome_id;
  my $name = $job->genome_name;

  # build search term
  my @terms = split(' ',$name);
  my $search = $terms[0];

  my $content = " <h1> Change Genome Name</h1>  <p>Change genome name for <b>$name</b> from user ". $job->user . ".</p>";
  
  $content .= '<p>'.$self->start_form("", { job => $job_id });
  #$self->application->cgi->param('job',"$job_id");
  $content .= "New name: ". $cgi->textfield( "new_name" , "") ;

  $content .= $cgi->submit(-name => 'accept_new_name', -value => 'Accept new name');
  $content .= $self->end_form.'</p>';

  return $content;
}


sub new_name {
  my $self = shift;

  my $job_id = $self->application->cgi->param('job');
  my $new_name = $self->application->cgi->param('new_name');
  my $job = Job48->new($job_id);
  my $fig = FIGV->new($job->dir);
  my $cgi = $self->application->cgi;
  
  my $id = $job->genome_id;
  my $old_name = $job->genome_name;

  my $changed_name = $job->set_genome_name( $new_name );


  my $content = "  <p>Name changed from $old_name to ". $job->genome_name." for  user ". $job->user . " and job $job_id.</p>";
  $content .= "<p>Go back to <a href=\"".$self->application->url."?page=ControlCenter\">V2C2</a>.";


  return $content;
}
