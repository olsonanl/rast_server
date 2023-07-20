package WebApplicationServer::Session;

use strict;
use warnings;

use Carp qw( confess );

use CGI;
use CGI::Cookie;
use Digest::MD5;

1;

# this class is a stub, this file will not be automatically regenerated
# all work in this module will be saved

=pod

=head1 NAME

Session - simple session management to support WebApplication

=head1 SYNOPSIS

TODO

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<new> ()

Creates a new instance of the Session object. This overwritten version of the method will retrieve a Session if the session_id already exists.

=cut

sub create {
  my $self = shift;

  # check if we are called properly
  unless (ref $self) {
    confess "Not called as an object method.\n";
  }
  
  my $session_id = $self->init_session_id();

  # get session from database
  my $sessions = $self->_master->Session->get_objects({ 'session_id' => $session_id });
  if (scalar(@$sessions)) {
    $self = $sessions->[0];
  }

  # or create a new one
  else { 
    my $session = $self->SUPER::create({ 'session_id' => $session_id,
					 'creation'   => $self->_timestamp() });

    if (ref $session) {
      $self = $session;
    }
    else {
      confess "Failure creating a session in __PACKAGE__.";
    }
  }
  
  # add cgi to object
  $self->{'_cgi'} = CGI->new();

  return $self;

}


=pod

=item * B<cookie> ()

Return the session cookie

=cut

sub cookie {
  return $_[0]->{'_cookie'};
}


=pod

=item * B<expire_cookie> ()

Expire the session cookie.

=cut

sub expire_cookie {
  my ($self) = @_;

  # create new cookie
  $self->{'_cookie'} = CGI::Cookie->new( -name    => 'WebSession',
					 -value   => '',
					 -expires => '-1d' );

}


=pod

=item * B<init_session_id> ()

Returns the id of the current session. If a cookie already exists it tries to retrieve the session id from there, else it creates a unique id and writes a session cookie.

=cut

sub init_session_id {
    my $self = shift;

    my $cgi = CGI->new();

    my $session_id = undef;

    # read existing cookie
    my $cookie = $cgi->cookie('WebSession');
    if ($cookie) {
      $session_id = $cookie;
    }

    # or create new one
    else { 
      
      # get 'random' data
      my $host= $cgi->remote_host();
      my $rand = int(int(time)*rand(100));
      
      # hide it behind a md5 sum (32 char hex)
      my $md5 = Digest::MD5->new;
      $md5->add($host, $rand);
      my $id = $md5->hexdigest;
      
      $session_id = $id;	
      
    }

    # create cookie
    if (defined $session_id) {
      $self->{'_cookie'} = CGI::Cookie->new( -name    => 'WebSession',
					     -value   => $session_id,
					     -expires => '+2d' );
      return $session_id;
    }
    else {
      confess "Could not generate a session id."
    }

}


=pod

=item * B<add_entry> (I<additional_info>)

Adds a session entry to the current session.

=cut

sub add_entry {
  my ($self, $additional_info) = @_;

  my $page = ($self->_cgi->param('page')) ? $self->_cgi->param('page') : undef;
  my $action = ($self->_cgi->param('action')) ? $self->_cgi->param('action') : undef;

  my $entry = $self->_master->SessionItem->create({ 'timestamp' => $self->_timestamp(),
						    'page' => $page,
						    'action' => $action,
						    'additional_info' => $additional_info,
						  });

  if (defined $entry and ref $entry eq 'WebApplicationServer::SessionItem') {
    my $entries = $self->entries();
    push @$entries, $entry;
    $self->entries($entries);
    return $self;
  }
  else {
    confess "Unable to add entry to the session.";
  }

}


=pod

=back

=head1 INTERNAL METHODS

Internal or overwritten default perl methods. Do not use from outside!

=over 4

=item * B<_timestamp> ()

Constructs a mysql compatible timestamp from time() (GMT)

=cut

sub _timestamp {
  my $self = shift;
  my ($sec,$min,$hour,$day,$month,$year) = gmtime();
  $year += 1900;
  $month += 1;
  return $year."-".$month.'-'.$day.' '.$hour.':'.$min.':'.$sec;
}


=pod

=item * B<cgi> ()

Returns the reference to the cgi object instance of this session.

=cut

sub _cgi {
  return $_[0]->{'_cgi'};
}
