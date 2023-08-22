package RAST::WebPage::UploadMetagenome;

use strict;
use warnings;

use POSIX;
use File::Basename;
use Data::Dumper;
use FIG_Config;
use FreezeThaw qw( freeze thaw );

use Job48;

use base qw( WebPage RAST::WebPage::Upload );

use WebConfig;

1;


=pod

=head1 NAME

UploadMetagenome - upload a metagenome job

=head1 DESCRIPTION

Upload page for metagenomes

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Upload a new metagenome");
  $self->application->register_component('TabView', 'Tabs');

}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->data('done', 0);

  my $tab_view = $self->application->component('Tabs');
  $tab_view->width(800);
  $tab_view->height(180);

  my $content = '<h1>Upload a metagenome</h1>';
  $content .= "<p>The upload page will guide you through the upload process. <br/>The <em>Current Step</em> tab is used to enter all necessary information step by step. <br/>The <em>Upload Summary</em> tab provides an overview of the current upload.</p>";
  my $log = '';

  # step 1: file upload
  my $temp = $self->file_upload();
  if ($self->data('done')) {
    $tab_view->add_tab('Upload Summary', $temp);
    $content .= $tab_view->output;
    return $content;
  }
  else {
    $log .= $temp;
  }

  # step 2: assign project name and description
  $temp = $self->project_info();
  if ($self->data('done')) {
    $tab_view->add_tab('Current Step', $temp);
    $tab_view->add_tab('Upload Summary', $log);
    $content .= $tab_view->output;
    return $content;
  }
  else {
    $log .= $temp;
  }

  # step 3: ask optional stuff
  $temp = $self->optional_info();
  if ($self->data('done')) {
    $tab_view->add_tab('Current Step', $temp);
    $tab_view->add_tab('Upload Summary', $log);
    $content .= $tab_view->output;
    return $content;
  }
  else {
    $log .= $temp;
  }
   

  # if we get here, upload is done
  $log .= $self->commit_upload();
  $tab_view->add_tab('Upload Summary', $log);
  $content .= $tab_view->output."<p></p>";
  return $content;
}




=item * B<file_upload> ()

Returns the file upload page parts for metagenomes

=cut

