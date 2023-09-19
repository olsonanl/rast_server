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

use strict;
use Carp;
use Data::Dumper;

use FIG;
my $fig = FIG->new();

use GenomeMeta;
use GenomeMetaDB;
use POSIX;

# usage: meta metafile.xml cmd

my $use_db;
if ($ARGV[0] eq '-db')
{
    $use_db++;
    shift @ARGV;
}

@ARGV > 0 or die "Usage: $0 [-db] [genome-id] metafile.xml [cmd]\n";
my $genome;
if ($ARGV[0] =~ /^\d+\.\d+/)
{
    $genome = shift;
}
@ARGV > 0 or die "Usage: $0 [-db] [genome-id] metafile.xml [cmd]\n";
my $meta_file = shift;

my $meta;
if ($use_db)
{
    $meta = GenomeMetaDB->new($genome, $meta_file);
}
else
{
    $meta = GenomeMeta->new($genome, $meta_file);
}

my $argv_cmd;
if (@ARGV > 0)
{
    $argv_cmd = join(" ", @ARGV);
}

while (my $req = &get_req)
{
    if ($req =~ /^\s*get\s+(\S+)\s*$/)
    {
	my $m = $meta->get_metadata($1);
	print "$1: ", flatten($m);
    }
    elsif ($req =~ /^\s*set\s+(\S+)\s*(.*?)\s*$/)
    {
	my $m = $meta->set_metadata($1, $2);
    }

    elsif ($req =~ /^\s*update_path\s+(\S+)\s*(.*?)\s*$/)
    {
	my $m = $meta->update_path($1, $2);
    }
    elsif ($req =~ /^\s*log\s+(\S+)\s*(.*?)\s*$/)
    {
	my $m = $meta->add_log_entry($1, $2);
    }
    elsif ($req =~ /^\s*list\s*$/)
    {
	my @keys = $meta->get_metadata_keys();

	map { print "   $_\n" } @keys;
    }
    elsif ($req =~ /^\s*get_all\s*$/)
    {
	my @keys = $meta->get_metadata_keys();

	for my $key (@keys)
	{
	    my $m = $meta->get_metadata($key);
	    print ("$key: ", flatten($m), "\n");
	}
    }
    elsif ($req =~ /^\s*get_tab\s*$/)
    {
	my @keys = $meta->get_metadata_keys();

	for my $key (@keys)
	{
	    my $m = $meta->get_metadata($key);
	    if (ref($m) eq 'ARRAY')
	    {
		$m = @$m;
	    }
	    print "$key\t$m\n";
	}
    }
    elsif ($req =~ /^\s*show_log\s*$/)
    {
	my $log = $meta->get_log();
	for my $ent (@$log)
	{
	    my($type, $ltype, $ts, $ent) = @$ent;
	    next unless $type eq 'log_entry';

	    my $ts = strftime('%c', localtime $ts);
	    #print Dumper($ent);
	    print join("\t", $ts, $ltype, flatten($ent)), "\n";
	}
    }
    elsif ($req =~ /^\s*show_all_log\s*$/)
    {
	my $log = $meta->get_log();
	print Dumper($log);
	for my $ent (@$log)
	{
	    my($type, $ltype, $ts, $ent) = @$ent;

	    my $ts = strftime('%c', localtime $ts);
	    #print Dumper($ent);
	    print join("\t", $ts, $ltype, flatten($ent)), "\n";
	}
    }
    elsif ($req =~ /^\s*h\s*$/ || $req =~ /^\s*help\s*$/)
    {
	&help;
    }
    else
    {
	print "invalid command\n";
    }
    print "\n";
}

sub get_req {
    my($x);

    if (@ARGV > 0)
    {
	if ($argv_cmd)
	{
	    $x = $argv_cmd;
	    undef $argv_cmd;
	}
	return $x;
    }

    my $echo;

    print "?? ";
    $x = <STDIN>;
    while (defined($x) && (($x =~ /^h$/i) or $x =~ /^\?$/))
    { 
	&help;
	print "?? ";
	$x = <STDIN>;
    }
    
    if ((! defined($x)) || ($x =~ /^\s*[qQxX]/))
    {
	return "";
    }
    else
    {
        if ($echo)
	{
	    print ">> $x\n";
	}
	return $x;
    }
}

sub flatten
{
    my($l) = @_;

    if (ref($l) eq 'ARRAY')
    {
	return qq(\[ )
	    . join(", ", map { flatten($_) } @$l)
	    . qq( \]);
    }
    elsif (ref($l) eq 'HASH')
    {
	my $out = qq(\{ )
	    . join(", ", map { "$_: " . flatten($l->{$_}) } sort keys %$l)
	    . qq( \});
    }
    else
    {
	return $l;
    }
}

sub help {
    print <<END;
    
    h					 Show this help text.
    get		       attrname		 Retrieve the value of attribute attrname.
    get_all	    			 Retrieve the value of all curently-set attributes.
    list				 List the names of currently-set attributes.
    log                type data         Add a log entry.
    show_log				 Dump the log.
    set		       attrname value	 Set attribute attrname to value.

END
}
