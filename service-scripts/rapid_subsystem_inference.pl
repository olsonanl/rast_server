########################################################################
#


use strict;

use Data::Dumper;
use FIG;
use Subsystem;
my $fig = new FIG;

my $usage = "usage: rapid_subsystem_inference SubsystemDescDir [evidence-log] < AssignedFunctions";

@ARGV == 1 or @ARGV == 2 or die $usage;

my $subsysD = shift;
my $evlogFile = shift;

my $evlogFH;

if ($evlogFile)
{
    $evlogFH = new FileHandle(">>$evlogFile");
    $evlogFH or warn "Cannot open evidence log $evlogFile for append: $!";
}
else
{
    $evlogFH = new FileHandle(">/dev/null");
}


&FIG::verify_dir($subsysD);
open(SUBS,">$subsysD/subsystems")
    || die "could not open $subsysD/subsystems";
open(BINDINGS,">$subsysD/bindings")
    || die "could not open $subsysD/bindings";

#
# Read the proposed function annotations from stdin. Split
# assignments that are joined with ; or @ into separate roles.
#
# Store the role => peg bindings in the %bindings hash.
#

my %bindings;
my %funcs;
while (defined($_ = <STDIN>))  ### Keep just the last assignment in the file
{
    if ($_ =~ /^(\S+)\t(\S.*\S)/)
    {
	$funcs{$1} = $2;
    }
}

foreach my $peg (keys(%funcs))
{
    my $func = $funcs{$peg};
    $func =~ s/\s*[\#\!].*$//;
    my @roles = split(/(; )|( [@\/] )/,$func);
    foreach my $role (@roles)
    {
	$bindings{$role}->{$peg} = 1;
    }
}

while (defined($_ = <STDIN>))
{
    if ($_ =~ /^(\S+)\t(\S.*\S)/)
    {
	my $peg  = $1;
	my $func = $2;
	$func =~ s/\s*[\#\!].*$//;
	my @roles = split(/(; )|( [@\/] )/,$func);
	foreach my $role (@roles)
	{
	    $bindings{$role}->{$peg} = 1;
	}
    }
}

foreach my $subsys_name (sort grep {$fig->usable_subsystem($_) } $fig->all_subsystems)
{
    # my $sobj = $fig->get_subsystem($subsys_name);
    my $sobj = Subsystem->new($subsys_name, $fig);
    if (! $sobj)
    {
	print STDERR "Something is screwed up with $subsys_name\n";
	next;
    }

    # print STDERR "Process $subsys_name\n";
    
    my @roles   = $sobj->get_roles;
    my @non_aux_roles = grep { ! $sobj->is_aux_role($_) } @roles;

    my(%vcodes);
    foreach my $genome ($sobj->get_genomes)
    {
	my @roles_in_genome = ();
	my $vcode = $sobj->get_variant_code($sobj->get_genome_index($genome));
        next if (($vcode eq '0') || ($vcode =~ /\*/));

	foreach my $role (@non_aux_roles)
	{
	    my @pegs = $sobj->get_pegs_from_cell($genome,$role);
	    if (@pegs > 0)
	    {
		push(@roles_in_genome,$role);
	    }
	}

	#
	# @roles_in_genome contains all of the roles in this subsystem
	# for which this genome has pegs.
	#
	# Construct $key from these; this is the signature of this
	# genome in this subsystem. Save the variant code for this set.
	#
	# There is an occasional bug where genomes have vc > 0 but no 
	# pegs in cells. In this case, the length of the key will be 0
	
	my $key = join("\t",sort @roles_in_genome);
	$vcodes{$key}->{$vcode}++ if (length($key) > 0);
    }

    # print STDERR Dumper($subsys_name, \%vcodes);
    #
    # Compute the signature for the genome in question based
    # on the %bindings hash we computed ealier.
    #

    my @roles_in_this_genome = ();
    foreach my $role (@non_aux_roles)
    {
	if (defined($bindings{$role}))
	{
	    push(@roles_in_this_genome,$role);
	}
    }

    my $key = join("\t",sort @roles_in_this_genome);

    #
    # Attempt to match this signature with one already present in the subsystem.
    #

    my $n;
    my $bestN = 0;
    my $bestK = undef;
    my $matches = $vcodes{$key};

    if ($matches)
    {
	#
	# We found an exact match.
	#
	print $evlogFH join("\t", "exact_match", $subsys_name, join(",", sort keys %$matches), $key), "\n";
    }
    else
    {
	#
	# No exact mactch
	#
	foreach my $key1 (sort keys(%vcodes))
	{
	    #
	    # Recall: $key is the key we are trying to match
	    #         $key1 is the key we are currently examining.
	    
            if (&not_minus_1($vcodes{$key1}) &&
                (length($key) > length($key1)) &&
                ($n = &contains($key,$key1)) &&
                ($n > $bestN))
	    {
		$bestN = $n;
		$bestK = $key1;
	    }
	}
	if ($bestK)
	{
	    $matches = $vcodes{$bestK};
	    print $evlogFH join("\t", "partial_match", $subsys_name, join(",", sort keys %$matches), $key), "\n" if $evlogFH;
	}
    }

    if (defined($matches))
    {
	my @vcs  = sort { ($vcodes{$b} <=> $vcodes{$a}) or ($b cmp $a) } keys(%$matches);
	my $best = $vcs[0];

	print $evlogFH join("\t", "best_subsys", $subsys_name, $best), "\n";
	print SUBS join("\t",($subsys_name,$best)),"\n";
	foreach my $role (sort @non_aux_roles)
	{
	    if (defined(my $bhash = $bindings{$role}))
	    {
		foreach my $peg (sort { &FIG::by_fig_id($a, $b) } keys(%{$bhash}))
		{
		    print BINDINGS join("\t",($subsys_name,$role,$peg)),"\n";
		}
	    }
	}
    }
}
close(SUBS);
close(BINDINGS);


# returns undef iff $k2 is not a subset of $k1.  If it is, it returns the size of $k2
sub contains {
    my($k1,$k2) = @_;

    my %s1 = map { $_ => 1 } split(/\t/,$k1);
    my @s2 = split(/\t/,$k2);
    my $i;
    for ($i=0; ($i < @s2) && $s1{$s2[$i]}; $i++) {}
    return ($i < @s2) ? undef : scalar @s2;
}

sub not_minus_1 {
    my($hits) = @_;

    my @poss = keys(%$hits);
    my $i;
    for ($i=0; ($i < @poss) && ($poss[$i] eq "-1"); $i++) {}
    return ($i < @poss);
}
