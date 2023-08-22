package RAST::WebPage::Jobs;

use strict;
use warnings;

use base qw( WebPage );

use WebComponent::WebGD;
use WebConfig;
use Data::Dumper;
use File::Slurp;

1;


=pod

=head1 NAME

Jobs - an instance of WebPage which displays an overview over all jobs

=head1 DESCRIPTION

Job overview page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
    my $self = shift;
    
    $self->title("Jobs Overview");
    $self->application->register_component('Table', 'Jobs');
    
    my $motd_file = "RAST.motd";
    if (my $msg = read_file($motd_file, err_mode => 'quiet'))
    {
	$self->application->add_message('info', $msg);
    }
}  

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
    my ($self) = @_;
    my $content = "";

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Job Load Report
#-----------------------------------------------------------------------
    my $rast_queue_load;
    if (defined($FIG_Config::daily_statistics_dir)) {
	if (open(QUEUE, '<', "$FIG_Config::daily_statistics_dir/rast_queue")) {
	    if (defined($rast_queue_load = <QUEUE>)) {
		$content .= "<h1>$rast_queue_load</h1>";
		
		my $load = qq();
		my ($num_jobs)  = ($rast_queue_load =~ m/(\d+)\s+jobs/);
		if (defined($num_jobs)) {
		    if ($num_jobs < 20) {
			$load = q(<font color=GREEN>Light</font>);
		    }
		    elsif ($num_jobs < 75) {
			$load = q(<font color=ORANGE>Moderate</font>);
		    }
		    elsif ($num_jobs < 150) {
			$load = q(<font color=RED>Heavy</font>);
		    }
		    else {
			$load = q(<font color=MAGENTA>Very Heavy</font>);
		    }
		    $content .= "<h1>Job Load is $load</h1>";
		}
		else {
		    $content .= "<h1>Job Load could not be parsed</h1>";
		}
	    }
	    close(QUEUE);
	}
	else {
	    $content .= '<h1>(Job Load is Unavailable)</h1>';
	}
    }
    else {
	$content .= '<h1>(Job Load is Unavailable)</h1>';
    }


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Main Body...
#-----------------------------------------------------------------------
    $content .= '<h1>Jobs Overview</h1>';
    
    $content .= '<p>The overview below list all genomes currently processed and the progress on the annotation. '
	.'To get a more detailed report on an annotation job, please click on the progress bar graphic in the overview.</p>';
    
    $content .= '<p>In case of questions or problems using this service, please contact: '
	.(($WebConfig::RAST_TYPE eq 'metagenome') 
	  ? '<a href="mailto:mg-rast@mcs.anl.gov">mg-rast@mcs.anl.gov</a>'
	  : '<a href="mailto:rast@mcs.anl.gov">rast@mcs.anl.gov</a>')
	.'.</p>';
    
    $content .= $self->get_color_key();
    
    $content .= '<h2>Jobs you have access to :</h2>';
    
    my $data = [];
    my @job_list;
    my $users;
    my $pjobs;
    my %admins;
    
    eval {

	@job_list = $self->app->data_handle('RAST')->Job->get_jobs_for_user_fast($self->application->session->user, 'view');

	#
	# Gather the user ids from the job list, and query for them.
	#
	
	my $udbh = $self->application->session->user->_master->db_handle;
	
	my %users = map { (ref($_) && $_->{owner} =~ /^\d+$/ ) ? ($_->{owner}  => 1) : () } @job_list;

	if (scalar(keys(%users))) {
	  my $user_cond = join(", ", keys %users);
	  $users = $udbh->selectall_hashref(qq(SELECT _id, firstname, lastname, email
					     FROM User
					     WHERE _id IN ($user_cond)), '_id');
	  
	  #
	  # Create display names for users, with email addresses if we're an admin.
	  #
	  
	  my $user = $self->app->session->user;
	  my $app  = $self->application->backend;
	  my $user_is_admin = $user and $user->is_admin($app);
	  
	  for my $val (values (%$users))
	    {
	      if ( $val->{email} and $user_is_admin )
		{
		  $val->{name_display} = qq(<a href="mailto:$val->{email}, rast\@mcs.anl.gov">$val->{lastname}, $val->{firstname}</a>);
		} else {
		  $val->{name_display} = "$val->{lastname}, $val->{firstname}";
		  
		}
	    }
	  
	} else {
	  @job_list = ();
	}
    };
    
    if (ref $pjobs and scalar (@$pjobs) ){
	$content .= "<p>You currently have access to ".scalar @$pjobs." public jobs.</p>";	
    }
    elsif ($WebConfig::RAST_TYPE eq 'metagenome'){
	$content .= "<p>There are no public jobs.</p>";
    }
    
    my $user = $self->app->session->user->_id;
    my $is_admin = $admins{$user};

    if (scalar(@job_list)) {
	@job_list = sort { $b->{id} <=> $a->{id} } @job_list;
	foreach my $job (@job_list) {
	    push @$data, $self->genome_entry_fast($job, $users, $is_admin);
	}
	# create table
	my $table = $self->application->component('Jobs');
	$table->width(800);
	if (scalar(@$data) > 50) {
	    $table->show_top_browse(1);
	    $table->show_bottom_browse(1);
	    $table->items_per_page(50);
	    $table->show_select_items_per_page(1);
	}
	$table->columns([ { name => 'Job', filter => 1, sortable => 1 }, 
			  { name => 'Owner', filter => 1, sortable => 1 },
			  { name => 'ID', filter => 1, sortable => 1 },
			  { name => 'Name', filter => 1, sortable => 1 },
			  { name => 'Num contigs', sortable => 1 },
			  { name => 'Size (bp)', sortable => 1 },
			  { name => 'Creation Date' },
			  { name => 'Annotation Progress' },
			  { name => 'Status', filter => 1, operator => 'combobox' }
			 ]);
	$table->data($data);
	$content .= $table->output();
    }
    else {
	$content .= "<p>You currently have no jobs.</p>";
	$content .= "<p> &raquo <a href='?page=Upload'>Upload a new genome</a></p>";
    }
    
    return $content;
}

