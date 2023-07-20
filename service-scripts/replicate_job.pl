#
# Replicate data from one job into another (based on a determination that
# the input data for the two  jobs were identical).
#
# Non-ascii files are
#
# similarities.index
# similarities.flips.index
# expanded_similarities.flips.index
# expanded_similarities.index
#
# contig_len.btree
# attr_id.btree
# attr_key.btree
# pchs.evidence.btree
# contigs.btree
# bbhs.index
# pchs.btree
#
# Features/rna/tbl.recno
# Features/peg/tbl.recno
#
# Features/peg/fasta.phr
# Features/peg/fasta.pin
# Features/peg/fasta.psq
#


use strict;
use Data::Dumper;
use POSIX;
use File::Copy;
use Job48;
use FIG;
use DB_File;

$| = 1;

my $usage = "Usage: replicate_job old-job new-job\n";

@ARGV == 2 or die $usage;

my($old_dir, $new_dir) = @ARGV;

-d $old_dir or die "Old dir $old_dir not found\n";
-d $new_dir or die "New dir $new_dir not found\n";

my $old_job = new Job48($old_dir);
my $new_job = new Job48($new_dir);

my $old_org_dir = $old_job->orgdir;
my $new_org_dir = $new_job->orgdir;

my $old_genome = $old_job->genome_id;
my $new_genome = $new_job->genome_id;

my %top_non_ascii = map { $_ => 1 } qw( similarities.index
				       similarities.flips.index
				       expanded_similarities.flips.index
				       expanded_similarities.index
				       contig_len.btree
				       attr_id.btree
				       attr_key.btree
				       pchs.evidence.btree
				       contigs.btree
				       bbhs.index
				       pchs.btree
				       proposed_user_functions);

my @keys_to_copy = qw(status.*
		      genome.neighbors
		      qc.*
		      correction.*);
my $key_match_str = join("|", map { "(?:" .  glob2pat($_)  . ")" } @keys_to_copy);
my $key_match_re = qr($key_match_str);

#
# If the new job already has an rp dir, move it out of the way.
#

my $now = strftime("%Y-%m-%d-%H-%M-%S",localtime);

if (-d "$new_dir/rp")
{
    if (!rename("$new_dir/rp", "$new_dir/rp.$now"))
    {
	die "Cannot rename existing $new_dir/rp to $new_dir/rp.$now: $!";
    }
}

if (-d "$new_dir/rp.errors")
{
    if (!rename("$new_dir/rp.errors", "$new_dir/rp.errors.$now"))
    {
	die "Cannot rename existing $new_dir/rp.errors to $new_dir/rp.errors.$now: $!";
    }
}
	
&FIG::verify_dir("$new_dir/rp.errors");
&FIG::verify_dir($new_org_dir);

#
# Copy selected metadata
#
for my $key ($old_job->meta->get_metadata_keys())
{
    if ($key =~ $key_match_re)
    {
	$new_job->meta->set_metadata($key, $old_job->meta->get_metadata($key));
    }
}


$new_job->meta->add_log_entry('replicate_job', ['replicate_from', $old_dir]);

#
# Determine if there is a pristine_annotations.tgz file that we should use
# to pull the annotations from. If so, extract into a temp dir and
# copy from there.
#

my $src_dir;
my $tmp_dir;
my $tar_file = "$old_dir/pristine_annotations.tgz";
if (-f $tar_file)
{
    $tmp_dir = $src_dir = "$FIG_Config::temp/anno_dir.$$";
    &FIG::verify_dir($src_dir);
    system("tar", "-x", "-f", $tar_file, "-C", $src_dir, "-z");
}
else
{
    $src_dir = $old_org_dir;
}

opendir(D, "$src_dir/Features") or die "Cannot open dir $src_dir/Features";
my @feature_types = grep { $_ !~ /^\./ and -d "$src_dir/Features/$_" } readdir(D);
closedir(D);

print "Got ftypes @feature_types\n";

for my $ft (@feature_types)
{
    &FIG::verify_dir("$new_org_dir/Features/$ft");

    my $ofd = "$src_dir/Features/$ft";
    my $nfd = "$new_org_dir/Features/$ft";

    copy_and_replace("$ofd/fasta", "$nfd/fasta");
    copy_and_replace("$ofd/tbl", "$nfd/tbl");
}

#
# Copy the plain files over.
#

opendir(D, $old_org_dir) or die "Cannot open dir $old_org_dir: $!";

my @top_files = grep { $_ !~ /^\./ and -f "$old_org_dir/$_" and ! $top_non_ascii{$_} } readdir(D);
closedir(D);

for my $file (@top_files)
{
    my $src = "$tmp_dir/$file";
    if (! -f $src)
    {
	$src = "$old_org_dir/$file";
    }
	    
    copy_and_replace("$src", "$new_org_dir/$file") or die "copy $file failed: $!";
}

#
# These come from this job.
#
system("cp", (map { "$new_dir/$_" } qw(GENOME PROJECT TAXONOMY)), $new_org_dir);
 

#
# Directories we don't need to munge.
#
system("cp", "-r", "$old_org_dir/Scenarios", $new_org_dir);

