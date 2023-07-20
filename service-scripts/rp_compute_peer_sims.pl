#
# Compute the all-to-all sims between a set of organism directories.
#
# Sims are stored in the RAST organism directory, in a directory named
# by the target genome ID:
#	 jobdir/rp/XXXXXX.YY/sims/QQQQQ.RR
#
# Within that directory the forward sims (from XXXXXX.YY => QQQQQ.RR) are in a file sims,
# with a btree index sims.index.
# Expanded sims are in sims_exp with an index in sims_exp.indx.
#
# Flipped sims not stored; they will be found in the other organism's job dir.
#

use strict;
use Data::Dumper;
use Carp;
use DB_File;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use FileHandle;
use Sim;

my $meta;

@ARGV > 1 or die "Usage: $0 work-dir job-id job-id ...\n";

my $workdir = shift;
my @job_ids = @ARGV;

if (! -d $workdir)
{
    mkdir($workdir) or &fatal("mkdir $workdir failed: $!\n");
}

my @blast_args = qw(-p blastp -m 8 -e 1.0e-5);

#
# Map the job ids to org dirs, and collect a fasta file.
#

my $info = new FileHandle "$workdir/INFO", "w";

my @org_dirs;
my @fasta_files;
my %genome_to_dir;

for my $job_id (@job_ids)
{
    my $org_dir;
    my $genome;
    if ($job_id =~ /^\d+$/)
    {
	my $job_dir = "$FIG_Config::rast_jobs/$job_id";
	$genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
	chomp $genome;
	$genome or &fatal("cannot find genome id for job $job_dir\n");

	$org_dir = "$job_dir/rp/$genome";
    }
    elsif ($job_id =~ m,^/,)
    {
	# Handle the case where we pass job directories or org dirs.

	if (-f "$job_id/GENOME_ID" and -d "$job_id/rp")
	{
	    my $job_dir = $job_id;
	    $genome = &FIG::file_head("$job_dir/GENOME_ID", 1);
	    chomp $genome;
	    $genome or &fatal("cannot find genome id for job $job_dir\n");
	    
	    $org_dir = "$job_dir/rp/$genome";
	}
	elsif (-f "$job_id/GENOME" and -d "$job_id/Features" and $job_id =~ m,/^(\d+\.\d+)$,)
	{
	    $org_dir = $job_id;
	    $genome = $1;
	}
	else
	{
	    &fatal("Unknown jobid $job_id\n");
	}
    }
    else
    {
	&fatal("Unknown jobid $job_id\n");
    }
    -d $org_dir or &fatal("org_dir $org_dir does not exist\n");

    my $fasta_file = "$org_dir/Features/peg/fasta";
    if (! -f $fasta_file)
    {
	warn "No fasta found for $org_dir\n";
	next;
    }

    push(@fasta_files, $fasta_file);
    
    print $info join("\t", $genome, $org_dir, $fasta_file), "\n";
    push(@org_dirs, $org_dir);
    $genome_to_dir{$genome} = $org_dir;
}

#
# Now write the combined fasta.
#

my $all_fasta = "$workdir/fasta";
my $fasta_fh = new FileHandle $all_fasta, "w";

#goto xx;
for my $file (@fasta_files)
{
    open(my $fh, "<", $file) or &fatal("cannot open $file: $!");
    my $buf;
    while (read($fh, $buf, 4096))
    {
	print $fasta_fh $buf;
    }
    close($fh);
}
close($fasta_fh);

&run("$FIG_Config::ext_bin/formatdb", "-p", "t", "-i", $all_fasta);

&run("$FIG_Config::ext_bin/blastall", @blast_args, "-i", $all_fasta, "-d", $all_fasta,
     "-o", "$workdir/sims.raw");

&run("$FIG_Config::bin/reformat_sims $all_fasta < $workdir/sims.raw > $workdir/sims.final");

#
# Read the generated sims (id1, id2, vals).
# A sim for id1, id2 is written to the file
# orgdir(genome-of(id1))/sims/genome-of(id2)
#
xx:
my $cur_genome;
open(S, "<", "$workdir/sims.final") or &fatal("Cannot open $workdir/sims.final: $!");
my($id1, $id2, $g1, $g2);
my($last_g1, $last_g2);
my %fhh;
my @new_files;
while (<S>)
{
    if (($id1, $g1, $id2, $g2) = /^(fig\|(\d+\.\d+)\S+)\t(fig\|(\d+\.\d+)\S+)/)
    {
	my $fh = $fhh{$g1, $g2};

	if (!$fh)
	{
	    my $sdir = "$genome_to_dir{$g1}/sims";
	    -d $sdir or mkdir $sdir or &fatal("cannot mkdir $sdir: $!");
	    
	    open($fh, ">", "$sdir/$g2") or &fatal("cannot write $sdir/$g2: $!");
	    push(@new_files, "$sdir/$g2");
	    $fhh{$g1, $g2} = $fh;
	}
	print $fh $_;
    }
}
close(S);
map { close($_) } values(%fhh);

for my $nf (@new_files)
{
    print "Index $nf\n";
    &index_sims($nf, "$nf.index");
}

exit(0);


#
# Use the C index_sims_file app to create a berkeley db index
# of the sims file.
#

sub index_sims
{
    my($sims, $index_file) = @_;

    my $path = &FIG::find_fig_executable("index_sims_file");

    open(IDX, "$path 0 < $sims |") or &fatal("Cannot open index_sims_file pipe: $!\n");

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

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("scenario.running", "no");
	$meta->set_metadata("status.scenario", "error");
    }

    croak "$0: $msg";
}
    
sub run
{
    my(@cmd) = @_;
    print "Run @cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	&fatal("error $rc running @cmd\n");
    }
}
