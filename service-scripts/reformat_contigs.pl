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

use FIG;
use File::Basename;
use strict;
use Pod::Text;
# use File::Basename;   $this_tool_name = basename($0);
if ((@ARGV == 1) && ($ARGV[0] =~ m/-help/))  {
    pod2text($0);  exit(0);
}

=pod

=over 5

=item Usage:     reformat_contigs [-help] [-logfile=logfilename] [-v(erbose)] [-split(=len)] [-keep] [-width=line_width] [-[no]renumber] [-min=min_length]  < fasta_in  > fasta_out
                 reformat_contigs [-help] [-logfile=logfilename] [-v(erbose)] [-split(=len)] [-keep] [-width=line_width] [-[no]renumber] [-min=min_length]    fasta_in    fasta_out

=item Function:  Reformats a contigs file to a uniform 50 chars per line,
                checking for non-IUPAC characters. Default behavior is to
                zero-pad the digits of names of the form 'Contig' followed
                by one or more digits to four digits.

                Optionally, renumbers
                contigs, and/or discards contigs that are too short.
		
		-split       Split contigs on runs of ambigs longer than len (def=3)
                    (writes scaffold-map to output path if there is an explicit 'fasta_out' arg)
                -keep        Appends original contig ID to new ID if -renumber
                -width       line width (def=50)
                -renumber    Renumbers contigs starting from Contig0001
                -norenumber  Does not renumber contigs
    	        -renumber-map=filename	Save the a mapping of renumbered contig names to filename
                -renumber-digits=ndigits Number of digits used in renumbered contig names
                -renumber-prefix=prefix  Prefix to use instead of Contig in renumbered contig names
                -remove-duplicates   Remove duplicate sequences
                -duplicates-file     File in which to save information about removed duplicates
                -min         Minimum acceptable contig length (def=0)
                -max         Maximum acceptable contig length (def=999999999999)
                -logfilename name of the optional logfile
		
=back

=cut

my $renumber_prefix = "Contig";
my $split       = 0;
my $keep        = 0;
my $width       = 50;
my $renumber    = 0;
my $renumber_map;
my $renumber_digits = 4;
my $remove_duplicates = 0;
my $duplicates_fh;
my $duplicates_removed = 0;

my $longrepeat  = 1000;
my $min_length  = 0;
my $max_length  = 999999999999;

my $short_chars = 0;
my $long_chars  = 0;
my $nx_chars    = 0;
my $logfilename = undef;

my $first_line  = 1;

my $trouble = 0;
my $basepath;

while ($ARGV[0] =~ m/^-/) {
    if    ($ARGV[0] =~ m/^-{1,2}v(erbose)?/) {
	$ENV{VERBOSE} = 1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}split/) {
    	$split = 3;
	if ($ARGV[0] =~ m/^-{1,2}split=(\d+)/)   { $split = $1; }
    }
    elsif ($ARGV[0] =~ m/^-{1,2}logfile=(.+)/) {
	$logfilename = $1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}keep/) {
	$keep = 1; 
    } 
    elsif ($ARGV[0] =~ m/^-{1,2}width=(\d+)/) {
	$width = $1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}(no)?renumber$/) {
	if ($1) { $renumber = 0 } else { $renumber = 1; }
    }
    elsif ($ARGV[0] =~ /-renumber-prefix=(\S+)/)
    {
	$renumber_prefix = $1;
    }
    elsif ($ARGV[0] =~ /-renumber-map=(\S+)/)
    {
	open($renumber_map, ">", $1) or die "Cannot open renumber mapping file $1 for writing: $!";
    }
    elsif ($ARGV[0] =~ /-renumber-digits=(\d+)/)
    {
	$renumber_digits = $1;
    }
    elsif ($ARGV[0] =~ /-remove-duplicates$/)
    {
	$remove_duplicates = 1;
    }
    elsif ($ARGV[0] =~ /-duplicates-file=(.+)/)
    {
	open($duplicates_fh, ">", $1) or die "Cannot open duplicates file $1 for writing: $!";
    }
    elsif ($ARGV[0] =~ m/^-{1,2}min=(\d+)/) {
	$min_length = $1;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}max=(\d+)/) {
	$max_length = $1;
    }
    else {
	$trouble = 1;
	print STDERR "bad arg $ARGV[0]\n\n";
    }
    
    shift;
}

if (defined($logfilename)) {
    open(STDERR, ">$logfilename");
}

my $fh_in  = \*STDIN;
my $fh_out = \*STDOUT;
my $input_eol_marker = $/;

