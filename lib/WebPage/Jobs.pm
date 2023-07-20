package WebPage::Jobs;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );

use GD;
use MIME::Base64;
use Table;

use Job48;

1;

=pod

=head1 NAME

Jobs - an instance of WebPage which displays the list of jobs currently in pipeline and their status

=head1 SYNOPSIS

TODO

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->title('Annotation Server - Jobs Overview');

  my $content = '';
  
  # check if a user is logged in
  if ($self->application->authorized(1)) {
    
    $content = $self->overview();
    
  }

  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error().
      "<br/>Please return to the <a href='".$self->application->url."?page=Login'>login page</a>.</p>";
  }
  
  return $content;
}

=pod

=item * B<overview> ()

Returns the list of jobs currently in pipeline

=cut

sub overview {
  my ($self) = @_;
  my $content = '<h1>Jobs Overview</h1>';

  $content .= '<p>The overview below list all genomes currently processed and the progress on the annotation.'.
    'To get a more detailed report on an annotation job, please click on the progress bar graphic in the overview.</p>';
  
  my @jobs = Job48::all_jobs();
  
  my $user = [];
  my $orga = [];
  my $all  = [];
  
  my $user_organization = $self->application->session->user->organisation->name();
  
  foreach my $job (@jobs) {

    next if ($job->to_be_deleted);
    
    my $entry = $self->genome_entry($job);

    if ($job->user eq $self->application->session->user->login) {
      push @$user, $entry;
    }
    
    my $jobuser = $job->getUserObject();
    die "Could not get user for job ".$job->id.".\n" unless ($jobuser);
    
    if ($jobuser->organisation->name eq $user_organization) {
      push @$orga, $entry;
    }
    
    push @$all, $entry;
  }

  my $table_defaults = { 'columns' => [ 'Job', 'User', 'Genome ID', 'Genome Name', 'Annotation Progress' ],
			 'show_topbrowse'    => 0,
			 'show_bottombrowse' => 0,
			 'sortable'          => 1,
			 'sortcols'          => { 'Job'         => 1,
						  'User'        => 1,
						  'Genome ID'   => 1,
						  'Genome Name' => 1,
						}, 
			 'table_width'       => 800,
			 'column_widths'     => [ undef, undef, undef, undef, 200 ],
			 'show_filter'       => 1,
			 'operands'          => { 'Job'         => 1,
						  'User'        => 1,
						  'Genome ID'   => 1,
						  'Genome Name' => 1,
						},
		       };

  $content .= $self->get_color_key();

  $content .= "<h4>Your personal jobs:</h4>";
  if (scalar(@$user)) {
    $table_defaults->{'data'} = $user;
    $table_defaults->{'id'} = 'user';
    $content .= Table::new($table_defaults);
  }
  else {
    $content .= "<p>You currently have no jobs.</p>";
    $content .= "<p> &raquo <a href='".$self->application->url."?page=Upload'>Upload a new genome</a></p>";
  }

  $content .= "<h4>Jobs of your Organization:</h4>";
  if (scalar(@$orga)) {
    $table_defaults->{'data'} = $orga;
    $table_defaults->{'id'} = 'org';
    $content .= Table::new($table_defaults);
  }
  else {
    $content .= "<p>Your organization currently has no jobs.</p>";
  }

  if ($self->application->authorized(2)) {
    $content .= "<h4>All jobs:</h4>";
    if (scalar(@$all) ) {
      $table_defaults->{'data'} = $all;
      $table_defaults->{'id'} = 'all';
      $content .= Table::new($table_defaults);
    }
    else {
      $content .= "<p>No jobs found.</p>";
    }

    # add menu item Control Center
    $self->application->menu->add_category("Admin");
    $self->application->menu->add_entry("Admin", "V&#178;C&#178;", $self->application->url."?page=ControlCenter");

  }
  
  return $content;
}

=pod

=item * B<genome_entry> (I<job>)

