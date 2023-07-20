
#
# Module to wrap an import job directory.
#

package ImportJob;

use FIG;
use FIGV;
use GenomeMeta;
use DBMaster;
use Mail::Mailer;
use File::Basename;

use DirHandle;
use strict;

use SOAP::Lite;

use FIG_Config;

sub all_jobs
{
    my @jobs;

    my $dh = new DirHandle($FIG_Config::import_jobs);

    while (defined($_ = $dh->read()))
    {
	next unless /^\d+$/;

	my $job = ImportJob->new($_);
	if ($job)
	{
	    push(@jobs, $job);
	}
    }
    return sort { $a->id <=> $b->id } @jobs;
}

#
# create new job directory on disk
# data is a hash reference 
#
sub create_new_job
{
    my ($class, $data) = @_;
    
    my $jobs_dir = $FIG_Config::import_jobs;
    
    # init job counter if necessary
    umask 0000;
    unless (-f "$jobs_dir/JOBCOUNTER") {
	open(FH, ">$jobs_dir/JOBCOUNTER") or die "could not create jobcounter file: $!\n";
	print FH "000\n";
	close FH;
    }
    
    # get new job id from job counter
    open(FH, "$jobs_dir/JOBCOUNTER") or die "could not open jobcounter file: $!\n";
    my $jobnumber = <FH>;
    chomp $jobnumber;
    $jobnumber = sprintf("%03d", $jobnumber + 1);
    close FH;
    while (-d $jobs_dir.'/'.$jobnumber)
    {
	$jobnumber = sprintf("%03d", $jobnumber + 1);
    }

    # create job directory
    my $job_dir = $jobs_dir.'/'.$jobnumber;
    mkdir $job_dir;
    open(FH, ">$jobs_dir/JOBCOUNTER") or die "could not write to jobcounter file: $!\n";
    print FH $jobnumber;
    close FH;
    
    unless (-d $job_dir) {
	return (undef, 'The job directory could not be created.');
    }

    # create metadata files  
    my $meta_id = "import_$jobnumber";
    
    my $meta = new GenomeMeta($meta_id, "$job_dir/meta.xml");
    
    open(FH, ">" . $job_dir . "/ACTIVE") or die "cannot open ACTIVE file in $job_dir: $!\n";
    close(FH);
  
  return ($jobnumber,'');
}


#
# load existing Job 
# 
sub new
{
    my($class, $job_id) = @_;


    my $dir;
    if ($job_id =~ /^\d+$/)
    {
	$dir = "$FIG_Config::import_jobs/$job_id";
    }
    else
    {
	$dir = $job_id;
	$job_id = basename($dir);
    }

    return if (! -d $dir);

    my $self = {
	id => $job_id,
	dir => $dir,
    };
    $self = bless $self, $class;
    $self->init();
    return $self;
}

sub init
{
    my($self) = @_;

    my $dir = $self->{dir};

    $self->{meta} = new GenomeMeta(undef, "$dir/meta.xml");
}

sub dir { return $_[0]->{dir}; }
sub id { return $_[0]->{id}; }
sub meta { return $_[0]->{meta}; }


1;