#
# Subsystems need some work.
#
&FIG::verify_dir("$new_org_dir/Subsystems");
if (-d "$tmp_dir/Subsystems")
{
    &copy_file("$tmp_dir/Subsystems/subsystems", "$new_org_dir/Subsystems/subsystems");
    &copy_and_replace("$tmp_dir/Subsystems/bindings", "$new_org_dir/Subsystems/bindings");
}
else
{
    &copy_file("$old_org_dir/Subsystems/subsystems", "$new_org_dir/Subsystems/subsystems");
    &copy_and_replace("$old_org_dir/Subsystems/bindings", "$new_org_dir/Subsystems/bindings");
}

if (-d $tmp_dir)
{
    system("rm", "-r", $tmp_dir);
}

#
# Reindex sims
#

print "Index sims\n";
&index_sims("$new_org_dir/similarities", "$new_org_dir/similarities.index");
print "Index sims flips\n";
&index_sims("$new_org_dir/similarities.flips", "$new_org_dir/similarities.flips.index");

print "Index expanded sims\n";
&index_sims("$new_org_dir/expanded_similarities", "$new_org_dir/expanded_similarities.index");
print "Index expanded sims flips\n";
&index_sims("$new_org_dir/expanded_similarities.flips", "$new_org_dir/expanded_similarities.flips.index");

print "Index bbhs\n";
&index_bbhs("$new_org_dir/bbhs", "$new_org_dir/bbhs.index");
print "Index pchs\n";
&index_pchs("$new_org_dir/pchs.scored", "$new_org_dir/pchs.btree",
	    "$new_org_dir/pchs", "$new_org_dir/pchs.evidence.btree");

print "Index attributes\n";
system("$FIG_Config::bin/rp_index_attributes", $new_dir);
print "Create exports\n";
system("$FIG_Config::bin/rp_write_exports", $new_dir);

#
# We are done. Remove the ACTIVE file if it was there, and create DONE.
# Set status.final as well to ensure it is set.
#

$new_job->meta->set_metadata("status.final", "complete");
unlink("$new_dir/ACTIVE");
unlink("$new_dir/ERROR");
open(F, ">", "$new_dir/DONE");
close(F);

system("$FIG_Config::bin/send_job_completion_email", $new_dir);

sub copy_file
{
    my($old, $new) = @_;
    $new_job->meta->add_log_entry('replicate_job', ['copy', $old, $new]);
    system("/bin/cp", $old, $new);
}

sub copy_and_replace
{
    my($old, $new) = @_;

    $new_job->meta->add_log_entry('replicate_job', ['copy/replace', $old, $new]);
    print "copy/replace $old $new\n";
    open(O, "<$old") or die "Cannot open $old: $!";
    open(N, ">$new") or die "Cannot open $new: $!";

    while (<O>)
    {
	s/fig\|$old_genome\./fig|$new_genome./go;
	print N $_;
    }
    close(O);
    close(N);
}

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

sub index_bbhs
{
    my($bbhs, $bbh_index) = @_;
    my %bbh_tie;
    my $bbh_db = tie %bbh_tie, "DB_File", $bbh_index, O_RDWR | O_CREAT, 0666, $DB_BTREE
	or die "Error opening DB_File tied to $bbh_index: $!\n";

    if (open(BBH, "<", $bbhs))
    {
	while (<BBH>)
	{
	    chomp;
	    my($id1, $id2, $psc, $nsc) = split(/\t/);

	    $bbh_tie{$id1} = join(",", $id2, $psc, $nsc);
	}
	close(BBHS);
    }
    else
    {
	warn "Cannot open $bbhs; $!";
    }

    untie %bbh_tie;
}

sub index_pchs
{
    my($scored_pch_file, $pch_btree_file, $proc_pch_file, $pch_ev_btree_file) = @_;
    $DB_BTREE->{flags} = R_DUP;
    my %index;
    unlink($pch_btree_file);
    my $tied = tie %index, 'DB_File', $pch_btree_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;
    
    if (!$tied)
    {
	die "cannot create $pch_btree_file: $!";
    }
    
    if (open(SC, "<$scored_pch_file"))
    {
	while (<SC>)
	{
	    chomp;
	    my($p1, $p2, $sc) = split(/\t/);
	    $index{$p1, $p2} = $sc;
	    $index{$p1} = join($;, $p2, $sc);
	}
	close(SC);
    }
    untie $tied;
    #
    # Coupling evidence. This one requires duplicate keys.
    #
    
    $DB_BTREE->{flags} = R_DUP;
    my %index;
    unlink($pch_ev_btree_file);
    my $tied = tie %index, 'DB_File', $pch_ev_btree_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;
    
    if (!$tied)
    {
	die "cannot create $pch_ev_btree_file: $!";
    }
    
    if (open(PCH, "<$proc_pch_file"))
    {
	while (<PCH>)
	{
	    chomp;
	    my($p1, $p2, $p3, $p4, $iden3, $iden4, undef, undef, $rep) = split(/\t/);
	    $index{$p1, $p2} = join($;, $p3, $p4, $iden3, $iden4, $rep);
	}
	close(PCH);
    }
    untie $tied;
}

sub glob2pat {
    my $globstr = shift;
    my %patmap = (
		  '*' => '.*',
		  '?' => '.',
		  '[' => '[',
		  ']' => ']',
		 );
    $globstr =~ s{(.)} { $patmap{$1} || "\Q$1" }ge;
    return '^' . $globstr . '$';
}
