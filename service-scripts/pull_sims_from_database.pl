#
# Given a fasta file, pull the sims from the a seed database. This is
# functionality similar to the guts of the sim server or FIG::osims,
# but meant to operate in a more standalone environment (like the
# detached RAST code running on a standalone compute cluster).
#
# Write them to stdout, and write nonmatching IDs to stderr.
#
# Usage: pull_sims_from_database dsn user password table_name < fasta > sims 2> non-matching
# 

use FIG;
use Digest::MD5;
use Data::Dumper;
use DBI;
use Sim;
use strict;

@ARGV == 4 or die "Usage: $0 database-dsn user password table_name < fasta > sims 2> non-matching-ids\n";

my $fig = new FIG;

my $dsn = shift;
my $user = shift;
my $pw = shift;
my $table = shift;

my $dbh = DBI->connect($dsn, $user, $pw);
$dbh or die "Cannot connect to dtabase $dsn";

my $sth = $dbh->prepare(qq(SELECT file, seek, len
			   FROM file_table f JOIN $table s ON s.fileN = f.fileno
			   WHERE s.id= ?));
my $fhin = \*STDIN;


{
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
    
    my $chunksize = 200;
    
    my %seen = %md5_to_id;
    while (@md5s)
    {
	my @chunk = splice(@md5s, 0, $chunksize);
	#print "process chunk\n";
	#print STDERR "@chunk \n";
	
	my $sims = get_sims(\@chunk);
	
	my $last;
	while (my $sim = shift @$sims)
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
}

sub get_sims
{
    my($ids) = @_;

    my @sims;
    for my $id (@$ids)
    {
	$sth->execute($id);
	while (my $r = $sth->fetchrow_arrayref())
	{
	    my($file, $seek, $len) = @$r;
            if ($file !~ m,^/,)
	    {
		$file = "$FIG_Config::fig_disk/$file";
	    }

	    my $fh = $fig->openF($file);
	    push @sims, map  { bless [ split( /\t/, $_ ), 'blastp'], 'Sim' }
                     @{ &FIG::read_block( $fh, $seek, $len - 1 ) };
	}
    }
    return \@sims;
}