sub file_upload {
  my ($self) = @_;

  # check for recent file in the upload form
  if ($self->application->cgi->param("upload")) {
    $self->save_upload_to_incoming();
  }
  
  # check if a file was uploaded
  if ($self->application->cgi->param("upload_file")) {
    my $content = '<p><strong>Uploaded one '.$self->application->cgi->param("upload_type").' file.</strong></p>';

    #
    # Unpack data if necessary and get a listing of files.
    #

    my $flist;
    if ($self->app->cgi->param('file_list'))
    {
	($flist) = thaw($self->app->cgi->param('file_list'));
	my ($info) = thaw($self->app->cgi->param('file_info'));
	$self->data('file_info', $info);
	warn "Extracted: ", Dumper($flist, $info);
    }
    else
    {
	my $files = $self->list_files_from_upload();
	
	#
	# Determine which of these files signify a potential job that we
	# need to process. We do this by finding the fasta files that contain
	# sequence data, and looking for .qual files that have the same file base.
	#
	
	my %bases;
	for my $file (@$files)
	{
	    my($base, $path, $suffix) = fileparse($file, qr/\.[^.]*$/);
	    my $format = $self->determine_file_format($file);
	    my $prev = $bases{$base}->{$format};
	    
	    if (defined($prev))
	    {
		warn "MGRAST file_upload(): while processing $file, already have a $format base named $prev\n";
	    }
	    
	    $bases{$base}->{$format} = $file;
	}
	$self->data('file_info', \%bases);
	
	$flist = [];
	for my $base (sort keys %bases)
	{
	    my $fa = $bases{$base}->{fasta};
	    next unless $fa;
	    push(@$flist, basename($fa));
	    
	    #
	    # Run characterize_dna_fasta to get various metrics on the fasta file,
	    # including duplicate sequence/id information.
	    #
	    if (open(P, "-|", "$FIG_Config::bin/characterize_dna_fasta", $fa))
	    {
		while (<P>)
		{
		    chomp;
		    my($k, $v) = split(/\t/);
		    $bases{$base}->{stats}->{$k} = $v;
		}
		close(P);
	    }
	}
	# warn Dumper(\%bases, $flist);
	
	my $fr = freeze($self->data('file_info'));
	$self->app->cgi->param('file_info', $fr);
	$self->app->cgi->param('file_list', freeze($flist));
    }
    
    $self->data('files', $flist);
    warn Dumper($flist);
    
    if (scalar(@{$self->data('files')})) {
      $content .= '<p><strong>Found '.scalar(@{$self->data('files')}).' sequence file(s).</strong></p>';
    }
    else {
      $content .= "<p><em>Unfortunately I have not been able to find any fasta files in the upload.</em></p>";
      $content .= "<p> &raquo <a href='?page=UploadMetagenome'>Start over the metagenome upload</a></p>";
      $self->data('done', 1);
    }

    return $content;
  }
  else {
  
    # upload info text
    my $content = "<p><strong>To upload sequence data to the metagenomics RAST server:</strong></p>";
    $content .= "<p><strong>(1)</strong> You can upload a fasta file containing just the nucleotide sequences.<br/>In this case the file name should end in .fa, .fasta, .fas, .fsa or .fna. <br/>" .
	        "If your sequence file is larger than 30 MB please use the compressed format (below) or contact us for other options.</p>";
    $content .= "<p><strong>(2)</strong> You can compress the sequence file containing just the nucleotide sequences with tar and gzip a popular compression tool. <br/>" .
	        "In this case the compressed file name should end in .tgz and the fasta file should end in .fa, .fasta, .fas, .fsa or .fna.</p>"; 
    $content .= "<p><strong>(3)</strong> Optionally, you can include a quality file along with the sequence file in a single compressed file. To do this, compress both files into a single archive and then upload the archive file. <br/>" .
	        "In this case the sequence file name should end in .fa, .fasta, .fas, .fsa or .fa, the quality file name should end in .qual, and the archive name should end in .tgz.</p>";
     
    # create upload information form
    $content .= $self->start_form(undef, 1);
    $content .= "<fieldset><legend> File Upload: </legend><table>";
    $content .= "<tr><td>Sequences File</td><td><input type='file' name='upload'></td></tr>";
    $content .= "</table></fieldset>";
    $content .= "<p><input type='submit' name='nextstep' value='Upload file and go to step 2'></p>";
    $content .= $self->end_form();

    $self->data('done', 1);

    return $content;

  }  
}


=item * B<project_info> ()

Returns the project info and metagenome name page parts

=cut

sub project_info {
  my ($self) = @_;

  my $form = 1;

  # check if all information were entered
  if ($self->application->cgi->param("project_name")) {
    $form = 0;

    # check names for files
    foreach (@{$self->data('files')}) {
      $form = 1 unless ($self->app->cgi->param($_.'_genome'));
    }
    
    # print summary
    unless ($form) {
      my $content = '<p><strong>Assigned project name to the upload:</strong></p>';
      $content .= '<p>'.$self->application->cgi->param("project_name").'</p>';
      $content .= '<p><strong>Assigned metagenome names and/or descriptions:</strong></p>';
  
      foreach (@{$self->data('files')}) {
	my $genome = $self->app->cgi->param($_.'_genome') || '';
	my $description = $self->app->cgi->param($_.'_description') || 'no description';
	$content .= "<p>$genome ($description)</p>";
      }
      return $content;
    }

  }

  # ask for project and metagenomes names
  if ($form) {
   
    my $content = $self->start_form('project', { 'upload_type' => $self->app->cgi->param('upload_type'),
						 'upload_file' => $self->app->cgi->param('upload_file'),
						 'file_info' => $self->app->cgi->param('file_info'),
						 'file_list' => $self->app->cgi->param('file_list'),
						 });

    $content .= '<p><strong>Please enter a project name and metagenome names for all uploaded files:</strong></p>';
    
    my $project_name = $self->app->cgi->param('project_name') || '';

    $content .= "<fieldset><legend> Project information: </legend><table>";
    $content .= "<tr><td><strong>Project Name:</strong></td>".
      "<td><input type='text' name='project_name' value='$project_name'></td></tr>\n";
    
    #
    # Captions for characterize_dna_fasta opts.
    #
    my @captions = (total_size => 'Total size of sequence data',
		    num_seq => 'Number of sequences',
		    min => "Shortest sequence size",
		    mean => "Mean sequence size",
		    max => "Longest sequence size",
		    bad_data => 'Number of sequences with bad data characters',
		    dup_id_count => "Number of duplicate sequence identifiers",
		    dup_seq_count => "Number of duplicate sequences",
		    );

    foreach (@{$self->data('files')}) {
      $content .= "<tr><td colspan='2'><strong>$_</strong></td><td></td></tr>\n";
	my($base) = /(.*)\.[^.]+$/;
	my $stats = $self->data('file_info')->{$base}->{stats};
	for (my $i = 0; $i < @captions; $i += 2)
	{
	    my($id, $capt) = @captions[$i, $i + 1];
	    my $val = $stats->{$id};
	    if (defined($val))
	    {
		$content .= "<tr><td>$capt</td><td>$val</td></tr>\n";
	    }
	}

      my $genome = $self->app->cgi->param($_.'_genome') || '';
      my $description = $self->app->cgi->param($_.'_description') || '';
      
      $content .= "<tr><td>Metagenome Name:</td><td>".
	"<input type='text' name='$_\_genome' value='$genome'></td></tr>\n";
      $content .= "<tr><td>Description:</td><td>".
	"<input type='text' name='$_\_description' value='$description'></td></tr>\n";
    }
    
    $content .= "</table></fieldset>";
    $content .= "<p><input type='submit' name='nextstep' value='Use this data and go to step 3'></p>";
    $content .= $self->end_form();

    $self->data('done', 1);
    return $content;
  }
}


