package WebApp::WebApplication;

# WebApplication - framework to develop application-like web sites

# $Id: WebApplication.pm,v 1.1 2007-05-11 19:16:44 paarmann Exp $

use strict;
use warnings;

use Carp qw( confess );

use CGI;

# include default WebPages
use WebPage::Error;

1;

=pod

=head1 NAME

WebApplication - framework to develop application-like web sites

=head1 SYNOPSIS

TODO

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<new> ()

Creates a new instance of the WebApplication object.

=cut

sub new {
    my ($class, $params) = @_;

    my $dbmaster = $params->{dbmaster};
    my $menu     = $params->{menu};
    my $default  = $params->{default};
    my $layout   = $params->{layout};

    my $cgi = CGI->new();

    my $self = { cgi        => $cgi,
		 _dbmaster  => $dbmaster, 
	         session    => $dbmaster->Session->create(),
		 menu       => $menu,
		 default    => $default,
		 error      => undef,
		 layout     => $layout
	       };
    
    bless $self, $class;

    return $self;
}

=pod

=item * B<default> ()

Returns the name of the default page to load.

=cut

sub default {
  return $_[0]->{default};
}


=pod

=item * B<dbmaster> ()

Returns a reference to the dbmaster object.

=cut

sub dbmaster {
  return $_[0]->{_dbmaster};
}


=pod

=item * B<session> ()

Returns a reference to the session object.

=cut

sub session {
  return $_[0]->{session};
}


=pod

=item * B<cgi> ()

Returns a reference to the cgi object.

=cut

sub cgi {
  return $_[0]->{cgi};
}


=pod

=item * B<menu> ()

Returns a reference to the menu object.

=cut

sub menu {
  return $_[0]->{menu};
}


=pod

=item * B<layout> ()

Returns a reference to the layout object.

=cut

sub layout {
  return $_[0]->{layout};
}


=pod

=item * B<url> ()

Returns the base url of the cgi script

=cut

sub url {
  return $_[0]->cgi->url(-relative=>1);
}


=pod

=item * B<run> ()

Produces the web page output.

=cut

sub run {
  my $self = shift;

  # sanity check on cgi param 'page'
  my $page = $self->default;
  if ( $self->cgi->param('page') and 
       $self->cgi->param('page') =~ /^\w+$/ ) {
    $page = $self->cgi->param('page');
  }

  # require the web page package
  my $package = 'WebPage::'.$page;
  {
    no strict;
    eval "require $package";
    if ($@) {
      $package = 'WebPage::Error';
      $self->error( "Page '$page' not found." );
      warn $@;
    }
  }

  # init the requested web page object
  my $webpage = $package->new($self); 
  unless (ref $webpage) {
    confess "Unable to initialize object '$package'.\n";
  }

  # generate the page content;
  # this is done here to allow the page to change the 
  # application and session during runtime
  my $content = $webpage->output;

  if ($self->error) {
    $webpage = WebPage::Error->new($self);
    $content = $webpage->output;
  }

  # fill the layout 
  $self->layout->set_content( { content => $content,
				menu    => $self->menu->output,
				title   => $webpage->title } );

  # print the output
  print $self->cgi->header( -cookie => $self->session->cookie );
  print $self->layout->output;

}

=pod

=item * B<authorized> ($minimum_level)

Checks the authorization of the logged in user.

Parameters

$minimum_level - integer indicating the minimum status level

Returns

if the currently logged in user has the appropriate status level: true
if the user lacks the appropriate status level: false, html_explanation

=cut

sub authorized {
  my ($self, $minimum_level) = @_;

  if ($self->session->user) {
    if (defined($minimum_level)) {
      if ($self->session->user->status >= $minimum_level) {
	return 1;
      } else {
	return undef;
      }
    } else {
      return 1;
    }
  } else {
    $self->error("<span class='warning'>You are currently not logged in.</span>");
    return undef;
  }
  
}

=pod

=item * B<error> ($error)

Gets and sets the error attribute.

Parameters

$error - string that contains the error

Returns

The string value of the error attribute

=cut

sub error {
  my ($self, $error) = @_;

  if (defined $error) {
    $self->{error} = $error;
  }

  return $self->{error};
}
