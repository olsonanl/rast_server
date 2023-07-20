#
# Given a fasta file, pull the sims from the sims server for the sequences.
#
# Write them to stdout, and write nonmatching IDs to stderr.
#

use FIG;
use Digest::MD5;
use Data::Dumper;

my $fhin = \*STDIN;

my $fig = new FIG;

my %id_to_md5;
my %md5_to_id;
my @ids;
my @md5s;
while ((my($id, $seqp, undef) = &FIG::read_fasta_record($fhin)))
{
    my $md5 = Digest::MD5::md5_hex(uc($$seqp));
    my $mid = "gnl|md5|$md5";
    $id_to_md5{$id} = $mid;
    $md5_to_id{$mid} = $id;
    push(@ids, $id);
    push(@md5s, $mid);
}

$chunksize = 200;

my %seen = %md5_to_id;
while (@md5s)
{
    my @chunk = splice(@md5s, 0, $chunksize);
    #print "process chunk\n";
    # print STDERR "@chunk \n";
    my @sims = $fig->sims(\@chunk, 300, undef, undef, 'raw');

    my $last;
    while (my $sim = shift @sims)
    {
	if ($sim->id1 ne $last)
	{
	    delete $seen{$last};
	    $last = $sim->id1;
	}
	
	my $new = $md5_to_id{$sim->id1};
	if ($new)
	{
	    $sim->[0] = $new;
	}
	    
	print join("\t", @$sim), "\n";
    }
    delete $seen{$last};
}

print STDERR "$_\n" for sort { &FIG::by_fig_id($a, $b) } values %seen;
