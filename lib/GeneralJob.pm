
#
# Module to wrap general rast-wide job queuing data.
#

package GeneralJob;

use FIG;
use FIGV;
my $have_genome_meta_db;
eval {
    require GenomeMetaDB;
    $have_genome_meta_db++;
};
use GenomeMeta;
use DBMaster;
use Fcntl qw(:DEFAULT :flock :seek);
use Mail::Mailer;
use FileHandle;
use File::Basename;
use FileLocking qw(lock_file unlock_file lock_file_shared);

my $have_fsync;
eval {
	require File::Sync;
	$have_fsync++;
};

use DirHandle;
use strict;

use SOAP::Lite;

use FIG_Config;

#
# create new job directory on disk
# data is a hash reference 
#
sub create_new_job {
    my ($class, $jobs_dir, $data) = @_;
    
    
    # init job counter if necessary
    umask 0000;
    unless (-f "$jobs_dir/JOBCOUNTER") {
	open(FH, ">$jobs_dir/JOBCOUNTER") or die "could not create jobcounter file $jobs_dir/JOBCOUNTER: $!\n";
	print FH "1";
	close FH;
    }
    
    #
    # get new job id from job counter
    # Carefully lock and fsync().
    #
    open(FH, "+<$jobs_dir/JOBCOUNTER") or die "could not open jobcounter file $jobs_dir/JOBCOUNTER: $!\n";
    FH->autoflush(1);
    lock_file(\*FH);
    seek(FH, 0, SEEK_SET);
    my $jobnumber = <FH>;
    
    $jobnumber++;
    while (-d $jobs_dir.'/'.$jobnumber) {
	$jobnumber++;
    }
    
    seek(FH, 0, SEEK_SET);
    FH->truncate(0);
    print FH "$jobnumber\n";
    
    eval { File::Sync::fsync(\*FH) if $have_fsync; };
    
    close FH;

    # create job directory
    my $job_dir = $jobs_dir.'/'.$jobnumber;
    mkdir $job_dir;
    
    unless (-d $job_dir) {
	return (undef, 'The job directory could not be created.');
    }
    
    mkdir "$job_dir/raw";

    # create metadata files  
    my $meta_id = 'general_'.$jobnumber;

    my $meta;
    if ($FIG_Config::meta_use_db and $have_genome_meta_db)
    {
	$meta = new GenomeMetaDB($meta_id, "$job_dir/meta.xml");
    }
    else
    {
	$meta = new GenomeMeta($meta_id, "$job_dir/meta.xml");
    }
    $meta->add_log_entry("genome", "Created $job_dir");
  
    return $jobnumber;
}


#
# load existing Job 
# 
sub new
{
    my($class, $job_dir, $job_id) = @_;

    my $dir;
    if ($job_id =~ /^\d+$/)
    {
	$dir = "$job_dir/$job_id";
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

    my $metaxml_key = 'general_'.$self->id;
    $self->{meta} = new GenomeMeta($metaxml_key, "$dir/meta.xml");

    $self->{to_be_deleted} = -f "$dir/DELETE" || 0;
    $self->{active} = -f "$dir/ACTIVE" || 0;
}

sub dir { return $_[0]->{dir}; }
sub id { return $_[0]->{id}; }
sub meta { return $_[0]->{meta}; }
sub active { return $_[0]->{active}; }
sub to_be_deleted { return $_[0]->{to_be_deleted}; }

1;