=item * B<optional_info> ()

Returns the optional info and questions page parts

=cut

sub optional_info {
  my ($self) = @_;

  
  if ($self->app->cgi->param('finish')) {
    my $content = '<p><strong>Assigned metadata to the project name:</strong></p>';
    my $meta = '';
    $meta .= "<p>Longitude: ".$self->app->cgi->param('longitude')."</p>" 
      if ($self->app->cgi->param('longitude'));
    $meta .= "<p>Latitude: ".$self->app->cgi->param('latitude')."</p>" 
      if ($self->app->cgi->param('latitude'));
    $meta .= "<p>Depth or Altitude: ".$self->app->cgi->param('altitude')."</p>" 
      if ($self->app->cgi->param('altitude'));
    $meta .= "<p>Time of sample collection: ".$self->app->cgi->param('time')."</p>" 
      if ($self->app->cgi->param('time'));
    $meta .= "<p>Habitat: ".$self->app->cgi->param('habitat')."</p>" 
      if ($self->app->cgi->param('habitat'));
    $content .= ($meta) ? $meta : '<p><em>No metadata provided.</em></p>';
    
    $content .= '<p><strong>MG-RAST Annotation Settings:</strong></p>';
    if ($self->app->cgi->param('remove_duplicates')) {
      $content .= '<p>Remove exact duplicate sequences during preprocessing.</p>';
    }
    else {
      $content .= '<p>Preprocessing will retain all sequences and not remove exact duplicates.</p>';
    }      

    if ($self->app->cgi->param('public')) {
      $content .= '<p>Metagenome will be made public via MG-RAST.</p>';
    }
    else {
      $content .= '<p>Metagenome will remain private.</p>';
    }      
    
    return $content;

  }
  else {

    my $content = $self->start_form('project', 1);

    $content .= '<p><strong>Please provide us with the following information where possible:</strong></p>';
    
    my $altitude = $self->app->cgi->param('altitude') || '';
    my $longitude = $self->app->cgi->param('longitude') || '';
    my $latitude = $self->app->cgi->param('latitude') || '';
    my $time = $self->app->cgi->param('time') || '';
    my $habitat = $self->app->cgi->param('habitat') || '';

    $content .= "<fieldset><legend> Project metadata: </legend>";
    $content .= "<table>";
    $content .= "<tr><td>Latitude:</td><td><input type='text' name='latitude' value='$latitude'></td><td><em>use Degree:Minute:Second (42d20m00s)</em></td></tr>\n";
    $content .= "<tr><td>Longitude:</td><td><input type='text' name='longitude' value='$longitude'></td><td><em> or Decimal Degree (56.5000)</em></td></tr>\n";
    $content .= "<tr><td>Depth or altitude:</td><td><input type='text' name='altitude' value='$altitude'></td><td><em> in Meter (m)</em></td></tr>\n";
    $content .= "<tr><td>Time of sample collection:</td><td><input type='text' name='time' value='$time'></td><td><em> in Coordinated Universal Time (UCT) YYYY-MM-DD</em></td></tr>\n";
    $content .= "<tr><td>Habitat:</td><td><input type='text' name='habitat' value='$habitat'></td><td></td></tr>\n";
    $content .= "</table></fieldset><br/>";

    $content .= "<fieldset><legend> MG-RAST Options: </legend>";
    $content .= "<table>";
    $content .= "<tr><td>Remove duplicate sequences from the uploaded data:</td>".
      "<td><input type='checkbox' name='remove_duplicates' value='1' checked='checked'></td></tr>\n";
    $content .= "<tr><td>Make this metagenome publically available via MG-RAST:</td>".
      "<td><input type='checkbox' name='public' value='1'></td></tr>\n";
    $content .= "</table></fieldset>";

    $content .= "<p><input type='submit' name='finish' value='Finish the upload'></p>";
    $content .= $self->end_form();

    $self->data('done', 1);
    return $content;
  }


}


