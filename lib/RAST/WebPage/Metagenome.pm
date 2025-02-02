package RAST::WebPage::Metagenome;

use strict;
use warnings;

use POSIX;

use base qw( WebPage RAST::WebPage::JobDetails );
use WebConfig;

use RAST::RASTShared qw( get_menu_job );

1;


=pod

=head1 NAME

Metagenome - displays detailed information about a metagenome job

=head1 DESCRIPTION

Job Details (Metagenome) page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Job Details");

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

}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  my $job = $self->data('job');

  my $content = '<h1>Jobs Details #'.$job->id.'</h1>';

  if ($job->ready_for_browsing) {
    $content .= '<p> &raquo; <a target="_blank" href="metagenomics.cgi?page=MetagenomeOverview&metagenome='.
      $job->genome_id.'">Browse annotated metagenome in SEED Viewer</a></p>';
  }

  # check for downloads
  my $downloads = $job->downloads();
  if (scalar(@$downloads)) {
    my @values = map { $_->[0] } @$downloads;
    my %labels = map { $_->[0] => $_->[1] || $_->[0] } @$downloads;
    $content .= $self->start_form('download', { page => 'DownloadFile', job => $job->id });
    $content .= '<p> &raquo; Available downloads for this job: ';
    $content .= $self->app->cgi->popup_menu( -name => 'file',
					     -values => \@values,
					     -labels => \%labels, );
    $content .= "<input type='submit' value=' Download '>";
    $content .= $self->end_form;
  }
  else {
    if ($job->ready_for_browsing) {
      $content .= '<p> &raquo; No downloads available for this metagenome yet.</p>';
    }
  }

  if ($self->app->session->user->has_right(undef, 'edit', 'genome', $job->genome_id, 1) and
      $self->app->session->user->has_right(undef, 'view', 'genome', $job->genome_id, 1)) {
    $content .= '<p> &raquo; <a href="?page=JobShare&job='.$job->id.
      '">Share this metagenome with selected users</a> ';
    $content .= '<p> &raquo; <a href="?page=PublishGenome&job='.$job->id.
      '">Make this metagenome publicly accessible</a> ';
  }

  $content .= "<p> &raquo <a href='?page=Jobs'>Back to the Jobs Overview</a></p>"; 
  
  # upload
  $content .= $self->get_section_bar($job->metaxml->get_metadata('status.uploaded'),
				     'Genome Upload');
  $content .= "<table>";
  $content .= "<tr><th>Metagenome ID - Name:</th><td>".$job->genome_id." - ".$job->genome_name."</td></tr>";
  $content .= "<tr><th>Job:</th><td> #".$job->id."</td></tr>";
  $content .= "<tr><th>User:</th><td>".$job->owner->login."</td></tr>";
  $content .= "<tr><th>Date:</th><td>".
    localtime($job->metaxml->get_metadata('upload.timestamp'))."</td></tr>";
  $content .= "<tr><th>Number of uploaded sequences:</th><td>".
    ($job->metaxml->get_metadata('preprocess.count_raw.num_seqs')||'unknown')."</td></tr>";
  $content .= "<tr><th>Total uploaded sequence length:</th><td>".
    ($job->metaxml->get_metadata('preprocess.count_raw.total')||'unknown')."</td></tr>";
  $content .= "</table>";

  # quality check
  $content .= $self->get_section_bar($job->metaxml->get_metadata('status.preprocess'), 
				     'Preprocessing');
  $content .= "<p>The following statistics are based on the sequences after preprocessing:</p>";

  # build table with preprocess statistics data
  my $stats = [[ 'preprocess.count_proc.num_seqs', 'Number of sequences' ],
	       [ 'preprocess.count_proc.total', 'Total sequence length' ],
	       [ 'preprocess.count_proc.average', 'Average read length' ],
	       [ 'preprocess.count_proc.longest_seq', 'Longest sequence id' ],
	       [ 'preprocess.count_proc.longest_len', 'Longest sequence length' ],
	       [ 'preprocess.count_proc.shortest_seq', 'Shortest sequence id' ],
	       [ 'preprocess.count_proc.shortest_len', 'Shortest sequence length' ],
	      ];
  
  my $statistics = '';
  foreach my $s (@$stats) {
    if ($job->metaxml->get_metadata($s->[0])) {
      my $value = $job->metaxml->get_metadata($s->[0]);
      if ($value) {
	$statistics .= "<tr><th>".$s->[1].":</th><td>".$value."</td></tr>";
      }
    }
  }
  
  if ($statistics) {
    $content .= "<table> $statistics </table>";
  }

  #
  # These are different in v1/v2
  #

  if ($job->mgrast2())
  {
      
      # similarity computation
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.sims'), 
					 'Similarity processing setup');
      
      # sims post processing
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.check_sims'),
					 'Similarity final check');
     
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.create_seed_org'),
					 'SEED organism directory creation');
      
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.export'),
					 'Exportable data creation');
      
      # final assignement
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.final'), 
					 'Final processing');
    
  }
  else
  {
      
      # similarity computation
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.sims'), 
					 'Similarity Computation');
      
      # sims post processing
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.sims_postprocess'), 
					 'Similarity postprocessing');
      
      # final assignement
      $content .= $self->get_section_bar($job->metaxml->get_metadata('status.final'), 
					 'Final Assignment');
    
  }
  return $content;
  
}
