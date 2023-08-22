package RAST::WebPage::Genome;

use strict;
use warnings;

use POSIX;

use base qw( WebPage RAST::WebPage::JobDetails );
use WebConfig;

use RAST::RASTShared qw( get_menu_job );

1;


=pod

=head1 NAME

Genome - displays detailed information about a genome job

=head1 DESCRIPTION

Job Details (Genome) page 

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
    
    # register quality revision actions
    $self->application->register_action($self, 'set_correction_requests', 'Correct selected quality problems');
    $self->application->register_action($self, 'accept_genome_quality', 'Accept quality and proceed');
}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
    my ($self) = @_;
    
    my $job = $self->data('job');
    
    my $content = '<h1>Job Details #'.$job->id.'</h1>';
    
    if ($self->application->session->user->is_admin($self->application->backend)) {
	$content .= '<p> &raquo; <a href="mailto:' . $job->owner->email . '">send email to ' 
	    . $job->owner->firstname . ' ' . $job->owner->lastname . ' (job owner)</a></p>';
    }
    
    if ($job->ready_for_browsing) {
	# check for PrivateOrganismPreferences
	my $application = $self->application;
	my $user = $application->session->user;
	my $prefs = $application->dbmaster->Preferences->get_objects( { user => $user, name => 'PrivateOrganismPeer' } );
	my $job_is_peer = 0;
	if (scalar(@$prefs)) {
	    foreach my $pref (@$prefs) {
		if ($pref->value eq $job->genome_id) {
		    $job_is_peer = 1;
		    last;
		}
	    }
	} else {
	    $application->dbmaster->Preferences->create( { user => $user, name => 'PrivateOrganismPeer', value => $job->genome_id } );
	    $job_is_peer = 1;
	}
	
	$content .= '<p> &raquo; <a target="_blank" href="seedviewer.cgi?page=Organism&organism='.
	    $job->genome_id.'">Browse annotated genome in SEED Viewer</a></p>';
    }

    my $link = $job->metaxml->get_metadata("model_build.viewing_link");
    if ($link && $link =~ /\S/)
    {
	$content .= qq(<p> &raquo; <a target="_blank" href="$link">View metabolic model</a></p>);
    }
    
    # check for downloads
    my $downloads = $job->downloads();
    
    my $scheme = $job->metaxml->get_metadata('annotation_scheme');
    if ($scheme eq 'RASTtk' && $job->metaxml->get_metadata('rasttk_workflow')) {
	# See RAST/WebPage/DownloadFile.pm for special case code for this file.
	
	unshift(@$downloads, ['workflow.json', 'RASTtk workflow']);
    }
    
    if (scalar(@$downloads)) 
    {
	@$downloads = sort { $a->[1] cmp $b->[1] } @$downloads;
	my @values = map { $_->[0] } @$downloads;
	my %labels = map { $_->[0] => $_->[1] || $_->[0] } @$downloads;
	my @default = grep { 1 if $_->[1] eq 'Genbank' } @$downloads;
	
	$content .= $self->start_form('download', { page => 'DownloadFile', job => $job->id });
	$content .= '<p> &raquo; Available downloads for this job: ';
	$content .= $self->app->cgi->popup_menu( -name => 'file',
						 -values => \@values,
						 -labels => \%labels,
						 -default => $default[0][0],
	    );
	$content .= "<input type='submit' name='do_download' value=' Download '>";
	$content .= "<input type='submit' name='do_update' value=' Update download files '>";
	$content .= $self->end_form;
    }
    else {
	if ($job->ready_for_browsing) {
	    $content .= '<p> &raquo; No downloads available for this genome yet.</p>';
	}
    }
    
    if ($self->app->session->user->has_right(undef, 'edit', 'genome', $job->genome_id, 1) and
	$self->app->session->user->has_right(undef, 'view', 'genome', $job->genome_id, 1)) {
	$content .= '<p> &raquo; <a href="?page=JobShare&job='.$job->id.
	    '">Share this genome with selected users</a> ';
    }
    
    my $dir = $job->dir;
    my $gid = $job->genome_id;
    my $jid = $job->id;
    
    if ($job->ready_for_browsing) {
	$content .= "<p> &raquo; View <a href='?page=ComputeCloseStrains&job=$jid'>Close Strains for this job</a> <p>\n";
    }
    
    if (0) {
	if ($job->genome_id =~ /^666666(6?)\./) {
	    $content .= "<p> &raquo; <i>This genome cannot be submitted to PATRIC because it does not have a valid taxon identifier; if you wish to submit it to PATRIC you may resubmit the genome to RAST and choose a valid taxon identifier.<br>\n";
	    $content .= "You may read more about PATRIC submission <a target='_blank' href=''>in this document.</a></i>\n";
	}
	else {
	    my $submit_url = "rast.cgi?page=PATRICSubmit&job=" . $job->id;
	    $content .= "<p> &raquo; <a href='$submit_url'>Submit this genome for inclusion in PATRIC</a><br>";
	    $content .= "You may read more about PATRIC submission <a target='_blank' href='Html/PATRIC_Submission.html'>in this document.</a>\n";
	}
    }
    
    $content .= "<p> &raquo <a href='?page=Jobs'>Back to the Jobs Overview</a></p>";
    
    # upload
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.uploaded'),
				       'Genome Upload');
    $content .= "<table>";
    $content .= "<tr><th>Genome ID - Name:</th><td>".$job->genome_id." - ".$job->genome_name."</td></tr>";
    $content .= "<tr><th>Job:</th><td> #".$job->id."</td></tr>";
    $content .= "<tr><th>User:</th><td>".$job->owner->login."</td></tr>";
    $content .= "<tr><th>Date:</th><td>".localtime($job->metaxml->get_metadata('upload.timestamp'))."</td></tr>";
    
    $content .= "<tr><td colspan=2></td></tr>";
    
