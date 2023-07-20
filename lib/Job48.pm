
#
# Module to wrap the lookups of 48-hour server job information.
#

package Job48;

use FIG;
use FIGV;
my $have_genome_meta_db;
eval {
    require GenomeMetaDB;
    $have_genome_meta_db++;
};
use JobUpload;
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

sub all_jobs
{
    my @jobs;

    my $dh = new DirHandle($FIG_Config::fortyeight_jobs);

    while (defined($_ = $dh->read()))
    {
	next unless /^\d+$/;

	my $job = Job48->new($_);
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
sub create_new_job {
    my ($class, $data) = @_;
    
    my $jobs_dir = $FIG_Config::rast_jobs;
    my $active_jobs_dir = $FIG_Config::rast_active_jobs;
    if (!defined($active_jobs_dir))
    {
	$active_jobs_dir = $jobs_dir;
    }
    
    if (exists $data->{'taxonomy_id'}) {
	
	my $tid = $data->{'taxonomy_id'} || "6666666";
	$tid =~ s/\s+//;
	
	# query clearing house about taxonomy id extension
	my $proxy = SOAP::Lite->uri('http://www.soaplite.com/Scripts')-> proxy($FIG_Config::clearinghouse_url);
	my $r = $proxy->register_genome($tid);
	if ($r->fault) {
	    return (undef, "Failed to deposit: " . $r->faultcode . " " . $r->faultstring);
	}
	
	$data->{'taxonomy_id_ext'} = $tid . "." . $r->result;
    }
    else {
	$data->{'taxonomy_id_ext'} = '';
    }
    
    # init job counter if necessary
    umask 0000;
    unless (-f "$jobs_dir/JOBCOUNTER") {
	open(FH, ">$jobs_dir/JOBCOUNTER") or die "could not create jobcounter file: $!\n";
	print FH "1";
	close FH;
    }

    #
    # get new job id from job counter
    # Carefully lock and fsync().
    #
    open(FH, "+<$jobs_dir/JOBCOUNTER") or die "could not open jobcounter file: $!\n";
    FH->autoflush(1);
    lock_file(\*FH);
    seek(FH, 0, SEEK_SET);
    my $jobnumber = <FH>;
    
    $jobnumber++;
    while (-d $jobs_dir.'/'.$jobnumber) {
	$jobnumber++;
    }

    if ($data->{jobnumber} && $data->{jobnumber} > $jobnumber) {
	$jobnumber = $data->{jobnumber};
    }
    
    seek(FH, 0, SEEK_SET);
    FH->truncate(0);
    print FH "$jobnumber\n";

    eval { File::Sync::fsync(\*FH) if $have_fsync; };
    
    close FH;
    
    #
    # Create job directory
    #
    # It is created in active_jobs_dir and symlinked back to the jobs_dir.
    #

    my $job_dir = "$jobs_dir/$jobnumber";
    
    if ($data->{jobnumber})
    {
	unless (-d $job_dir) {
	    return (undef, 'The job directory could not be created.');
	}
    }
    else
    {
	my $active_job_dir = $active_jobs_dir.'/'.$jobnumber;
	mkdir $active_job_dir;
    
	unless (-d $active_job_dir) {
	    return (undef, 'The job directory could not be created.');
	}
    
	if ($job_dir ne $active_job_dir)
	{
	    symlink($active_job_dir, $job_dir);
	}
    }
    
    mkdir "$job_dir/raw";
    if ($data->{'taxonomy_id_ext'}) {
	mkdir "$job_dir/raw/" . $data->{'taxonomy_id_ext'};
	$data->{'tax_dir'} = "$job_dir/raw/".$data->{'taxonomy_id_ext'};
    }
    
    # create metadata files  
    my $meta_id = $data->{'taxonomy_id_ext'} || 'genome_'.$jobnumber;
    
    if ($data->{'metagenome'})
    {
	$meta_id = 'metagenome_'.$jobnumber;
	open(FH, ">". "$job_dir/MGRAST2");
	close(FH);
    }
    
    my $meta;
    if ($FIG_Config::meta_use_db and $have_genome_meta_db)
    {
	$meta = new GenomeMetaDB($meta_id, "$job_dir/meta.xml");
    }
    else
    {
	$meta = new GenomeMeta($meta_id, "$job_dir/meta.xml");
    }
    $meta->add_log_entry("genome", "Created $job_dir for uploaded file by " . $data->{'user'});
  
    open(FH, ">" . $job_dir . "/GENOME") or die "could not open GENOME file in $job_dir: $!\n";
    print FH $data->{'genome'}."\n";
    close FH;
    
    open(FH, ">" . $job_dir . "/PROJECT") or die "could not open PROJECT file in $job_dir: $!\n";
    print FH $data->{'project'}."\n";
    close FH;
    
    open(FH, ">" . $job_dir . "/TAXONOMY") or die "could not open TAXONOMY file in $job_dir: $!\n";
    print FH $data->{'taxonomy'}."\n";
    close FH;
    
    if ($data->{'tax_dir'}) {
	system("cp $job_dir/GENOME $job_dir/PROJECT $job_dir/TAXONOMY ".$data->{'tax_dir'});
	
	open(FH, ">" . $data->{'tax_dir'} . "/GENETIC_CODE") or die "cannot open GENETIC_CODE file in $job_dir: $!\n";
	print FH $data->{'genetic_code'}."\n";
	close(FH);
	
    }
  
    open(FH, ">" . $job_dir . "/GENOME_ID") or die "cannot open GENOME_ID file in $job_dir: $!\n";
    print FH $data->{'taxonomy_id_ext'}."\n";
    close(FH);
    
    open(FH, ">" . $job_dir . "/USER") or die "cannot open USER file in $job_dir: $!\n";
    print FH $data->{'user'}."\n";
    close(FH);
    
    $meta->add_log_entry("genome", "Created metadata files.");
    
    # save uploaded file to raw directory
    if ($data->{genome_dir} && $data->{sequence_file})
    {
	my $upload_file = $data->{'sequence_file'};
	#
	# Start of this code. It's not right yet.
	# 
	# User is submitting a raw genome directory. Untar it, and
	# renumber.
	#
	
	open(FH, ">", "$data->{tax_dir}/upload.tgz");
	my $buf;
	while (read($upload_file, $buf, 4096))
	{
	    print FH $buf;
	}
	close(FH);
	
	my @cmd = ('tar', '-C', $data->{tax_dir}, '-x', '-f', "$data->{tax_dir}/upload.tgz");
	my $rc = system(@cmd);
	if ($rc != 0)
	{
	    die "tar extract failed with rc=$rc: @cmd\n";
	}
	if (! -f "$data->{tax_dir}/contigs" || ! -d "$data->{tax_dir}/Features")
	{
	    die "Invalid data directory";
	}
	
    }
    elsif ($data->{upload_dir})
    {
	#
	# We are initializing from a genome directory that was unpacked by the
	# JobUpload code.
	#
	# Save the directory in $jobdir/original_upload.
	# Renumber the upload orgdir into $jobdir/raw.
	#

	my $upload_job = new JobUpload($data->{upload_dir});

	my $upload_copy = "$job_dir/original_upload";
	mkdir $upload_copy || die "mkdir $upload_copy failed: $!";
	my $cmd = "tar -C $data->{upload_dir} -c -f - . | tar -C $upload_copy -x -f - -p";
	print STDERR "$cmd\n";
	my $rc = system($cmd);
	$rc == 0 || die "Copy of upload data failed with rc=$rc: $cmd";

	#
	# Use renumber_seed_dir to copy and renumber the extracted
	# orgdir into the raw directory.
	#
	$cmd = "$FIG_Config::bin/renumber_seed_dir --old-id $data->{taxonomy_id} --exists-ok $data->{upload_dir}/orgdir $data->{taxonomy_id_ext} $data->{tax_dir}";
	print STDERR "$cmd\n";
	$rc = system($cmd);
	$rc == 0 || die "renumber failed with rc=$rc: $cmd";
	#...Fix genome metadata files mangled by `parse_genbank`...
	system("cp -pf  $job_dir/GENOME  $job_dir/PROJECT  $job_dir/TAXONOMY  $data->{tax_dir}/");
	$meta->add_log_entry("genome", "Copied genome data from $data->{upload_dir}");
    }
    elsif ($data->{'sequence_file'}  and !$data->{'metagenome'}) {
	my $upload_file = $data->{'sequence_file'};
	
	# check whether this is a FASTA or a Genbank file
	my $firstline = <$upload_file>;
	if ($firstline =~ /^\>\S+/) {
	    # this is a FASTA file, print it to unformatted_contigs
	    open(FH, ">" . $data->{'tax_dir'} . "/unformatted_contigs") 
		or die "could not open unformatted_contigs file in ".$data->{'tax_dir'}."\n";
	    $firstline =~ s/(\r\n\n|\r\n|\n|\r)/\n/go;   #...Fix CR, CRLF, and CRLFLF newlines...
	    print FH $firstline;
	    while (<$upload_file>) {
		s/(\r\n\n|\r\n|\n|\r)/\n/go;   #...Fix CR, CRLF, and CRLFLF newlines...
		print FH;
	    }
	    close FH;
	}
	
	elsif ($firstline =~ /^LOCUS/) {
	    # this is a Genbank file, call parse_genbank
	    open(FH, ">" . $data->{'tax_dir'} . "/genbank_file") 
		or die "could not open genbank_file file in ".$data->{'tax_dir'}."\n";
	    print FH $firstline;
	    while (<$upload_file>) {
		s/(\r\n\n|\r\n|\n|\r)/\n/go;   #...Fix CR, CRLF, and CRLFLF newlines...
		print FH;
	    }
	    close FH;
	    my $source = $data->{'tax_dir'} . "/genbank_file";
	    &FIG::run($FIG_Config::bin."/parse_genbank " . $data->{'taxonomy_id_ext'} . " " . $data->{'tax_dir'} . " < $source");
	    system("cp " . $data->{'tax_dir'} . "/contigs " . $data->{'tax_dir'} . "/unformatted_contigs");
	    
	    #...Fix genome metadata files mangled by `parse_genbank`...
	    system("cp -pf  $job_dir/GENOME  $job_dir/PROJECT  $job_dir/TAXONOMY  $data->{tax_dir}/");
	}
	
	else {
	    # the file is in incorrect format, throw an error
	    $meta->add_log_entry("genome", "Upload failed, invalid format.");
	    return (undef, "The uploaded file has an incorrect format. Visit <a href='http://www.theseed.org/wiki/RAST_upload_formats'>our wiki<a> for more inforamtion about valid formats.");
	    
	}
	$meta->add_log_entry("genome", "Successfully uploaded sequence file.");
    }
    
    if ($data->{'metagenome'}) {
	open(FH, ">" . $job_dir . "/METAGENOME") or die "cannot open METAGENOME file in $job_dir: $!\n";
	close(FH);
    }
    
    if (!$data->{non_active})
    {
	open(FH, ">" . $job_dir . "/ACTIVE") or die "cannot open ACTIVE file in $job_dir: $!\n";
	close(FH);
	$meta->add_log_entry("genome", "Job set to active.");
    }
    
    if (defined $data->{'meta'} and ref $data->{'meta'} eq 'HASH') {
	foreach my $key (keys(%{$data->{'meta'}})) {
	    $meta->set_metadata($key, $data->{'meta'}->{$key});
	}
    }  
    
    $meta->set_metadata("upload.timestamp", time);
    $meta->set_metadata("status.uploaded", "complete");
    
    return ($jobnumber,'');
}


#
# load existing Job 
# 
sub new
{
    my($class, $job_id, $user) = @_;

    my $dir;
    if ($job_id =~ /^\d+$/)
    {
	$dir = "$FIG_Config::fortyeight_jobs/$job_id";
    }
    else
    {
	$dir = $job_id;
	$job_id = basename($dir);
    }
       
    if (! -d $dir)
    {
	warn "Job directory $dir does not exist\n";
	return undef;
    }

    my $self = {
	id => $job_id,
	dir => $dir,
    };
    $self = bless $self, $class;
    $self->init();

    if (ref $user) {

      my $jobuser = $self->getUserObject();
      die "Could not get user for job ".$self->id.".\n" unless ($jobuser);

      unless ($self->user eq $user->login)
      {
	return undef;
      }
    
    }

    return $self;
}

sub init
{
    my($self) = @_;

    my $dir = $self->{dir};

    my $genome = &FIG::file_head("$dir/GENOME_ID", 1);
    chomp $genome;
    $self->{genome_id} = $genome;

    $self->{genome_name} = &FIG::file_head("$dir/GENOME", 1);
    chomp $self->{genome_name};

    $self->{project_name} = &FIG::file_head("$dir/PROJECT", 1);
    chomp $self->{project_name};

    $self->{user} = &FIG::file_head("$dir/USER", 1);
    chomp $self->{user};

    $self->{orgdir} = "$dir/rp/$genome";
    $self->{metagenome} = -f "$dir/METAGENOME" || 0;

    my $metaxml_key = ( $self->{metagenome} ) ? 'metagenome_'.$self->id : $genome;
    $self->{meta} = new GenomeMeta($metaxml_key, "$dir/meta.xml");

    $self->{to_be_deleted} = -f "$dir/DELETE" || 0;
    $self->{active} = -f "$dir/ACTIVE" || 0;
}

sub dir { return $_[0]->{dir}; }
sub id { return $_[0]->{id}; }
sub genome_id { return $_[0]->{genome_id}; }
sub genome_name { return $_[0]->{genome_name}; }
sub project_name { return $_[0]->{project_name}; }
sub meta { return $_[0]->{meta}; }
sub user { return $_[0]->{user}; }
sub active { return $_[0]->{active}; }
sub orgdir { return $_[0]->{orgdir}; }
sub metagenome { return $_[0]->{metagenome}; }
sub to_be_deleted { return $_[0]->{to_be_deleted}; }

#
# changes genome name in all occurences of the GENOME file
#
sub set_genome_name {
  my ( $self , $new_name ) = @_;

  my $dir =  $self->dir;
  my $name_changed = 0;
  my @GENOME = `find $dir -name GENOME`; 
  
  foreach my $gfile ( @GENOME ){
    chomp $gfile;
    my $old_name = $self->genome_name;
    my $replaced = $self->_replace_pattern_in_file( $gfile , $old_name , $new_name);
    if ( $replaced){
      $self->meta->add_log_entry("genome", "Changed name from $old_name to $new_name in $gfile.");
      $name_changed = 1;
    }
  }
  
  $self->{genome_name} = $new_name if ( $name_changed);

  return $self->{genome_name};
}

#
# replaces a pattern in a file 
#
sub _replace_pattern_in_file {
  my ( $self , $file , $old , $new , $tmp) = @_;

  $tmp = $self->dir."/change_pattern.tmp" unless ( $tmp );
  my $nr = 0;


 #  print STDERR "READING FILE: $file!!!!\n";
#   print STDERR "WRITING FILE: $tmp!!!!\n";
#   print STDERR "OLD NAME: $old!\n";
#   print STDERR "NEW NAME: $new!\n";
  open ( TMP , ">$tmp" ) or die "Can't open tempfile $tmp for writing\n";
  open ( FILE , $file ) or die "Can't open $file for reading\n";

  while ( my $line = <FILE> ){
    $nr = $line =~ s/$old/$new/g ;
    print TMP $line;
  }
  close TMP ;
  close FILE ;
  #`cp $tmp $tmp.bak`;
  my $success = rename($tmp, $file) ;
  
  unless( $success ){
    print STDERR "Can't rename $tmp to $file, exit process!\n";
    exit 0;
  }

  # print STDERR "Replace: $success and $nr\n";
  return $nr;
}

#
# return the dbmaster user object for the owner of the job
#
sub getUserObject {
    my($self) = @_;

    my $dbm = DBMaster->new(
			    -database => $FIG_Config::webapplication_db,
			    -backend  => $FIG_Config::webapplication_backend,
			    -host     => $FIG_Config::webapplication_host,
			    -user     => $FIG_Config::webapplication_user,
			    -password  => $FIG_Config::webapplication_password,
			    );

    my $username   = $self->user();
    my $userobject = $dbm->User->init({ login => $username });
    return $userobject;
}
	     
sub get_figv
{
    my ($self) = @_;
    return new FIGV($self->orgdir());
}

#
# A job is finished for our purposes when it has
# completed the auto_assign phase.
#
sub finished
{
    my($self) = @_;

    return $self->meta->get_metadata('status.bbhs') eq 'complete';
}

#
# Return a list of contigs. Read the contig file and 
# read the contig name from the header line.
#

sub contigs
{
    my($self) = @_;
    my %contigs;

#    my $tbl = $self->orgdir . "/Features/peg/tbl";


    my $contigfile = $self->orgdir . "/contigs";

    if (open(TBL, "<$contigfile"))
    {
	while (<TBL>)
	{
	    chomp;
	    if (/^>([^\s]+)/)
	    {
		$contigs{$1}++;
	    }
	}
    }
    else
    {
	warn "No $contigfile found\n";
    }
    return sort keys %contigs;
}


#
# Send an email message to the owner of the job.
#
# Do so only if the metadata key passed in has not been set to "yes".
#
sub send_email_to_owner
{
    my($self, $key, $subject, $body) = @_;

    my $meta = $self->meta;

    if ($meta->get_metadata($key) ne "yes")
    {
	my $userobj = $self->getUserObject();

	if ($userobj)
	{
	    my($email, $name);
	    if ($FIG_Config::rast_jobs eq '')
	    {
		$email = $userobj->eMail();
		$name = join(" " , $userobj->firstName(), $userobj->lastName());
	    }
	    else
	    {
		$email = $userobj->email();
		$name = join(" " , $userobj->firstname(), $userobj->lastname());
	    }
		
            #
            # Names with HTML escapes do not work properly. Drop
            # them as they are just for decoration.
            #
            $name = '' if $name =~ /&#\d+;/;
	    
	    my $full = $name ? "$name <$email>" : $email;
	    warn "send notification email to $full\n";

	    eval {
		my $mail = Mail::Mailer->new();
		$mail->open({
		    To => $full,
		    Cc => 'Annotation Server <rast@mcs.anl.gov>',
		    From => 'Annotation Server <rast@mcs.anl.gov>',
		    Subject => $subject,
		});
		
		print $mail $body;
		$mail->close();
		$meta->set_metadata($key, "yes");
		$meta->set_metadata("${key}_address", $email);
		$meta->set_metadata("${key}_timestamp", time);
	    };

	    if ($@)
	    {
		warn "Error sending mail to $full: $@\n";
		return 0;
	    }
	    else
	    {
		return 1;
	    }
	}
    }
    return 0;
}


#
# get_status_of_job - this method returns the latest job stage and it's status
# requires the job number and a User object reference
# (implemented as class method as by Terry's request)
#
sub get_status_of_job {
  my ($class, $job_id, $user) = @_;

  return ('no job id given', '') unless ($job_id);
  return ('no user given', '') unless (ref $user);
  
  my $job = $class->new($job_id, $user);

  return ('unknown job', '') unless (ref $job);

  my @keys = ( 'status.uploaded', 'status.rp', 'status.qc', 'status.correction',
	        'status.sims', 'status.bbhs', 'status.auto_assign', 
	        'status.pchs', 'status.scenario', 'status.final' );
  if ($job->metagenome) {
    @keys = ( 'status.uploaded', 'status.preprocess',
	       'status.sims', 'status.sims_postprocess',
	       'status.final' );
  }

  warn "keys=@keys\n";
  foreach my $stage (@keys) {
    my $status = $job->meta->get_metadata($stage) || 'not_started';
    warn "For $stage: $status\n";
    next if ($status eq 'complete');
    return ($stage, $status);
  }

  # if we get here the last stage was complete
  return ($keys[scalar(@keys)-1], 'complete');

}

=head3 compute_job_metrics

 $metrics = $job->compute_job_metrics()

Returns a hash containing information about the job; used for computing aggregate
summary statistics.

=over 4

=item upload_time

Time at which the job was originally uploaded.

=item start_time

Time at which the job began processing.

=item end_normal_time

Time at which the job finished normal processing - exclusive of attribute computation.

=item end_complete_time

Time at which the job finished all processing.

=item successful

True if the job completed successfully.

=item local_user

True if the job was submitted by a "local" user - ANL, UC, FIG. Batch jobs 
are considered ANL.


=cut

sub compute_job_metrics
{
}

#
# Determine the name of the server the job directory is on.
#

sub find_job_fileserver
{
    my($self) = @_;

    my $dir = $self->dir;
    if (-f "$dir/MOVED")
    {
	$dir = &FIG::file_head("$dir/MOVED", 1);
	chomp $dir;
	if ($dir =~ /location\s+is\s+(\S+)/i)
	{	
	    $dir = $1;
	}
    }
    if (! -d $dir)
    {
	warn "find_job_fileserver: jobdir $dir does not exist";
	return;
    }

    if (!open(DF, "df -P -T $dir|"))
    {
	warn "find_job_fileserver: could not open df $dir: $!";
	return;
    }
    # skip header
    $_ = <DF>;
    $_ = <DF>;
    my $ret;
    if (/^([^:]+):(\S+)\s+(\S+)/)
    {
	my($host, $path, $type) = ($1, $2, $3);
	if ($type eq 'lustre')
	{
	    $ret = 'lustre';
	}
	else
	{
	    $ret = $host;
	}
    }
    elsif  (m,^/dev,)
    {
	$ret = `hostname`;
	chomp $ret;
    }
    return $ret;
}



1;
