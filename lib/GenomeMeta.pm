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

package GenomeMeta;

use Carp;
use Data::Dumper;
use Errno;

use FileLocking qw(lock_file unlock_file lock_file_shared);
use FileHandle;
use Fcntl ':seek';
use GenomeMetaDB;
use XML::LibXML;
use strict;
my $have_fsync;
eval {
	require File::Sync;
	$have_fsync++;
};
#print STDERR "have_fsync=$have_fsync\n";
#my $host = `hostname`;
#chomp $host;

sub new
{
    my($class, $genome, $file, %opts) = @_;

    #
    # First see if this is a database-based file.
    #
    if (open(my $fh, "<$file"))
    {
	my $n = 0;
	while (my $l = <$fh>)
	{
	    last if $n++ > 4;
	    if ($l =~ /serviceHandle/)
	    {
		close($fh);
		return new GenomeMetaDB($genome, $file);
	    }
	}
	close($fh);
    }

    my $self = bless {
	genome => $genome,
	file => $file,
	options => \%opts,
	readonly => $opts{readonly},
    }, $class;
    
    if (-f $file)
    {
	$self->load();
    }
    else
    {
	$self->create_new();
    }
    return $self;
}

sub get_file
{
    my($self) = @_;
    return $self->{file};
}
    
sub readonly
{
    my $self = @_;
    return $self->{readonly};
}

sub load
{
    my($self) = @_;

    my $fh = new FileHandle("<$self->{file}");
    if (!$fh)
    {
	die "Cannot open meta file $self->{file}: $!\n";
    }
    lock_file_shared($fh);
    seek($fh, 0, SEEK_SET);
    my @stat = stat($fh);
    $self->{last_mod} = $stat[9];

    eval {  $self->load_from_fh($fh) };
    if($@) { die "Error reading ".$self->{file}.":\n $@"; }
	
    unlock_file($fh);
    close($fh);
}

sub load_from_fh
{
    my($self, $fh) = @_;
    
    my $parser = XML::LibXML->new();

    $parser->keep_blanks(0);
    my $dom = $parser->parse_fh($fh);

    my $root = $dom->documentElement();
    if ($root->nodeName ne "genomeMeta")
    {
	die "invalid root nodename ". $root->nodeName() ." in metadata";
    }

    my $g = $root->getAttribute('genomeId');

    if (defined($self->{genome}))
    {
	if ($g ne $self->{genome})
	{
	    warn "metadata genome $g does not match our genome $self->{genome}\n";
	}
    }
    else
    {
	$self->{genome} = $g;
    }
    $self->set_dom($dom);
}
    

=head3

Create a new metadata file.

=cut

sub create_new
{
    my($self) = @_;

    my $dom = XML::LibXML->createDocument;
    my $root = $dom->createElement('genomeMeta');
    $root->setAttribute(genomeId => $self->{genome});
    $root->setAttribute(creationDate => time);
    $dom->setDocumentElement($root);

    my $md = $dom->createElement('metadata');
    $root->appendChild($md);

    my $log = $dom->createElement('log');
    $root->appendChild($log);

    $self->set_dom($dom);

    $self->{fh} = new FileHandle(">$self->{file}");

    $self->write();
}

=head3 lock_for_writing

Open and lock the metadata file. If the last_mod time on the file
is later than the state we have internally, reread the file before
continuing. Leave the file locked.

=cut

sub lock_for_writing
{
    my($self) = @_;

    my $tries = 10;

    my $fh;
    while ($tries--)
    {
    
	$SIG{INT} = sub { $self->{exit} = 1;};
	$SIG{TERM} = sub { $self->{exit} = 1;};
	$SIG{HUP} = sub { $self->{exit} = 1;};
	$fh = new FileHandle("+<$self->{file}");
	$fh or die "Cannot open $self->{file}: $!\n";
	if (!defined(lock_file($fh)))
	{
	    my $err = $!;
	    if ($err == Errno::EOVERFLOW)
	    {
		warn "Hit EOVERFLOW, sleeping and retrying\n";
		sleep 1;
		next;
	    }
	    die "lock_file failed: $err";
	}
	$fh->autoflush(1);

	seek($fh, 0, SEEK_SET);

	eval {
	    $self->load_from_fh($fh);
	};

	if ($@)
	{
	    warn "Error in lock_for_writing at tries=$tries: $@";
	    close($fh);
	    undef $fh;
	}
	else
	{
	    last;
	}
    }
    
    seek($fh, 0, SEEK_SET);
    $fh->truncate(0);
    
    $self->{fh} = $fh;

}

sub check_for_reading
{
    my($self) = @_;

    my $fh = new FileHandle("<$self->{file}");
    $fh or die "Cannot open $self->{file}: $!\n";
    if (!defined(lock_file_shared($fh)))
    {
	die "lock failed: $!";
    }
    my @stat = stat($fh);
    my $last_mod = $stat[9];

    if ($last_mod > $self->{last_mod})
    {
	seek($fh, 0, SEEK_SET);
	warn "check_for_reading: rereading after obtaining lock\n";
	$self->load_from_fh($fh);
    }
    unlock_file($fh);
    close($fh);
}

