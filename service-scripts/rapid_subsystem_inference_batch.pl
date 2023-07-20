########################################################################
#


use strict;
use Data::Dumper;
use Getopt::Long;

use SeedUtils;
use FIG;
my $fig = new FIG;

my $missing_genomes_file;
my $verbose;

my $usage = "usage: rapid_subsystem_inference_batch [--verbose] [--missing-genomes filename] [evidence-log] < input-def";

my $rc = GetOptions("missing-genomes=s" => \$missing_genomes_file,
		    "verbose" => \$verbose);

$rc && (@ARGV == 0 or @ARGV == 1) or die $usage;

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

my $missing_genomes_fh;
if (defined($missing_genomes_file))
{
    open($missing_genomes_fh, ">", $missing_genomes_file) or die "Cannot open $missing_genomes_file: $!";
}

my %ss_data;

my $res = $fig->db_handle->SQL(qq(SELECT subsystem, genome, variant
				  FROM subsystem_genome_variant));
for my $ent (@$res)
{
    my($ss, $genome, $variant) = @$ent;
    $ss_data{$ss}->{variant}->{$genome} = $variant;
}

$res = $fig->db_handle->SQL(qq(SELECT subsystem, role
			       FROM subsystem_nonaux_role));
for my $ent (@$res)
{
    my($ss, $role) = @$ent;
    push(@{$ss_data{$ss}->{roles}}, $role);
}

my %genome_roles;
my $sth = $fig->db_handle->{_dbh}->prepare(qq(SELECT subsystem, genome, role
					      FROM subsystem_genome_role),
				       { mysql_use_result => 1 });
$sth->execute();
while (my $ent = $sth->fetchrow_arrayref())
{
    my($ss, $genome, $role) = @$ent;
    push(@{$genome_roles{$ss}->{$genome}}, $role);
    #push(@{$ss_data{$ss}->{roles}->{$genome}}, $role);
}
$sth->finish();

for my $ss (keys %ss_data)
{
    my $rhash = $genome_roles{$ss};
    while (my($genome, $roles) = each %$rhash)
    {
	my $vcode = $ss_data{$ss}->{variant}->{$genome};
	my $key = join("\t", sort @$roles);
	if ($key eq '')
	{
	    print STDERR "Null key from $ss $genome $vcode\n";
	    next;
	}
	$ss_data{$ss}->{vcodes}->{$key}->{$vcode}++;
    }
}
undef %genome_roles;

#print STDERR Dumper(\%ss_data);
#print "dumped\n";
while (<STDIN>)
{
    chomp;
    my($funcs_file, $ss_out, $bindings_out) = split(/\t/);

    my ($func_fh, $ss_fh, $bindings_fh);
    open($func_fh, "<", $funcs_file) or die "Cannot read $funcs_file: $!";
    open($ss_fh, ">", $ss_out) or die "Cannot write $ss_out: $!";
    open($bindings_fh, ">", $bindings_out) or die "Cannot write $bindings_out: $!";

    print STDERR "Process $funcs_file\n" if $verbose;
    print $evlogFH "assigned_functions\t$funcs_file\n";
    process_file($func_fh, $ss_fh, $bindings_fh, $missing_genomes_fh);

    close($bindings_fh);
    close($ss_fh);
}

close $missing_genomes_fh if $missing_genomes_fh;

sub process_file
{
    my($func_fh, $ss_fh, $bindings_fh, $missing_genomes_fh) = @_;

    #
    # Read the proposed function annotations from the given fh. Split
    # assignments that are joined with ; or @ into separate roles.
    #
    # Store the role => peg bindings in the %bindings hash.
    #

    my %bindings;
    my %funcs;
    my $genome;
    my $errs;
    while (defined($_ = <$func_fh>))  ### Keep just the last assignment in the file
    {
	chomp;
	my($peg, $func) = split(/\t/);
	my $this = &FIG::genome_of($peg);
	if (defined($genome))
	{
	    if ($this ne $genome)
	    {
		warn "Invalid peg $peg: Does not match previous genome $genome\n";
		$errs++;
		next;
	    }
	}
	else
	{
	    $genome = $this;
	}
	
	$funcs{$peg} = $func;
    }
    if ($errs)
    {
	warn "Errors found scanning input\n";
	return;
    }
    
    foreach my $peg (keys(%funcs))
    {
	my $func = $funcs{$peg};
	my @roles = &SeedUtils::roles_of_function($func);
	foreach my $role (@roles)
	{
	    $bindings{$role}->{$peg} = 1;
	}
    }

    my %ss_vc;

    for my $subsys_name (sort grep { $fig->usable_subsystem($_) } keys %ss_data)
    {
	# print STDERR "Process $subsys_name\n";
	print $evlogFH "subsystem\t$subsys_name\n";
	
	my $ss_data = $ss_data{$subsys_name};
	my $variant = $ss_data->{variant};
	my $roles = $ss_data->{roles};
	my $vcodes = $ss_data->{vcodes};
	       
	#
	# Compute the signature for the genome in question based
	# on the %bindings hash we computed ealier.
	#
	
	my @roles_in_this_genome = grep { exists($bindings{$_}) } @$roles;
	
	my $key = join("\t",sort @roles_in_this_genome);
	
	#
	# Attempt to match this signature with one already present in the subsystem.
	#
	
	my $n;
	my $bestN = 0;
	my $bestK = undef;
	my $matches = $vcodes->{$key};
	
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
	    foreach my $key1 (sort keys(%$vcodes))
	    {
		#
		# Recall: $key is the key we are trying to match
		#         $key1 is the key we are currently examining.
		
		if (&not_minus_1($vcodes->{$key1}) &&
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
		$matches = $vcodes->{$bestK};
		print $evlogFH join("\t", "partial_match", $subsys_name, join(",", sort keys %$matches), $key), "\n" if $evlogFH;
	    }
	}
	
	if (defined($matches))
	{
	    my @vcs  = sort { ($vcodes->{$b} <=> $vcodes->{$a}) or ($b cmp $a) } keys(%$matches);
	    my $best = $vcs[0];

	    $ss_vc{$subsys_name} = $best;
	    print $evlogFH join("\t", "best_subsys", $subsys_name, $best), "\n";
	    print $ss_fh join("\t",($subsys_name,$best)),"\n";

	    foreach my $role (sort @$roles)
	    {
		if (defined(my $bhash = $bindings{$role}))
		{
		    foreach my $peg (sort { &FIG::by_fig_id($a, $b) } keys(%{$bhash}))
		    {
			print $bindings_fh join("\t",($subsys_name,$role,$peg)),"\n";
		    }
		}
	    }
	}
    }
    if ($missing_genomes_fh && $fig->is_prokaryotic($genome))
    {
	#
	# Determine if this genome is already present in
	# any of the subsystems we found a variant for it in.
	my @ss = keys %ss_vc;
	if (@ss)
	{
	    my $in = join(",", map { "?" } @ss);
	    my $res = $fig->db_handle->SQL(qq(SELECT subsystem, variant
					      FROM subsystem_genome_variant
					      WHERE subsystem IN ($in) AND
					      	    genome = ?), undef,
					   @ss, $genome);
	    #print "Search for $genome in @ss\n";
	    for my $ent (@$res)
	    {
		my($ss, $v) = @$ent;
		delete $ss_vc{$ss};
	    }
	    print $missing_genomes_fh join("\t", $genome, $_, $ss_vc{$_}), "\n" foreach sort keys %ss_vc;
	}
    }
}

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
