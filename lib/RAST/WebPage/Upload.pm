package RAST::WebPage::Upload;

use Data::Dumper;
use strict;
use warnings;

use POSIX;
use File::Copy;
use File::Basename;
use File::Temp;
use Archive::Tar;
# use Archive::Zip;

use base qw( WebPage );
use WebConfig;

1;


=pod

=head1 NAME

Upload - an instance of WebPage which displays upload forms

=head1 DESCRIPTION

Upload page

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated. 
Check WebConfig::RAST_TYPE and redirect.

=cut

sub init {
  my $self = shift;

  $self->title("Upload a new Job");

  if ($WebConfig::RAST_TYPE eq 'genome') {
    $self->application->redirect('UploadGenome');
  }
  elsif ($WebConfig::RAST_TYPE eq 'metagenome') {
    $self->application->redirect('UploadMetagenome');
  }
  else {
    $self->application->error('Unknown rast server type. Not sure which upload page to show.');
  }

}


=pod

=item * B<save_upload_to_incoming> ()

Stores a file from the upload input form to the incoming directory
in the rast jobs directory. If successful the method writes back 
the two cgi parameters I<upload_file> and I<upload_type>.

=cut

sub save_upload_to_incoming {
  my ($self) = @_;
  
  return if ($self->application->cgi->param("upload_file") and
	     $self->application->cgi->param("upload_type"));

  if ($self->application->cgi->param("upload")) {

    my $upload_file = $self->application->cgi->param('upload');	
    my ($fn, $dir, $ext) = fileparse($upload_file, qr/\.[^.\s]*/);

    my $incoming_jobs = $FIG_Config::rast_incoming_jobs;
    $incoming_jobs = "$FIG_Config::rast_jobs/incoming" if $incoming_jobs eq '';
    
    my $file = File::Temp->new( TEMPLATE => $self->app->session->user->login.'_'.
				            $self->app->session->session_id.'_XXXXXXX',
				DIR => $incoming_jobs,
				SUFFIX => $ext,
				UNLINK => 0,
			      );

    my($buf, $n);
    while (($n = read($upload_file, $buf, 4096)))
    {
	print $file $buf;
    }
    $file->close();
    
    chmod 0664, $file->filename;
    
    # set info in cgi
    $self->application->cgi->param('upload_file', $file->filename);
    my $type = $self->determine_file_format($file->filename);
    $self->application->cgi->param('upload_type', $type);
  }
}


=pod

=item * B<list_files_from_upload> ()

Returns the list of individual files that have been uploaded. If a single
file was uploaded, that files name is returned. If an archive was uploaded,
a list of all files in the archive is returned. Files are returned as
full pathnames. Semantic processing of what files are of what type is
left to the caller.

=cut

sub list_files_from_upload {
    my ($self) = @_;
    
    my @files;

    if ($self->application->cgi->param("upload_file")) {
	
	my $file = $self->application->cgi->param("upload_file") || '';

	my $type = $self->application->cgi->param('upload_type');
	if ($type eq 'archive/tar' or $type eq 'archive/zip')
	{
	    #
	    # Untar the file, since we need to have it extracted at some
	    # point anyway.

	    my $targ = "$file.extract";
	    mkdir($targ);
	    my @content;
	    eval {
		if ($type eq 'archive/tar')
		{
		    @content = untar_file($file, $targ);
		}
		elsif ($type eq 'archive/zip')
		{
		    @content = unzip_file($file, $targ);
		}
	    };
	    if ($@)
	    {
		$self->application->error("Error unpacking uploaded tarfile: $@");
		return;
	    }

	    @files = @content;
#	    foreach my $file (@content)
#	    {
#		my $format = $self->determine_file_format($file);
#		push @files, basename($file) if ($self->is_acceptable_format($format));	  
#	    }

	}
	elsif ($self->application->cgi->param('upload_type') eq 'fasta') {
	    push @files, $file;
	}
	elsif ($WebConfig::RAST_TYPE eq 'genome' and
	       $self->application->cgi->param('upload_type') eq 'genbank') {
	    push @files, $file;
	}
	else {
	    $self->application->error('Unknown file type during upload.');
	    return;
	}
	
    }
    $self->application->cgi->param('upload_file_list', \@files);
    return \@files;
}

