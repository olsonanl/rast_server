package WebPage::Genome;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage WebPage::JobDetails );

use Table;

use POSIX;

use Job48;


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

  $self->title('Annotation Server - Jobs Details');
  
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
    
    # accept genome quality and proceed 
    if ($self->application->cgi->param('accept')) {
      $self->accept_genome_quality($job);
    }
    
    # set correction requests 
    elsif ($self->application->cgi->param('correction')) {
      $self->set_correction_requests($job);
    }
    
    $self->title('Annotation Server - Job Details #'.$job->id);
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
  
  my $content = '';
  my $cgi = $self->application->cgi;
  
  # start content
  $content = "<h1>Job Details #".$job->id."</h1>";
  
  my ($img, $status_text);

  my $formats = { 'genbank' => 'GenBank', 
		  'embl' => 'embl', 
		  'GTF' => 'GTF', 
		  'gff' => 'GFF3' };
  my @values = keys(%$formats);

  #############################
  # job done?                 #
  #############################
  if ($job->meta->get_metadata('status.final') and 
      $job->meta->get_metadata('status.final') eq 'complete') {

    # add a few final urls
    $content .= '<p> &raquo; <a target="_blank" href="seedviewer.cgi?action=ShowOrganism&initial=1&genome='.
      $job->genome_id.'&job='.$job->id.'">Browse annoted genome in SEED Viewer</a></p>';

    $content .= '<form action="'.$self->application->url.'" method="post">'.
      '<p> &raquo; Export the annotated genome as '.
	"<input type=hidden name=page value=ExportGenome >".
	"<input type=hidden name=job value=".$job->id." >".
	$self->application->cgi->popup_menu( -name => 'format', -default => 'genbank',
					     -values => \@values, -labels => $formats, ).
					     $self->application->cgi->submit( -name => 'Go!' ).
	"<br/>&nbsp;&nbsp;&nbsp;".
	$self->application->cgi->checkbox( -name => 'strip_ec',
					   -checked=>1,
					   -value=>'ON',
					   -label=>'omit EC/TC numbers from the product name (annotation text)').

	'</form></p>';
    $content .= '<p> &nbsp; <em> (Exporting the genome may take a while. A save file dialog will appear once it is done.)</em></p>';
      
    # add browse genome link for admins
    if ($self->application->authorized(2)) {
      $self->application->menu->add_entry("Admin", "Browse Genome", 
					  $self->application->url.'?page=BrowseGenome&initial=1&job='.$job->id);
    }

    my $scenario_tgz = "Models/".$job->genome_id."/Analysis/model_files.tgz";
    if (-f $job->orgdir."/".$scenario_tgz) {
      $content .= "<p> &raquo <a target='_blank' href='".$self->application->url."?page=Download&job=".$job->id."&file=$scenario_tgz'>".
	"Download Flux Balance Model and Model Analysis Reports</a></p>";
    }

  }

  $content .= "<p> &raquo <a href='".$self->application->url."?page=Jobs'>Back to the Jobs Overview</a></p>";

  #############################
  # upload                    #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.uploaded'),
							      'Genome Upload');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";
  $content .= "<table>";
  $content .= "<tr><th>Genome:</th><td>".$job->genome_id." - ".$job->genome_name."</td></tr>";
  $content .= "<tr><th>Job:</th><td> #".$job->id."</td></tr>";
  $content .= "<tr><th>User:</th><td>".$job->user."</td></tr>";
  $content .= "<tr><th>Date:</th><td>".localtime($job->meta->get_metadata('upload.timestamp'))."</td></tr>";
  $content .= "</table>";

  
  #############################
  # rapid propagation         #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.rp'),
							      'Rapid Propagation');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";
  

  #############################
  # quality check             #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.qc'), 
							       'Quality Check');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

  # build table with quality statistics data
  my $QCs = [[ 'qc.Num_features', 'Number of features' ],
	     [ 'qc.Num_warn', 'Number of warnings' ],
	     [ 'qc.Num_fatal', 'Number of fatal problems' ],
	     [ 'qc.Possible_missing', 'Possibly missing genes' ],
	     [ 'qc.RNA_overlaps', 'RNA overlaps' ],
	     [ 'qc.Bad_STARTs', 'Genes with bad starts' ],
	     [ 'qc.Bad_STOPs', 'Genes with bad stops' ],
	     [ 'qc.Same_STOP', 'Genes with identical stop' ],
	     [ 'qc.Embedded', 'Embedded genes' ],
	     [ 'qc.Impossible_overlaps', 'Critical quality check errors' ],
	     [ 'qc.Too_short', 'Genes which are too short (< 90 bases)' ],
	     [ 'qc.Convergent', 'Convergent overlaps' ],
	     [ 'qc.Divergent', 'Divergent overlaps' ],
	     [ 'qc.Same_strand', 'Same strand overlaps' ],
	    ];
  
  my $statistics = '';
  foreach my $qc (@$QCs) {
    if ($job->meta->get_metadata($qc->[0])) {
      my ($type, $value) = @{$job->meta->get_metadata($qc->[0])};
      if ($value or ($type and $type eq 'SCORE')) {
	my $info = ($type eq 'SCORE') ? '' : ucfirst(lc($type));
	$statistics .= "<tr><th>".$qc->[1].":</th><td>".$value."</td><td>".$info."</td></tr>";
      }
    }
  }
  
  if ($statistics) {
    $content .= "<table> $statistics </table>";
  }
  

  #############################
  # correction phase          #
  #############################

  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.correction'), 
							      'Quality Revision');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

  # correction request form
  if ($job->meta->get_metadata('status.correction') and
      $job->meta->get_metadata('status.correction') eq 'requires_intervention') {
    
    $content .= '<p id="section_content">Please select the correction procedures you would like to run on your genome and press the <em>Correct selected quality problems</em> button. If you do want to keep the all information despite failure to meet the quality check requirements, accept the genome as it is.</p>';
    $content .= '<p id="section_content">Please refer to our documentation to find a <a href="http://www.theseed.org/wiki/SponkeyQualityRevision" target="_blank">detailed explanation of the quality revision</a>.</p>';

    my $corrections = { 'remove_embedded_pegs' => 'Remove embedded genes', 
			'remove_rna_overlaps'  => 'Remove RNA overlaps', };

    my $possible = $job->meta->get_metadata("correction.possible");
    
    $content .= '<p>'.$self->start_form(undef, { 'job' => $job->id });
    $content .= join('', $cgi->checkbox_group( -name      => 'corrections',
					       -values    => $possible,
					       -linebreak => 'true',
					       -labels    => $corrections,
					     )
		    );
    $content .= "</p><p>".$cgi->submit(-name => 'correction', -value => 'Correct selected quality problems');
    $content .= " &laquo; or &raquo; ";
    $content .= $cgi->submit(-name => 'accept', -value => 'Accept quality and proceed');
    $content .= $self->end_form.'</p>';  
    
  }

  # show info if quality revision is running
  if ($job->meta->get_metadata('correction.request') and
      $job->meta->get_metadata('status.correction') and
      $job->meta->get_metadata('status.correction') ne 'complete' ) {
    $content .= "<p>Quality revision has been requested for this job.</p>";
  }

  # show info if quality revision is complete
  if ($job->meta->get_metadata('status.correction') eq 'complete') {
    if ($job->meta->get_metadata('correction.timestamp') and
	$job->meta->get_metadata('correction.acceptedby')) {
      $content .= "<table>";
      $content .= "<tr><th>Accepted by:</th><td>".$job->meta->get_metadata('correction.acceptedby')."</td></tr>";
      $content .= "<tr><th>Date:</th><td>".localtime($job->meta->get_metadata('correction.timestamp'))."</td></tr>";
      $content .= "</table>";
    }
    else {
      $content .= "<p>No quality revision was necessary.</p>";
    }
  }
  
  #############################
  # similarity computation    #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.sims'), 
							       'Similarity Computation');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

  
  #############################
  # BBH computation           #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.bbhs'), 
							       'Bidirectional Best Hit Computation');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";


  #############################
  # auto assignement          #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.auto_assign'), 
							       'Auto Assignment');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

  #############################
  # PCH computation           #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.pchs'), 
							       'Computation of Pairs of Close Homologs');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

  #############################
  # Scenario computation      #
  #############################
  ($img, $status_text) = $self->get_image_and_text_for_status($job->meta->get_metadata('status.scenario'), 
							       'Scenario Computation (metabolic reconstruction)');
  $content .= "<p id='section_bar'><img src='$img'>$status_text</p>";

  
  return $content;
  
}


sub set_correction_requests {
  my ($self, $job) = @_;

  my @corrections = $self->application->cgi->param('corrections');
  
  if (scalar(@corrections)) {
    $job->meta->set_metadata('status.correction', 'not_started');
    $job->meta->set_metadata('correction.request', \@corrections);
    $job->meta->set_metadata('correction.acceptedby', $self->application->session->user->login);
    $job->meta->set_metadata('correction.timestamp', time());
  }
  
}


sub accept_genome_quality {
  my ($self, $job) = @_;
  
  if ($job->meta->get_metadata('status.uploaded') eq 'complete' and 
      $job->meta->get_metadata('status.rp') eq 'complete' and 
      $job->meta->get_metadata('status.qc') eq 'complete' and
      $job->meta->get_metadata('status.correction') ne 'complete' and 
      ($self->application->session->user->login eq $job->user or
       $self->application->authorized(2))) {

    $job->meta->set_metadata('status.correction', 'complete');
    $job->meta->set_metadata('correction.timestamp', time());
    $job->meta->set_metadata('correction.acceptedby', $self->application->session->user->login);
  
  }
  else {
    $self->application->error('Illegal call of proceed genome quality.');
  }

}



