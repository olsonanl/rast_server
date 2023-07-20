package WebApp::WebPage;

1;

use strict;
use warnings;

=pod

=head1 NAME

WebPage - an abstract object for webpages used by WebApplication. Instaces of this object each represent a distinct page.

=head1 SYNOPSIS

TODO

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<new> ()

Creates a new instance of the WebPage object.

=cut

sub new {
  my ($class, $application) = @_;

  my $self = { application => $application,
	       _title => '',
	     };

  bless($self, $class);

  return $self;
}


=pod

=item * B<title> ()

Get/set the title of a page. By default the title is empty.

=cut

sub title {
  my ($self, $title) = @_;
  if (defined $title) {
    $self->{'_title'} = $title;
  }
  return $self->{'_title'};
}

=pod

=item * B<output> ()

Returns the html output of the page. This method is abstract and must be implemented.

=cut

sub output {
  my ($self) = @_;

  die 'Abstract method "output" must be implemented in __PACKAGE__.\n';
}

=pod

=item * B<application> ()

Returns the reference to the WebApplication object which called this WebPage

=cut

sub application {
  return $_[0]->{application};
}


=pod

=item * B<name> ()

Returns the page name which is used to retrieve this page using the 
cgi param 'page';

=cut

sub name {
  ref($_[0]) =~ /^\w+\:\:(\w+)/;
  return $1;
}


=pod

=item * B<url> ()

Returns the name of the cgi script of this page; 
this is used as a relative url 

=cut

sub url {
  my ($self) = @_;
  return $self->application->url . "?page=" . $self->name . "&";
}

=pod

=item * B<start_form> (I<id, state>)

Returns the start of a form

Parameters:

id - (optional) an html id that can be referenced by javascript
state - (optional) a hash whose keys will be turned into the names of hidden
variables with the according values set as values

=cut

sub start_form {
  my ($self, $id, $state) = @_;
  
  my $id_string = "";
  if ($id) {
    $id_string = " id='$id'";
  }

  my $start_form = "<form method='post'$id_string enctype='multipart/form-data' action='" . $self->application->url . "'>\n<input type='hidden' name='page' value='" . $self->name . "'>\n";
  
  if (defined($state)) {
    foreach my $key (keys(%$state)) {
      $start_form .= "<input type='hidden' name='" . $key . "' value='" . $state->{$key} . "'>\n";
    }
  }

  return $start_form;
}

=pod

=item * B<end_form> ()

Returns the end of a form

=cut

sub end_form {
  my ($self) = @_;
  
  return "</form>";
}
