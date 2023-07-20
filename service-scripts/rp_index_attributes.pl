#
# Index the attributes in a job's organism directory.
#

use Data::Dumper;
use DB_File;
use Carp;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use Sim;

#
# allow 2-arg form where we ignore the second, for use in teh attribute generation scripts.
#
@ARGV == 1 or @ARGV == 2 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $genome_dir = "$jobdir/rp/$genome";

my $attr_key_file = "$genome_dir/attr_key.btree";
my $attr_id_file = "$genome_dir/attr_id.btree";

unlink($attr_key_file);
unlink($attr_id_file);

my(%key, %id);

$DB_BTREE->{flags} = R_DUP;

my $key_tie = tie %key, 'DB_File', $attr_key_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;
$key_tie or die "cannot create $attr_key_file tie: $!";
my $id_tie = tie %id, 'DB_File', $attr_id_file, O_RDWR | O_CREAT, 0666, $DB_BTREE;
$id_tie or die "cannot create $attr_id_file tie: $!";

#
# Process attributes files.
#

#
# Evidence codes are a little special.
#

if (open(E, "<$genome_dir/evidence.codes"))
{
    while (<E>)
    {
	chomp;
	my($id, $ev) = split(/\t/);
	my $val = join($;, $id, 'evidence_code', $ev);
	$id{$id} = $val;
	$key{evidence_code} = $val;
    }
}

my @attr_files = <$genome_dir/attributes/*>;

for my $af (@attr_files)
{
    if (open(AF, "<$af"))
    {
	while (<AF>)
	{
	    chomp;
	    my($id, $attr, $val, $url) = split(/\t/);
	    my $str = join($;, $id, $attr, $val, $url);
	    $id{$id} = $str;
	    $key{$attr} = $str;
	}
	close(AF);
    }
}

untie($key_tie);
untie($id_tie);

exit(0);
