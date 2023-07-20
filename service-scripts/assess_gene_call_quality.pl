# -*- perl -*-

use FIG;
use GenomeMeta;
use strict;

$0 =~ m/([^\/]+)$/;
my $this_tool_name = $1;
my $usage = "$this_tool_name [-h(elp)] [-no_fatal] [-meta=meta.file] [-gap=maxgap] [-parms=minlen,rna,conv,div,samestrand] OrgDir > fatal_errs 2> warnings";

if ((not @ARGV) || ($ARGV[0] =~ m/^-{1,2}h(elp)?/)) {
    die "\n   usage: $usage\n\n";
}

my $no_fatal      = "";
my $meta_file     = "";
my $overlap_parms = "";

my $max_gap       = 1500;

my $FATAL = qq(FATAL);
while (@ARGV && ($ARGV[0] =~ m/^-/))
{
    if    ($ARGV[0] =~ m/^-{1,2}no_fatal/) {
	$no_fatal = shift @ARGV;
	$FATAL    = qq(WARNING);
    }
    elsif ($ARGV[0] =~ m/^-{1,2}meta=(\S+)/) {
	$meta_file = $1;
	shift @ARGV;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}gap=(\d+)/) {
	$max_gap = $1;
	shift @ARGV;
    }
    elsif ($ARGV[0] =~ m/^-{1,2}parms=\d+,\d+,\d+,\d+,\d+/) {
	$overlap_parms = shift @ARGV;
    }
    else {
	die "Invalid arg $ARGV[0]\n\n   usage: $usage\n\n";
    }
}

my $org_dir;
(($org_dir = shift @ARGV) && (-d $org_dir))
    || die "OrgDir $org_dir does not exist\n   usage: $usage\n\n";
$org_dir =~ s/\/$//;

my $org_id;
if ($org_dir =~ m/(\d+\.\d+)$/) {
    $org_id = $1;
}
else {
    die "Could not extract a well-formed Org-ID from directory-name $org_dir";
}

my $meta;
if ($meta_file)
{
    $meta = GenomeMeta->new($org_id, $meta_file);
    $meta->add_log_entry("qc", ["Assessing gene-call quality", $org_id, $org_dir]);
}

my $genome = (-s "$org_dir/GENOME") ?
    &FIG::file_read(qq($org_dir/GENOME))
    : die "\n   No GENOME file in $org_dir\n\n";
$genome =~ s/[\s\n]+/ /gs;
$genome =~ s/^\s*//;
$genome =~ s/\s*$//;

my $taxonomy = (-s "$org_dir/TAXONOMY") ?
    &FIG::file_read(qq($org_dir/TAXONOMY))
    : die "\n   No TAXONOMY file in $org_dir\n\n";
$taxonomy =~ s/[\s\n]+/ /gs;
$taxonomy =~ s/^\s*//;
$taxonomy =~ s/\s*$//;

if (($taxonomy =~ m/^\s*Bact/) ||
    ($taxonomy =~ m/^\s*Arch/) ||
    ($taxonomy =~ m/plasmid/i)  ||
    ($genome   =~ m/plasmid/i)  ||
    (-e qq($org_dir/PLASMID))
    ) {
    #...Proceed normally
}
else {
    warn "\n   WARNING: This heuristic is sensible only for Bacteria, Archaea, or Plasmids;\n"
	, "   TAXONOMY in $org_dir is:\n\n"
	, "      $taxonomy\n\n";
}

my $contigs  = "$org_dir/contigs";

my $rna_tbl  = (-s ($_ = "$org_dir/Features/rna/tbl")) ? $_ : "/dev/null";
my $peg_tbl  = (-s ($_ = "$org_dir/Features/peg/tbl")) ? $_ : "/dev/null";
my $orf_tbl  = (-s ($_ = "$org_dir/Features/orf/tbl")) ? $_ : "/dev/null";

if (!open(SUMMARY, ">$org_dir/overlap.summary"))
{
    my $err = "cannot open $org_dir/overlap.summary: $!";
    $meta->add_log_entry($0, $err) if $meta_file;
    die $err;
}

