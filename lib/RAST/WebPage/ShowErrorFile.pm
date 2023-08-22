package RAST::WebPage::ShowErrorFile;

use strict;
use warnings;

use base qw( WebPage );
use WebConfig;

use File::Basename;

1;


=pod

=head1 NAME

ShowErrorFile - an instance of WebPage that dumps the contents of a file from rp.errors to the user.

=head1 DESCRIPTION

Show an error file.

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("");

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  my $error_file = $self->application->cgi->param('file');
  $error_file = $self->application->cgi->param('files') if $error_file eq '';
  if ($error_file eq '' or $error_file =~ m,/,)
  {
      $self->app->error("Invalid file specfication.");
  }
  $self->data('file', $error_file);
  $self->data('job', $job);

}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
    my ($self) = @_;

    my $job = $self->data('job');
    my $file = $job->directory . '/rp.errors/' . $self->app->cgi->param('file');
    
    -f $file or $file = $job->org_dir."/" . $self->app->cgi->param('file');
    
    if (!open(FILE, "<$file"))
    {
	$self->app->error("Unable open file for job ".$job->id.": $file <br> $@");
	return;
    }

    my $size = -s FILE;
    
    print "Content-Type: text/plain\n";  
    print "Content-Length: $size\n";
    print "\n";

    my $buf;
    while (read(FILE, $buf, 4096))
    {
	print $buf;
    }
    close(FILE);
    die 'cgi_exit';
}


=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], ];
  push @$rights, [ 'edit', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}



