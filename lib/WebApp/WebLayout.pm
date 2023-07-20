package WebApp::WebLayout;

use strict;
use warnings;

use HTML::Template;

1;

sub new {
  my ($class, $template_path) = @_;

  my $self = { _template => HTML::Template->new(filename => $template_path) };

  bless($self, $class);

  return $self;
}

sub set_content {
  die "Abstract Method 'set_content' not implemented.";  
}

sub output {
  my $self = shift;

  return $self->_template->output();
}

sub _template {
  my $self = shift;

  return $self->{_template};
}