#   $content .= "<tr><th>Sequencing method:</th><td>".$job->metaxml->get_metadata('genome.sequencing_method')."</td></tr>";
#   $content .= "<tr><th>Coverage:</th><td>".$job->metaxml->get_metadata('genome.coverage')."</td></tr>";
#   $content .= "<tr><th>Number of contigs:</th><td>".$job->metaxml->get_metadata('genome.contigs')."</td></tr>";
#   $content .= "<tr><th>Read length:</th><td>".($job->metaxml->get_metadata('genome.read_length') || '')."</td></tr>";
    
    $content .= "<tr><th>Genetic code:</th><td>".$job->metaxml->get_metadata('genome.genetic_code')."</td></tr>";
    
    $content .= "<tr><td colspan=2></td></tr>";

#   my $text = $job->metaxml->get_metadata('import.candidate')? 'yes' : 'no';
#   $content .= "<tr><th>Include into SEED:</th><td>".$text."</td></tr>";
    
    my $text = $job->metaxml->get_metadata('annotation_scheme');
    $text = "(RASTClassic)" unless $text;
    $content .= "<tr><th>Annotation scheme:</th><td>".$text."</td></tr>";
    
    $text = $job->metaxml->get_metadata('keep_genecalls')? 'yes' : 'no';
    $content .= "<tr><th>Preserve gene calls:</th><td>".$text."</td></tr>";
    
    $text = $job->metaxml->get_metadata('correction.automatic')? 'yes' : 'no';
    $content .= "<tr><th>Automatically fix errors:</th><td>".$text."</td></tr>";
    
    $text = $job->metaxml->get_metadata('correction.frameshifts')? 'yes' : 'no';
    $content .= "<tr><th>Fix frameshifts:</th><td>".$text."</td></tr>";
    
    $text = $job->metaxml->get_metadata('correction.backfill_gaps')? 'yes' : 'no';
    $content .= "<tr><th>Backfill gaps:</th><td>".$text."</td></tr>";
    
    $content .= "</table>";
    
    # rapid propagation
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.rp'),
				       'Rapid Propagation');
    
    # quality check
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.qc'), 
				       'Quality Check');
    
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
	if ($job->metaxml->get_metadata($qc->[0])) {
	    my ($type, $value) = @{$job->metaxml->get_metadata($qc->[0])};
	    if ($value or ($type and $type eq 'SCORE')) {
		my $info = ($type eq 'SCORE') ? '' : ucfirst(lc($type));
		$statistics .= "<tr><th>".$qc->[1].":</th><td>".$value."</td><td>".$info."</td></tr>";
	    }
	}
    }
    
    if ($statistics) {
	$content .= "<p>For detailed explanations of the terms used in our quality report, please refer to <a href='http://www.theseed.org/wiki/index.php/RAST_Quality_Report' target='_blank'>our wiki</a>.</p>";
	$content .= "<table> $statistics </table>";
    }
    
    
    # correction phase
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.correction'), 
				       'Quality Revision');
    
    # correction request form
    if ($job->metaxml->get_metadata('status.correction') and
	$job->metaxml->get_metadata('status.correction') eq 'requires_intervention') {
	
	$content .= '<p id="section_content">Please select the correction procedures you would like to run on your genome and press the <em>Correct selected quality problems</em> button. If you do want to keep the all information despite failure to meet the quality check requirements, accept the genome as it is.</p>';
	$content .= '<p id="section_content">Please refer to our documentation to find a <a href="http://www.theseed.org/wiki/index.php/SponkeyQualityRevision" target="_blank">detailed explanation of the quality revision</a>.</p>';
	
	my $corrections = { 'remove_embedded_pegs' => 'Remove embedded genes', 
			    'remove_rna_overlaps'  => 'Remove RNA overlaps', };
	
	my $possible = $job->metaxml->get_metadata("correction.possible");
	
	$content .= '<p>'.$self->start_form(undef, { 'job' => $job->id });
	$content .= join('', $self->app->cgi->checkbox_group( -name      => 'corrections',
							      -values    => $possible,
							      -linebreak => 'true',
							      -labels    => $corrections,
			 )
	    );
	
	$content .= "</p><p>".$self->app->cgi->submit(-name => 'action', -value => 'Correct selected quality problems');
	$content .= " &laquo; or &raquo; ";
	$content .= $self->app->cgi->submit(-name => 'action', -value => 'Accept quality and proceed');
	$content .= $self->end_form.'</p>';  
    }
    
    # show info if quality revision is running
    if ($job->metaxml->get_metadata('correction.request') and
	$job->metaxml->get_metadata('status.correction') and
	$job->metaxml->get_metadata('status.correction') ne 'complete' ) {
	$content .= "<p>Quality revision has been requested for this job.</p>";
    }
    
    # show info if quality revision is complete
    if ($job->metaxml->get_metadata('status.correction') and
	$job->metaxml->get_metadata('status.correction') eq 'complete') {
	if ($job->metaxml->get_metadata('correction.timestamp') and
	    $job->metaxml->get_metadata('correction.acceptedby')) {
	    $content .= "<table>";
	    $content .= "<tr><th>Accepted by:</th><td>".$job->metaxml->get_metadata('correction.acceptedby')."</td></tr>";
	    $content .= "<tr><th>Date:</th><td>".localtime($job->metaxml->get_metadata('correction.timestamp'))."</td></tr>";
	    $content .= "</table>";
	}
	else {
	    $content .= "<p>No quality revision was necessary.</p>";
	}
    }
    
    
    # similarity computation
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.sims'), 
				       'Similarity Computation');
    
    # BBH computation
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.bbhs'), 
				       'Bidirectional Best Hit Computation');
    
    # auto assignement
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.auto_assign'), 
				       'Auto Assignment');
    
    # PCH computation
    $content .= $self->get_section_bar($job->metaxml->get_metadata('status.pchs'), 
				       'Computation of Pairs of Close Homologs');
    
    # Scenario computation
    # $content .= $self->get_section_bar($job->metaxml->get_metadata('status.scenario'), 
    #                                    'Scenario Computation (metabolic reconstruction)');
    
    return $content;
}


