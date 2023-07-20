# -*- perl -*-

use strict;
use warnings;

use FIG;
my $fig = FIG->new();

$0 =~ m/([^\/]+)$/;
my $self  = $1;
my $usage = "$self  [-verbose] [-code=genetic_code_num] [-minlen=min_training_len] [-train=training_tbl[,training_contigs]] [-skip_called]  Taxon_ID contigs";


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...PATH environment variables
#-----------------------------------------------------------------------
my $elph_bin        = $ENV{ELPH_BIN}          ||  $FIG_Config::ext_bin;
my $glimmer_bin     = $ENV{GLIMMER_3_BIN}     || "$FIG_Config::ext_bin/../apps/glimmer3/bin";
my $glimmer_scripts = $ENV{GLIMMER_3_SCRIPTS} || "$FIG_Config::ext_bin/../apps/glimmer3/bin";

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Defaults for vars set during argument parsing
#-----------------------------------------------------------------------
my $genetic_code     =   11;   #...Default to the "standard" code

my $train            = qq();   #...Flag associated with '-train' switch
my $training_tbl     = qq();
my $training_contigs = qq();

my $min_training_len = 2000;   #...Shortest contig used for self-training

my $glimmeropts = qq(-o50 -g110 -t30 -l);   #...NOTE: Make these the default for a switch

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# NOTE: '-skip' is an obscure option introduced to handle one job
#   for which new contigs had been added to a set of existing contigs,
#   and it was required that we not re-call the existing contigs,
#   but instead use their calls as the 'training set' for the new contigs.
#   It seems quite unlikely that this option will ever be used again.
#-----------------------------------------------------------------------
my %skip;                #...Hash storing already-called contig IDs to be skipped.
my $skip_called = qq();  #...Flag indicating whether '-skip' switch is present.


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Parse argument list
#-----------------------------------------------------------------------
my $trouble = 0;
for (my $arg=$#ARGV; ($arg >= 0); $arg--)
{
    if ($ARGV[$arg] =~ m/^-{1,2}help/) {
	warn "\n\tusage: $usage\n\n";
	exit(0);
    }
    elsif ($ARGV[$arg] =~ m/^-{1,2}code=(\d+)/) {
	$genetic_code = $1;
	splice(@ARGV, $arg, 1);
    }
    elsif ($ARGV[$arg] =~ m/^-{1,2}minlen=(\d+)/) {
	$min_training_len = $1;
	splice(@ARGV, $arg, 1);
    }
    elsif ($ARGV[$arg] =~ m/^-{1,2}verbose/) {
	$ENV{VERBOSE} = 1;
	splice(@ARGV, $arg, 1);
    }
    elsif ($ARGV[$arg] =~ m/^-{1,2}train=(\S+)/) {
	$train = $1;
	($training_tbl, $training_contigs) = split /,/, $train;
	
	if (-s $training_tbl) {
	    print STDERR "Training features will be taken from $training_tbl\n"
		if $ENV{VERBOSE};
	}
	else {
	    $trouble = 1;
	    warn "Training tbl $training_tbl does not exist";
	}
	
	if ($training_contigs) {
	    if (-s $training_contigs) {
		print STDERR "Training set will be extracted from $training_contigs\n"
		    if $ENV{VERBOSE};
	    }
	    else {
		$trouble = 1;
		warn "Training contigs $training_contigs do not exist";
	    }
	}
	splice(@ARGV, $arg, 1);
    }
    elsif ($ARGV[$arg] =~ m/^-{1,2}skip_called/) {
	$skip_called = $ARGV[$arg];
	print STDERR "Skip option is set\n" if $ENV{VERBOSE};
	splice(@ARGV,$arg,1);
    }
    elsif ($ARGV[$arg] =~ /^-/) {
	$trouble = 1;
	warn "Unrecognized argument $ARGV[$arg]";
    }
}

my $genetic_code_switch = qq(-z $genetic_code);


my $taxon_ID     = qq();
my $contigs_file = qq();

if (@ARGV == 2) {
    ($taxon_ID, $contigs_file) = @ARGV;
    if (! $training_contigs) { $training_contigs = $contigs_file }

    if ($taxon_ID && ($taxon_ID =~ m/^\d+\.\d+$/)) {
	print STDERR "Taxon-ID is $taxon_ID\n" if $ENV{VERBOSE};
    } else {
	$trouble = 1;
	warn "Bad Taxon-ID $taxon_ID\n";
    }
    
    if (-s $contigs_file) {
	print STDERR "Contigs file is $contigs_file\n" if $ENV{VERBOSE};
    } else {
	$trouble = 1;
	warn "Missing or zero-size contigs file $contigs_file";
    }
}
else {
    $trouble = 1;
    print STDERR
	qq(\nWrong number of mandatory arguments: ),
	&FIG::flatten_dumper(@ARGV),
	qq(\n);
}
die "\n\tusage: $usage\n\n" if $trouble;



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# ... Initial Training Pass
#-----------------------------------------------------------------------
if (not $training_contigs) {
    $training_contigs = $contigs_file;
}

my $tmp_prefix = "$FIG_Config::temp/tmp$$";
$fig->run("rm -f $tmp_prefix.*");

my $tmp_contig       = "$tmp_prefix.contig";
my $tmp_coords       = "$tmp_prefix.coords";
my $tmp_train        = "$tmp_prefix.train";
my $tmp_model        = "$tmp_prefix.icm";

my ($contig_id, $seqP);

if (not $train) {
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    print STDERR "\nFinding training ORFs using GLIMMER default procedure\n"
	if $ENV{VERBOSE};
#-----------------------------------------------------------------------    
    if (-s "$tmp_train") {
	system("rm -f $tmp_train") 
	    && die "Could not remove $tmp_train";
    }
    print STDERR "Training file is $training_contigs\n" if $ENV{VERBOSE};
    open(CONTIGS, "<$training_contigs")
	|| die "could not read-open training contigs file: $training_contigs";
    
    $training_tbl = "$tmp_prefix.train.tbl";
    open(TRAINING,  ">$training_tbl")  || die "Could not write-open training_tbl file: $training_tbl";
    
    my $orf_num = 0;
    my %len_of;     #...Hash storing training contig lens
    while (($contig_id, $seqP) = &read_fasta_record(\*CONTIGS))
    {
	my $len = $len_of{$contig_id} = length($$seqP);
	
	open( TMP, ">$tmp_contig") || die "Could not write-open $tmp_contig";
	&display_id_and_seq($contig_id, $seqP, \*TMP);
	close(TMP) || die "Could not close $tmp_contig";
	
	if ($len >= $min_training_len) {
	    print STDERR "\nScanning contig $contig_id for long orfs\n" if $ENV{VERBOSE};
	}
	else {
	    print STDERR "\nSkipping contig $contig_id --- too short (len=$len)\n" if $ENV{VERBOSE};
	    next;
	}
	
	my $longorfs_err = qq();
	my $tmp_longorfs_err = "$tmp_prefix.longorfs.err";
	my $rc = system("$glimmer_bin/long-orfs -l -n -t 1.15 $genetic_code_switch  $tmp_contig $tmp_coords > $tmp_longorfs_err 2>&1");
	if (-s $tmp_longorfs_err) {
	    $longorfs_err = &FIG::file_read($tmp_longorfs_err);
	    print STDERR $longorfs_err if $ENV{VERBOSE};
	}
	
	if ($rc) {
	    if ($longorfs_err) {
		if ($longorfs_err =~ m/WHAT: ERROR:  No valid orfs found below entropy cutoff/so) {
		    #...Error is harmless --- ignore it
		}
		else {
		    die (qq(Could not extract training ORFs from contig $contig_id --- return-code $rc:\n), $longorfs_err);
		}
	    }
	    else {
		die qq(Could not extract training ORFs from contig $contig_id --- return-code $rc);
	    }
	}
	
	system("$glimmer_bin/extract -t $tmp_contig $tmp_coords >> $tmp_train") 
	    && die "Could not extract training sequences from contig $contig_id";
	
	#... Translate GLIMMER  $tmp_coords into SEED $training_tbl
	open(TMP_COORDS, "<$tmp_coords") || die "Could not read-open $tmp_coords";
	print TRAINING map { ++$orf_num;
			     chomp $_;
			     my (undef, $beg, $end) = split /\s+/o, $_;
			     die "Bad coords in entry: $_" unless ($beg && $end);
			     my $fid = qq(orf) . (qq(0)x(5-length($orf_num))) . $orf_num;
			     my $loc = join(qq(_), ($contig_id, $beg, $end));
			     $_ = qq($fid\t$loc\n)
			     } <TMP_COORDS>;
    }
    close(TRAINING) || die "Could not close $training_tbl";
    close(CONTIGS)  || die "Could not close $contigs_file";
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
print STDERR ("\n",
	      "Training using:\n",
	      "   contigs --- $training_contigs\n",
	      "   ORFs    --- $training_tbl\n"
	      )
    if $ENV{VERBOSE};
#-----------------------------------------------------------------------
open(CONTIGS, "<$training_contigs") 
    || die "Could not read-open $training_contigs";

my ($len_of, $seq_of);
while (($contig_id, $seqP) = &read_fasta_record(\*CONTIGS))  {
    $len_of->{$contig_id} = length($$seqP);
    $seq_of->{$contig_id} = $$seqP;
}
close(CONTIGS) || die "Could not close $contigs_file";

my $entry;
my $orf_num;
my $max_orf_num = 0;
my %training_tbl;
open(TBL,   "<$training_tbl") || die "Could not read-open $training_tbl";
open(TRAIN, ">$tmp_train")    || die "Could not write-open $tmp_train";
while (defined($entry = <TBL>)) {
    chomp $entry;
    my ($fid, $locus) = split /\t/, $entry;
    
    if ($fid =~ m/(\d+)$/) {
	$orf_num     = $1;
	$max_orf_num = ($orf_num > $max_orf_num) ? $orf_num : $max_orf_num;
    }
    else {
	die "Could not parse FID $fid for training entry $.: $entry";
    }
    
    #...If -skip_called option was selected, record which contigs are in the training set
    if ($skip_called) { $skip{$contig_id} = 1; }
    
    my $training_seq = qq();
    my @exons        = split /,/, $locus;
    foreach my $exon (@exons) {
	if ($exon =~ m/^(\S+)_(\d+)_(\d+)/) {
	    my ($contig, $beg, $end) = ($1, $2, $3);
	    
	    my $contig_seq = $seq_of->{$contig};
	    
	    my $dna = &get_dna_seq($contig, $beg, $end, $len_of, $seq_of);
	    
	    $training_seq .= lc($dna);
	}
	else {
	    die "Could not parse exon $exon for training entry $.: $entry";
	}
	
	my $training_ID = qq(orf) . (qq(0) x (5-length($orf_num))) . $orf_num;
	&display_id_and_seq($training_ID, \$training_seq, \*TRAIN);
    }
}
close(TRAIN) || die "Could not close $tmp_train";
close(TBL)   || die "Could not close $training_tbl";

if (($_ = `grep -c "^>" $tmp_train`) && ($_ =~ m/^\s*(\d+)/)) {
    print STDERR "\nExtracted $1 training sequences\n\n" if $ENV{VERBOSE};
} 
else {
    die "\nCould not extract any training sequences";
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Build ICM (interpolated context model)
#-----------------------------------------------------------------------
print STDERR ("Building interpolated context model ---\n",
	      "   output in $tmp_model\n\n"
	      ) if $ENV{VERBOSE};

if (-s "$tmp_model") {
    system("rm -f $tmp_model") && die "Could not remove $tmp_model";
}

$fig->run("$glimmer_bin/build-icm -r $tmp_model < $tmp_train");



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... First GLIMMER pass
#-----------------------------------------------------------------------
print STDERR "Running first GLIMMER pass\n" if $ENV{VERBOSE};
$fig->run("$glimmer_bin/glimmer3 $glimmeropts $genetic_code_switch $contigs_file $tmp_model $tmp_prefix.pass_1");



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Extract upstream regions and START codon counts
#-----------------------------------------------------------------------
my $tmp_predictions_pass_1 = "$tmp_prefix.pass_1.predict";
print STDERR "\nExtracting upstream regions and START counts from $tmp_predictions_pass_1\n"
    if $ENV{VERBOSE};

open(PREDICT,  "<$tmp_predictions_pass_1")
    || die "Could not read-open $tmp_predictions_pass_1";

my $tmp_upstream = "$tmp_prefix.upstream";
open(UPSTREAM, ">$tmp_upstream")
    || die "Could not write-open $tmp_upstream";

my %start_counts;    #...Hash to hold START codon counts
$start_counts{0}   = 0;
$start_counts{atg} = 0;
$start_counts{gtg} = 0;
$start_counts{ttg} = 0;

$contig_id = qq();
while(defined($entry = <PREDICT>)) {
    chomp $entry;
    
    if ($entry =~ m/^>(\S+)/) {
	$contig_id = $1;
	next;
    }
    elsif ($entry =~ m/^(\S+)\s+(\d+)\s+(\d+)/) {
	my ($id, $beg, $end) = ($1, $2, $3);
	
	my $sign = ($beg < $end) ? +1 : -1;
	
	my $end_start   = $beg + $sign * 2;
	my $start_codon = &get_dna_seq($contig_id, $beg, $end_start, $len_of, $seq_of);
	
	++$start_counts{0};
	++$start_counts{$start_codon};
	
	my $up_id = $id;
	$up_id =~ s/^orf/ups/o;
	my $up_beg = $beg - $sign * 25;
	my $up_end = $beg - $sign;
	
	my $up_seq;
	if ($up_seq = &get_dna_seq($contig_id, $up_beg, $up_end, $len_of, $seq_of)) {
	    &display_id_and_seq($id, \$up_seq, \*UPSTREAM);
	}
    }
    else {
	die "Could not parse prediction $.: $entry";
    }
}

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Compute pseudocount-stabilized START codon frequencies
#-----------------------------------------------------------------------
my $atg_freq    = ($start_counts{atg} + 80) / ($start_counts{0} + 100);
my $gtg_freq    = ($start_counts{gtg} + 15) / ($start_counts{0} + 100);
my $ttg_freq    = ($start_counts{ttg} +  5) / ($start_counts{0} + 100);
my $start_freqs = "$atg_freq,$gtg_freq,$ttg_freq";

print STDERR "start_freqs = $start_freqs\n\n" if $ENV{VERBOSE};


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Build Position Weight Matrix for upstream regions using ELPH
#-----------------------------------------------------------------------
print STDERR "\nExtracting upstream motifs from $tmp_predictions_pass_1\n";

my $motif_width = 6;
my $tmp_motifs = "$tmp_prefix.motifs";
system("$elph_bin/elph $tmp_upstream LEN=$motif_width > $tmp_motifs")
    && ((-s $tmp_motifs)
	|| die("Could not extract upstream motifs")
	);


print STDERR "\nBuilding PWM from upstream motifs in $tmp_motifs\n";

open( MOTIFS, "<$tmp_motifs") || die "Could not read-open $tmp_motifs";
my @motifs = <MOTIFS>;
close(MOTIFS) || die "Could not close $tmp_motifs";
while ($motifs[0] !~ m/^Motif counts/) { shift @motifs };
shift @motifs;
my $last = 0;
for (my $i=0; $i < @motifs; ++$i) {
    last unless ($motifs[$i] =~ m/\S+/);
    if ($motifs[$i] =~ m/^[acgt]:((\s+\d+){$motif_width})/) {
	$last = $i;
    }
}
$#motifs = $last;

my $tmp_matrix = "$tmp_prefix.pwm";
open( MATRIX, ">$tmp_matrix") || die "Could not write-open $tmp_matrix";
print MATRIX  "$motif_width\n";
foreach my $line (@motifs) {
    chomp $line;
    my @fields = split /\s+/, $line;
    my $base   = substr((shift @fields), 0, 1);
    print MATRIX ($base, (map { sprintf(qq(%7u), $_) } @fields), qq(\n));
}
close(MATRIX)    || die "Could not close $tmp_matrix";

(-s $tmp_matrix) || die "Could not construct PWM --- empty file $tmp_matrix";



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Re-call PEGs using ICM and PWM
#-----------------------------------------------------------------------
print STDERR "Re-calling PEGs using trained ICM\n" if $ENV{VERBOSE};

$fig->run("$glimmer_bin/glimmer3 $glimmeropts $genetic_code_switch -b $tmp_matrix -P $start_freqs $contigs_file $tmp_model $tmp_prefix");



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#... Parse and write final predictions
#    NOTE: Does not yet handle '-skip' option
#-----------------------------------------------------------------------
my $tmp_predictions = "$tmp_prefix.predict";
print STDERR "\nParsing $tmp_predictions\n"
    if $ENV{VERBOSE};

open(PREDICT,  "<$tmp_predictions")
    || die "Could not read-open $tmp_predictions";

my $fid_num = 0;

$contig_id  = qq();
while(defined($entry = <PREDICT>)) {
    chomp $entry;
    
    if ($entry =~ m/^>(\S+)/) {
	$contig_id = $1;
	next;
    }
    elsif ($entry =~ m/^(\S+)\s+(\d+)\s+(\d+)/) {
	my ($id, $beg, $end) = ($1, $2, $3);
	
	if ($beg && $end) {
	    ++$fid_num;
	    my $fid = qq(fig|$taxon_ID.peg.) . $fid_num;
	    print STDOUT (qq($fid\t), join(qq(_), ($contig_id, $beg, $end)), qq(\n));
	}
	else {
	    die "Error in $tmp_predictions line $.: $entry";
	}
    }
    else {
	die "Could not parse prediction $.: $entry";
    }
}

if (not $ENV{VERBOSE}) {
    $fig->run("rm -f $tmp_prefix.*");
}
else {
    print STDERR "\nKeeping tmp files\n\n";
}

exit 0;


########################################################################
sub get_dna_seq {
    my ($contig, $beg, $end, $len_of, $seq_of) = @_;
    my $dna = qq();
    
    my $contig_len = $len_of->{$contig};
    my $contig_seq = $seq_of->{$contig};
    
    return undef if (&max($beg, $end) > $contig_len);
    return undef if (&min($beg, $end) < 1);
    
    if ($beg < $end) {
	$dna = substr($contig_seq, ($beg-1), ($end+1-$beg));
    }
    else {
	$dna = substr($contig_seq, ($end-1), ($beg+1-$end));
	$dna = $ { &rev_comp(\$dna) };
    }
    
    return lc($dna);
}


sub read_fasta_record
{
    my ($file_handle) = @_;
    my ( $old_end_of_record, $fasta_record, @lines, $head, $sequence, $seq_id, $comment, @parsed_fasta_record );

    if (not defined($file_handle))  { $file_handle = \*STDIN; }

    $old_end_of_record = $/;
    $/ = "\n>";

    if (defined($fasta_record = <$file_handle>))
    {
        chomp $fasta_record;
        @lines  =  split( /\n/, $fasta_record );
        $head   =  shift @lines;
        $head   =~ s/^>?//;
        $head   =~ m/^(\S+)/;
        $seq_id = $1;

        if ($head  =~ m/^\S+\s+(.*)$/)  { $comment = $1; } else { $comment = ""; }

        $sequence  =  join( "", @lines );

        @parsed_fasta_record = ( $seq_id, \$sequence, $comment );
    }
    else
    {
        @parsed_fasta_record = ();
    }

    $/ = $old_end_of_record;

    return @parsed_fasta_record;
}

sub display_id_and_seq 
{
    my( $id, $seq, $fh ) = @_;

    if (! defined($fh) )  { $fh = \*STDOUT; }

    print $fh ">$id\n";
    &display_seq($seq, $fh);
}

sub display_seq
{
    my ( $seq, $fh ) = @_;
    my ( $i, $n, $ln );

    if (! defined($fh) )  { $fh = \*STDOUT; }

    $n = length($$seq);
#   confess "zero-length sequence ???" if ( (! defined($n)) || ($n == 0) );
    for ($i=0; ($i < $n); $i += 60)
    {
        if (($i + 60) <= $n)
        {
            $ln = substr($$seq,$i,60);
        }
        else
        {
            $ln = substr($$seq,$i,($n-$i));
        }
        print $fh "$ln\n";
    }
}

sub rev_comp 
{
    my( $seqP ) = @_;
    my( $rev  );

    $rev =  reverse( $$seqP );
    $rev =~ tr/a-z/A-Z/;
    $rev =~ tr/ACGTUMRWSYKBDHV/TGCAAKYWSRMVHDB/;
    return \$rev;
}

sub min { my ($x, $y) = @_; return (($x < $y) ? $x : $y); }

sub max { my ($x, $y) = @_; return (($x > $y) ? $x : $y); }
