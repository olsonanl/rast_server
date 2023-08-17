#
# Module to handle the mechanisms involved in uploading a new job.
#
# Sketch:
#
# my $newjob = JobUpload->new($workdir)
#
# Workdir is a directory into which temporary files etc should be written.
#
# $newjob->create_from_file($name)
#
#
# Name here is a filename of one of the formats we accept.
#  genbank
#  fasta
# or the compressed version of one of these.
#

package JobUpload;

use base 'Class::Accessor';
use strict;

use Encode;
use GenomeMeta;
use Data::Dumper;
use FIG_Config;

our $max_id_len = 70;

__PACKAGE__->mk_accessors(qw(workdir meta orgdir orig_file));

sub new
{
    my($class, $workdir) = @_;

    if (! -d $workdir)
    {
	if (!mkdir($workdir))
	{
	    warn "Cannot create workdir $workdir: $!";
	    return undef;
	}
    }

    my $orgdir = "$workdir/orgdir";
    mkdir $orgdir unless -d $orgdir;

    my $meta = new GenomeMeta(undef, "$workdir/meta.xml");

    my $self = {
	workdir => $workdir,
	orgdir => $orgdir,
	meta => $meta,
    };
    return bless $self, $class;
}

sub create_from_filehandle
{
    my($self, $fh, $filename, $errors) = @_;

    #
    # We read the first block of the file to evaluate it for badness
    # of format and to get an estimate on the line terminators. We also stash
    # the original data in a file in our work directory.
    #
    
    # $self->meta->set_metadata("upload_filename", $filename);
    open(my $wfh, ">", $self->workdir . "/upload_filename");
    print $wfh $filename;
    close($wfh);
    
    open(my $wfh, ">", $self->workdir . "/upload_filename.utf8");
    print $wfh encode_utf8($filename);
    close($wfh);
    
    my $block;
    
    read($fh, $block, 4096) or die "Read failed: $!";

    if ($block =~ /^\{\\rtf/)
    {
	die "File $filename is an RTF document\n";
    }
    elsif ($block =~ /^(\376\067\0\043)|(\320\317\021\340\241\261\032\341)|(\333\245-\0\0\0)/)
    {
	die "File $filename is a Microsoft Office document.";
    }

    my $orig_file = $self->workdir . "/original_upload";
    my $orig_fh = new FileHandle($orig_file, ">");
    $orig_fh or die "Cannot write file $orig_file: $!";

    print $orig_fh $block;
    
    #
    # Try to guess line endings based on NL / CR counts.
    #

    my $nlcount = ($block =~ tr/\n//);
    my $crcount = ($block =~ tr/\r//);

    my $sep;
    if ($nlcount > 0 and $crcount == 0)
    {
	$sep = "\n";
    }
    elsif ($crcount > 0 and $nlcount == 0)
    {
	$sep = "\r";
    }
    elsif ($nlcount == 0 and $crcount == 0)
    {
	warn "Document is probably binary, no NL or CR in first block.";
	push(@$errors, "Document is probably binary, no NL or CR in first block.");
	#
	# Try to read as normal doc in case there's just a really really long annotation.
	#
	$sep = "\n";
    }
    else
    {
	#
	# We have a mix of separators, treat as NL sep. We strip CR in any case.
	#
	$sep = "\n";
    }

    my $n;
    while (($n = read($fh, $block, 4096)) > 0)
    {
	print $orig_fh $block;
    }
    if (!defined($n))
    {
	die "Error reading uploaded filehandle: $!";
    }
    close($fh);
    close($orig_fh);

    my $res;
    eval {
	$res = $self->parse_as_fasta($orig_file, $sep);
    };
    if ($@)
    {
	    if ( ref($@))
	    {
		warn "fasta parse failed: @{$@}";
		push @$errors, "fasta parse failed: @{$@}";
	    }
	    else
	    {
		warn "fasta parse failed: $@";
		push @$errors, "fasta parse failed: $@";
	    }
    }

    if (!$res)
    {
	eval {
	    $res = $self->parse_as_genbank($orig_file, $sep);
	};
	if ($@)
	{
	    if ( ref($@))
	    {
		warn "genbank parse failed: @{$@}";
		push @$errors, "genbank parse failed: @{$@}";
	    }
	    else
	    {
		warn "genbank parse failed: $@";
		push @$errors, "genbank parse failed: $@";
	    }
		
	}
    }

    if (!$res)
    {
	return 0;
    }
	
    $self->reformat_contigs();
    $self->compute_contig_stats("contigs");
    $self->compute_contig_stats("split_contigs");

    $self->compute_feature_stats();

    return 1;
}

#
# For the parses that gave us features, determine the feature
# types and the counts for each.
#
sub compute_feature_stats
{
    my($self) = @_;

    my %features;
    my $feature_dir = $self->orgdir() . "/Features";
    if (opendir(D, $feature_dir))
    {
	for my $ftype (readdir(D))
	{
	    next if $ftype =~ /^\./;
	    my $fdir = "$feature_dir/$ftype";
	    if (open(TBL, "<", "$fdir/tbl"))
	    {
		my $c = 0;
		while (<TBL>)
		{
		    $c++;
		}
		close(TBL);
		$features{$ftype} = $c;
	    }
	}
	closedir(D);
    }

    if (%features)
    {
	$self->meta->set_metadata("feature_counts", \%features);
    }
}

sub parse_as_fasta
{
    my($self, $file, $sep) = @_;

    my $orig_file = $self->workdir() . "/fasta_orig";
    my $clean_file = $self->workdir() . "/fasta_clean";

    my $orig_fh = new FileHandle($orig_file, ">");
    $orig_fh or die "Cannot open $orig_file for writing: $!";
    my $clean_fh = new FileHandle($clean_file, ">");
    $orig_fh or die "Cannot open $clean_file for writing: $!";

    local $/ = $sep;

    my $fh = new FileHandle($file, "<") or die "cannot open $file: $!";

    my $state = 'expect_header';
    my $cur_id;

    my %ids_seen;
    my $cur_seq_len;
    my @empty_sequences;
    my @bad_ids;
    my @long_ids;
    eval {
	while (<$fh>)
	{
	    print $orig_fh $_;
	    chomp;
	    
	    if ($state eq 'expect_header')
	    {
		if (/^>(\S+)/)
		{
		    $cur_id = $1;
		    push(@bad_ids, $cur_id) if ($cur_id =~ /,/);
		    push(@long_ids, $cur_id) if length($cur_id) > $max_id_len;
			
		    $ids_seen{$cur_id}++;
		    $state = 'expect_data';
		    print $clean_fh ">$cur_id\n";
		    $cur_seq_len = 0;
		    next;
		}
		else
		{
		    die "Invalid fasta: Expected header at line $.\n";
		}
	    }
	    elsif ($state eq 'expect_data')
	    {
		if (/^>(\S+)/)
		{
		    if ($cur_seq_len == 0)
		    {
			push(@empty_sequences, $cur_id);
		    }
		    $cur_seq_len = 0;
		    $cur_id = $1;
		    push(@bad_ids, $cur_id) if ($cur_id =~ /,/);
		    push(@long_ids, $cur_id) if length($cur_id) > $max_id_len;
		    $ids_seen{$cur_id}++;
		    $state = 'expect_data';
		    print $clean_fh ">$cur_id\n";
		    next;
		}
		#
		# Strip any whitespace - we will allow it.
		#
		s/\s*//g;
		if (/^([acgtumrwsykbdhvn]*)\s*$/i)
		{
		    print $clean_fh lc($1) . "\n";
		    $cur_seq_len += length($1);
		    next;
		}
		elsif (/^[*abcdefghijklmnopqrstuvwxyz]*\s*$/i)
		{
		    die "Invalid fasta: Bad data (appears to be protein translation data) at line $.\n";
		}
		else
		{
		    my $str = $_;
		    if (length($_) > 100)
		    {
			$str = substr($_, 0, 50) . " [...] " . substr($_, -50);
		    }
		    die "Invalid fasta: Bad data at line $.:\n$str\n";
		}
	    }
	    else
	    {
		die "Internal error: invalid state $state\n";
	    }
	}
	$clean_fh->close();
	$orig_fh->close();
    };
    if ($@)
    {
	#
	# error during parse, clean up & rethrow.
	#
	$clean_fh->close();
	$orig_fh->close();
	unlink($clean_file);
	unlink($orig_file);
	die $@;
    }

    #
    # Check for ID uniqueness.
    #
    my @duplicate_ids = grep { $ids_seen{$_} > 1 } keys %ids_seen;
    my $errs;
    if (@duplicate_ids)
    {
	my $n = @duplicate_ids;
	if ($n > 10)
	{
	    $#duplicate_ids = 10;
	    push(@duplicate_ids, "...");
	}
	$errs .= "$n duplicate sequence identifiers were found:\n" . join("", map { "\t$_\n" } @duplicate_ids);
    }
    if (@empty_sequences)
    {
	my $n = @empty_sequences;
	if ($n > 10)
	{
	    $#empty_sequences = 10;
	    push(@empty_sequences, "...");
	}
	$errs .= "$n empty sequences were found:\n" . join("", map { "\t$_\n" } @empty_sequences);
    }
    if (@bad_ids)
    {
	my $n = @bad_ids;
	if ($n > 10)
	{
	    $#bad_ids = 10;
	    push(@bad_ids, "...");
	}
	my $t = $n == 1 ? "id was" : "ids were";
	$errs .= "$n bad $t found:\n" . join("", map { "\t$_\n" } @bad_ids) .
	    "Commas are not allowed in sequence IDs in RAST\n";
    }
    if (@long_ids)
    {
	my $n = @long_ids;
	if ($n > 10)
	{
	    $#long_ids = 10;
	    push(@long_ids, "...");
	}
	my $t = $n == 1 ? "id was" : "ids were";
	$errs .= "$n long $t found:\n" . join("", map { "\t$_\n" } @long_ids) .
	    "Sequence IDs are limited to $max_id_len characters or fewer in RAST.\n";
    }
    die "\n$errs" if $errs;

    #
    # Otherwise we had a clean fasta parse.
    #
    $self->meta->set_metadata("original_fasta", $orig_file);
    $self->meta->set_metadata("clean_fasta", $clean_file);
    $self->meta->set_metadata("upload_type", "fasta");

    $self->setup_fasta_org_dir();

    return 1;
}

sub parse_as_genbank
{
    my($self, $file, $sep) = @_;

    my $orig_file = $self->workdir() . "/genbank_orig";
    my $clean_file = $self->workdir() . "/genbank_clean";

    my $orig_fh = new FileHandle($orig_file, ">");
    $orig_fh or die "Cannot open $orig_file for writing: $!";
    my $clean_fh = new FileHandle($clean_file, ">");
    $orig_fh or die "Cannot open $clean_file for writing: $!";

    local $/ = $sep;

    my $fh = new FileHandle($file, "<") or die "cannot open $file: $!";

    my $state = 'expect_header';
    my $cur_id;

    #
    # A genbank file must start with a LOCUS line.
    #
    # We do some primitive parsing here to attempt to pull out
    # genome name, taxon id, and translation table from the file.
    #

    my @orgs;
    my %strain;
    my %taxon;
    my %code;
    my $cur_acc;
    my $cur_data;
    my ($major, $minor);
    my $in_state;
    my $in_seq_data;
    my $seq_data_lines = 0;
    eval {

	my $first = 1;
	
	while (<$fh>)
	{
	    print $orig_fh $_;
	    chomp;
	    s/\r//g;
	    print $clean_fh "$_\n";

	    # genbank file must start with LOCUS line
	    if ($first)
	    {
		if (! /^LOCUS/)
		{
		    die "File does not appear to be a properly formatted genbank file\n";
		}
		$first = 0;
	    }

	    if ($in_seq_data)
	    {
		if (m,^//,)
		{
		    $in_seq_data = 0;
		    $cur_data->{seq_data_lines} = $seq_data_lines;
		    $seq_data_lines = 0;
		}
		else
		{
		    $seq_data_lines++;
		}
	    }

	    if (/^ORIGIN/)
	    {
		$in_seq_data = 1;
	    }

	    if (/^\s+(.*)/ and ($in_state eq 'definition' or $in_state eq 'project'))
	    {
		$cur_data->{$in_state} .= " " . $1;
		next;
	    }
	    undef $in_state;
		

	    if (m,^//,)
	    {
		undef $major;
		undef $minor;
	    }
	    if (/^(\S+)/)
	    {
		$major = $1;
		undef $minor;
	    }
	    elsif (/^\s+(([a-zA-Z_]){1,40})/)
	    {
		$minor = $1;
	    }

	    if (/^\s+source\s+(\d+)\.\.(\d+)/)
	    {
		$cur_data->{size} = $2 - $1 + 1;
	    }

	    if (/^LOCUS\s+(\S+)/)
	    {
		$cur_acc = $1;
		$cur_data = {accession => $cur_acc};
		push(@orgs, $cur_data);
	    }

	    if ($major eq 'FEATURES')
	    {
		while (tr/\"// == 1)
		{
		    my $l = <$fh>;
		    print $orig_fh $l;
		    my $x = $l;
		    chomp $x;
		    print $clean_fh "$x\n";

		    last if !defined($l);
		    $l =~ s/^\s*/ /;
		    chomp $l;
		    #print STDERR "Read line '$l' appending to '$_'\n";
		    $_ .= $l;
		}
		#print STDERR "After loop have '$_'\n";
	    }
	    my($what, $val);
	    if (m,^\s*/([^=]+)=\"([^\"]+)\", or
	       m,^\s*/([^=]+)=(\S+),)
	    {
		($what, $val) = ($1,$2);
		#print "GOT $major' '$minor' '$what' = '$val'\n";

	    }

	    if (/^(PROJECT|DEFINITION)\s+(.*)/)
	    {
		$cur_data->{lc($1)} = $2;
		$in_state = lc($1);
	    }
	    elsif ($major eq 'FEATURES')
	    {
		if ($minor eq 'source')
		{
			
		    if ($what =~ /^(organism|strain|plasmid)$/)
		    {
			$cur_data->{$what} = $val;
		    }
		    elsif ($what eq 'db_xref' && $val =~ /taxon:(\d+)/)
		    {
			$cur_data->{taxon} = $1;
		    }
		}
		elsif ($minor eq 'CDS')
		{
		    if ($what eq 'transl_table')
		    {
			$cur_data->{$what} = $val;
		    }
		    elsif ($what eq 'translation')
		    {
			$cur_data->{$what}++;
		    }
		}
	    }
	}
	$orig_fh->close();
	$clean_fh->close();
    };
    if ($@)
    {
	#
	# error during parse, clean up & rethrow.
	#
	$clean_fh->close();
	$orig_fh->close();
	unlink($clean_file);
	unlink($orig_file);
	die $@;
    }

    #
    # We have a cleaned genbank file now in $clean_file.
    #
    # We believe that we should have at least seen more than one LOCUS
    # 

    if (@orgs == 0)
    {
	die "No organisms found in genbank file\n";
    }

    #
    # Fill in some defaults from the org list.
    #

    my $ref_org = $orgs[0];

    if ($ref_org->{organism} =~ /^(\S+)\s+(\S+)(\s+(.*))?/)
    {
	$self->meta->set_metadata(genus => $1);
	$self->meta->set_metadata(species => $2);

	my $maybe_strain = $4;
	if ($maybe_strain)
	{
	    $self->meta->set_metadata(strain => $maybe_strain);
	}
	elsif ($ref_org->{strain})
	{
	    $self->meta->set_metadata(strain => $ref_org->{strain});
	}
    }
    if ($ref_org->{taxon})
    {
	$self->meta->set_metadata(taxonomy_id => $ref_org->{taxon});
    }
    if ($ref_org->{transl_table})
    {
	$self->meta->set_metadata(genetic_code => $ref_org->{transl_table});
    }

    $self->meta->set_metadata("original_genbank", $orig_file);
    $self->meta->set_metadata("clean_genbank", $clean_file);
    $self->meta->set_metadata("upload_type", "genbank");
    $self->meta->set_metadata("genbank_org_list", \@orgs);

    $self->setup_genbank_org_dir();
}

#
# Create a prototypical orgdir from the fasta file. 
#
sub setup_fasta_org_dir
{
    my($self) = @_;

    my $orgdir = $self->orgdir();
    my $workdir = $self->workdir();
    
    system("cp", $self->meta->get_metadata('clean_fasta'), "$orgdir/unformatted_contigs");
}

sub setup_genbank_org_dir
{
    my($self) = @_;
    my $orgdir = $self->orgdir();
    my $workdir = $self->workdir();
    
    system("cp", $self->meta->get_metadata('clean_genbank'), "$orgdir/genbank_file");

    my $orgs = $self->meta->get_metadata("genbank_org_list");
    my $tax_id = 888888888;
    if (ref($orgs))
    {
	my $tmp = $orgs->[0]->{taxon};
	if ($tmp ne '')
	{
	    $tax_id = $tmp;
	}
    }
    my $cmd = "$FIG_Config::bin/parse_genbank $tax_id '$orgdir' < '$orgdir/genbank_file' 2> '$workdir/parse_genbank.stderr'";
    my $rc = system($cmd);
    if ($rc != 0)
    {
	die "Error $rc running $cmd\n";
    }

    #
    # parse_genbank writes contigs into "contigs". Move that to
    # unformatted_contigs and run the reformat with an without split.
    #

    rename("$orgdir/contigs", "$orgdir/unformatted_contigs");

    #                                                                                                                        
    # Create a TAXONOMY_ID file                                                                                              
    #                                                                                                                        
    if (! -f "$orgdir/TAXONOMY_ID")
    {
        if (open(my $tfh, ">", "$orgdir/TAXONOMY_ID"))
        {
            print $tfh "$tax_id\n";
            close($tfh);
        }
    }

}

sub reformat_contigs
{
    my($self) = @_;
    my $workdir = $self->workdir();
    my $orgdir = $self->orgdir();
    
    my @cmd = ("$FIG_Config::bin/reformat_contigs", "-v", "-logfile=$workdir/reformat.stderr",
	       "$orgdir/unformatted_contigs", "$orgdir/contigs");
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	warn "Error $rc running cmd: @cmd\n";
    }

    my $split_size = 3;
    if ($FIG_Config::rast_contig_ambig_split_size =~ /^\d+$/)
    {
	$split_size = $FIG_Config::rast_contig_ambig_split_size;
    }
    my @cmd = ("$FIG_Config::bin/reformat_contigs", "-v", "-logfile=$workdir/reformat.split.stderr",
	       "-split=$split_size",
	       "$orgdir/unformatted_contigs", "$orgdir/split_contigs");
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	warn "Error $rc running cmd: @cmd\n";
    }
}    

#
# Use sequence_length_histogram to determine GC content and other length measures of the given
# contig file. Store results in the metadata.
#
sub compute_contig_stats
{
    my($self, $which) = @_;

    my $orgdir = $self->orgdir();
    my $workdir = $self->workdir();
    my $cmd = "$FIG_Config::bin/sequence_length_histogram -get_dna -get_gc -nolabel  < '$orgdir/$which' > '$workdir/histogram.$which' 2> '$workdir/stats.$which' ";
    my $rc = system($cmd);
    if ($rc != 0)
    {
	warn "Error $rc running command $cmd\n";
	return;
    }
    my $fh = new FileHandle("$workdir/stats.$which", "<");
    $fh or die "Cannot open stats output file $workdir/stats.$which: $!";
    my %stats;
    while (<$fh>)
    {
	if (/(\d+)\s+chars\s+in\s+(\d+).*G\+C\s+=\s+([^%]+)%.*Ambig:(\d+)/)
	{
	    ($stats{chars}, $stats{seqs}, $stats{gc}, $stats{ambigs}) = ($1, $2, $3, $4);
	}
	elsif (/^min/)
	{
	    ($stats{min}, $stats{median}, $stats{mean}, $stats{max}) = /(\d+(?:\.\d+)?)/g;
	}
    }
    close($fh);

    #
    # Determine the number of basepairs in sequences greater than 2k.
    #
    $fh = new FileHandle("$workdir/histogram.$which", "<");
    $fh or die "Cannot open histogram file $workdir/histogram.$which: $!";
    my $count_over_2k = 0;
    while (<$fh>)
    {
	chomp;
	my($size, $count, $cumul) = split(/\t/);
	if ($size > 2000)
	{
	    $count_over_2k += $size * $count;
	}
    }
    close($fh);
    
    #
    # Also compute N50.
    #
    if (open(my $fh, "<", "$orgdir/$which"))
    {
	my $length;
	my $totalLength; 
	my @arr;
	while(<$fh>){
	    chomp; 
	    if(/>/){
		push (@arr, $length);
		$totalLength += $length; 
		$length=0;
		next;
	    }
	    $length += length($_);
	}
	
	my @sort = sort {$b <=> $a} @arr;
	my $n50; 
	my $L50;
	foreach my $val(@sort){
	    $n50 += $val;
	    $L50++;
	    if($n50 >= $totalLength/2){
		$stats{N50} = $val;
		$stats{L50} = $L50;
		last; 
	    }
	}
	close($fh);
    }
    $self->meta->set_metadata("bp_in_seqs_over_2k_$which", $count_over_2k);
    $self->meta->set_metadata("stats_$which", \%stats);

}

#
# Perform checks on the extracted FASTA.
# Returns a ref of output.
# Check for duplicate contig ids. Returns the list of duplicate ids in key duplicate_ids
# Check for empty contigs. Returns list in empty_ids.
# Check for invalid characters in ids. Returns list in invalid_ids.
#

sub check_contigs
{
    my($self) = @_;

    my $fasta = $self->meta->get_metadata('clean_fasta');
    open(FA, "<", $fasta) or die "check_contigs(): Cannot open fasta file $fasta: $!";
    my %ids;
    my %empty_ids;
    my %invalid;
    my $out = {};
    my $len = 0;
    my $last;
    while (<FA>)
    {
	if (/^>(\S+)/)
	{
	    my $id = $1;
	    if ($last)
	    {
		if ($len == 0)
		{
		    $empty_ids{$last}++;
		}
	    }
	    
	    $ids{$id}++;
	    $len = 0;
	    $last = $1;

	    if ($id =~ /,/)
	    {
		$invalid{$id}++;
	    }
	}
	else
	{
	    $len++;
	}
    }
    if ($len == 0)
    {
	$empty_ids{$last}++;
    }
    close(FA);
    $out->{duplicate_ids} = [grep { $ids{$_} > 1 } keys %ids];
    $out->{empty_ids} = [keys %empty_ids];
    $out->{invalid_ids} = [keys %invalid];
    return $out;
}

#
# Produce a HTML report of the contents of this upload.
#

sub html_report
{
    my($self) = @_;

    my $c;

    my %stat_strings = (chars => 'Sequence size',
			seqs => 'Number of contigs',
			gc => 'GC content (%)',
			min => 'Shortest contig size',
			median => 'Median sequence size',
			mean => 'Mean sequence size',
			max => 'Longest contig size',
			contigs => 'contigs as uploaded',
			split_contigs => 'contigs after split into scaffolds',
			N50 => 'N50 value',
			L50 => 'L50 value',
			);

    if (0)
    {
	#
	# The second form is more readable and more compact.
	#
	for my $set ('contigs', 'split_contigs')
	{
	    $c .= "<p>Contig statistics for $stat_strings{$set}:</p>\n";
	    $c .= "<table>\n";
	    my $stats = $self->meta->get_metadata("stats_$set");
	    for my $k (qw(chars seqs gc min median mean max))
	    {
		$c .= "<tr><td>$stat_strings{$k}</td><td>$stats->{$k}</td></tr>\n";
	    }
	    $c .= "</table>\n<p>\n";
	}
    }

    my $stats_uploaded = $self->meta->get_metadata("stats_contigs");
    my $stats_split = $self->meta->get_metadata("stats_split_contigs");
    $c .= "<h3>Contig statistics</h3>\n";
    $c .= "<table>\n";
    $c .= "<tr><th>Statistic</th><th>As uploaded</th><th>After splitting into scaffolds</th></tr>\n";
    for my $k (qw(chars seqs gc min median mean max N50 L50))
    {
	$c .= "<tr><td>$stat_strings{$k}</td><td>$stats_uploaded->{$k}</td><td>$stats_split->{$k}</td></tr>\n";
    }
    $c .= "</table>\n";

    #
    # If this was a genbank file, list the details from there.
    #

    if ($self->meta->get_metadata("upload_type") eq 'genbank')
    {
	$c .= "<h3>Genbank file data</h3>\n";
	$c .= $self->html_report_genbank();
    }

    my $feature_counts = $self->meta->get_metadata("feature_counts");
    if ($feature_counts)
    {
	$c .= "<h3>Feature statistics</h3>\n";
	$c .= "<table>";
	$c .= "<tr><th>Feature type</th><th>Count</th></tr>\n";
	for my $ftype (keys %$feature_counts)
	{
	    my $ct = $feature_counts->{$ftype};
	    $c .= "<tr><td>$ftype</td><td>$ct</td></tr>\n";
	}
	$c .= "</table>\n";
    }
    
    return $c;
}


sub html_report_genbank
{
    my($self) = @_;

    my $c = '';

    my $orgs = $self->meta->get_metadata("genbank_org_list");

    my $n= @$orgs;
    my $p = $n == 1 ? "" : "s";
    $c .= "Genbank file contains $n contig$p:\n";

    my %names = (taxon => "Taxonomy ID",
		 organism => "Organism",
		 strain => "Strain",
		 plasmid => "Plasmid",
		 transl_table => "Translation table",
		 project => "Project ID",
		 definition => "Definition",
		 accession => "Accession",
		 size => "Genome size",
		);
    my @names = qw(accession organism strain plasmid taxon size transl_table project definition );
    $c .= "<table>\n";
    for my $org (@$orgs)
    {
	for my $n (@names)
	{
	    my $v = $org->{$n};
	    next unless $v;
	    my $disp = $names{$n};
	    $c .= "<tr><td>$disp</td><td>$v</td></tr>\n";
	}
    }
    $c .= "</table>\n";
    return $c;
}

1;
