package WebPage::UploadMetaGenome;

use WebApp::WebPage;

1;

our @ISA = qw ( WebApp::WebPage );

use Carp qw( confess );

use File::Basename;
use File::Temp;
use Archive::Tar;

use FIG_Config;

use Job48;

=pod

=head1 NAME

Upload - an instance of WebPage which handles uploading of metagenomes

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the Upload page.

=cut

sub output {
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  my $session  = $self->application->session;

  my $content  = '';
  my $warnings = '';

  $self->title('Annotation Server - Upload Meta Genome');

  # if the user presses 'start over', try to remove the file from the previous upload
  if ($cgi->param('start_over') and $cgi->param('tgz')) {
      unlink($cgi->param('tgz'));
  }

  if ($cgi->param('perform_upload_step2')) {
      ($content, $warnings) = perform_upload_step2($self, $session, $cgi);
      if ($warnings) {
          $content = $warnings . upload_step2($self, $session, $cgi);
      }
  }
  elsif ($cgi->param('perform_upload')) {
      ($content, $warnings) = perform_upload($self, $session, $cgi);
      if ($warnings) {
	  $content = $warnings . upload($self, $session, $cgi);
      }
      else {
	  $content = upload_step2($self, $session, $cgi);
      }
  }
  else {
      $content = upload($self, $session, $cgi);
  }

  return $content;
}

=pod

=item * B<upload> ()

Returns the html for the upload page.

=cut

sub upload {
  my ($self, $session, $cgi) = @_;

  my $content = "";
  
  if ($self->application->authorized(1)) {
    
      $content .= $self->start_form;
    
      $content .= "<h1>Upload Meta Genome</h1>";
      $content .= "<p><strong>Please upload either a single plain text file containing all the sequences in FASTA format, or a gzip compressed tar archive (tar.gz) that has your FASTA sequences.</strong></p>";
      $content .= "<p>Please do not upload uncompressed files larger than 30 MB. If your data set is larger, use the compressed format or contact us for other options. If you would like, you can also include the quality files in your archive. The fasta file names should end either *.fna, *.fa, or *.fasta, and the quality files should be named *.qual. The quality files are not currently used in the analysis, but the sequences will be renamed and renumbered along with the fasta sequences.</p>";
      $content .= "<p>If you have trouble with the upload format please email <a href='mailto:mg-rast\@mcs.anl.gov'>mg-rast\@mcs.anl.gov</a>  and we'll be happy to help.</p>";
      $content .= "<p><strong>Email notification:</strong> An email will be sent once the automatic annotation has finished or in case user intervention is required.</p>
<p><strong>Confidentiality information</strong>: Data entered into the server will not be used for any purposes or in fact integrated into the main SEED environment, it will remain on this server for 120 days or until deleted by the submitting user. <p>
<p>If you use the results of this annotation in your work, please cite:
<pre>Overbeek, R. et al
The Subsystems Approach to Genome Annotation and its Use in the Project to Annotate 1000 Genomes
Nucleic Acids Res 33(17) 2005
</pre></p>";
    
    # create upload information form
    $content .= "<fieldset><legend>Step 1:</legend>";
    $content .= "<span id='warning_message' style='color: red;'></span>";
    $content .= "<table>";
    $content .= "<tr><td>Sequences File</td><td><input type='file' name='sequence_file'></td></tr>";
    $content .= "<tr><td></td><td>Please use the compressed and archived sequences file (tar/gz). </td></tr>";
    $content .= "</table></fieldset>";
    $content .= "<input type='hidden' name='metagenome' value='1'>";
    $content .= "<table><tr><td><input type='submit' name='perform_upload' value='Upload file and go to step 2'></td></tr></table>";
    $content .= "</form>";
  } 
  else {
      $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }

  return $content;
}


=pod

=item * B<perform_upload> ()

Performs the upload operation.

=cut