=item * B<set_correction_requests> ()

Action method that will set the requested quality corrections.

=cut

sub set_correction_requests {
    my ($self) = @_;
    
    my @corrections = $self->application->cgi->param('corrections');
    my $job = $self->data('job');  
    
    if (scalar(@corrections)) {
	$self->application->add_message('info', 'Quality revision(s) requested.');
	$job->metaxml->set_metadata('status.correction', 'not_started');
	$job->metaxml->set_metadata('correction.request', \@corrections);
	$job->metaxml->set_metadata('correction.acceptedby', $self->application->session->user->login);
	$job->metaxml->set_metadata('correction.timestamp', time());
    }
    else {
	$self->application->add_message('info', 'You did not select any quality revision. Nothing changed.');
    }
}


=item * B<accept_genome_quality> ()

Action method that will set the quality revision to accepted 

=cut

sub accept_genome_quality {
    my ($self) = @_;
    
    $self->application->add_message('info', 'Genome quality accepted.');
    
    my $job = $self->data('job');  
    if ($job->metaxml->get_metadata('status.uploaded') eq 'complete' and 
	$job->metaxml->get_metadata('status.rp') eq 'complete' and 
	$job->metaxml->get_metadata('status.qc') eq 'complete' and
	$job->metaxml->get_metadata('status.correction') ne 'complete') {
	
	$job->metaxml->set_metadata('status.correction', 'complete');
	$job->metaxml->set_metadata('correction.timestamp', time());
	$job->metaxml->set_metadata('correction.acceptedby', $self->application->session->user->login);
    }
    else {
	$self->application->error('Illegal call of proceed genome quality.');
    }
}
