package RAST::WebPage::DownloadFile;

use strict;
use warnings;

use base qw( WebPage );
use WebConfig;

use File::Basename;
use JSON::XS;

1;


=pod

=head1 NAME

DownloadFile - an instance of WebPage provides a file download

=head1 DESCRIPTION

Download File page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Download File");
  $self->omit_from_session(1);

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  $self->data('job', $job);

}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  my $job = $self->data('job');

  if ($self->app->cgi->param('do_update'))
  {
      #
      # Enqueue a request to recompute downloads.
      #

      my $dir = $job->dir;
      my $id = $job->id;
      my $cmd = ". /vol/sge/default/common/settings.sh; " .
	  "qsub -e $dir/sge_output -o $dir/sge_output " .
	  " -q compute.q " .
	  "-N exp_$id -v PATH -b yes $FIG_Config::bin/rp_write_exports $dir > /tmp/submit.$$";
      my $rc = system($cmd);
      if ($rc != 0)
      {
	  warn "Error $rc submitting $cmd\n";
	  return "Error encountered while submitting download recomputation.\n";
      }
      else
      {
	  return ("Download file recomputation has been submitted.\n"
		  . "Please note that it will take a few minutes to regenerate your files.\n"
		  );
      }
  }
  
  my $base = $self->app->cgi->param('file');

  #
  # Special case downloads that aren't really files.
  #

  if ($base eq 'workflow.json')
  {
      my $id = $job->id;
      my $wf = $job->metaxml->get_metadata("rasttk_workflow");
      my $json = JSON::XS->new->pretty(1);
      my $enc = $json->encode($wf);

      print "Content-Type:application/x-download\n";  
      print "Content-Length: " . length($enc) . "\n";
      print "Content-Disposition:attachment;filename=job_${id}.workflow.json\n\n";
      print $enc;
      die 'cgi_exit';
  }
  
  if ($base =~ m,/,)
  {
    $self->app->error("Unable open / find file for job ".$job->id.": $base");
    return;
  }
  my $file = $job->download_dir . "/$base";

  if (! -f $file && $base =~ /.gbk.gz$/)
  {
    $file = $job->directory() . "/$base";
  }

  if ($base =~ /^fasta$/) {
    $file = $job->org_dir."/Features/peg/fasta";
  }

  if (-f $file) {
    open(FILE, $file) or 
      $self->app->error("Unable open export file for job ".$job->id.": $file");
    print "Content-Type:application/x-download\n";  
    print "Content-Length: " . (stat($file))[7] . "\n";
    print "Content-Disposition:attachment;filename=".
      $self->app->cgi->param('file')."\n\n";
    while(<FILE>) {
      print $_;
    }
    close(FILE);
    die 'cgi_exit';
  }
  else {
    $self->app->error("Unable open / find file for job ".$job->id.": $file");
  }

  return;

}


=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], ];
  push @$rights, [ 'view', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}



