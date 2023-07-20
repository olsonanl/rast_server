package WebPage::Nosuchpage;

use WebApp::WebPage;

1;

our @ISA = qw ( WebApp::WebPage );

sub output {
  my ($self, $session) = @_;

  my $content = 'The requested page could not be found.';

  return $content;
}
