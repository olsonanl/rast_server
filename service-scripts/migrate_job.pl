#
# Migrate the given job to the destination job directory.
#
# It will retain its job number.
#
# metadata and raw data are copied, and a new meta.xml is created
# with the required initial data.
#

my $usage = "usage: migrate_job [-new] job-dir target";


use strict;
use GenomeMeta;
use File::Basename;
use File::Copy;
use FIG;

my @meta_keys_to_copy = ( qr/^(?:genome|upload)\..*/,
			 qr/^correction\.automatic/);
my $files_to_skip = qr/^(?:ACTIVE|DONE|DELETED|meta\.xml)$/;

my $new_num;
while ($ARGV[0] =~ /^-(.*)/)
{
    shift;
    my $arg = $1;
    if ($arg =~ /^new/)
    {
	$new_num = 1;
    }
    else
    {
	die "Unknown argument $arg\n";
    }
}



@ARGV == 2 or die "$usage\n";

my $jobdir = shift;
my $target = shift;

opendir(JOBDIR, $jobdir) or die "Cannot open job $jobdir: $!\n";
my $jobnum = basename($jobdir);

$jobnum =~ /^\d+$/ or die "Job directory $jobdir is not numeric\n";

-d $target or die "Target directory $target does not exist\n";


-f "$jobdir/meta.xml" or die "Source meta.xml not present\n";


my $genome_id = &FIG::file_head("$jobdir/GENOME_ID", 1);
defined($genome_id) or die "Cannot read genomem id\n";
chomp $genome_id;

my $target_jobnum;
if ($new_num)
{
    # get new job id from job counter
    open(FH, "$target/JOBCOUNTER") or die "could not open jobcounter file: $!\n";
    $target_jobnum = <FH>;
    $target_jobnum++;
    close FH;
    while (-d "$target/$target_jobnum")
    {
	$target_jobnum++;
    }
    open(FH, ">$target/JOBCOUNTER") or die "could not write to jobcounter file: $!\n";
    print FH $target_jobnum;
    close FH;
}
else
{
    $target_jobnum = $jobnum;
}

my $new_jobdir = "$target/$target_jobnum";

warn "Copying job $jobnum for genome $genome_id from $jobdir to $new_jobdir\n";

my $old_meta = new GenomeMeta(undef, "$jobdir/meta.xml");
$old_meta or die "Cannot open $jobdir/meta.xml: $!\n";

-d $new_jobdir and die "Job $target_jobnum in $target already exists\n";

mkdir $new_jobdir or die "cannot mkdir $new_jobdir: $!\n";

my $new_meta = new GenomeMeta($genome_id, "$new_jobdir/meta.xml");
$new_meta or die "Cannot create $new_jobdir/meta.xml: $!\n";

for my $key ($old_meta->get_metadata_keys())
{
    if (grep { $key =~ /$_/ } @meta_keys_to_copy)
    {
	$new_meta->set_metadata($key, $old_meta->get_metadata($key));
    }
}

$new_meta->add_log_entry("creation", "Migrated job from $jobdir");

for my $f (readdir(JOBDIR))
{
    my $path = "$jobdir/$f";
    next unless -f $path;

    next if $f =~ /$files_to_skip/;

    copy($path, "$new_jobdir/$f") or die "Copy $path $new_jobdir/$f failed: $!";
}

#
# And copy the data.
#

my $rc = system("cp", "-r", "$jobdir/raw", "$new_jobdir");
$rc == 0 or die "Copy of $jobdir/raw to $new_jobdir failed";

#
# Don't send email, and automatically process corrections.
#

$new_meta->set_metadata('qc.email_notification_sent', 'yes');
$new_meta->set_metadata('correction.automatic', 1);
$new_meta->set_metadata('status.uploaded', 'complete');

#
# And make active.
#
open(F, ">$new_jobdir/ACTIVE");
close(F);