=pod

=item * B<genome_entry> (I<job>)

Returns one entry row for the overview table, containing job id, user, 
genome info and the progress bar graphic. I<job> has to be the reference 
to a RAST::Job object.

=cut

sub genome_entry_fast {
    my ($self, $job, $users, $is_admin) = @_;
    
    my $stages;
    if ($job->{type} eq 'Metagenome')
    {
	$stages = $job->{server_version} == 1 ? RAST::Job::stages_for_mgrast_1() : RAST::Job::stages_for_mgrast_();
    }
    else
    {
	$stages = RAST::Job::stages_for_rast();
    }
    
    # create a new image
    my $height = 14; my $box_width = 12;
    my $image = WebGD->new(scalar(@$stages)*$box_width,$height);
    
    # allocate some colors
    my $colors = $self->get_colors($image);
    
    # make the background transparent and interlaced
    $image->transparent($colors->{'white'});
    $image->interlaced('true');
    my $info = '';
    
    my $index = 0;
    my $cs = 'not started';
    foreach my $stage (@$stages)
    {
	my $s = $job->{status}->{$stage} || '';
	my $status = $s !~ /^\s*$/ ? $s : 'not_started';
	if (!exists($colors->{$status})) {
	    $status = 'not_started';
	}
	$image->filledRectangle($index*$box_width,0,10+$index*$box_width,$height,$colors->{$status});
	
	if ($status ne 'not_started') {
	    $status =~ s/_/ /g;
	    unless (($status eq 'complete') && ($index != scalar(@$stages) - 1)) {
	      $cs = $status;
	    }
	    my $steps = $index + 1;
	    $info = "$steps of ".scalar(@$stages)." steps, current step: $status ";
	}
	$index++;
    }

    my $id = $job->{id};
    my $progress = '<img style="border: none;" src="'.$image->image_src.'"/>';
    my $link_img  = "<a title='$info' href='?page=JobDetails&job=".$id."'>$progress</a>";
    my $link_text = "[ <a href='?page=JobDetails&job=".$id."'><em> view details </em></a> ]";

    my $owner = $users->{$job->{owner}};
    
    my $creation_date = $job->{created_on};
    #my $size = $job->metaxml->get_metadata('preprocess.count_raw.total') || 0;
    my $size = $job->{bp_count};
    
    return [ $job->{id}, $owner->{name_display}, $job->{genome_id}, $job->{genome_name},
	    $job->{contig_count}, $size, $creation_date, $link_img.'<br/>'.$link_text, $cs ];
}

sub genome_entry {
  my ($self, $job) = @_;

  # create a new image
  my $height = 14; my $box_width = 12;
  my $image = WebGD->new(scalar(@{$job->stages})*$box_width,$height);

  # allocate some colors
  my $colors = $self->get_colors($image);

  # make the background transparent and interlaced
  $image->transparent($colors->{'white'});
  $image->interlaced('true');
  my $info = '';

  my $index = 0;
  foreach my $stage (@{$job->stages}) {
    my $s = $job->status($stage);
    my $status = (ref $s) ? $s->status : 'not_started';
    if (exists($colors->{$status})) {
      $image->filledRectangle($index*$box_width,0,10+$index*$box_width,$height,$colors->{$status});
    }
    else {
      die "Found unknown status for stage '$stage' in job ".$job->id."\n";
    }

    if ($status ne 'not_started') {
      $status =~ s/_/ /g;
      my $steps = $index + 1;
      $info = "$steps of ".scalar(@{$job->stages})." steps, current step: $status ";
    }
    $index++;
  }

  my $progress = '<img style="border: none;" src="'.$image->image_src.'"/>';
  my $link_img  = "<a title='$info' href='?page=JobDetails&job=".$job->id."'>$progress</a>";
  my $link_text = "[ <a href='?page=JobDetails&job=".$job->id."'><em> view details </em></a> ]";
  my $email     = $job->owner->email if (ref $job->owner);
  my $firstname = $job->owner->firstname if (ref $job->owner);
  my $lastname  = $job->owner->lastname if (ref $job->owner);

  my $name_display;

  my $user = $self->app->session->user;
  my $app  = $self->application->backend;

  if ( $firstname and $lastname ) {
      if ( $email and $user and $user->is_admin($app) ) {
	  $name_display = qq(<a href="mailto:$email, rast\@mcs.anl.gov">$lastname, $firstname</a>);
      } else {
	  $name_display = "$lastname, $firstname";
      }
  } else {
      $name_display = 'unknown';
  }

  my $creation_date = $job->created_on;
  my $size = 0;
  if ($WebConfig::RAST_TYPE eq 'metagenome')
  {
      $size = $job->metaxml->get_metadata('preprocess.count_raw.total') || 0;
  }
    
  return [ $job->id, $name_display, $job->genome_id, $job->genome_name, $size, $creation_date, $link_img.'<br/>'.$link_text ];
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

  my $html = "<h4>Progress bar color key:</h4>";
  foreach my $k (@$keys) {
    
    my $image = WebGD->new(10, 14);
    my $colors = $self->get_colors($image);
    $image->filledRectangle(0,0,10,14,$colors->{$k->[0]});
    $html .= '<img style="border: none;" src="'.$image->image_src.'"/> '.$k->[1].'<br>';
    
  }

  return $html;
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

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  return [ [ 'login' ],
	 ];
}
