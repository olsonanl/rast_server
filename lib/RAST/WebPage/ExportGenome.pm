package RAST::WebPage::ExportGenome;

use strict;
use warnings;

use base qw( WebPage );
use WebConfig;

use FortyEight::SeedExport;
use File::Basename;

use RAST::RASTShared qw( get_menu_job );

1;


=pod

=head1 NAME

ExportGenome - an instance of WebPage which exports a genome job

=head1 DESCRIPTION

Export Genome page

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Export Genome");

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

  my $content = '<h1>Export annotated genome for job #'.$job->id.'</h1>';

  # get parameters
  my $format = $self->app->cgi->param('format') || '';
  my $strip  = $self->app->cgi->param('strip_ec');
  $strip = 1 if ($format and $format eq 'default');

  # format missing, ask for parameters
  unless ($format) {
    
    my $formats = { 'genbank' => 'GenBank', 'embl' => 'embl', 'GTF' => 'GTF', 'gff' => 'GFF3' };
    my @values = keys(%$formats);

    $content .= $self->start_form('export', { page => 'ExportGenome', job  => $job->id });
    $content .= "<p><strong>Choose export format: </strong>";
    $content .= $self->app->cgi->popup_menu( -name => 'format', -default => 'genbank',
					     -values => \@values, -labels => $formats, )."</p>";
    $content .= "<p>".$self->app->cgi->checkbox( -name => 'strip_ec', -checked=>1, -value=>'ON',
	 -label=>'omit EC/TC numbers from the product name (annotation text)')."</p>";
    $content .= $self->app->cgi->submit( -name => ' Download genome ' )."</p>";
    $content .= $self->end_form;
    $content .= '<p><em> (Exporting the genome may take a while. A save file dialog will appear once it is done.)</em></p>';
    $content .= '<p> &raquo; <a href="?page=JobDetails&job='.$job->id.'">Back to the Job Details</a></p>';
    
  }
  # export
  else {
    $format = 'genbank' if ($format eq 'default');
    my ($output, $msg) = SeedExport::export( { 'virtual_genome_directory' => $job->org_dir,
					       'genome' => $job->genome_id, 
					       'directory' => $FIG_Config::temp . "/", 
					       'export_format' => $format,
					       'strip_ec' => $strip 
					     } );
    
    if (-f $output) {
      open(FILE, $output) or 
	$self->app->error("Unable open export file for job ".$job->id.": $output");
      print "Content-Type:application/x-download\n";  
      print "Content-Disposition:attachment;filename=".basename($output)."\n\n";
      while(<FILE>) {
	print $_;
      }
      close(FILE);
      die 'cgi_exit';
    }

  }

  return $content;

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



