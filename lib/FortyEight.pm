package FortyEight;

use base qw( WebApp::WebLayout );

1;

sub set_content {
  my ($self, $parameters) = @_;
  
  my $content = $parameters->{content} || "";
  my $menu    = $parameters->{menu} || "";
  my $title   = $parameters->{title} || "";

  # fill in variable template parameters
  my $template = $self->_template;
  $template->param( CONTENT => $content);
  $template->param( MENU    => $menu );
  $template->param( TITLE   => $title );

  # fill in static template parameters
  $template->param(STYLESHEET        => "./Html/css/fortyeight.css");
  $template->param(JAVASCRIPT        => "./Html/layout.js");
  $template->param(LOGO              => "./Html/seed-logo-green.png");
  $template->param(LOGO_ALT          => "The SEED Logo @ RAST");
  $template->param(TITLE_IMAGE       => "./Html/rast-title.png");
  $template->param(TITLE_ALT         => "RAST - Rapid Annotation using Subsystem Technology");
  $template->param(VERSION           => "version 1.2");
  $template->param(TITLE_DESCRIPTION => "The NMPDR, SEED-based, prokaryotic genome annotation service.<br/>For more information about the SEED please visit <a href='http://www.theseed.org'>theSEED.org.</a>" );
  $template->param(FOOTER            => "");
}