=item * B<commit_upload> ()

Finalizes the upload by creating the job directories

=cut

sub commit_upload  {
    my ($self) = @_;
    
    my $cgi = $self->application->cgi;
    
    # prepare data to create job dirs
    my $jobs = [];

    my @optional_parameters = qw(altitude longitude latitude time habitat);
    
    foreach my $file (@{$self->data('files')})
    {
	my $job = { # 'taxonomy_id' => '',
	       'genome'      => $cgi->param($file.'_genome'),
	       'project'     => $cgi->param('project_name'),
	       'user'        => $self->app->session->user->login,
	       'taxonomy'    => '',
	       'metagenome'  => 1,
	       'meta' => { 'source_file'    => $file,
			   'project.description' => $cgi->param($file.'_description') || '',
			   'options.remove_duplicates' => $cgi->param('remove_duplicates') || 0,
			   'options.public' => $cgi->param('public') || 0,
			 },
	      };
	for my $opt (@optional_parameters)
	{
	    my $val = $cgi->param($opt);
	    $val =~ s/\s+$//;
	    $val =~ s/^\s+//;
	    $job->{meta}->{"optional_info.$opt"} = $val;
	}
	my($base) = $file =~ /(.*)\.[^.]+$/;
	my $file_info = $self->data('file_info')->{$base};
	
	while (my($sname, $sval) = each %{$file_info->{stats}})
	{
	    $job->{meta}->{"upload_stat.$sname"} = $sval;
	}
	$job->{meta}->{source_fasta} = $file_info->{fasta};
	$job->{meta}->{source_qual} = $file_info->{qual} if exists $file_info->{qual};
      
	push @$jobs, $job;
  }
    
    
  # create the jobs
  my $ids = [];
  foreach my $job (@$jobs) {
    
    my ($jobid, $msg) = Job48->create_new_job($job);
#    my ($jobid, $msg) = (undef, 'Upload disabled.');# = Job48->create_new_job($job);
    if ($jobid) {
      push @$ids, $jobid;
    }
    else {
      $self->app->add_message('warning', "There has been an error uploading your jobs: <br/> $msg");
    }
  }
	  
  my $content = '';
  if(scalar(@$ids)) {
    $content .= '<p><strong>Your upload will be processed as job(s) '.join(', ',@$ids).'.</strong></p>';
    $content .= "<p>Go back to the <a href='?page=UploadMetagenome'>metagenome upload page</a>".
      " to add another annotation job.</p>";
    $content .= "<p>You can view the status of your project on the <a href='?page=Jobs'>status page</a>.</p>";
  }
  else {
    $content .= "<p><em>Failed to upload any jobs.</em></p>";
    $content .= "<p> &raquo <a href='?page=UploadMetagenome'>Start over the metagenome upload</a></p>";
  }

  return $content;



}

=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  return [ [ 'login' ], ];
}