Returns one entry row for the overview table, containing job id, user, 
genome info and the progress bar graphic. I<job> has to be the reference 
to a Job48 object.

=cut

sub genome_entry {
  my ($self, $job) = @_;

  my @keys = ( 'status.uploaded', 'status.rp', 'status.qc', 'status.correction',
	        'status.sims', 'status.bbhs', 'status.auto_assign', 
	        'status.pchs', 'status.scenario', 'status.final' );
  if ($job->metagenome) {
    @keys = ( 'status.uploaded', 'status.preprocess',
	       'status.sims', 'status.sims_postprocess',
	       'status.final' );
  }

  # create a new image
  my $height = 14; my $box_width = 12;
  my $image = new GD::Image(scalar(@keys)*$box_width,$height);

  # allocate some colors
  my $colors = $self->get_colors($image);

  # make the background transparent and interlaced
  $image->transparent($colors->{'white'});
  $image->interlaced('true');
  
  my $info = '';

  my $index = 0;
  foreach my $k (@keys) {
    my $value = $job->meta->get_metadata($k) || 'not_started';
    if (exists($colors->{$value})) {
      $image->filledRectangle($index*$box_width,0,10+$index*$box_width,$height,$colors->{$value});
    }
    else {
      die "Found unknown status for key '$k' in job ".$job->id."\n";
    }

    if ($value ne 'not_started') {
      $value =~ s/_/ /g;
      my $steps = $index + 1;
      $info = "$steps of ".scalar(@keys)." steps, current step: $value ";
    }
    $index++;
  }
  
  # base64 inline encode
  my $encoded = MIME::Base64::encode($image->png());
  my $progress = qq~<img style="border: none;" src="data:image/gif;base64,$encoded"/>~;

  # assemble details link
  my $link_img = "<a title='$info(click for details)' href='".
    $self->application->url."?page=JobDetails&job=".
    $job->id."'>$progress</a>";
  my $link_text = " [ <a href='".$self->application->url."?page=JobDetails&job=".
    $job->id."'><em> view details </em></a> ]";

  my $entry = [ $job->id, $job->user, $job->genome_id, $job->genome_name, $link_img.'<br/>'.$link_text ];

  return $entry;

}


=pod

=item * B<get_colors> (I<gd_image>)

Returns the reference to the hash of allocated colors. I<gd_image> is mandatory and
has to be a GD Image object reference.

=cut

sub get_colors {
  my ($self, $image) = @_;
  return { 'white' => $image->colorResolve(255,255,255),
	   'black' => $image->colorResolve(0,0,0),
	   'not_started' => $image->colorResolve(185,185,185),
	   'queued' => $image->colorResolve(30,120,220),
	   'in_progress' => $image->colorResolve(255,190,30),
	   'requires_intervention' => $image->colorResolve(255,30,30),
	   'error' => $image->colorResolve(175,45,45),
	   'complete' => $image->colorResolve(60,165,60),
	 };
}


=pod

=item * B<get_color_key> ()

Returns the html of the color key used in the progress bars.

=cut

sub get_color_key {
  my ($self) = @_;



  my $keys = [ [ 'not_started', 'not started' ],
	       [ 'queued', 'queued for computation' ],
	       [ 'in_progress', 'in progress' ],
	       [ 'requires_intervention' => 'requires user input' ],
	       [ 'error', 'failed with an error' ],
	       [ 'complete', 'successfully completed' ] ];

  my $html = "<h4>Progress bar color key:</h4>";;
  foreach my $k (@$keys) {
    
    # create a new image
    my $image = new GD::Image(10,14);
    my $colors = $self->get_colors($image);
    $image->filledRectangle(0,0,10,14,$colors->{$k->[0]});

    # base64 inline encode
    my $encoded = MIME::Base64::encode($image->png());
    $html .= qq~<img style="border: none;" src="data:image/gif;base64,$encoded"/> ~.$k->[1].'</br>';
    
  }

  return $html;
}