my $cmd = "$FIG_Config::bin/make_overlap_report  $overlap_parms  $contigs $rna_tbl $peg_tbl $orf_tbl";

$meta->add_log_entry($0, ['start', $cmd]) if $meta_file;
if (!open(OVER, "$cmd 2>&1 1> $org_dir/overlap.report |"))
{
    my $err = "Execution of $cmd  failed: $!";
    $meta->add_log_entry($0, [$err, $cmd]) if $meta_file;
    die $err;
}

my @overlap_summary;

while (<OVER>)
{
    push(@overlap_summary, $_);
    print SUMMARY $_;
}
close(SUMMARY);

if (!close(OVER))
{
    my $err = "close failed with \$!=$! \$?=$?";
    $meta->add_log_entry($0, [$err, $cmd]) if $meta_file;
    die "Execution of $cmd > $org_dir/overlap.summary failed: $err";
}
$meta->add_log_entry($0, ['end', $cmd])     if $meta_file;
# The following can be very large and hard to read in the web
# interface for the job (cf test rast job 466)
#$meta->add_log_entry($0, \@overlap_summary) if $meta_file;

my $num_features = 0;
my $bad_starts   = 0;
my $bad_stops    = 0;
my $too_short    = 0;
my $rna_overlaps = 0;
my $same_stop    = 0;
my $embedded     = 0;
my $convergent   = 0;
my $divergent    = 0;
my $same_strand  = 0;
my $impossible   = 0;

my $msg;
foreach my $line (@overlap_summary)
{
    if ($line =~ m/^Number of features\:\s+(\d+)/) {
	$num_features = $1;
    }
    
    if ($line =~ m/^Bad START codons\:\s+(\d+)/) {
	$bad_starts = $1;
    }
    
    if ($line =~ m/^Bad STOP codons\:\s+(\d+)/) {
	$bad_stops = $1;
    }
    
    if ($line =~ m/^Too short\:\s+(\d+)/) {
	$too_short = $1;
    }
    
    if ($line =~ m/^RNA overlaps\:\s+(\d+)/) {
	$rna_overlaps = $1;
    }
    
    if ($line =~ m/^Same-STOP PEGs\:\s+(\d+)/) {
	$same_stop = $1;
    }
    
    if ($line =~ m/^Embedded PEGs\:\s+(\d+)/) {
	$embedded = $1;
    }
    
    if ($line =~ m/^Convergent overlaps\:\s+(\d+)/) {
	$convergent = $1;
    }
    
    if ($line =~ m/^Divergent overlaps\:\s+(\d+)/) {
	$divergent = $1;
    }
    
    if ($line =~ m/^Same-strand overlaps\:\s+(\d+)/) {
	$same_strand = $1;
    }
    
    if ($line =~ m/^Impossible overlaps\:\s+(\d+)/) {
	$impossible = $1;
    }
}

my $num_missing = 0;
my @gaplen_histogram = `($FIG_Config::bin/find_gaps $org_id $contigs $rna_tbl $peg_tbl | $FIG_Config::bin/feature_length_histogram -nolabel) 2> /dev/null`;
foreach my $entry (@gaplen_histogram)
{
    if ($entry =~ m/^(\d+)\t(\d+)/) {
	my ($len, $num) = ($1, $2);
	if ($len > $max_gap) {
	    $num_missing += $num*$len;
	}
    }
    else {
	die "Malformed gap histogram entry: $entry";
    }
}
$num_missing = int(0.5 + $num_missing/1000);


