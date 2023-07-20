#
# Write the GO mappings for the data in the given
# genome directory. (Using FIGV to access, originally
# meant for use in RAST).
#

use File::Basename;
use FIG_Config;
use FIGV;
use strict;
use Getopt::Long;

my $pegs;
my $ec_file;
my $peg_fh;
my $rc = GetOptions("pegs" => \$pegs,
		    "ec=s" => \$ec_file);

($rc && @ARGV == 1) or die "Usage: $0 [-pegs] [-ec ec-file] genome-dir > go.mappings";

my $dir = shift;

if ($pegs)
{
    if ($dir eq '-')
    {
	$peg_fh = \*STDIN;
    }
    else
    {
	open($peg_fh, "<", $dir) or die "Cannot open $dir: $!";
    }
}
else
{
    # genome-dir option
    if (! -d $dir)
    {
	die "Genome directory $dir does not exist";
    }
}

my $ec_fh;
if (defined($ec_file))
{
    open($ec_fh, ">", $ec_file) or die "Cannot write $ec_file: $!\n";
}

my $fig = -d $dir ? new FIGV($dir) : new FIG();

# get the functional role name -> GO file
open(FH, $FIG_Config::data . "/Ontologies/GO/fr2go") or die "could not open fr2go";
my $fr2go = {};
while (<FH>) {
    chomp;
    my ($fr, $go) = split /\t/;
    $fr2go->{$fr} = [] unless (exists $fr2go->{$fr});
    push @{$fr2go->{$fr}}, $go;
}
close FH;

if (!$pegs)
{

    my $genome = basename($dir);

    # get the pegs
    foreach my $peg (sort { &FIG::by_fig_id($a,$b) } $fig->pegs_of($genome), $fig->rnas_of($genome))
    {
	my $func = $fig->function_of($peg);

	process($peg, $func);
    }
}
else
{
    while (<$peg_fh>)
    {
	chomp;
	my($peg, $func) = split(/\t/);

	process($peg, $func);
    }
}

close($ec_fh) if defined($ec_fh);
	    
sub process
{
    my($peg, $func) = @_;
    
    my %ecs;
    my @gos;
    
    # get EC / GO from role
    if (defined $func) {
	foreach my $role ($fig->roles_of_function($func)) {
	    my ($ec) = ($role =~ /\(EC ((\d+|-)\.(\d+|-)\.(\d+|-)\.(\d+|-))\)/);
	    $ecs{$ec} = 1 if ($ec);
	    push @gos, @{$fr2go->{$role}} if ($fr2go->{$role});
	}
    }

    my @ecs = keys %ecs;
    if (@ecs && defined($ec_fh))
    {
	print $ec_fh join("\t", $peg, $func, @ecs), "\n";
    }

    return unless @gos;
    
    my %gos = map { $_ => 1 } @gos;
    print join("\t", $peg, $func, sort keys %gos), "\n";
}