sub write
{
    my($self) = @_;

    my $fh = $self->{fh};
    if (!$fh)
    {
	confess "GenomeMeta::write: fh not set";
    }
	
    $self->{dom}->toFH($fh, 2);

    my @stat = stat($fh);
    $self->{last_mod} = $stat[9];

    eval { File::Sync::fsync($fh) if $have_fsync; };

    unlock_file($fh);
    close($fh);
    delete $self->{fh};
    $SIG{INT} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $SIG{HUP} = 'DEFAULT';
    if ($self->{exit})
    {
	die "Exiting on deferred signal\n";
    }
}


=head3 set_dom

Set the DOM document for our metadata file.

This also sets root - root of documents, md - metadata container noe, and log - log container node.

=cut

sub set_dom
{
    my($self, $dom) = @_;

    my $root = $dom->documentElement();

    my @md = $root->findnodes("/genomeMeta/metadata");
    if (@md != 1)
    {
	die "Invalid metadata list in document";
    }
    $self->{md} = $md[0];

    my @log = $root->findnodes("/genomeMeta/log");
    if (@log != 1)
    {
	die "Invalid log element in document";
    }
    $self->{log} = $log[0];

    $self->{dom} = $dom;
    $self->{root} = $root;
}

sub add_log_entry
{
    my($self, $type, $data) = @_;

    $self->lock_for_writing();

    if (ref($type))
    {
	die "log type cannot be a reference";
    }

    my $lnode = $self->{dom}->createElement("log_entry");
    $lnode->setAttribute(type => $type);
    $lnode->setAttribute(updateTime => time);
    $lnode->appendChild($self->serialize_value($data));

    $self->{log}->appendChild($lnode);
    $self->write();
}

sub set_metadata
{
    my($self, $name, $val) = @_;

    if (ref($name))
    {
	die "metadata key cannot be a reference";
    }

    $self->lock_for_writing();

    my $did_create;
    my $md_node = $self->find_metadata_node($name, \$did_create);

    my $sval = $self->serialize_value($val);

    my $md_new = $self->{dom}->createElement("entry");
    $md_new->setAttribute(name => $name);
    $md_new->appendChild($sval);

    my $lnode;
    if (not $did_create)
    {
	my $md_old = $md_node->replaceNode($md_new);

	$lnode = $self->{dom}->createElement("meta_updated");
	$lnode->setAttribute(updateTime => time);
	$lnode->appendChild($md_old);
    }
    else
    {
	my $md_old = $md_node->replaceNode($md_new);

	$lnode = $self->{dom}->createElement("meta_created");
	$lnode->setAttribute(updateTime => time);
	$lnode->setAttribute(name => $name);
    }
	
    $self->{log}->appendChild($lnode);

    $self->write();
}

sub get_metadata
{
    my($self, $name) = @_;

    $self->check_for_reading();

    if (ref($name))
    {
	die "metadata key cannot be a reference";
    }

    my $md_node = $self->find_metadata_node($name);

    my $val;
    if (defined($md_node))
    {
	$val = $self->deserialize_value($md_node->firstChild());
    }

    return $val;
}

sub get_metadata_keys
{
    my($self) = @_;
    $self->check_for_reading();

    my $expr = '//metadata/entry/@name';

    my @m = $self->{md}->findnodes($expr);

    return map { $_->value() } @m;
}

sub get_log
{
    my($self) = @_;
    $self->check_for_reading();

    my $out = [];
    for (my $node = $self->{log}->firstChild; $node; $node = $node->nextSibling)
    {
	my $type = $node->nodeName();

	if ($type eq 'meta_created')
	{
	    push(@$out, [$type, $node->getAttribute("name"), $node->getAttribute("updateTime")]);
	}
	elsif ($type eq 'meta_updated')
	{
	    my $ent = $node->firstChild();
	    my $val = $self->deserialize_value($ent->firstChild());
	    push(@$out, [$type, $ent->getAttribute("name"), $node->getAttribute("updateTime"), $val]);
	}
	elsif ($type eq "log_entry")
	{
	    my $val = $self->deserialize_value($node->firstChild());
	    push(@$out, [$type, $node->getAttribute('type'), $node->getAttribute('updateTime'), $val]);
	}
    }
    return $out;
}

sub deserialize_value
{
    my($self, $node) = @_;

    return unless defined($node);
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

sub find_metadata_node
{
    my($self, $name, $created) = @_;

    my $expr = qq(./entry[\@name="$name"]);
    my @m = $self->{md}->findnodes($expr);
    my $m;
    if (@m == 0)
    {
	$m = $self->{dom}->createElement("entry");
	$m->setAttribute(name => $name);
	$self->{md}->appendChild($m);
	$created and $$created = 1;
    }
    else
    {
	$m = shift @m;
    }
    return $m;
}

1;
