package WebPage::JobDebugger;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );

use POSIX;
use File::Basename;

use Job48;

=pod

=head1 NAME

JobDebugger - an instance of WebPage which displays debug information on a job

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  my $content = '';
  
  # check if a user is logged in and admin
  if ($self->application->authorized(2)) {
    
    # delete the job?
    if ($cgi->param('action') and $cgi->param('action') eq 'delete') {
      $self->title('Annotation Server - Delete Job #'.$cgi->param('job'));
      $content = $self->delete_job( $cgi->param('job') );
    }
    else {
      $self->title('Annotation Server - Debug Job #'.$cgi->param('job'));
      $content = $self->debug( $cgi->param('job') );
    }

  }
  else {
    $self->application->error('Not authorized to access jobs in debug mode.');
  }

  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error().
      "<br/>Please return to the <a href='".$self->application->url."?page=Login'>login page</a>.</p>";
  }
  
  return $content;
}


sub debug {
    my ($self, $id) = @_;
    
    my $content = '';
    my $cgi = $self->application->cgi;
    
    # sanity check on job
    my $job = Job48->new( $id );
    unless ($job) {
      $self->application->error("Invalid job id given (id='$id').");
      return $content;
    }
    
    $content = "<h1>Debug Job #$id</h1>";
    $content .= "<p> &raquo <a href='".$self->application->url."?page=Jobs'>Back to the Jobs Overview</a></p>";
    $content .= "<p> &raquo <a href='".$self->application->url."?page=JobDetails&job=".
      $id."'>Back to the Job Details</a></p>";
    $content .= "<p>&nbsp;</p>";
    $content .= "<p> &raquo <a href='".$self->application->url."?page=JobDebugger&action=delete&job=$id'>Delete this job</a></p>";
    
    $content .= "<p id='section_bar'><img src='./Html/48-info.png'/>Job Information</p>";
    $content .= "<table>";
    $content .= "<tr><th>Genome:</th><td>".$job->genome_id." - ".$job->genome_name."</td></tr>";
    $content .= "<tr><th>Meta Genome:</th><td>".$job->metagenome."</td></tr>";
    $content .= "<tr><th>Job:</th><td> #".$id."</td></tr>";    
    $content .= "<tr><th>Directory:</th><td>".$job->dir."</td></tr>";
    $content .= "<tr><th>User:</th><td>".$job->user."</td></tr>";
    $content .= "<tr><th>Active:</th><td>".$job->active."</td></tr>";
    $content .= "<tr><th>To be deleted:</th><td>".$job->to_be_deleted."</td></tr>";
    $content .= "</table>";
    
    my $job_dir = $job->dir;
    my $org_dir = $job->orgdir;
    my @stderr_files = <$job_dir/rp.errors/*.stderr>;
    push(@stderr_files, <$org_dir/*.report>);
    
    my @pairs = map { my @a = stat($_); [$_, $a[9]] } @stderr_files;
    @stderr_files = map { $_->[0] } sort { $a->[1] <=> $b->[1] } @pairs;
    
    $content .= "<p id='section_bar'><img src='./Html/48-info.png'/>Error Reports</p>";
    $content .= "<table>";
    for my $sf (@stderr_files) {
      my $b = basename($sf);
      my $url = $self->application->url."?page=JobDebugger&job=$id&file=$b#report";
      my $link = "<a href='$url'>$b</a>";
      $content .= "<tr><td>$link</td></tr>";
    }
    $content .= "</table>";


    if ($cgi->param('file')) {
	my $file = $cgi->param('file');
	$content .= "<p id='section_bar'><img src='./Html/48-info.png'/><a id='report'>Report</a>: $file</p>";
	
	$content .= "<p> &raquo <a href='".$self->application->url."?page=JobDebugger&job=".
	    $id."'>Hide this error report</a></p>";
	
	my $path = $job->orgdir."/$file";
	-f $path or $path = $job->dir."/rp.errors/$file";
	
	if (open(F, "<$path")) {
	    $content .= "<pre>\n";
	    my @fc = <F>;
	    $content .= join('',@fc);
	    $content .= "</pre>\n";
	    close(F);
	}
	else {
	    $content .= "File $file not found in job $id\n";
	}
    }
    
    $content .= "<p id='section_bar'><img src='./Html/48-info.png'/>MetaXML Dump</p>";
    $content .= "<table>";
    for my $key (sort $job->meta->get_metadata_keys()) {
	my $value = $job->meta->get_metadata($key);
	if (ref($value) eq 'ARRAY') {
	    $value = join(', ',@$value);
	}
	$value = '' unless (defined $value);
	$content .= "<tr><th>".$key."</th><td>".$value."</td></tr>";
    }
    $content .= "</table>";
    
    $content .= "<p id='section_bar'><img src='./Html/48-info.png'/>MetaXML Log</p>";
    $content .= "<table>";
    for my $ent (@{$job->meta->get_log()}) {
	my ($type, $ltype, $ts, $entry) = @$ent;
	next unless $type eq 'log_entry';
	$ts = strftime('%c', localtime $ts);
	$ltype =~ s,.*/,,;
	$entry = join('&nbsp;&nbsp; || &nbsp;&nbsp;',@$entry) if (ref($entry) eq 'ARRAY');
	$content .= "<tr><th>".$ts."</th><th>".$ltype."</th><td>".$entry."</td></tr>";
    }
    $content .= "</table>";
    
    return $content;
  
}
  

sub delete_job {
    my ($self, $id) = @_;
    
    # sanity check on job
    my $job = Job48->new( $id );
    unless ($job and $job->active) {
	$self->application->error("Invalid job id given (id='$id').");
	return;
    }

    my $content = "<h1>Deleting Job #$id</h1>";
    $content .= '<p>This job is now scheduled for deletion.</p>';
    $content .= "<p> &raquo <a href='".$self->application->url."?page=Jobs'>Back to the Jobs Overview</a></p>";

    open(DEL, '>'.$job->dir.'/DELETE')
	or die "Cannot create file in ".$job->dir;
    close(DEL);
    unlink ($job->dir.'/ACTIVE');
    
    $job->meta->add_log_entry('genome', 'Job scheduled for deletion by user '.$self->application->session->user->login.'.');

    return $content;
}


1;
