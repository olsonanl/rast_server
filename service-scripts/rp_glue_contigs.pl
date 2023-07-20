
#
# Glue split scaffolded contigs back together.
#

use strict;
use Data::Dumper;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Carp 'croak';


@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $job = basename($jobdir);

my $meta_file = "$jobdir/meta.xml";
my $meta = new GenomeMeta($genome, $meta_file);

my $raw_dir = "$jobdir/raw/$genome";
my $rp_dir = "$jobdir/rp/$genome";

my $errdir = "$jobdir/rp.errors";
&FIG::verify_dir($errdir);

if (! -d $raw_dir)
{
    &fatal("raw genome directory $raw_dir does not exist");
}

if (! -d $rp_dir)
{
    &fatal("processed genome directory $rp_dir does not exist");
}

#
# Replace the original scaffolded contigs.
#

my $new_contigs = "$rp_dir/contigs";
my $raw_contigs = "$rp_dir/unformatted_contigs";
my $split_contigs = "$rp_dir/split_contigs";
my $scaffold_map = "$rp_dir/scaffold.map";

-f $new_contigs or &fatal("cannot find new contigs file $new_contigs");
-f $raw_contigs or &fatal("cannot find raw contigs file $raw_contigs");

#
# Contigs moves to split_contigs for future reference.
# Unformatted contigs get formatted into contigs.
# When all is complete, map_to_scaffolds is run to fix the tbl files.
#
# We only do this if scaffold_map exists - if it doesn't exist, we hadn't
# split the contigs, so none of this is necessary.
#

if (-f $scaffold_map)
{
    rename($new_contigs, $split_contigs) or &fatal("cannot rename $new_contigs $split_contigs: $!");

    my @cmd = ("$FIG_Config::bin/map_to_scaffold", $scaffold_map, $rp_dir);
    print "Run @cmd\n";
    $meta->add_log_entry($0, ['running', @cmd]);
    
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	&fatal("map_to_scaffold failed with rc=$rc: @cmd");
    }
    
    my $reformat_log = "$errdir/reformat_contigs_glue.stderr";
    
    my @cmd = ("$FIG_Config::bin/reformat_contigs", "-v", "-logfile=$reformat_log", $raw_contigs, $new_contigs);
    
    print "Run @cmd\n";

    $meta->add_log_entry($0, ['running', @cmd]);
    
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	&fatal("reformat command failed with rc=$rc: @cmd\n");
    }
}
else
{
    #
    # We didn't need to map. Don't need to do anything here.
    #
}

#
# Now that our contig coordinates are back to their original state, we can map
# original assigned_functions. 
#

my %map;

open(MAP, "$FIG_Config::bin/make_peg_map_from_tbl $raw_dir $rp_dir |") or
    &fatal("cannot open pipe from$FIG_Config::bin/make_peg_map_from_tbl $raw_dir $rp_dir: $!");
while (<MAP>)
{
    chomp;
    my($f, $t) = split(/\t/);
    $map{$f} = $t;
}
close(MAP);

if (-s "$raw_dir/assigned_functions")
{
    $meta->add_log_entry($0, "begin mapping $raw_dir/assigned_functions");
    open(OLD, "<$raw_dir/assigned_functions") or &fatal("Cannot open $raw_dir/assigned_functions: !");
    open(NEW, ">$rp_dir/assigned_functions") or &fatal("Cannot open $rp_dir/assigned_functions: !");

    while (<OLD>)
    {
	chomp;
	my($opeg, $fun) = split(/\t/);
	my $npeg = $map{$opeg};

	if ($npeg)
	{
	    print NEW "$npeg\t$fun\n";
	}
    }
    close(OLD);
    close(NEW);
}

if (-s "$raw_dir/annotations")
{
    $meta->add_log_entry($0, "begin mapping $raw_dir/annotations");

    if (! -f "$rp_dir/annotations.pre_glue")
    {
	rename("$rp_dir/annotations", "$rp_dir/annotations.pre_glue");
    }

    open(OLD, "<$raw_dir/annotations") or &fatal("Cannot open $raw_dir/annotations: !");
    open(NEW, ">$rp_dir/annotations") or &fatal("Cannot open $rp_dir/annotations: !");

    local $/ = "//\n";
    while (<OLD>)
    {
	chomp;
	if (/^(fig\|\S+)(.*)/ms)
	{
	    my $npeg = $map{$1};
	    if ($npeg)
	    {
		print STDERR "rewrite $1 to $npeg '$2'\n";
		print NEW "$npeg$2//\n";
	    }
	    else
	    {
		print STDERR "nomap $_\n";
	    }
	}
	else
	{
	    print STDERR "nomatch $_\n";
	}
    }
    close(OLD);

    if (open(OLD, "<", "$rp_dir/annotations.pre_glue"))
    {
	while (<OLD>)
	{
	    print NEW $_;
	}
	close(OLD);
    }
    close(NEW);
}

#
# And since we now have all of our parts and pieces, create annotations & evidence.
#

my $rc = system("$FIG_Config::bin/initialize_ann_and_ev $rp_dir 2> $errdir/initialize_ann_and_ev.stderr");
if ($rc != 0)
{
    &fatal("initialize_ann_and_ev $rp_dir failed with rc=$rc");
}

system("$FIG_Config::bin/rp_index_attributes", $jobdir);

$meta->add_log_entry($0, "glue_contigs completed\n");
$meta->set_metadata("glue_contigs.running", "no");
$meta->set_metadata("status.glue_contigs", "complete");

exit;

sub fatal
{
    my($msg) = @_;

    $meta->add_log_entry($0, ['fatal error', $msg]);
    $meta->set_metadata("status.glue_contigs", "error");
    $meta->set_metadata("glue_contigs.running", "no");

    croak "$0: $msg";
}
    
