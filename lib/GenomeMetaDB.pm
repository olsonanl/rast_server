# -*- perl -*-
########################################################################
# Copyright (c) 2003-2006 University of Chicago and Fellowship
# for Interpretations of Genomes. All Rights Reserved.
#
# This file is part of the SEED Toolkit.
#
# The SEED Toolkit is free software. You can redistribute
# it and/or modify it under the terms of the SEED Toolkit
# Public License.
#
# You should have received a copy of the SEED Toolkit Public License
# along with this program; if not write to the University of Chicago
# at info@ci.uchicago.edu or the Fellowship for Interpretation of
# Genomes at veronika@thefig.info or download a copy from
# http://www.theseed.org/LICENSE.TXT.
########################################################################

#
# Package to maintain metadata records about a genome.
#
# Intended to be used to maintain state of a genome during its passage through
# the 48-hour annotation server.
#
# Metadata keys are simple strings.
# Metadata values may be any of the basic perl data structures: scalar,
# list, hash.
# Metadata values may contain nested data structures.
#
# We also maintain a log of changes made to the genome. Each log entry
# has a log-date, comment, and data field.
#
# Changes to metadata result in log entries that contain the old and new
# values for the metadata entry.
#
# The metadata file in the DB verison contains the address of the
# service that handles the actual metadata storage:
#
# <genomeMeta genomeId="..." creationDate="...">
#   <serviceHandle url="..."/>
# </genomeMeta>
#

package GenomeMetaDB;

use strict;
use Carp;
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Request::Common;
use IO::Socket::INET;
use Cwd 'abs_path';
use HTTP::Request;
use Storable qw(fd_retrieve);
use IO::Scalar;
use XML::LibXML;
use Time::Piece;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(ua file id url dom parser));

my $service_url = 'http://mg-rast.mcs.anl.gov:8080/meta/genome_meta_server.cgi';

sub new
{
    my($class, $genome, $file) = @_;

    my $self = bless {
	genome => $genome,
	file => $file,
	dom => XML::LibXML->createDocument(),
	parser => XML::LibXML->new(),
    }, $class;

    if (! -f $file)
    {
	$self->create_new();
    }

    $self->open();
    
    return $self;
}

sub get_file
{
    my($self) = @_;
    return $self->{file};
}

sub touch_file
{
    my($self) = @_;
    utime(undef, undef, $self->{file});
}

sub open
{
    my($self) = @_;

    open(F, "<", $self->{file}) or die "cannot open $self->{file}: $!";

    my $url;
    while (<F>)
    {
	if (/serviceHandle=['"]([^'"]+)['"]/)
	{
	    $url = $1;
	    last;
	}
    }
    close(F);

    $url or die "Cannot find service url in $self->{file}";

    $self->url($url);
    $self->ua(LWP::UserAgent->new);

    my $abs = abs_path($self->file);

    my @res = $self->invoke('id_for_path', path => $abs);
    $self->id($res[0]);
}

sub invoke
{
    my($self, $op, @opts) = @_;

    push(@opts, op => $op, id => $self->id);

    # print "Invoke: " . Dumper(\@opts);

    my $req = HTTP::Request::Common::POST($self->url, \@opts);

    # print "Connect to " . $req->uri->host . " " . $req->uri->port . "\n";
    my $sock = IO::Socket::INET->new(PeerHost => $req->uri->host,
				     PeerPort => $req->uri->port,
				     Proto => 'tcp');
    $sock or die "cannot connect to " . $req->uri->as_string;

    my $path = $req->uri->path;
    $path = '/' if $path eq '';
    print $sock "POST $path HTTP/1.0\n";
    print $sock $req->headers->as_string();
    print $sock "\n";
    print $sock $req->content();

    $sock->shutdown(1);

    my $l = <$sock>;
    my($proto, $code, $rest) = split(/\s+/, $l, 3);
    # print "proto=$proto code==$code rest=$rest\n";
    if ($code !~ /^2/)
    {
	die "failed with res: $_";
    }
    
    while (my $l = <$sock>)
    {
	# print "Got '$l'\n";
	$l =~ s/[\r\n]//g;
	
	last if  $l eq '';
    }

    local $/;
    undef $/;
    my $dat = <$sock>;
    #print "Got dat '$dat'\n";
    my $ret = $self->deserialize_value($dat);
    #print Dumper($ret);
    return $ret;
}

