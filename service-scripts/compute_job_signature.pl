
use strict;
use Job48;
use Digest;
use Data::Dumper;

my $alg = 'SHA-256';

@ARGV == 1 or @ARGV == 2 or die "Usage: $0 job-dir [outfile]\n";

my $dir = shift;

my $out_fh;

if (@ARGV)
{
    my $outfile = shift;

    $out_fh = new FileHandle($outfile, "w");
    
    $out_fh or die "Cannot open output file $outfile: $!";
}
else
{
    $out_fh = \*STDOUT;
}

my $job = new Job48($dir);

my $meta = $job->meta;

#
# A signature is based on the metadata keys listed in
# @signature_keys below.
#
# It also includes a checksum of the original input file.
# This is found in the raw/<genome-id>/ directory.
# If it was a genbank job, file genbank_file has the original input.
# For either genbank or fasta files we include the checksum
# of the unformatted_contigs file.
#
# The genbank signature is not a simple signature; rather it
# is a set of the signatures of the individual genbank files
# that were concatenated to form the full file. They are sorted
# on locus id.


my @signature_keys = qw(use_glimmer
			annotation_scheme
			rasttk_workflow
			correction.disabled
			correction.automatic
			correction.backfill_gaps
			correction.frameshifts
			genome.genetic_code
			keep_genecalls
			genome.contig_count
			genome.bp_count
			genome.ambig_count
			options.figfam_version
			);

my @sig_data;

for my $key (@signature_keys)
{
    my $val = $meta->get_metadata($key);
    if (ref($val))
    {
	$val = Dumper($val);
    }
    push(@sig_data, [$key, $val]);
}

my $raw_dir = $job->dir . "/raw/" . $job->genome_id;

my $md5 = '';
if (open(F, "<", "$raw_dir/unformatted_contigs"))
{
    my $d = Digest->new($alg);
    $d->addfile(\*F);
    $md5 = $d->hexdigest();
    close(F);
}
push(@sig_data, ['unformatted_contigs', $md5]);

if (open(F, "<", "$raw_dir/genbank_file"))
{
    my @segs;

    my $digest = Digest->new($alg);

    my $cur;
    my $l = <F>;
    while (defined($l))
    {
	if ($l =~ /^LOCUS\s+(\S+)/)
	{
	    $cur = $1;
	    $digest->add($l);
	    $l = <F>;
	}
	elsif ($l =~ m,^//$,)
	{
	    $digest->add($l);
	    my $md5 = $digest->hexdigest();
	    push(@segs, [$cur, $md5]);
	    #
	    # Spin until we hit the next start, in case there
	    # was text between the files. (If anything but blank lines,
	    # mark it with extra crud in the @segs list).
	    #
	    $l = <F>;
	    while (defined($l) && $l !~ /^LOCUS/)
	    {
		if ($l !~ /^\s*$/)
		{
		    $digest->add($l);
		}
		$l = <F>;
	    }
	    push(@segs, ["gap_$cur", $digest->hexdigest()])
	}
	else
	{
	    $digest->add($l);
	    $l = <F>;
	}
	    
    }
    close(F);

    push(@sig_data, sort { $a->[0] cmp $b->[0] } @segs);
}


my $sig_txt = join("\n", map { join("\t", @$_) } @sig_data) . "\n";
my $digest = Digest->new($alg);
$digest->add($sig_txt);
my $sig_md5 = $digest->hexdigest;

print $out_fh "$sig_md5\n$sig_txt";
close($out_fh);
