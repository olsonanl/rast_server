package RAST::WebPage::UploadGenome2;

use strict;
use warnings;

use FIG_Config;

use FortyEight::JobUpload;

use POSIX;
use File::Basename;
use LWP::UserAgent;
use IO::File;
use File::Temp 'tempdir';

use base qw( WebPage RAST::WebPage::Upload );

use WebConfig;

use Job48;

1;


=pod

=head1 NAME

UploadGenome - upload a genome job

=head1 DESCRIPTION

Upload page for genomes

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("Upload a new genome");
  $self->application->register_component('Ajax', 'Ajax');
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

  my $content = '<h1>Upload a genome</h1>';
  $content .= "<p>The upload page will guide you through the whole process. <br/>The <em>Current Step</em> tab is used to enter all necessary information step by step. <br/>The <em>Upload Summary</em> tab does provide an overview of the current upload.</p>";
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

If we haven't been here before, returns the file upload page parts for metagenomes.
If we have been here before, it will process the uploaded file via the JobUpload
module.

=cut

sub file_upload {
  my ($self) = @_;

  if ($self->application->cgi->param("upload"))
  {
      #
      # We have been given a file to upload.
      #

      my $upload_file = $self->application->cgi->param('upload');	
      my ($fn, $dir, $ext) = fileparse($upload_file, qr/\.[^.]*/);
      my $workdir = tempdir($self->app->session->user->login . '_' .
			    $self->app->session->session_id . '_XXXXXXX',
			    DIR => $FIG_Config::rast_jobs . '/incoming/');
      chmod 0755, $workdir;
      my $upload_job = new JobUpload($workdir);
      my $ok;
      my $errors = [];
      eval {
	  $ok = $upload_job->create_from_filehandle($self->application->cgi->upload('upload'), "$fn$ext",
						    $errors);
      };

      if ($@ || !$ok)
      {
	  #
	  # Bad parse.
	  #
	  my $txt = $self->application->cgi->escapeHTML($@);
	  $txt .= $self->application->cgi->escapeHTML($_ ) . "<p>\n" for @$errors;
	  my $content .= <<END;
<p><strong>There was an error processing your upload:</strong></p><p>
$txt
<p>Please go back to the <a href='?page=UploadGenome2'>genome upload page</a>.</p>
END
	  $self->data('done', 1);
	  return $content;
      }
      else
      {
	  #
	  # Good parse.
	  #
	  $self->application->cgi->param("upload_dir", $workdir);
      }
	   
  }
  
  if ($self->application->cgi->param("upload_dir"))
  {
      #
      # The upload has completed successfully.
      # Report on the status of the upload.
      #

      my $upload_job = new JobUpload($self->application->cgi->param("upload_dir"));

      my $content = $upload_job->html_report();
      
      # we cache it for subsequent steps
      $self->application->cgi->param("upload_check", $content);

      return $content;

  }
  else {

    # upload info text
    my $content = "<p>A prokaryotic genome in one or more contigs should be uploaded in either a single <a target=_blank href='http://en.wikipedia.org/wiki/Fasta_format'>FASTA</a> format file or in a Genbank format file. Our pipeline will use the taxonomy identifier as a handle for the genome. Therefore if at all possible please input the numeric <a href='http://www.ncbi.nlm.nih.gov/Taxonomy/taxonomyhome.html/index.cgi'>taxonomy identifier</a> and genus, species and strain in the following upload workflow.</p>";
    $content .= "<p>Please note, that only if you submit all relevant contigs (i.e. all chromosomes, if more then one, and all plasmids) that comprise the genomic information of your organism of interest in one job, Features like <em>Metabolic Reconstruction</em> and <em>Scenarios</em> will give you a coherent picture.</p>";
    $content .= "<p><strong>Confidentiality information:</strong> Data entered into the server will not be used for any purposes or in fact integrated into the main SEED environment, it will remain on this server for 120 days or until deleted by the submitting user. <p>";
    $content .= '<p><strong>If you use the results of this annotation in your work, please cite:</strong><br/><em>The RAST Server: Rapid Annotations using Subsystems Technology.</em><br/>Aziz RK, Bartels D, Best AA, DeJongh M, Disz T, Edwards RA, Formsma K, Gerdes S, Glass EM, Kubal M, Meyer F, Olsen GJ, Olson R, Osterman AL, Overbeek RA, McNeil LK, Paarmann D, Paczian T, Parrello B, Pusch GD, Reich C, Stevens R, Vassieva O, Vonstein V, Wilke A, Zagnitko O.<br/><em>BMC Genomics, 2008, [ <a href="http://www.ncbi.nlm.nih.gov/pubmed/18261238" target="_blank">article</a> ]</em></p>';
    
    $content .= "<p><strong>File formats:</strong> You can either use <a target=_blank href='http://en.wikipedia.org/wiki/Fasta_format'>FASTA</a> or Genbank format. </p>";
    $content .= "<ul><li>If in doubt about FASTA, <a target=_blank href='http://thr.cit.nih.gov/molbio/readseq/'>this service</a> allows conversion into FASTA format.</li>";
    $content .= "<li>If you use Genbank, you have the option of preserving the gene calls in the options block below. By default, genes will be recalled.</li></ul>";

    $content .= "<p><strong>Please note:</strong> This service is intended for complete or nearly complete prokaryotic genomes. For now we are not able to reliably process sequence data of very small size, like small plasmid, phages or fragments.</p>";

    # create upload information form
    $content .= $self->start_form();
    $content .= "<fieldset><legend> File Upload: </legend><table>";
    $content .= "<tr><td>Sequences File</td><td><input type='file' name='upload'></td></tr>";
    $content .= "</table></fieldset>";
    $content .= "<p><input type='submit' name='nextstep' value='Upload file and go to step 2'></p>";
    $content .= "</form>";
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

  # check taxonomy
  my $taxonomy_ok = 1;
  my $tax = $self->application->cgi->param("taxonomy_id");
  if ($tax) {
    unless ($tax =~ /^\d+$/) {
      $self->application->add_message('warning', "Taxonomy IDs do only contain digits. Please check your input or leave it blank if unknown.");
      $taxonomy_ok = 0;
    }
  }

  # check if all information were entered
  if ($self->application->cgi->param("genus") and
      $self->application->cgi->param("species") and
      $self->application->cgi->param("domain") and
      $self->application->cgi->param("genetic_code") and
      $taxonomy_ok
     ) {
    
    # remove leading and trailing spaces from genus and species
    my $g = $self->application->cgi->param("genus");
    my $s = $self->application->cgi->param("species");
    $g =~ s/^\s+//;
    $g =~ s/\s+$//;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    $self->application->cgi->param("genus", $g);
    $self->application->cgi->param("species", $s);

    # check if genus and species are correctly formatted
    if (($g =~ /^\w+$/) && ($s =~ /^\w+$/)) {
      $form = 0;
      
      # print summary
      unless ($form) {
	my $content = '<p><strong>Assigned following organism information to the upload:</strong></p>';
	if ($self->application->cgi->param("taxonomy_id")) {
	  $content .= '<p>Taxonomy ID: '.$self->application->cgi->param("taxonomy_id").'</p>';
	}
	else {
	  $content .= '<p>Taxonomy ID: <em>unknown, will be assigned automatically</em></p>';
	}
	$content .= '<p>Lineage: '.$self->application->cgi->param("lineage").'</p>'
	  if ($self->application->cgi->param("lineage"));
	$content .= '<p>Domain: '.$self->application->cgi->param("domain").'</p>';
	$content .= '<p>Genus: '.$self->application->cgi->param("genus").'</p>';
	$content .= '<p>Species: '.$self->application->cgi->param("species").'</p>';
	$content .= '<p>Strain: '.$self->application->cgi->param("strain").'</p>';
	$content .= '<p>Genetic Code: '.$self->application->cgi->param("genetic_code").'</p>';
	
	return $content;
      }    
    } else {
      $self->application->add_message('warning', 'Genus and species may not contain non-word characters');
    }

  }
  else {
    if ($self->application->cgi->param("laststep")) {
      my $missing = [];
      push @$missing, 'Domain' unless ($self->application->cgi->param("domain"));
      push @$missing, 'Genus' unless ($self->application->cgi->param("genus"));
      push @$missing, 'Species' unless ($self->application->cgi->param("species"));
      push @$missing, 'Genetic Code' unless ($self->application->cgi->param("genetic_code"));
      if (@$missing) {
	$self->application->add_message('warning', "Please enter the following data to proceed: ".join(', ',@$missing).".");
      }
    }
  }

  # ask for taxonomy information
  if ($form) {
   
    my $content = $self->application->component('Ajax')->output();
    
    $content .= $self->start_form('taxonomy_info', { 'upload_type' => $self->app->cgi->param('upload_type'),
						     'upload_dir' => $self->app->cgi->param('upload_dir'),
						     'upload_check' => $self->app->cgi->param('upload_check'),
						     });


    #
    # Fill in default information from the upload metadata if present.
    #

    my $upload_job = new JobUpload($self->application->cgi->param("upload_dir"));
    my $meta = $upload_job->meta;
    
    $content .= '<p><strong>Please enter the following information about this organism:</strong></p>';
    
    my $taxonomy = $self->app->cgi->param('taxonomy_id') || $meta->get_metadata('taxonomy_id') || '';
    my $genus = $self->app->cgi->param('genus') || $meta->get_metadata('genus') || '';
    my $species = $self->app->cgi->param('species') || $meta->get_metadata('species') ||'';
    my $strain = $self->app->cgi->param('strain') || $meta->get_metadata('strain') ||'';
    my $archaea = ($self->app->cgi->param('domain') and 
		   $self->app->cgi->param('domain') eq 'Archaea') ? "checked='checked'" : '';
    my $bacteria = ($self->app->cgi->param('domain') and 
		    $self->app->cgi->param('domain') eq 'Bacteria') ? "checked='checked'" : '';
    my $gcvar = $self->app->cgi->param('genetic_code') || $meta->get_metadata('gcvar');
    my $gc4 = ($gcvar eq '4') ? "selected='selected'" : '';
    my $gc11 = ($gcvar eq '1') ? "selected='selected'" : '';

    $content .= "<fieldset><legend> Required information: </legend><table>";
    $content .= "<tr><td><strong>Taxonomy ID:<strong></td>".
      "<td><input type='text' name='taxonomy_id' id='taxonomy_id' value='$taxonomy' onblur='execute_ajax(\"ncbi_lookup\",\"organism\",\"taxonomy_info\",\"Checking NCBI for taxonomy data, please wait.\");'>&nbsp;&nbsp;<i>(leave blank if NCBI-Taxonomy ID unknown)</i></td></tr>";
    $content .= "<tr><td></td><td>Find the taxonomy id for your organism by searching for it's name in the <a href='http://www.ncbi.nlm.nih.gov/Taxonomy/taxonomyhome.html/' target='_blank'>NCBI taxonomy browser</a>.</td></tr></table>";
    $content .= "<div id='organism'><table>";
    $content .= "<tr><td><strong>Domain:</strong></td>".
      "<td><input type='radio' name='domain' id='domain_b' $bacteria value='Bacteria'>Bacteria ".
	"<input type='radio' name='domain' id='domain_a' $archaea value='Archaea'>Archaea</td></tr>";
    $content .= "<tr><td><strong>Genus: </strong></td>".
      "<td><input type='text' name='genus' id='genus' value='$genus'></td></tr>";
    $content .= "<tr><td><strong>Species: </strong></td>".
      "<td><input type='text' name='species' id='species' value='$species'></td></tr>";
    $content .= "<tr><td><strong>Strain: </strong></td><td>".
      "<input type='text' name='strain' id='strain' value='$strain'></td></tr>";
    $content .= "<tr><td><strong>Genetic Code:</strong></td><td><select id='genetic_code' name='genetic_code'>".
      "<option value=''></option><option $gc11 value='11'>11</option><option $gc4 value='4'>4</option></select>&nbsp;For information on genetic codes follow <a href='http://www.ncbi.nlm.nih.gov/Taxonomy/Utils/wprintgc.cgi' target=_blank>this link</a>.</td></tr>";
    $content .= "<tr><td colspan='2'><input type='hidden' name='lineage' value=''></td></tr>";
    $content .= "</table></div></fieldset>";
    $content .= "<p><input type='submit' name='laststep' value='Use this data and go to step 3'></p>";
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

    my $content = '<p><strong>Optional information for quality assurance:</strong></p>';
    $content .= '<p>Sequence method: '.$self->application->cgi->param("sequencing_method").'</p>';
    $content .= '<p>Coverage: '.$self->application->cgi->param("coverage").'</p>';
    $content .= '<p>Number of contigs: '.$self->application->cgi->param("contigs").'</p>';
    $content .= "<p>Average read length: ".($self->application->cgi->param("contigs") || 'unknown').'</p>';

    
    $content .= '<p><strong>RAST Annotation Settings:</strong></p>';
    if ($self->app->cgi->param('submit_seed')) {
      $content .= '<p>Genome will be suggested for inclusion into the SEED.</p>';
    }
    else {
      $content .= '<p><em>Genome will remain private.</em></p>';
    }      

    if ($self->app->cgi->param('keep_genecalls')) {
      $content .= '<p>Keep original gene calls.</p>';
    }
    else {
      $content .= '<p>Use RAST gene calls.</p>';
    }      

    if ($self->app->cgi->param('fix_errors')) {
      $content .= '<p>Automatic error corrections ON</p>';
    }
    else {
      $content .= '<p>Automatic error corrections OFF</p>';
    }     

    if ($self->app->cgi->param('fix_frameshifts')) {
      $content .= '<p>Automatic frame shift corrections ON</p>';
    }
    else {
      $content .= '<p>Automatic frame shift corrections OFF</p>';
    }     
    
    if ($self->app->cgi->param('backfill_gaps')) {
      $content .= '<p>Automatic backfill of gaps ON</p>';
    }
    else {
      $content .= '<p>Automatic backfill of gaps OFF</p>';
    }

    return $content;

  }
  else {

    # create little js to uncheck / check things depending on preserve genecalls
    my $content = qq~<script>function preserve_change () {
	var kg = document.getElementById('keep_genecalls');
	var fe = document.getElementById('fix_errors');
	var ff = document.getElementById('fix_frameshifts');
	var bg = document.getElementById('backfill_gaps');
	if (kg.checked == 1) {
	    fe.checked = 0;
	    ff.checked = 0;
	    bg.checked = 0;
	} else {
	    fe.checked = 1;
	    bg.checked = 1;
	}
     }</script>~;

    $content .= $self->start_form('project', 1);

    $content .= '<p><strong>By filling answering the following questions you will help us improve our ability to track problems in processing your genome:</strong></p>';
    
    my $average_read = $self->app->cgi->param('average_read_length') || '';

    $content .= "<fieldset><legend>Optional information:</legend>";
    $content .= "<table>";
    $content .= "<tr><td>Sequencing Method</td><td><select name='sequencing_method'><option value='Sanger'>Sanger</option><option value='Sanger_454'>Mix of Sanger and Pyrosequencing</option><option value='454'>pyrosequencing</option><option value='other'>other</option></select></td></tr>";
    $content .= "<tr><td>Coverage</td><td><select name='coverage'><option value='unknown'>unknown</option><option value='lt4'>&lt; 4X</option><option value='4-6'>4-6 X</option><option value='6-8'>6-8 X</option><option value='gt8'>&gt;8 X</option></select></td></tr>";
   $content .= "<tr><td>Number of contigs</td><td><select name='contigs'><option value='unknown'>unknown</option><option value='1'>1</option><option value='2-10'>2-10</option><option value='11-100'>11-100</option><option value='101-500'>101-500</ooption><option value='501-1000'>501-1000</option><option value='1001+'>&gt; 1000</option></select></td></tr>";
    $content .= "<tr><td>Average Read Length</td><td><input type='text' name='average_read_length' value='$average_read'>&nbsp;&nbsp;<i>(leave blank if unknown)</i></td></tr>";
    $content .= "</table></fieldset><br>";

    $content .= '<p><strong>Please consider the following options for the RAST annotation pipeline:</strong></p>';

    $content .= "<fieldset><legend> RAST Annotation Settings: </legend>";
    $content .= "<table>";

    my $user = $self->application->session->user;
    if ($user->has_right($self->application, 'edit', 'user', '*')) {
      $content .= "<tr><td>Include into SEED?</td>".
	"<td><input type='checkbox' name='submit_seed' value='1'></td>";
      $content .= "<td><em>If you wish to allow and encourage the inclusion of this genome into the SEED, please mark this box. Please note that by default this is turned off and will not happen without your consent.</em></td></tr>";
    }
    
    # check if the uploaded file is genbank, if so offer preserving genecalls
    if ($self->application->cgi->param('upload_type') && ($self->application->cgi->param('upload_type') eq 'genbank')) {
      $content .= "<tr><td>Preserve gene calls?</td>".
	"<td><input type='checkbox' name='keep_genecalls' value='1' id='keep_genecalls' onchange='preserve_change();'></td>";
      $content .= "<td><em>If you upload a Genbank file and wish to keep the genecalls, check this option. Otherwise, the genes will be recalled by our pipeline.</em></td></tr>";
    }

    $content .= "<tr><td>Automatically fix errors?</td>".
      "<td><input type='checkbox' checked='checked' name='fix_errors' value='1' id='fix_errors'></td>";
    $content .= "<td><em>The automatic annotation process may run into problems, such as gene candidates overlapping RNAs, or genes embedded inside other genes. To automatically resolve these problems (even if that requires deleting some gene candidates), please check this box.</em></td></tr>";
    $content .= "<tr><td>Fix frameshifts?</td>".
      "<td><input type='checkbox' name='fix_frameshifts' id='fix_frameshifts'></td>";
    $content .= "<td><em>If you wish for the pipeline to fix frameshifts, check this option. Otherwise frameshifts will not be corrected.</em></td></tr>";
    $content .= "<tr><td>Backfill gaps?</td>".
      "<td><input type='checkbox' name='backfill_gaps' checked='checked' value='1' id='backfill_gaps'><br></td>";
    $content .= "<td><em>If you wish for the pipeline to blast large gaps for missing genes, check this option.</em></td></tr>";

    if ($self->app->session->user->has_right($self->app, 'edit', 'genome', '*')) {
      $content .= "<tr><td>Turn on debug?</td><td><input type='checkbox' name='debug'></td><td><em>If you wish debug statements to be printed for this job, check this box.</em></td></tr>";
      $content .= "<tr><td>Set verbose level</td><td><input type='text' name='verbose' value='0' size=1></td><td><em>Set this to the verbosity level of choice for error messages.</em></td></tr>";
    }

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

  my $genus = $cgi->param('genus');
  my $species = $cgi->param('species');
  my $strain = $cgi->param('strain') || "";  
  
  unless ($genus && $species) {
    # something broke
  }

  # get the taxonomy info
  my $taxonomy_data = $cgi->param('lineage') || "";
  $taxonomy_data = $cgi->param('domain') unless ($taxonomy_data);
  my $taxonomy_id = $cgi->param('taxonomy_id') || "666666";

  # reopen the upload file
  my $fh = new IO::File "<".$cgi->param('upload_file');
  unless (defined $fh) {
    $self->app->add_message('warning', "There has been an error uploading your job: <br/>Unable to read file.");
    return "<p><em>Failed to upload your job.</em></p>".
      "<p> &raquo <a href='?page=UploadGenome2'>Start over the genome upload</a></p>";
  }

  # assemble job data
  my $job = {'genome'       => "$genus $species $strain",
	     'project'      => $self->app->session->user->login."_".$taxonomy_id,
	     'user'         => $self->app->session->user->login,
	     'taxonomy'     => $taxonomy_data."; $genus $species $strain",
	     'taxonomy_id'  => $taxonomy_id,
	     'genetic_code' => $cgi->param('genetic_code') || 'unknown',
	     'sequence_file' => $fh, #$cgi->param('sequence_file')
	     'meta' => { 'source_file'    => $cgi->param('upload_file'),
			 'genome.genetic_code' => $cgi->param('genetic_code') || 'unknown',
			 'genome.sequencing_method' => $cgi->param('sequencing_method') || 'unknown',
			 'genome.coverage' => $cgi->param('coverage') || 'unknown',
			 'genome.contigs' => $cgi->param('contigs') || 'unknown',
			 'genome.average_read_length' => $cgi->param('genome.average_read_length') || 'unknown',
			 'genome.gc_content' => $cgi->param('gc_content') || 'unknown',
			 'genome.bp_count' => $cgi->param('bp_count') || 0,
			 'genome.contig_count' => $cgi->param('contig_count') || 0,
			 'genome.ambig_count' => $cgi->param('ambig_count') || 0,
			 'import.candidate' => $cgi->param('submit_seed') || 0,
			 'keep_genecalls' => $cgi->param('keep_genecalls') || 0,
			 'correction.automatic' => $cgi->param('fix_errors') || 0,
			 'correction.frameshifts' => $cgi->param('fix_frameshifts') || 0,
			 'correction.backfill_gaps' => $cgi->param('backfill_gaps') || 0,
			 'env.debug' => $cgi->param('debug') || 0,
			 'env.verbose' => $cgi->param('verbose') || 0,
		       },
	    };
  

  my $content = '';

  #
  # Use the job database to create a new job id.
  #

  my $id = $self->create_new_job_id();
  
  # create the jobs
  my ($jobid, $msg) = Job48->create_new_job($job); # (undef, 'Upload disabled.');
  if ($jobid) {
    
    # sync job
    my $sync;
    eval { $sync = $self->app->data_handle('RAST')->Job->init({ id => $jobid }); };
    unless ($sync) {
      warn "Error syncing job $jobid.";
    }
    
    # print success
    $content .= '<p><strong>Your upload will be processed as job '.$jobid.'.</strong> ';
    $content .= "<a href='?page=JobDetails&job=$jobid'>View job status</a></p>";
    $content .= "<p>Go back to the <a href='?page=UploadGenome2'>genome upload page</a>".
      " to add another annotation job.</p>";
    $content .= "<p>You can view the status of your project on the <a href='?page=Jobs'>status page</a>.</p>";

  }
  else {
    $self->app->add_message('warning', "There has been an error uploading your jobs: <br/> $msg");
    $content .= "<p><em>Failed to upload your job.</em></p>";
    $content .= "<p> &raquo <a href='?page=UploadGenome2'>Start over the genome upload</a></p>";
  }

  return $content;

}

sub create_new_job_id
{
    my($self, $jobdir) = @_;

    my $backend = $self->app->data_handle('RAST');
    my $dbh = $backend->dbh;
    
    while (1)
    {
	my $res = $dbh->selectcol_arrayref(qq(SELECT MAX(id) FROM Job));
	my $curmax = 0;
	if (@$res)
	{
	    $curmax = $res->[0];
	}
	
	print "curmax=$curmax\n";
	my $id = $curmax + 1;
	my $job;
	eval {
	    $job = $backend->Job->create({id => $id});
	};
	if ($@)
	{
	    print "Failed\n$@\n";
	    sleep 2;
	    next;
	}
	
	print "Created new job $job " . $job->id . "\n";
	$dbh->commit();
	last;
    }
}


=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  return [ [ 'login' ], ];
}



=pod

=item * B<ncbi_lookup>()

Ajax method to lookup a taxonomy id on the ncbi website

=cut

sub ncbi_lookup {
  my $self = shift;

  my $success = 0;
  my $error = '';

  # get the LWP user agent
  my $ua = LWP::UserAgent->new;
  $ua->timeout(10);
  $ua->env_proxy;
  
  # get the taxonomy id, init other fields
  my $id = $self->app->cgi->param('taxonomy_id') || '';
  my $lineage = '';
  my $domain = '';
  my $genus = '';
  my $species = '';
  my $strain = '';
  my $genetic_code = 11;

  # ncbi lookup
  if ($id) {
  
    my $url="http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=taxonomy&report=sgml&id=$id";
    my $response = $ua->get($url);

    # parse result
    if ($response->is_success) {
      my $ncbi = $response->content; 

      if ($ncbi =~ /\&lt\;GCId\&gt\;(.*)\&lt\;\/GCId\&gt\;/) {
	$genetic_code = $1;
      }

      if ($ncbi =~ /\&lt\;Lineage\&gt\;cellular organisms; (.*)\&lt\;\/Lineage\&gt\;/) {
	$lineage = $1;
	$success = 1;
      }

      if ($lineage =~ /^(Bacteria|Archaea|Eukaryota)\;/) {
	$domain = $1;
      }

      if ($domain eq 'Eukaryota') {
	$error = "The NCBI taxonomy ID you entered is a Eukaryote. Unfortunately RAST currently only handles archaeal and bacterial genomes.";
      }

      if ($ncbi =~ /\&lt\;ScientificName\&gt\;(.*)\&lt\;\/ScientificName\&gt\;(\W*)\&lt\;Rank\&gt\;genus\&lt\;\/Rank\&gt\;/) {
	$genus = $1;
      }
      
      if ($ncbi =~ /\&lt\;ScientificName\&gt\;(.*)\&lt\;\/ScientificName\&gt\;(\W*)\&lt\;Rank\&gt\;species\&lt\;\/Rank\&gt\;/) {
	$species = $1;
	$species =~ s/$genus\s//;
	$species =~ s/ii$/i/;
	$species =~ s/ae$/a/;
      }

      if ($ncbi =~ /\&lt\;ScientificName\&gt\;(.*)\&lt\;\/ScientificName\&gt\;(\W*)\&lt\;OtherNames\&gt\;/) {
	$strain = $1;
	$strain =~ s/$genus\s//;
	$strain =~ s/$species\s//;
      }

      # if we didnt pick up a species and strain, it's likely that $strain contains the species
      # example 1313 hasn't got a species taxon
      unless ($species) {
	$species = $strain;
	$strain = '';
      }

    }

    # lookup failed
    else {
      $error = $response->status_line;
    }

    unless ($success) {
      $error = "$id not found.";
    }
  }

  # set domain selector
  my $archaea  = ($domain eq 'Archaea') ? "checked='checked'" : '';
  my $bacteria = ($domain eq 'Bacteria') ? "checked='checked'" : '';

  # set gcode selector
  my $code11 = ($genetic_code eq '11') ? "selected='selected'" : '';
  my $code4 = ($genetic_code eq '4') ? "selected='selected'" : '';

  my $content = ($error) ? "<p><em>NBCI taxonomy lookup failed: $error<em></p>" : '';

  $content .= "<table>";
  $content .= "<tr><td><strong>Domain:</strong></td>".
    "<td><input $bacteria type='radio' name='domain' id='domain_b' value='Bacteria'>Bacteria ".
      "<input $archaea type='radio' name='domain' id='domain_a' value='Archaea'>Archaea</td></tr>";
  $content .= "<tr><td><strong>Genus: </strong></td>".
    "<td><input type='text' name='genus' id='genus' value='$genus'></td></tr>";
  $content .= "<tr><td><strong>Species: </strong></td>".
    "<td><input type='text' name='species' id='species' value='$species'></td></tr>";
  $content .= "<tr><td><strong>Strain: </strong></td><td>".
    "<input type='text' name='strain' id='strain' value='$strain'></td></tr>";
  $content .= "<tr><td><strong>Genetic Code:</strong></td><td><select id='genetic_code' name='genetic_code'>".
      "<option value=''></option><option $code11 value='11'>11</option><option $code4 value='4'>4</option></select></td></tr>";
  $content .= "<tr><td colspan='2'><input type='hidden' name='lineage' value='$lineage'></td></tr>";
  $content .= "</table>";
  
  return $content;

}