if (@ARGV == 2) {
    my $fasta_in  = shift;
    my $fasta_out = shift;
    
    if (!-s $fasta_in) {
	$trouble = 1;
	warn "Input file $fasta_in does not exist\n";
    }
    else {
	open($fh_in,  "<$fasta_in")  || die "Could not read-open $fasta_in";
	open($fh_out, ">$fasta_out") || die "Could not write-open $fasta_out";
	$basepath = dirname($fasta_out);

	my $file_type;
	if (($file_type = `file '$fasta_in' | cut -f2 -d:`) && ($file_type =~ m/\S/o)) {
	    my $saved_file_type = $file_type;
	    
	    $file_type =~ s/^\s+//o;   #...trim leading whitespace
	    $file_type =~ s/\s+$//o;   #...trim trailing whitespace
	    $file_type =~ s/, with very long lines//;
	    
	    print STDERR "file_type = $file_type\n" if $ENV{VERBOSE};
	    
	    if    ($file_type =~ m/^ASCII.*text$/) {
		print STDERR "ASCII text file\n" if $ENV{VERBOSE};
	    }
	    elsif ($file_type =~ m/^ASCII.*text, with CR line terminators$/) {
		print STDERR "CR terminated file\n" if $ENV{VERBOSE};
		$input_eol_marker = "\cM";
	    }
	    elsif ($file_type =~ m/^ASCII.*text, with CRLF line terminators$/) {
		print STDERR "CRLF terminated file\n" if $ENV{VERBOSE};
		$input_eol_marker = "\cM\cJ";
	    }
	    elsif ($file_type =~ m/^ASCII.*text, with CR, LF line terminators$/) {
		print STDERR "CR, LF terminated file\n" if $ENV{VERBOSE};
		$input_eol_marker = "\cM\cJ";
	    }
	    elsif ($file_type =~ m/^ASCII.*text, with CRLF, LF line terminators$/) {
		print STDERR "CRLF, LF terminated file\n" if $ENV{VERBOSE};
		$input_eol_marker = "\cM\cJ\n";
	    }
	    else {
		die "Could not handle file-type $saved_file_type";
	    }
	}
	else {
	    die "'file' command failed on $fasta_in";
	}
    }
}


if ($split && $basepath) {
    open(SCAFFOLD_MAP, ">$basepath/scaffold.map")
	|| die "Could not write-open scaffold-map file $basepath/scaffold.map";
}
else {
    open(SCAFFOLD_MAP, ">/dev/null")
	|| die "Could not write-open scaffold-map file /dev/null";
}


if ($trouble || @ARGV) {
    warn qq(There were invalid arguments: ), join(" ", @ARGV), qq(\n\n);
    pod2text($0);
    die "aborted";
}


my $num   = 0;
my $bad   = 0;
my $short = 0;
my $long  = 0;
my $max_contig_id_len = 0;

my $badchars = 0;
my $max_bad  = 500;

my %id_by_content;

