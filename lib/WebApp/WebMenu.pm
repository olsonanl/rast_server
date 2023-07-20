package WebApp::WebMenu;

use strict;
use warnings;

use Carp qw( confess );

use CGI;

1;

=pod

=head1 NAME

WebMenu - manage menu for the WeApplication framework

=head1 SYNOPSIS

use WebMenu;

my $menu = WebMenu->new();

$menu->add_category("Edit");

$menu->add_entry("Edit", "Copy", "copy.cgi");

$menu->add_entry("Edit", "Paste", "paste.cgi", "_blank");

$menu->output();


=head1 DESCRIPTION

The WebMenu module defines a mechanism to build a menu structure by defining categories (top level menu entries) and optional links, as well as sub entries for each of the categories (consisting of a entry name, an url and an optional browser target.

The html output of the menu consists of an unordered list of lists, ie. a two level hierarchy of html links (<a href> tags) embedded in <ul> tags representing categories and their entries.

=head1 METHODS

=over 4

=item * B<new> ()

Creates a new instance of the WebMenu object. 

=cut

sub new {
    my $class = shift;
    
    my $self = { home => undef,
		 entries => {},
		 categories => [],
		 categories_index => {},
    };
    bless $self, $class;
    
    return $self;
}


=pod
    
=item * B<flush> ()

Flushes all categories and entries from the menu (leaving it empty).

=cut

sub flush {
    my $self = shift;
    $self->{home} = undef;
    $self->{entries} = {};
    $self->{categories} = [];
    $self->{categories_index} = {};
    return $self;
}


=pod
    
=item * B<home> (I<url>)

Returns the link of the home page. If the optional parameter I<url> is given, home will be set. 
I<url> may be undef.

=cut

sub home {
    my $self = shift;
    if (scalar(@_)) {
	$self->{home} = $_[0];
    }
    return $self->{home};
}


=pod
    
=item * B<add_category> (I<category>, I<url>, I<target>)

Adds a category to the menu. I<category> is mandatory and expects the name of the menu category. I<url> is optional and will add a link to the category name in the menu. I<target> is optional and defines a href target for that link.

=cut

sub add_category {
    my ($self, $category, $url, $target) = @_;
    
    unless ($category) {
	confess 'No category given.';
    }

    if (exists($self->{categories_index}->{$category})) {
	confess "Trying to add category '$category' which already exists.";
    }

    $url = '' unless ($url);
    $target = '' unless ($target);
    
    # update the category index
    $self->{categories_index}->{$category} = scalar(@{$self->{categories}});
    
    # add the category and link
    push @{$self->{categories}}, [ $category, $url, $target ];

    # init the entries array for that category
    $self->{entries}->{$category} = [];

    return $self;
}


=pod
    
=item * B<delete_category> (I<category>)

Deletes a category from the menu. I<category> is mandatory and expects the name of the menu category. 
If the category does not exist a warning is printed.

=cut

sub delete_category {
    my ($self, $category) = @_;
    
    unless ($category) {
	confess 'No category given.';
    }

    my $i = $self->{categories_index}->{$category};
    if ($i) {
	splice @{$self->{categories}}, $i, 1;
	delete $self->{categories_index}->{$category};
	delete $self->{entries}->{$category}
    }
    else {
	warn "Trying to delete non-existant category '$category'.";
    }

    return $self;
}


=pod
    
=item * B<get_categories> ()

Returns the names of all categories (in a random order).

=cut

sub get_categories {
    return keys(%{$_[0]->{categories_index}});
}


=pod

=item * B<add_entry> (I<category>, I<entry>, I<url>)

Adds an entry and link to a existing category of the menu. I<category>, I<entry> and I<url> are mandatory. I<category> expects the name of the menu category. I<entry> can be any string, I<url> expects a url.
I<target> is optional and defines a href target for that link.

=cut

sub add_entry {
    my ($self, $category, $entry, $url, $target) = @_;
    
    unless ($category and $entry and $url) {
	confess "Missing parameter ('$category', '$entry', '$url').";
    }

    unless (exists($self->{categories_index}->{$category})) {
	confess "Trying to add to non-existant category '$category'.";
    }
    
    $target = '' unless ($target);

    push @{$self->{entries}->{$category}}, [ $entry, $url, $target ];

    return $self;
}

=pod

=item * B<output> ()

Returns the html output of the menu.

=cut

sub output {
  my $self = shift;

  my $html = "<div id='menu'>\n";
  $html .= "\t<ul id='nav'>\n";

  foreach (@{$self->{categories}}) {
    
    my ($cat, $c_url, $c_target) = @$_;
    my $url = ($c_url) ? qq~href="$c_url"~ : '';
    my $target = ($c_target) ? qq~target="$c_target"~ : '';
    
    $html .= qq~\t\t<li><div><a $url $target> $cat</a></div>\n~;
    
    if (scalar(@{$self->{entries}->{$cat}})) {

      $html .= "\t\t<ul>\n";

      foreach (@{$self->{entries}->{$cat}}) {

	my ($entry, $e_url, $e_target) = @$_;
	my $target = ($e_target) ? qq~target="$e_target"~ : '';
	$html .= qq~\t\t\t<li><a href="$e_url" $target>$entry</a></li>\n~;
      }
	
      $html .= "\t\t</ul>\n";
      
    }

    $html .= "\t\t</li>\n";
  
  }

  $html .= "\t</ul>\n";
  $html .= "</div>\n";

  return $html;

}
