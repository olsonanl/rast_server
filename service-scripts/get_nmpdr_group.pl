
use strict;
use FIG_Config;
use Data::Dumper;

my $usage = "get_nmpdr_group genus species";

if (@ARGV == 1)
{
    @ARGV = split(/\s+/, $ARGV[0]);
}

@ARGV >= 2 or die $usage;
my $genus = shift;
my $species = shift;

my $genus_species = "$genus $species";

my $nmpdr_data = parse_nmpdr_groups("$FIG_Config::fortyeight_data/NMPDR.GROUPS");

my $sm = $nmpdr_data->{species_match}->{$genus_species};

if ($sm ne "")
{
    print "$sm\n";
    exit 0;
}

my $gm = $nmpdr_data->{genus_match}->{$genus};
if ($gm ne "")
{
    print "$gm\n";
    exit 0;
}
exit 1;

#
# Parse the NMPDR group definitions.
#

sub parse_nmpdr_groups
{
    my($group_file) = @_;

    open(GF, "<$group_file") or die "cannot open nmpdr group file $group_file: $!";

    my $dat = {};
    while (<GF>)
    {
	chomp;
	my $groupname;
	s/^\s+//;
	s/\s+$//;
	if (/^(.*)\s+=>\s+(.*)/)
	{
	    $groupname = $2;
	    $_ = $1;
	}
	if (/^([a-z]+)\s+(\S+)/)
	{
	    $groupname = $_ unless $groupname;
	    $dat->{genus_match}->{$2} = $groupname;
	}
	else
	{
	    $groupname = $_ unless $groupname;
	    $dat->{species_match}->{$_} = $groupname;
	}
    }
#    print Dumper($dat);

    return $dat;
    
}


#
# Process any NMPDR marking for this job.
#

sub process_nmpdr
{
}