if ($num_features == 0) {
    if ($meta_file) {
	$meta->add_log_entry("qc", "$org_dir has no features called");
	
	$meta->set_metadata( qq(qc.Org-ID),            [ qq(INFO),  $org_id ] );
	$meta->set_metadata( qq(qc.Num_features),      [ qq(SCORE), 0 ] );
	$meta->set_metadata( qq(qc.Num_tot),           [ qq(SCORE), 999999999 ] );
	$meta->set_metadata( qq(qc.Num_fatal),         [ qq(SCORE), 999999999 ] );
	$meta->set_metadata( qq(qc.Num_warn),          [ qq(SCORE), 999999999 ] );
	$meta->set_metadata( qq(qc.Possible_missing),  [ qq(SCORE), $num_missing ] );
        $meta->set_metadata( qq(qc.Pct_fatal),         [ qq(SCORE), 100 ] );
        $meta->set_metadata( qq(qc.Pct_warn),          [ qq(SCORE), 100 ] );
	$meta->set_metadata( qq(qc.Pct_missing),       [ qq(SCORE), 100 ] );
    }
    
    print STDOUT "# $org_dir has no features called\n"
	, "INFO\tOrg-ID\t$org_id\n"
	, "SCORE\tNum_features\t0\n"
	, "SCORE\tNum_tot\t999999999\n"
	, "SCORE\tNum_fatal\t999999999\n"
	, "SCORE\tNum_warn\t999999999\n"
	, "SCORE\tPossible_missing\t$num_missing\n"
	, "SCORE\tPct_fatal\t100\n"
	, "SCORE\tPct_warn\t100\n"
	, "SCORE\tPct_missing\t100\n"
	, "//\n";
    
    exit(0);
}

my $num_fatal = $rna_overlaps + $bad_starts + $bad_stops + $same_stop + $embedded + $impossible;
my $num_warn  = $too_short + $convergent + $divergent + $same_strand;

if ($no_fatal) {
    $num_warn += $num_fatal;
    $num_fatal = 0;
}

my $num_tot   = $num_fatal + $num_warn;

my ($pct_fatal, $pct_warn, $pct_tot, $pct_missing);
if ($num_features) {
    $pct_fatal   = sprintf "%3.1f", 100 *  $num_fatal  / $num_features;
    $pct_warn    = sprintf "%3.1f", 100 *   $num_warn  / $num_features;
    $pct_tot     = sprintf "%3.1f", 100 *   $num_tot   / $num_features;
    $pct_missing = sprintf "%3.1f", 100 * $num_missing / $num_features;
}
else {
    $num_fatal   = $num_warn = $num_tot = 999999999;
    $pct_fatal   = $pct_warn = $pct_tot = $pct_missing = 100;
}

my  $recall = 0;
if ($num_missing > (0.1) * $num_features) {
    $recall = 1;
}

my $out_fh = \*STDERR;
if (($num_fatal && !$no_fatal) || ($num_tot >= (0.10) * $num_features)) {
    $recall = 1; 
    $out_fh = \*STDOUT;
}

