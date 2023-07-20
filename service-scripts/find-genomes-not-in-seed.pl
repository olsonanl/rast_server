#
# Find any genomes currently in the 48-hour queue that are finished and appear to
# not exist in the SEED.
#

use strict;
use Data::Dumper;
use FIG;
use Job48;

my $fig = new FIG();

my @genomes = $fig->genomes();

my %by_tax;
my %genome_to_name;
my %name_to_genome;
my %contig_to_genome;
my %normalized_name_to_genome;
my %normalized_gs_to_genome;

for my $g (@genomes)
{
    my($tax, $vers) = split(/\./, $g);
    push @{$by_tax{$tax}}, $g;
    my $gs = $fig->genus_species($g);
    $name_to_genome{$gs} = $g;
    $genome_to_name{$g} = $gs;

    #
    # normalized names
    #
    my $ngs = lc($gs);
    $ngs =~ s/\s//g;
    $normalized_name_to_genome{$ngs} = $g;
    if ($gs =~ /^\s*(\S+)\s+(\S+)/)
    {
	$normalized_gs_to_genome{lc("$1$2")} = $g;
    }
}

#warn Dumper(\%normalized_name_to_genome);
#warn Dumper(\%normalized_gs_to_genome);


#
# Poke the db to read all contig ids.
#
warn "Reading contigs\n";
my $res = $fig->db_handle->SQL(qq(SELECT genome, contig from contig_lengths));
for my $ent (@$res)
{
    my($genome, $contig) = @$ent;
    
    push @{$contig_to_genome{$contig}}, $genome;
}
warn "done reading contigs\n";

my @jobs = Job48::all_jobs();
@jobs = grep { $_->active() } @jobs;

for my $job (@jobs)
{
#    print "Job " . $job->id . " " . $job->genome_id . " " . $job->genome_name . "\n";
    check($job);
}

sub check
{
    my($job) = @_;

    my $id = $job->id;
    my $g = $job->genome_id();
    my $gs = $job->genome_name();
    my @inseed;
    my $status = "UNKNOWN";

    #
    # find normalized names
    #
    my $ngs = lc($gs);
    my $gsonly;
    $ngs =~ s/\s//g;

    if ($gs =~ /^\s*(\S+)\s+(\S+)/)
    {
	$gsonly = lc("$1$2");
    }

#    warn "$g $gs $ngs $gsonly\n";

    if (!$job->finished())
    {
	$status = "INCOMPLETE";
    }
    elsif (my $sname = $name_to_genome{$gs})
    {
	$status = "NAME_IN_SEED";
	@inseed = ($sname, $genome_to_name{$sname});
	$job->meta->set_metadata("seed.genome_id", $sname);
	$job->meta->set_metadata("seed.genome_name", $genome_to_name{$sname});
    }
    else
    {
	(my $tax = $g) =~ s/\..*$//;
	my @bytax = @{$by_tax{$tax}} if $by_tax{$tax};
	if (@bytax)
	{
	    $status = "TAX_IN_SEED";
	    
	    for my $seedg (@bytax)
	    {
		my $seedname = $genome_to_name{$seedg};
		push(@inseed, $seedg, $seedname);
		$job->meta->set_metadata("seed.genome_id", $seedg);
		$job->meta->set_metadata("seed.genome_name", $seedname);
	    }
	}
	else
	{
	    if (my $sname = $normalized_name_to_genome{$ngs})
	    {
		$status = "NORMALIZED_NAME_IN_SEED";
		@inseed = ($sname, $genome_to_name{$sname});
		$job->meta->set_metadata("seed.genome_id", $sname);
		$job->meta->set_metadata("seed.genome_name", $genome_to_name{$sname});
	    }
	    elsif (my $sname = $normalized_gs_to_genome{$gsonly})
	    {
		$status = "NORMALIZED_GS_IN_SEED";
		@inseed = ($sname, $genome_to_name{$sname});
		$job->meta->set_metadata("seed.genome_id", $sname);
		$job->meta->set_metadata("seed.genome_name", $genome_to_name{$sname});
	    }

	    #
	    # Search for contig names that map.
	    #

	    my @clist;
	    for my $contig ($job->contigs())
	    {
		my $glist = $contig_to_genome{$contig};
		if ($glist)
		{
		    $status = "MATCHING_CONTIG_ID";
		    for my $sg (@$glist)
		    {
			push(@inseed, $sg, $genome_to_name{$sg});
			push(@clist, [$sg, $genome_to_name{$sg}]);
		    }
		    last;
		}
	    }
	    $job->meta->set_metadata("seed.matching_contigs", \@clist) if @clist;

	    if ($status eq 'UNKNOWN')
	    {
		$status = "NEW";
	    }
	}
    }
    $job->meta->set_metadata("seed.status", $status);

    print join("\t", $status, $job->id, $job->user, $g, $gs, @inseed), "\n";

}
