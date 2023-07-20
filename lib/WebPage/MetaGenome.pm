package WebPage::MetaGenome;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage WebPage::JobDetails );

use Table;

use Job48;

1;

=pod

=head1 NAME

MetaGenome - an instance of WebPage which displays a detailed description of a MetaGenome job

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->title('Annotation Server - Jobs Details');
  
  my $cgi = $self->application->cgi;
  my $content = '';

  # sanity check on job
  my $id = $self->application->cgi->param('job');
  my $job = Job48->new( $id, $self->application->session->user );
  unless ($job) {
    $self->application->error("Invalid job id given (id='$id').");
    return $content;
  }
  
  # check if a user is logged in
  if ($self->application->authorized(1)) {
    
    $self->title('Annotation Server - Job Details #'.$id);
    $content = $self->details( $job );
  }
  
  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error().
      "<br/>Please return to the <a href='".$self->application->url."?page=Login'>login page</a>.</p>";
  }
  
  return $content;
}



sub details {
    my ($self, $job) = @_;
    
    # start content
    my $content = "<h1>Job Details #".$job->id."</h1>";
    
    my ($img, $status_text);
    
    my $formats = { 'genbank' => 'GenBank', 
		    'embl' => 'embl', 
		    'GTF' => 'GTF', 
		    'gff' => 'GFF3' };
    my @values = keys(%$formats);
    
    # add a few final urls
    if ($job->meta->get_metadata('status.final') and
	$job->meta->get_metadata('status.final') eq 'complete') {
      $content .= '<p> &raquo; <a target="_blank" href="index.cgi?action=ShowOrganism&initial=1&genome='.
	$job->genome_id.'&job='.$job->id.'">Browse annoted genome in SEED Viewer</a></p>';
      $content .= '<form action="'.$self->application->url.'" method="post">'.
	'<p> &raquo; Export the annotated genome as '.
	  "<input type=hidden name=page value=ExportGenome >".
	    "<input type=hidden name=job value=".$job->id." >".
	      $self->application->cgi->popup_menu( -name => 'format', -default => 'genbank',
						   -values => \@values, -labels => $formats, ).
						     $self->application->cgi->submit( -name => 'Go!' ).
						       '</form></p>';
      $content .= '<p> &nbsp; <em> (Exporting the genome may take a while. A save file dialog will appear once it is done.)</em></p>';
    }

    $content .= "<p> &raquo <a href='".$self->application->url."?page=Jobs'>Back to the Jobs Overview</a></p>";
    
    # upload
    ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.uploaded'), 
								 'Genome Upload');
    $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";
    $content .= "<table>";
    $content .= "<tr><th>Genome:</th><td>".$job->genome_id." - ".$job->genome_name."</td></tr>";
    $content .= "<tr><th>Job:</th><td> #".$job->id."</td></tr>";
    $content .= "<tr><th>User:</th><td>".$job->user."</td></tr>";
    $content .= "<tr><th>Date:</th><td>".localtime($job->meta->get_metadata('upload.timestamp'))."</td></tr>";
    $content .= "</table>";
    
    # preprocessing
    ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.preprocess'), 
								 'Preprocessing');
    $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

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
      my $value = $job->meta->get_metadata($s->[0]);
      if ($value) {
	$statistics .= "<tr><th>".$s->[1].":</th><td>".$value."</td></tr>";
      }
    }
    
    if ($statistics) {
      $content .= "<table> $statistics </table>";
    }
    
    # blast sim
    ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.sims'),
                                                                 'Similarity computation');
    $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";
    
    # blast phylo
    ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.sims_postprocess'),
                                                                 'Similarity postprocessing');
    $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";
    
    ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.final'), 
								 'Final Assigment');
    $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";
    
    return $content;

}

