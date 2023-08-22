package RAST::WebPage::DownloadMetagenome;

use strict;
use warnings;

use POSIX;

use base qw( WebPage RAST::WebPage::JobDetails );
use WebConfig;

use RAST::RASTShared qw( get_menu_job );
use SeedViewer::SeedViewer qw( get_menu_metagenome get_menu_organism get_public_metagenomes );

1;


=pod

=head1 NAME

DownloadMetagenome - displays download information about a metagenome job

=head1 DESCRIPTION

Download metagenome page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Job Downloads");

  my($job, $id);

  # initialize objects                                                                                                                                                                                      
  my $application = $self->application();
  my $cgi = $application->cgi();
  my $fig = $application->data_handle('FIG');

  # check if we have a valid fig                                                                                                                                          
  unless ($fig) {
      $application->add_message('warning', 'Invalid organism id');
      return "";
  }
  
  # set up the menu                                                                                                                                                                                         
  my $menu_done = 0;
  if ($fig->isa('FIGV')) {
      my $rast = $application->data_handle('RAST');
      my $jobs = $rast->Job->get_objects( { genome_id => $cgi->param('metagenome') } );

      if(scalar(@$jobs) and $jobs->[0]->metagenome) {
	  my $genome_id = $cgi->param('metagenome');
	  &get_menu_metagenome($self->application->menu, $genome_id);
	  $menu_done = 1;
      }
  }

  unless($menu_done) {
      &get_menu_organism($self->application->menu, $cgi->param('organism'));
  }

  if ( $self->application->cgi->param('job') )
  {
      # get to metagenome using the job id
      $id = $self->application->cgi->param('job');

      eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  }
  elsif ( $self->application->cgi->param('metagenome') )
  {
      # get to metagenome using the metagenome id
      $id = $self->application->cgi->param('metagenome');

      eval { $job = $self->app->data_handle('RAST')->Job->init({ genome_id => $id }); };
  }

  if ( $job ) 
  {
      $self->data('job', $job);
      
      # add job specific links
      &get_menu_job($self->app->menu, $job);
  } 
  else 
  {
      $self->app->error("Unable to retrieve the metagenome '$id'.");
      return 1;
  }
}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  my $job = $self->data('job');

  my $content = '';
      
  # check for download files
  my $downloads = $job->downloads();

  if ( @$downloads or $job->ready_for_browsing ) 
  {
      $content  = "<span style='font-size: 1.6em'><b>Downloads for " . $job->genome_name . " (" . $job->genome_id . ")</b></span>\n";
      $content .= "<p>\n<table>\n";

      if ( @$downloads )
      {
	  foreach my $rec ( sort {$a->[1] cmp $b->[1]} @$downloads )
	  {
	      my($file, $label) = @$rec;
	      my $link  = "<a href=\"?page=DownloadFile&job=" . $job->id . "&file=$file\">$file</a>";
	      $content .= "<tr><th>$label</th><td>$link</td></tr>\n";
	  }
	  $content .= "<tr><td colspan=2></td></tr>\n";
      }
      
      if ( $job->ready_for_browsing )
      {
	  $content .= "<tr><th>Sequences subsets</th><td>\n" .
	              "<a href=\"metagenomics.cgi?page=MetagenomeProfile&dataset=SEED:subsystem_tax&metagenome=" . $job->genome_id . "\">Fasta sequence file</a> " .
		      "based on the metabolic reconstruction using SEED subsystems.<br>\n" .
		      "Follow the link above, and select the parameters for the metabolic reconstruction.<br>\n" .
		      "After clicking '<b><em>Re-compute results</em></b>' go to the '<b><em>Tabular View</em></b>' lower down on the same page.<br>\n" .
		      "Select and click on a subsystem name or classification, the sequences can be downloaded from the resulting page.\n" .
		      "</td></tr>\n";
      }
      
      $content .= "</table>\n";
  }
  else
  {
      $content  = "<span style='font-size: 1.6em'><b>No downloads available for " . $job->genome_name . " (" . $job->genome_id . ")</b></span>\n";
  }

  return $content;
}