sub perform_upload {
  my ($self, $session, $cgi) = @_;
  
  if ($self->application->authorized(1)) {
    
    unless ($cgi->param('sequence_file')) {
      return ('', "<span class='warning'>You need to provide a sequence file!</span>");
    }
    
    my $upload_file = $cgi->param('sequence_file');	
    my ($fn, $dir, $ext) = fileparse($upload_file, qr/\.[^.]*/);

    my $file = File::Temp->new( TEMPLATE => $session->user->login.'_XXXXXXX',
				DIR => $FIG_Config::rast_jobs . '/incoming/',
				SUFFIX => $ext,
				UNLINK => 0,
			      );
    
    while (<$upload_file>) {
      print $file $_;
    }
    
    chmod 0664, $file;

    # set path to saved upload file in cgi
    if ($ext =~ /\.(fasta|fa|fna)$/) {
	print STDERR $ext;
	$cgi->param('fasta', $file->filename);
    }
    else {
	$cgi->param('tgz', $file->filename);
    }
    
  }
  else {
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }
  
  return '';
  
}


=pod

=item * B<upload_step2> ()

Check content of the uploaded file and ask the user to assign names and descriptions to the files

=cut

sub upload_step2 {
  my ($self, $session, $cgi) = @_;
  
  my $content = "";
  
  if ($self->application->authorized(1)) {
    
      my @files;
      my $file = '';
      if ($cgi->param('tgz')) { 

	  $file = $cgi->param('tgz') || '';
    
	  # get list of files from archive
	  my $tar = Archive::Tar->new;
	  $tar->read($file,1);

	  foreach ($tar->list_files) {
	      push @files, $_ if ($_ =~ /\.fna$/ or
				  $_ =~ /\.fasta$/ or
				  $_ =~ /\.fa$/);
	  }
      }
      elsif ($cgi->param('fasta')) {
	  $file = $cgi->param('fasta');
	  push @files, basename($cgi->param('fasta'));
      }
      
      $content .= $self->start_form;
      $content .= "<fieldset><legend> Step 2: </legend>";
      $content .= "<span id='warning_message' style='color: red;'></span>\n";
      $content .= "<input type='hidden' name='metagenome' value='1'>";
      $content .= "<input type='hidden' name='tgz' value='".$cgi->param('tgz')."'>\n";
      $content .= "<input type='hidden' name='fasta' value='".$cgi->param('fasta')."'>\n";
      $content .= "<input type='hidden' name='files' value='".join(',',@files)."'>\n";
      $content .= "\n<table>\n";
      $content .= "<tr><td colspan='3'>Sequences file: ".basename($file)."</td></tr>\n";
    
      if (scalar(@files)) {
      
	  $content .= "<tr><td colspan='3'>Please enter a project name and description for each of the files from the archive. It is recommended to keep the project name short and precise and to add any additional information on that sample to the description.</td></tr>";
	  $content .= "</table><table>";
	  
	  foreach (@files) {
	      my $genome = $cgi->param($_.'_genome') || '';
	      my $project = $cgi->param($_.'_project') || '';
	      my $description = $cgi->param($_.'_description') || '';
	      
	      $content .= "<tr><th>$_</th><td>Genome Name:</td><td>".
		  "<input type='text' name='$_\_genome' value='$genome'></td></tr>\n";
	      $content .= "<tr><th></th><td>Project Name:</td><td>".
		  "<input type='text' name='$_\_project' value='$project'></td></tr>\n";
	      $content .= "<tr><th></th><td>Description:</td><td>".
		  "<input type='text' name='$_\_description' value='$description'></td></tr>\n";
	  }
	  
	  $content .= "</table></fieldset>";
	  
	  my $altitude = $cgi->param('altitude') || '';
	  my $longitude = $cgi->param('longitude') || '';
	  my $latitude = $cgi->param('latitude') || '';
	  my $time = $cgi->param('time') || '';
	  my $habitat = $cgi->param('habitat') || '';
	  
	  $content .= "<p>The following information are optional for the annotation process, but it's recommended to add them to the extent they are known.</p>";
	  $content .= "<fieldset><legend> Optional information: </legend>";
	  $content .= "<table>";
	  $content .= "<tr><td>Latitude:</td><td><input type='text' name='latitude' value='$latitude'></td><td><em>use Degree:Minute:Second (42d20m00s)</em></td></tr>\n";
	  $content .= "<tr><td>Longitude:</td><td><input type='text' name='longitude' value='$longitude'></td><td><em> or Decimal Degree (56.5000)</em></td></tr>\n";
	  $content .= "<tr><td>Depth or altitude:</td><td><input type='text' name='altitude' value='$altitude'></td><td><em> in Meter (m)</em></td></tr>\n";
	  $content .= "<tr><td>Time of sample collection:</td><td><input type='text' name='time' value='$time'></td><td><em> in Coordinated Universal Time (UCT) YYYY-MM-DD</em></td></tr>\n";
	  $content .= "<tr><td>Habitat:</td><td><input type='text' name='habitat' value='$habitat'></td><td></td></tr>\n";
	  
	  $content .= "</table></fieldset>";
	  
	  
	  $content .= "<table><tr><td><input type='submit' name='perform_upload_step2' value='Finish Upload'>&nbsp;";
	  $content .= "<input type='submit' name='start_over' value='Start over'></td></tr></table>";
      }
      else {
	  $content .= "<tr><td colspan='3'><em>Unfortunately I have not been able to find any ".
	      "fasta files in the upload.</em></td></tr>";
	  $content .= "</table></fieldset>";
	  $content .= "<table><tr><td><input type='submit' name='start_over' value='Start over'></td></tr></table>";
      }
      
      $content .= "</form>";
      
  }
  else {
      $content .= $self->application->error."<br/>Please return to the <a href='".$self->application->url."'>login page</a>.";
  }
  
  return $content;
  
}