=head3 create_new

Create a new metadata file.

=cut

sub create_new
{
    my($self) = @_;
    my $file = $self->file;
    CORE::open(F, ">", $file) or die "Cannot create $file: $!";
    print F "<genomeMeta serviceHandle='$service_url' genome='$self->{genome}'/>\n";
    close(F);
}

sub readonly
{
    my $self = @_;
    return $self->{readonly};
}

sub set_metadata
{
    my($self, $name, $val) = @_;

    $self->invoke('set', key => $name, data => $self->serialize_value($val)->toString);
    $self->touch_file();
}

sub update_path
{
    my($self, $path, $new_path) = @_;
    return $self->invoke('update_path', path => $path, new_path => $new_path);
}


sub get_metadata
{
    my($self, $name) = @_;

    return $self->invoke('get', key => $name);
}

sub get_metadata_keys
{
    my($self) = @_;
    my $l = $self->invoke('get_keys');
    return @$l;
}

sub add_log_entry
{
    my($self, $type, $data) = @_;

    $self->invoke("log", type => $type, data => $self->serialize_value($data)->toString);
    $self->touch_file();
}

sub get_log
{
    my($self) = @_;

    my $out = [];
    my $l = $self->invoke('get_log');
    map { my($type, $str, $date) = @$_;
	  $date =~ s/\.\d+$//;
	  my $ndate = Time::Piece->strptime($date, '%Y-%m-%d %H:%M:%S' )->epoch;
	  @$_ = ('log_entry', $type, $ndate, $str);
      } @$l;
    return $l;
}

sub serialize_value
{
    my($self, $val) = @_;

    if (ref($val) eq 'ARRAY')
    {
	my $n = $self->{dom}->createElement("array");
	for my $elt (@$val)
	{
	    my $selt = $self->serialize_value($elt);
	    $n->appendChild($selt);
	}
	return $n;
    }
    elsif (ref($val) eq 'HASH')
    {
	my $n = $self->{dom}->createElement("hash");

	for my $k (keys(%$val))
	{
	    my $sk = $self->serialize_value($k);
	    my $sv = $self->serialize_value($val->{$k});

	    my $sn = $self->{dom}->createElement("k");
	    $sn->appendChild($sk);
	    $n->appendChild($sn);
	    $sn = $self->{dom}->createElement("v");
	    $sn->appendChild($sv);
	    $n->appendChild($sn);
	}
	return $n;
    }
    elsif (ref($val))
    {
	die "Cannot serialize other refs ($val)";
    }
    elsif (defined($val))
    {
	my $n = $self->{dom}->createElement("scalar");
	$n->appendChild($self->{dom}->createCDATASection($val));
#	$n->setAttribute(value => $val);
	return $n;
    }
    else
    {
	my $n = $self->{dom}->createElement("undef");
	return $n;
    }
}

sub deserialize_value
{
    my($self, $node) = @_;

    return unless defined($node);

    if (!ref($node))
    {
	$node = $self->parser->parse_string($node)->documentElement();
    }
    
    my $type = $node->nodeName();

    if ($type eq 'scalar')
    {
	my $cd = $node->firstChild();
	return ref($cd) ? $cd->nodeValue() : undef;
    }
    elsif ($type eq 'hash')
    {
	my $h = {};
	my $e = $node->firstChild();
	while ($e)
	{
	    my $e2 = $e->nextSibling();
	    if ($e->nodeName() ne 'k' or $e2->nodeName() ne 'v')
	    {
		die "invalid hash values";
	    }
	    my $k = $self->deserialize_value($e->firstChild());
	    my $v = $self->deserialize_value($e2->firstChild());
	    $h->{$k} = $v;
	    $e = $e2->nextSibling();
	}
	return $h;
    }
    elsif ($type eq 'array')
    {
	my $l = [];
	my $e = $node->firstChild();
	while ($e)
	{
	    my $v = $self->deserialize_value($e);
	    push(@$l, $v);
	    $e = $e->nextSibling();
	}
	return $l;
    }
    elsif ($type eq 'undef')
    {
	return undef;
    }
}
1;
