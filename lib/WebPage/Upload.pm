package WebPage::Upload;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );
use WebPage::UploadGenome;
use WebPage::UploadMetaGenome;

1;

=pod

=head1 NAME

JobDetails - a factory that loads either the Genome or MetaGenome variant of the Upload page

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<new> ()

Creates a new instance of the WebPage object.

=cut

sub new {
  my ($class, $application) = @_;

  my $self;
  if ($application->cgi->param('metagenome') or $ENV{METAGENOME}) {
    $self = WebPage::UploadMetaGenome->new($application);
  }
  else {
    $self = WebPage::UploadGenome->new($application);
  }

  return $self;
}