=pod

=item * B<perform_upload> ()

Performs the upload operation.

=cut

sub perform_upload_step2 {
  my ($self, $session, $cgi) = @_;
  
  my $content  = '';
  my $warnings = '';
  
  if ($self->application->authorized(1)) {
    
    unless ($cgi->param('files')) {
      $warnings .= "<span class='warning'>Server Error: I lost your uploaded file.!</span>";
    }
    
    return ('', $warnings) if ($warnings);
    
    my @files = split(',',$cgi->param('files'));
    
    my $jobs = [];
    
    foreach my $file (@files) {
      
      unless ($cgi->param($file.'_genome')) {
	$warnings .= "<span class='warning'>You need to provide a genome name for $file!</span><br/>";
      }
      
      unless ($cgi->param($file.'_project')) {
	$warnings .= "<span class='warning'>You need to provide a project name for $file!</span><br/>";
      }
      
      my $job = { # 'taxonomy_id' => '',
		  'genome'      => $cgi->param($file.'_genome'),
		  'project'     => $cgi->param($file.'_project'),
		  'user'        => $session->user->login,
		  'taxonomy'    => '',
		  'metagenome'  => 1,
		  'meta' => { 'source_archive' => $cgi->param('tgz'),
			      'source_fasta'   => $cgi->param('fasta'),
			      'source_file'    => $file,
			      'project.description' => $job->{'description'} || 0,
			      'optional_info.altitude' => $cgi->param('altitude') || '',
			      'optional_info.longitude' => $cgi->param('longitude') || '',
			      'optional_info.latitude' => $cgi->param('latitude') || '',
			      'optional_info.time' => $cgi->param('time') || '',
			      'optional_info.habitat' => $cgi->param('habitat') || '',
			    },
		  'sequence_file' => $cgi->param('sequence_file'),
		};
      
      push @$jobs, $job;
    }
    
    return ('', $warnings) if ($warnings);
    
    my $ids = [];
    foreach my $job (@$jobs) {
      
      my ($jobid, $msg) = Job48->create_new_job($job);
      if ($jobid) {
	push @$ids, $jobid;
      }
      else {
	$warnings .= "<span class='warning'>There has been an error uploading your jobs: <br/> $msg</span>";
      }
    }
	  
    if ($warnings) {
      return ('', $warnings);
    }
    else {
      $content .= "<span class='info'>Your file has been uploaded and will be processed as job(s) ".
	join(', ',@$ids).".</span><br/>";
      $content .= "<span class='info'>Go back to the <a href='".$self->application->url."?page=Upload'>upload page</a>".
	" to add another annotation job.</span><br/>";
      $content .= "<span class='info'>You can view the status of your projects on the ".
	"<a href='".$self->application->url."?page=Jobs'>status page</a></span><br/>";
    }
    
  } 
  else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }

  return $content;

}
