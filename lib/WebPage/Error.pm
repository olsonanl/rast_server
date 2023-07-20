package WebPage::Error;

use base qw( WebApp::WebPage );

1;

=pod

=head1 NAME

Error - display an error page for the WebApplication Server

=head1 DESCRIPTION

WebPage module to display an error message within the context of the WebApplication web framework. This module file only defines the output method, all other functionality is inherited from WebPage.pm

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the Error page.

=cut

sub output {
  my ($self) = @_;
  
  my $html = "<h2>An error has occured:</h2>";
  $html .= "<p>".$self->application->error."</p>";
  
  $html .= "<p>To continue please go back to the <a href='".$self->application->url."'>start page</a>.</p>";
  
  return $html;

}
