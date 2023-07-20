
#
# Postprocess a completed set of sims.
#

use DB_File;
use Data::Dumper;
use FIGV;

use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Sim;
use Carp 'croak';

@ARGV == 4 or die "Usage: $0 job-dir nr peg.synonyms keep\n";

my $jobdir = shift;
my $nr = shift;
my $peg_syn = shift;
my $keep_count = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";
-f $nr or die "$0: NR file $nr does not exist\n";
-f $peg_syn or die "$0: peg.synonyms file $peg_syn does not exist\n";
$keep_count =~ /^\d+$/ or die "$0: keep-count $keep_count is not numeric\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

my $fasta = "$jobdir/rp/$genome/Features/peg/fasta";
-f $fasta or die "$0: Cannot find fasta file $fasta\n";

my @sims_files = <$jobdir/sims.job/sims.raw/*/*>;

if (!$meta->get_metadata("skip_sims"))
{
    @sims_files or die "$0: No sims files found\n";
}

#
# If the preprocess found sims from the sims server, add
# that file to the file list.
#
my $server_sims = "$jobdir/sims.job/sims.server";
if (-f $server_sims)
{
    push(@sims_files, $server_sims);
    $meta->add_log_entry($0, "using sims serer output from $server_sims");
}

my $prefix = "sims.rp." . basename($jobdir);

my $out = "$jobdir/sims.job/sims.proc";

my $reduce_cmd = "$FIG_Config::bin/reduce_sims $peg_syn $keep_count";
my $reformat_cmd = "$FIG_Config::bin/reformat_sims $nr $fasta";
my $split_cmd = "$FIG_Config::bin/split_sims $out $prefix";
#my $pipeline = "$reduce_cmd | $reformat_cmd | $split_cmd";
my $pipeline = "$reduce_cmd | $reformat_cmd ";

my $sim_dest = "$jobdir/rp/$genome/similarities";
my $exp_sim_dest = "$jobdir/rp/$genome/expanded_similarities";

my $fig = new FIGV("$jobdir/rp/$genome");

warn "starting postprocessing pipeline $pipeline into $sim_dest\n";

open(SYNS,"<$peg_syn") or &fatal("Cannot open synonyms file $peg_syn: $!");

$meta->add_log_entry($0, "start postprocessing on $jobdir");

if (!open(PROC, "| $pipeline | sort -k 1,1 -k 3,3nr > $sim_dest 2> $jobdir/sims.job/postproc.errors"))
{
    &fatal("Error running sims postproc pipeline\n   $pipeline > $sim_dest\n");
}

for my $sim_file (@sims_files)
{
    open(F, "<$sim_file") or die "Cannot open sim file $sim_file: $!\n";
    warn "processing $sim_file\n";
    while (<F>)
    {
	print PROC $_;
    }
    close(F);
}


if (!close(PROC))
{
    if ($!)
    {
	&fatal("Error closing sims postproc pipeline: $!\n   $pipeline\n");
    }
    else
    {
	&fatal("Nonzero return $? from sims postproc pipeline\n   $pipeline\n");
    }
}
warn "preprocessing completed\n";

syns:


#
# Process syns while processing finishes up.
#

    
#
# See if there are preprocessed indexes available.
#
   
my $pegsyn_to = "$peg_syn.index.t";
my $pegsyn_from = "$peg_syn.index.f";

my %peg_mapping;
my(%ps_to, %ps_from);
my $get_mapping;
if (-f $pegsyn_to and -f $pegsyn_from)
{

    my $tie = tie %ps_to, 'DB_File', $pegsyn_to, O_RDONLY, 0666, $DB_BTREE;

    $tie or &fatal("cannot tie $pegsyn_to: $!");

    my $tie = tie %ps_from, 'DB_File', $pegsyn_from, O_RDONLY, 0666, $DB_BTREE;

    $tie or &fatal("cannot tie $pegsyn_from: $!");
    $get_mapping = \&get_tied_mapping;
}
else
{
    warn "Start processing syns ($pegsyn_to $pegsyn_from)\n";
    my($to, $to_len, $from);
    while (defined($_ = <SYNS>))
    {
	if (($to, $to_len, $from) =  /^([^,]+),(\d+)\t(\S+)/)
	{
	    my @from = map { [ split(/,/, $_) ] } split(/;/,$from);
	    if (@from > 0)
	    {
		$peg_mapping{$to} = [$to_len, \@from];
	    }
	}
    }
    warn "finished with syns\n";

    $get_mapping = sub { $peg_mapping{$_[0]} };
}
close(SYNS);

#
# Create the raw sims flips.
#
my $rflipped_sims = "$sim_dest.flips";
my $rflipped_sims_index = "$sim_dest.flips.index";
my $rc = system("$FIG_Config::bin/flip_sims", $sim_dest, $rflipped_sims);
if ($rc != 0)
{
    &fatal("Error flipping $sim_dest to $rflipped_sims\n");
}

index_sims($sim_dest, "$sim_dest.index");
index_sims($rflipped_sims, $rflipped_sims_index);



#
# Now perform the expansion.
#

open(SIMS, "<$sim_dest") or &fatal("Cannot open similarities file $sim_dest: $!\n");
open(EXP, ">$exp_sim_dest") or &fatal("Cannot open expanded similarities file $exp_sim_dest for writing: $!\n");

while (<SIMS>)
{
    chomp;
    my @s = split(/\t/, $_);
    
    my $id2 = $s[1];
    my $id1 = $s[0];
    my @relevant = ();

    #
    # Find contig / location info
    #
    
    my $loc1 = $fig->feature_location($id1);
    my($contig1, $beg1, $end1) = $loc1 =~ /(.*)_(\d+)_(\d+)$/;
    ($beg1, $end1) = ($end1, $beg1) if $end1 < $beg1;

    my ($genome1) = $id1 =~ /^fig\|(\d+\.\d+)/;
    
#    my @maps_to = $fig->mapped_prot_ids( $id2 );

    my $mapping = &$get_mapping($id2);
#    my $mapping = $peg_mapping{$id2};
    if ($mapping)
    {
	my($ref_len, $pairs) = @$mapping;
	
	my @maps_to = grep { $_->[0] !~ /^xxx\d+/ } @$pairs;
	
	my $seen = {};
	foreach my $x ( @maps_to )
	{
	    next if @$x == 0;
	    my ( $x_id, $x_ln ) = @$x;
	    
	    #
	    # Find contig / location info
	    #

	    my @loc;
	    
	    if  ($x_id =~ /^fig\|(\d+\.\d+)/)
	    {
		my $genome2 = $1;
		my $loc2 = $fig->feature_location($x_id);
		my($contig2, $beg2, $end2) = $loc2 =~ /(.*)_(\d+)_(\d+)$/;
		($beg2, $end2) = ($end2, $beg2) if $end2 < $beg2;
		@loc = ($genome1, $contig1, $beg1, $end1, $genome2, $contig2, $beg2, $end2);
	    }
			    
	    next if $seen->{$x_id};
	    $seen->{$x_id} = 1;
	    
	    my $delta2  = $ref_len - $x_ln; # Coordinate shift
	    my $sim1    = [ @s ]; # Make a copy
	    $sim1->[1]  = $x_id;
	    $sim1->[8] -= $delta2;
	    $sim1->[9] -= $delta2;
	    
	    print EXP join("\t", @$sim1, @loc), "\n";
	}
    }
    else
    {
	my @loc;
	if  ($id2 =~ /^fig\|(\d+\.\d+)/)
	{
	    my $genome2 = $1;
	    my $loc2 = $fig->feature_location($id2);
	    my($contig2, $beg2, $end2) = $loc2 =~ /(.*)_(\d+)_(\d+)$/;
	    ($beg2, $end2) = ($end2, $beg2) if $end2 < $beg2;
	    @loc = ($genome1, $contig1, $beg1, $end1, $genome2, $contig2, $beg2, $end2);
	}
	print EXP join("\t", @s, @loc), "\n";
    }
}
close(SIMS);
close(EXP);
undef %peg_mapping;

#
# And index.
#
-f $exp_sim_dest or die "expanded sims file $exp_sim_dest does not exist\n";
my $index_file = "$exp_sim_dest.index";

index_sims($exp_sim_dest, $index_file);

#
# Flip and index the flips.
#

my $flipped_sims = "$exp_sim_dest.flips";
my $flipped_sims_index = "$exp_sim_dest.flips.index";
my $rc = system("$FIG_Config::bin/flip_sims", $exp_sim_dest, $flipped_sims);
if ($rc != 0)
{
    &fatal("Error flipping $exp_sim_dest to $flipped_sims\n");
}

index_sims($flipped_sims, $flipped_sims_index);

$meta->add_log_entry($0, "finish postprocessing on $jobdir");
$meta->set_metadata("status.sims", "complete");
$meta->set_metadata("sims.running", "no");
exit(0);

#
# Retrieve mapping data thru hashes.
#

sub get_tied_mapping
{
    my($peg) = @_;

    my $dat = $ps_to{$peg};
    my($to_len, $from) = split(/:/, $dat, 2);
    my @from = map { [ split(/,/, $_) ] } split(/;/,$from);
    if (@from > 0)
    {
	return [$to_len, \@from];
    }
    else
    {
	return ();
    }
}


#
# Use the C index_sims_file app to create a berkeley db index
# of the sims file.
#

sub index_sims
{
    my($sims, $index_file) = @_;

    my $path = &FIG::find_fig_executable("index_sims_file");
    open(IDX, "$path 0 < $sims |") or die "Cannot open $path pipe: $!\n";

    my %index;
    my $tied = tie %index, 'DB_File', $index_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;

    $tied or &fatal("Creation of hash $index_file failed: $!\n");

    while (<IDX>)
    {
	chomp;
	my($peg, undef, $seek, $len) = split(/\t/);
	
	$index{$peg} = "$seek,$len";
    }
    close(IDX);
    
    $tied->sync();
    untie %index;
}

sub fatal
{
    my($msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status.sims", "error");

    croak "$0: $msg";
}
    