#
# We want to always write output.
#
if (1 || $num_fatal || $num_warn || $recall) {
    if ($meta_file) {
	$meta->set_metadata( qq(qc.Org-ID),            [ qq(INFO),  $org_id ] );
	
	$meta->set_metadata( qq(qc.Num_features),      [ qq(SCORE),   $num_features  ] );
	$meta->set_metadata( qq(qc.Num_tot),           [ qq(SCORE),   $num_tot       ] );
	$meta->set_metadata( qq(qc.Num_fatal),         [ qq(SCORE),   $num_fatal     ] );
	$meta->set_metadata( qq(qc.Num_warn),          [ qq(SCORE),   $num_warn      ] );
	$meta->set_metadata( qq(qc.Possible_missing),  [ qq(SCORE),   $num_missing   ] )     if $num_missing;
	
	$meta->set_metadata( qq(qc.Pct_tot),           [ qq(SCORE),   $pct_tot       ] );
	$meta->set_metadata( qq(qc.Pct_fatal),         [ qq(SCORE),   $pct_fatal     ] );
	$meta->set_metadata( qq(qc.Pct_warn),          [ qq(SCORE),   $pct_warn      ] );
	$meta->set_metadata( qq(qc.Pct_missing),       [ qq(SCORE),   $pct_missing   ] );#   if $num_missing;
	
	$meta->set_metadata( qq(qc.RNA_overlaps),      [ qq($FATAL),  $rna_overlaps  ] );#   if $rna_overlaps;
	$meta->set_metadata( qq(qc.Bad_STARTs),        [ qq($FATAL),  $bad_starts    ] );#   if $bad_starts;
        $meta->set_metadata( qq(qc.Bad_STOPs),         [ qq($FATAL),  $bad_stops     ] );#   if $bad_stops;
	$meta->set_metadata( qq(qc.Embedded),          [ qq($FATAL),  $embedded      ] );#   if $embedded;
	$meta->set_metadata( qq(qc.Impossible),        [ qq($FATAL),  $impossible    ] );#   if $impossible;
	
	$meta->set_metadata( qq(qc.Too_short),         [ qq(WARNING), $too_short   ] );#     if $too_short;
	$meta->set_metadata( qq(qc.Convergent),        [ qq(WARNING), $convergent  ] );#     if $convergent;
        $meta->set_metadata( qq(qc.Divergent),         [ qq(WARNING), $divergent   ] );#     if $divergent;
	$meta->set_metadata( qq(qc.Same_strand),       [ qq(WARNING), $same_strand ] );#     if $same_strand;
    }
    
    if ($num_fatal) {
	$msg = "$org_dir contains $num_tot features with fatal errors or warnings"
	    .  " ($pct_tot\%), out of $num_features features";
	print $out_fh "# $msg\n";
	$meta->add_log_entry("qc", $msg) if $meta_file;
    }
    
    if ($num_warn) {
	$msg = "$org_dir contains or may lack $num_warn features with warnings"
	    .  " ($pct_warn\%), out of $num_features features";
	print $out_fh "# $msg\n";
	$meta->add_log_entry("qc", $msg) if $meta_file;
    }
    
    if ($recall) {
	$msg = "Recommend recalling PEGs, or at least deleting the features with fatal errors";
	print $out_fh "# $msg\n";
	$meta->add_log_entry("qc", $msg) if $meta_file;
    }
    
    print $out_fh "INFO\tOrg-ID\t$org_id\n";
    
    print $out_fh "SCORE\tNum_features\t$num_features\n";
    print $out_fh "SCORE\tNum_tot\t$num_tot\n";
    print $out_fh "SCORE\tNum_fatal\t$num_fatal\n";
    print $out_fh "SCORE\tNum_warn\t$num_warn\n";
    print $out_fh "SCORE\tPossible_missing\t$num_missing\n"   ;#   if $num_missing;
    
    print $out_fh "SCORE\tPct_tot\t$pct_tot\n";
    print $out_fh "SCORE\tPct_fatal\t$pct_fatal\n";
    print $out_fh "SCORE\tPct_warn\t$pct_warn\n";
    print $out_fh "SCORE\tPct_missing\t$pct_missing\n"        ;#   if $num_missing;
    
    print $out_fh "$FATAL\tRNA_overlaps\t$rna_overlaps\n"     ;#   if $rna_overlaps;
    print $out_fh "$FATAL\tBad_STARTs\t$bad_starts\n"         ;#   if $bad_starts;
    print $out_fh "$FATAL\tBad_STOPs\t$bad_stops\n"           ;#   if $bad_stops;
    print $out_fh "$FATAL\tSame_STOP\t$same_stop\n"           ;#   if $same_stop;
    print $out_fh "$FATAL\tEmbedded\t$embedded\n"             ;#   if $embedded;
    print $out_fh "$FATAL\tImpossible_overlaps\t$impossible\n";#   if $impossible;
    
    print $out_fh "WARNING\tToo_short\t$too_short\n"          ;#   if $too_short;
    print $out_fh "WARNING\tConvergent\t$convergent\n"        ;#   if $convergent;
    print $out_fh "WARNING\tDivergent\t$divergent\n"          ;#   if $divergent;
    print $out_fh "WARNING\tSame_strand\t$same_strand\n"      ;#   if $same_strand;
    
    print $out_fh "//\n";
}

exit(0);