while (my($head, $seqP) = &get_fasta_record($fh_in)) {
    $num++;

    if ($badchars > $max_bad)
    {
	warn "Aborting reformat: reached $badchars bad characters\n";
	last;
    }
    
    if ($bad > $max_bad)
    {
	warn "Aborting reformat: reached $bad bad contigs\n";
	last;
    }
    
    $$seqP = lc($$seqP);
    my $len = length($$seqP);
    
    unless (defined($head) && $len) {
	++$bad;
	warn "No header for record num=$num, line=$., len=$len" unless (defined($head));
	warn "Zero-length record num=$num, line=$., head=$head" unless ($len);
	next;
    }

    my $prev_id = $id_by_content{$$seqP};

    if ($renumber) {
	my $orig = $head;
	my $contig_id = $renumber_prefix . ("0" x ($renumber_digits - length($num))) . $num; 
	if ($keep) {
	    $head = "$contig_id\t$head";
	}
	else {
	    $head = $contig_id;
	}
	print $renumber_map "$orig\t$head\n" if $renumber_map;
    }
    else {
	if ($head =~ m/^(\S+)/o) {
	    $head =  $1;
	}
	else {
	    ++$bad;
	    $trouble = 1;
	    print STDERR "Record $. has leading whitespace or no contig name\n";
	    next;
	}
    }
    
    my $contig_id;
    if ($head =~ m/^(\S+)/o) {
	$contig_id =  $1;
	print STDERR "$contig_id --> " if $ENV{DEBUG};
	$contig_id =~ s/\,$//o;
	print STDERR "$contig_id\n"    if $ENV{DEBUG};
	
	if ($contig_id =~ m/\,/o) {
	    ++$bad;
	    $trouble = 1;
            print STDERR "Record $. has a comma embedded in the contig name\n";
            next;
	}
    }
    else {
	print STDERR "Record $. has impossible leading whitespace or no contig name\n";
	next;
    }
    
    if ((my $l = length($contig_id)) > $max_contig_id_len)
    {
	$max_contig_id_len = $l;
    }

    if ($prev_id)
    {
	if ($remove_duplicates)
	{
	    print $duplicates_fh "$prev_id\t$contig_id\n" if $duplicates_fh;
	    $duplicates_removed++;
	    next;
	}
    }
    else
    {
	$id_by_content{$$seqP} = $contig_id;
    }
    
    my $accept;
    my @ambig_runs = ();
    if ($split) {
	$_ =  $$seqP;
	while ($_ =~ m/([nbdhvrykmswx]{$split,}|a{$longrepeat,}|c{$longrepeat,}|g{$longrepeat,}|t{$longrepeat,})/gio) {
	    my $run = $1;
	    $nx_chars += length($run);
	    push @ambig_runs, $run;
	}

	my $runs;
	if (@ambig_runs > 1) { $runs = 'runs'; } else { $runs = 'run'; }
	
	if (defined($ENV{VERBOSE}) && @ambig_runs) {
	    if ($ENV{VERBOSE} == 1) {
		print STDERR "$head contains "
		    , (scalar @ambig_runs)
		    , " long $runs of ambiguity characters separating subcontigs, with run-lengths "
		    , join(qq(, ), (map { length($_) } @ambig_runs)), "\n"
		    if (@ambig_runs && $ENV{VERBOSE});
	    }
	    elsif ($ENV{VERBOSE} > 1) {
		print STDERR "$head contains "
		    , (scalar @ambig_runs)
		    , " long $runs of ambiguity characters separating subcontigs: "
		    , join(qq(, ), @ambig_runs), "\n"
		    if (@ambig_runs && $ENV{VERBOSE});
	    }
	}		
    }
    
    print SCAFFOLD_MAP "$contig_id\n" if $split;
    if ($split && @ambig_runs) {
	my $last_pos   = 0;
	my $subcon_num = 0;
	my($subcontig, $subcontig_id);
	my($prefix, $bridge, $suffix) = ("", "", "");
	while ($$seqP =~ m/[nbdhvrykmswx]{$split,}|a{$longrepeat,}|c{$longrepeat,}|g{$longrepeat,}|t{$longrepeat,}/gio) {
	    ($prefix, $bridge, $suffix) = ($`, $&, $');
	    print STDERR "$bridge\n";
	    
	    $accept = 1;
	    if (length($prefix)) {
		++$subcon_num;
		$subcontig_id = "$contig_id.$subcon_num";
		
		$subcontig = substr($$seqP, $last_pos, length($prefix) - $last_pos);
		print SCAFFOLD_MAP "$subcontig_id\t", $last_pos, "\n";
		
		if (($len = length($subcontig)) < $min_length) {		    
		    print STDERR "   skipping len=$len $subcontig_id\n" if ($ENV{VERBOSE});
		    ++$short;
		    $short_chars += $len;
		    $accept = 0;
		}
		
		if (($len = length($subcontig)) > $max_length) {		    
		    print STDERR "   skipping len=$len $subcontig_id\n" if ($ENV{VERBOSE});
		    ++$long;
		    $long_chars += $len;
		    $accept = 0;
		}
		
		print STDERR "   accepting prefix len=$len $subcontig_id\n" if $ENV{VERBOSE};
		&display_id_and_seq($subcontig_id, \$subcontig, $fh_out) if $accept;
	    }
	    $last_pos = pos($$seqP);
	}

	$accept = 1;
	if ($suffix) {
	    ++$subcon_num;
	    $subcontig_id = "$contig_id.$subcon_num";
	    
	    $subcontig = $suffix;
	    print SCAFFOLD_MAP "$subcontig_id\t", $last_pos,"\n";
	    
	    if (($len = length($subcontig)) < $min_length) {		    
		print STDERR "   skipping len=$len $subcontig_id\n" if ($ENV{VERBOSE});
		++$short;
		$short_chars += $len;
		$accept = 0;
	    }
	    
	    if (($len = length($subcontig)) > $max_length) {		    
		print STDERR "   skipping len=$len $subcontig_id\n" if ($ENV{VERBOSE});
		++$long;
		$long_chars += $len;
		$accept = 0;
	    }
	    
	    print STDERR "   accepting suffix len=$len $subcontig_id\n" if $ENV{VERBOSE};
	    &display_id_and_seq($subcontig_id, \$subcontig, $fh_out) if $accept;
	}
    }
    else {
	$accept = 1;
	
	if (($len = length($$seqP)) < $min_length) {		    
	    print STDERR "   skipping len=$len $head\n" if ($ENV{VERBOSE});
	    ++$short;
	    $short_chars += $len;
	    $accept = 0;
	}
	
	if (($len = length($$seqP)) > $max_length) {		    
	    print STDERR "   skipping len=$len $head\n" if ($ENV{VERBOSE});
	    ++$long;
	    $long_chars += $len;
	    $accept = 0;
	}
	
	&display_id_and_seq( $contig_id, $seqP, $fh_out ) if $accept;
    }
    
    print SCAFFOLD_MAP "//\n" if $split;
}

my ($s, $sa, $sb);
print STDERR "\n" if ($bad);
print STDERR "max id length $max_contig_id_len\n";

$s = ($duplicates_removed == 1) ? qq() : qq(s);
print STDERR "removed $duplicates_removed duplicate$s.\n" if ($duplicates_removed);

$s = ($bad == 1) ? qq() : qq(s);
print STDERR "skipped $bad bad contig$s.\n" if ($bad);

$s = ($badchars == 1) ? qq() : qq(s);
print STDERR "skipped $badchars invalid char$s.\n"   if ($badchars);

$s = ($nx_chars == 1) ? qq() : qq(s);
print STDERR "skipped $nx_chars ambiguity char$s.\n" if ($nx_chars);

$sa = ($short_chars == 1) ? qq() : qq(s);
$sb = ($short == 1) ? qq() : qq(s);
print STDERR "skipped $short_chars char$sa in $short contig$sb shorter than $min_length bp.\n" if ($short);

$sa = ($long_chars == 1) ? qq() : qq(s);
$sb = ($long == 1) ? qq() : qq(s);
print STDERR "skipped $long_chars char$sa in $long contig$sb longer than $max_length bp.\n"   if ($long);
print STDERR "\n" if ($bad);

if (defined($logfilename)) {
    close STDERR;
}

exit($trouble || $bad);


sub get_fasta_record {
    my ( $fh ) = @_;
    my ( $old_eol, $entry, @lines, $head, $seq);
    
    if (not defined($fh))  { $fh = \*STDIN; }
    $old_eol = $/;
    $/ = "$input_eol_marker>";
    
    my @record = ();
    if (defined($entry = <$fh>)) {
	chomp $entry;
	@lines =  split( /$input_eol_marker/, $entry );
	while (@lines and (not defined($lines[0])))  { shift @lines; }
	
	$head  =  shift @lines;
	if ($first_line) {
	    $first_line = 0;
	    if (not ($head  =~ s/^\s*>//)) {
		$trouble = 1;
		warn $head;
		die "ERROR: File does not appear to be in FASTA format\n";
	    }
	}
	else {
	    if ($head  =~ s/^\s*>//) {
		$trouble = 1;
		warn $head;
		die "Spurious beginning-of record mark found in record $.\n";
	    }
	}
	
	foreach my $ln (@lines) {
	    $_  =  $ln;
	    $ln =~ s/\s//g;
	    
	    print STDERR "$head: contains X's\n"    if ($ln =~ s/x/n/ig);
	    print STDERR "$head: contains colons\n" if ($ln =~ s/://g);
	    
	    while ($ln =~ s/([^ACGTUMRWSYKBDHVN]+)/n/i) {
		$trouble = 1;
		$badchars++;
		print STDERR ">$head:\tbad char $1 at ", pos($ln), " at line $.\n";
	    }
	}
	
	$seq   =  join( "", @lines );
	$seq   =~ s/\cM//g;
	$seq   =~ tr/a-z/A-Z/;
	@record = ($head, \$seq);
    }
    
    $/ = $old_eol;
    return @record;
}


sub display_id_and_seq {
    my( $id, $seq, $fh ) = @_;
    my ( $i, $n, $ln );
    
    if (! defined($fh) )  { $fh = \*STDOUT; }
    
    print $fh ">$id\n";
    
    $n = length($$seq);
#   confess "zero-length sequence ???" if ( (! defined($n)) || ($n == 0) );
    for ($i=0; ($i < $n); $i += $width) {
	if (($i + $width) <= $n) {
	    $ln = substr($$seq,$i,$width);
	}
	else {
	    $ln = substr($$seq,$i,($n-$i));
	}
	
	print $fh "$ln\n";
    }
}
