
#
# Finish a job that has its work directories over on the
# lustre spool directory by copying them back and then
# setting the job to done.
#

use Data::Dumper;
use Carp;
use strict;
use FIG;
use FIG_Config;
use File::Basename;
use GenomeMeta;
use JobError;
use File::Basename;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $job = new Job48($jobdir);
$job or die "cannot create job for $jobdir";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

my $genome_dir = "$jobdir/rp/$genome";

$meta->set_metadata("lustre_stage_in.hostname", $hostname);

$meta->add_log_entry($0, "copy lustre spooled job back to $jobdir");

#
# Find any directories in the jobdir that are symlinked to the lustre spool. Copy
# the contents back here.
#
opendir(D, $jobdir) or &fatal("cannot opendir $jobdir: $!");
for my $f (readdir(D))
{
    my $path = "$jobdir/$f";
    next unless -l $path;
    my $targ = readlink($path);
    if (!$targ)
    {
	warn "Error reading symlink $path: $!";
	next
    }

    if ($targ =~ /^$FIG_Config::lustre_spool_dir/)
    {
	warn "Copying back data from $targ to $path\n";
	unlink($path);
	my $targ_dir = dirname($targ);
	if ($targ_dir eq '' or ! -d $targ_dir)
	{
	    warn "Some error extracting dirname '$targ_dir' from target '$targ'\n";
	    next;
	}
	my $tar_cmd = "tar -C $targ_dir -c -p -f - $f | tar -C $jobdir -x -p -f -";
	warn "Execute $tar_cmd\n";
	my $rc = system($tar_cmd);
	if ($rc != 0)
	{
	    &fatal("Error $rc running tar cmd $tar_cmd\n");
	}
    }
}
    
if (open(D, ">$jobdir/DONE"))
{
    print D time . "\n";
    close(D);
}
else
{
    warn "Error opening $jobdir/DONE: $!\n";
}

unlink("$jobdir/ACTIVE");

exit(0);

sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
    }

    flag_error($genome, $job->id, $jobdir, $meta, "luster_stage_in");

    croak "$0: $msg";
}
    