sub untar_file
{
    my($tar, $target_dir) = @_;

    my $comp_flag;
    if ($tar =~ /gz$/)
    {
	$comp_flag = "-z";
    }
    elsif ($tar =~ /bz2$/)
    {
	$comp_flag = "-j";
    }
    else
    {
	my $ftype = `file $tar`;
	if ($ftype =~ /gzip/)
	{
	    $comp_flag = "-z";
	}
	elsif ($ftype =~ /bzip2 compressed/)
	{
	    $comp_flag = "-j";
	}
    }
    
    my @tar_flags = ("-C", $target_dir, "-v", "-x", "-f", $tar, $comp_flag);
    
    warn "Run tar with @tar_flags\n";
    
    my(@tar_files);

    #
    # Extract and remember filenames.
    #
    # Need to do the 'safe-open' trick here since for now, tarfile names might
    # be hard to escape in the shell.
    #
    
    open(P, "-|", "tar", @tar_flags) or die("cannot run tar @tar_flags: $!");
    
    while (<P>)
    {
	chomp;
	my $path = "$target_dir/$_";
	warn "Created $path\n";
	push(@tar_files, $path);
    }
    if (!close(P))
    {
	die("Error closing tar pipe: \$?=$? \$!=$!");
    }

    return @tar_files;
}

sub unzip_file
{
    my($zip, $target_dir) = @_;

    my @unzip_flags = ("-o", $zip, "-d", $target_dir);
    
    warn "Run unzip with @unzip_flags\n";
    
    my(@files);

    #
    # Extract and remember filenames.
    #
    # Need to do the 'safe-open' trick here since for now, tarfile names might
    # be hard to escape in the shell.
    #
    
    open(P, "-|", "unzip", @unzip_flags) or die("cannot run unzip @unzip_flags: $!");
    
    while (<P>)
    {
	chomp;
	if (/^\s*[^:]+:\s+(.*?)\s*$/)
	{
	    my $path = $1;
	    if ($path !~ m,^/,)
	    {
		$path = "$target_dir/$path";
	    }
	    warn "Created $path\n";
	    push(@files, $path);
	}
    }
    if (!close(P))
    {
	die("Error closing unzip pipe: \$?=$? \$!=$!");
    }

    return @files;
}



=pod
    
=item * B<is_acceptable_format> (I<format>)

Returns true if that file format is accepted by this RAST server type

=cut

sub is_acceptable_format {
  my ($self, $format) = @_;
  
  if ($WebConfig::RAST_TYPE eq 'genome') {
    return 1 if ($format and ($format eq 'fasta' or $format eq 'genbank'));
  }
  elsif ($WebConfig::RAST_TYPE eq 'metagenome') {
    return 1 if ($format and $format eq 'fasta');
  }
  else {
    $self->application->error('Unknown rast server type. Not sure which upload page to show.');
  }
  
  return 0;  
}


=pod

=item * B<determine_file_format> (I<filename>, I<dont_read>)

Returns the format type of the file: currently fasta, genbank or archive.
If I<dont_read> is provided and true, it will not try to read the file.

=cut

sub determine_file_format {
  my ($self, $file, $dont_read) = @_;

  my $format = '';
  my ($fn, $dir, $ext) = fileparse($file, qr/\.[^.]*/);

  # first let's try to check by file extension
  if ($ext =~ /\.(fasta|fa|fas|fsa|fna)$/i) {
    $format = 'fasta';
  }
  elsif ($ext =~ /\.(gbk|genbank|gb)$/) {
    $format = 'genbank';
  }
  elsif ($ext =~ /\.(qual)$/) {
    $format = 'qual';
  }
  elsif ($file =~ /\.tgz$/ or 
	 $file =~ /\.tar\.gz$/ or
	 $file =~ /\.gz$/) {
    $format = 'archive/tar';
  }
  elsif ($file =~ /\.zip$/) {
    $format = 'archive/zip';
  }

  warn "dff: file='$file' fn='$fn' ext='$ext' fmt=$format\n";
  return $format if ($format or $dont_read);

  # file extension didnt tell us anything, let's read some lines
  my $line = 0;
  open(FILE, "<$file") ||
    die "Unable to read file $file.";
  while(<FILE>) {
    $line++;
    chomp;
    next unless $_;
    if (/LOCUS\s+(\S+)/os) {
      $format = 'genbank';
      last;
    }
    elsif (/^>(\S+)/) {
      $format = 'fasta';
      last;
    }
    
    # after 10 lines we give up
    last if ($line>10);

  }
  close(FILE);

  return $format;

}



=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  return [ [ 'login' ], [ 'edit', 'user' ] ];
}


