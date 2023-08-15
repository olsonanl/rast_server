package RAST::Import;

# $Id: Import.pm,v 1.13 2008-10-09 17:22:42 olson Exp $ 

use strict;
use warnings;

use Data::Dumper;

1;

=pod

=head1 NAME

Import - object that represents all import information for a RAST job 

=head1 METHODS

=over 4

=item * B<update> ()

Update the import information from the meta.xml

=cut

sub update {
  my($self) = @_;

  my $job = $self->job();
  unless (ref $job and $job->isa('RAST::Job')) {
    die "This import data is not associated with any job.";
  }

  # 0, 1, 2
  my $suggested_by = $job->metaxml->get_metadata('import.candidate');
  $self->suggested_by($suggested_by || 0);

  # 1..10
  my $priority = $job->metaxml->get_metadata('import.priority');
  $self->priority($priority || 0);

  # update, new genome, user, unknown
  my $reason = $job->metaxml->get_metadata('import.reason');
  $self->reason($reason || 'unknown');

  # replace genome_id
  my $replace = $job->metaxml->get_metadata('import.replace');
  $self->replaces($replace || '');

  # new, import, pending, rejected
  my $action = $job->metaxml->get_metadata('import.action');
  $self->action($action || 'new');

  # not_started, computed, installed
  my $status = $job->metaxml->get_metadata('import.status');
  $status =~ s/_/ /g if ($status);
  $self->status($status || 'not started');

  return $self;

}


=pod

=item * B<action> ()

This overloaded version of the action attribute method also set the value in 
the metaxml file of the job.

=cut

sub action {
  my $self = shift;
  
  if(scalar(@_)) {
    
    my $v = $_[0];
    unless ($v and ($v eq 'new' or 
		    $v eq 'import' or 
		    $v eq 'pending' or 
		    $v eq 'rejected')) {
	warn "Invalid value for metaxml key import.action";
	return;
    }

    unless( $v eq $self->job->metaxml->get_metadata('import.action') ){
      $self->job->metaxml->set_metadata('import.action', $v);
    }
    
  }    
  
  return $self->SUPER::action(@_);
  
}


sub priority {
  my $self = shift;

  if(scalar(@_)) {
    
    my $v = $_[0];
    unless ( $v =~ /[1234567890]/ ) {
	warn "Invalid value $v for metaxml key import.priority";
	return;
    }
    unless( $v eq $self->job->metaxml->get_metadata('import.priority') ){
      $self->job->metaxml->set_metadata('import.priority', $v);
    }

  }    
    
  return $self->SUPER::priority(@_);

}

sub comment {
  my ($self , $comment) = @_;
  
  if ( $comment ) {
    unless( $self->job->metaxml->get_metadata('import.comment') and $comment eq $self->job->metaxml->get_metadata('import.comment') ){

      $self->job->metaxml->set_metadata('import.comment', $comment);
    }
  
  }    
  else {
    $comment = $self->job->metaxml->get_metadata('import.comment');
  }

  
  return $comment;
  
}


sub replaces {
  my $self = shift;
  
  if(scalar(@_)) {
    
    my $v = $_[0];
    if ( $v =~ /\d+\.\d+/ ) {
      
      unless( $self->job->metaxml->get_metadata('import.replace') and $v eq $self->job->metaxml->get_metadata('import.replace') ){
	$self->job->metaxml->set_metadata('import.replace', $v);
      }
      
    }
    else{
      print STDERR  "Invalid value \"$v\" for metaxml key import.replace";
    }
    
  }    
  
  return $self->SUPER::replaces(@_);
  
}
