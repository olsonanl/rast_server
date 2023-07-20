package WebPage::UploadGenome;

use WebApp::WebPage;

1;

our @ISA = qw ( WebApp::WebPage );

use Carp qw( confess );

use FIG_Config;
use Job48;


=pod

=head1 NAME

Upload - an instance of WebPage which handles uploading of organism data.

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

  my $session = $self->application->session;
  my $content = 'unknown action';
  $self->title('Annotation Server - Upload Genome');

  my $action = 'default';
  if (defined($cgi->param('action'))) {
    $action = $cgi->param('action');
  }

  if ($action eq 'default') {
    $content = upload($self, $session, $cgi);
  } elsif ($action eq 'perform_upload') {
    $content = perform_upload($self, $session, $cgi);
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
    
    # check for previous upload
    if ($cgi->param('genus')) {
      $content .= $self->perform_upload($session, $cgi);
    }
    
    $content .= $self->start_form;
    
#     $content .= "<h1>Upload Genome</h1><p>A prokaryotic genome in one or more contigs can be uploaded in a single <a target=_blank href='http://en.wikipedia.org/wiki/Fasta_format'>FASTA</a> format file. 
# Our pipeline will use the taxonomy identifier as a handle for the genome. Therefore if at all possible please input the numeric <a href='http://www.ncbi.nlm.nih.gov/Taxonomy/taxonomyhome.html/index.cgi'>taxonomy identifier</a> and genus, species and strain below.

# <p><strong>Email notification:</strong> An email will be sent once the automatic annotation has finished or in case user intervention is required.</p>
# </p><p><strong>Confidentiality information:</strong> Data entered into the server will not be used for any purposes or in fact integrated into the main SEED environment, it will remain on this server for 120 days or until deleted by the submitting user. <p>
# <p>If you use the results of this annotation in your work, please cite:
# <pre>Overbeek, R. et al
# The Subsystems Approach to Genome Annotation and its Use in the Project to Annotate 1000 Genomes
# Nucleic Acids Res 33(17) 2005
# </pre></p>";

    $content .= "<h1>Upload Genome</h1> <p>A prokaryotic genome in one or more contigs should be uploaded in a single <a target=_blank href='http://en.wikipedia.org/wiki/Fasta_format'>FASTA</a> format file. 
Our pipeline will use the taxonomy identifier as a handle for the genome. Therefore if at all possible please input the numeric <a href='http://www.ncbi.nlm.nih.gov/Taxonomy/taxonomyhome.html/index.cgi'>taxonomy identifier</a> and genus, species and strain below.
<br>Please note, that only if you submit all relevant contigs (i.e. all chromosomes, if more then one, and all plasmids) that comprise the genomic information of your organism of interest in one job, Features like <i>Metabolic Reconstruction</i> and <i>Scenarios</i> will give you a coherent picture.

<p><strong>Email notification:</strong> An email will be sent once the automatic annotation has finished or in case user intervention is required.</p>
</p><p><strong>Confidentiality information:</strong> Data entered into the server will not be used for any purposes or in fact integrated into the main SEED environment, it will remain on this server for 120 days or until deleted by the submitting user. <p>
<p>If you use the results of this annotation in your work, please cite:
<pre>Overbeek, R. et al
The Subsystems Approach to Genome Annotation and its Use in the Project to Annotate 1000 Genomes
Nucleic Acids Res 33(17) 2005
</pre></p>";
    
    # get url path
    my $url_base = $FIG_Config::cgi_url.'/';

    # write ajax method for on the fly retrieval of lineage information
    $content .= qq~
<script>
function check_ncbi () {
    // get request object
    var http_request;
    if (window.XMLHttpRequest) {
        http_request = new XMLHttpRequest();
        http_request.overrideMimeType('text/xml');
    } else if (window.ActiveXObject) {
        http_request = new ActiveXObject("Microsoft.XMLHTTP");
    }

    // get taxonomy_id
    var taxonomy_id = document.getElementById('taxonomy_id').value;
    var script_url = '~ . $url_base . qq~check_ncbi.cgi?id=' + taxonomy_id; 
    document.getElementById('warning_message').innerHTML = "checking NCBI for taxonomy data, please wait.";
    http_request.onreadystatechange = function() { check_ncbi_result(http_request); };
    http_request.open('GET', script_url, true);
    http_request.send(null);
}

function check_ncbi_result (http_request) {
    if (http_request.readyState == 4) {
        var select_gencode = document.getElementById('genetic_code');
        if (http_request.responseText == "not found") {
             document.getElementById('warning_message').innerHTML = "Taxonomy ID not found at NCBI";
             for (i=0; i< select_gencode.options.length; i++) {
               if ( select_gencode.options[i].value == '11' ) {
                  select_gencode.options[i].selected = true;
               }
             } 
             document.getElementById('domain').value = "Bacteria";
        } else {
             document.getElementById('warning_message').innerHTML = "";
             var result = http_request.responseText.split('<br/>');
             document.getElementById('taxonomy_data').value = result[0];
             for (i=0; i< select_gencode.options.length; i++) {
               if ( select_gencode.options[i].value == result[1] ) {
                  select_gencode.options[i].selected = true;
               }
             } 
             document.getElementById('genus').value = result[2];
             document.getElementById('species').value = result[3];
             document.getElementById('strain').value = result[4];
             if (result[5] == "Bacteria") {
               document.getElementById('domain_b').checked = 1;
             }
             else if (result[5] == "Archaea") {
               document.getElementById('domain_a').checked = 1;
             }
             else {
               document.getElementById('domain_a').checked = 1;
               document.getElementById('domain_b').checked = 1;
             }
        }
    }
}
</script>
~;
    # create little js to uncheck / check things depending on preserve genecalls
    $content .= qq~<script>function preserve_change () {
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

    # create upload information form
    $content .= "<fieldset><legend>Required information:</legend>";
    $content .= "<span id='warning_message' style='color: red;'></span>";
    $content .= "<table>";
    $content .= "<tr><td>Taxonomy ID</td><td><input type='text' name='taxonomy_id' id='taxonomy_id' onblur='check_ncbi();'>&nbsp;&nbsp;<i>(leave blank if NCBI-Taxonomy ID unknown)</i></td></tr>";
    $content .= "<tr><td></td><td>Find the taxonomy id for your organism by searching for it's name in the <a href='http://www.ncbi.nlm.nih.gov/Taxonomy/taxonomyhome.html/' target='_blank'>NCBI taxonomy browser</a>.</td></tr>";
    $content .= "<tr><td>Domain:</td><td><input checked='checked' type='radio' name='domain' id='domain_b' value='Bacteria'>Bacteria <input type='radio' name='domain' id='domain_a' value='Archaea'>Archaea</td></tr>";
    $content .= "<tr><td>Genus</td><td><input type='text' name='genus' id='genus'></td></tr>";
    $content .= "<tr><td>Species</td><td><input type='text' name='species' id='species'></td></tr>";
    $content .= "<tr><td>Strain</td><td><input type='text' name='strain' id='strain'></td></tr>";
    $content .= "<tr><td>Sequence File</td><td><input type='file' name='sequence_file'></td></tr>";
    $content .= "<tr><td></td><td>You can either use <a target=_blank href='http://en.wikipedia.org/wiki/Fasta_format'>FASTA</a> or Genbank format.<li>If in doubt about FASTA, <a target=_blank href='http://thr.cit.nih.gov/molbio/readseq/'>this service</a> allows conversion into FASTA format.</li><li>If you use Genbank, you have the option of preserving the gene calls in the options block below. By default, genes will be recalled.</li></td></tr>";
    $content .= "</table></fieldset>";
    $content .= "<fieldset><legend>Annotation Settings:</legend>";
    $content .= "<table>";
    $content .= "<tr><td>Include into SEED?</td><td><input type='checkbox' name='submit_seed' value='1'><br></td>";
    $content .= "<td><em>If you wish to allow and encourage the inclusion of this genome into the SEED, please mark this box. Please note that by default this is turned off and will not happen without your consent.</em></td></tr>";
    $content .= "<tr><td>Preserve gene calls?</td><td><input type='checkbox' name='keep_genecalls' value='1' id='keep_genecalls' onchange='preserve_change();'><br></td>";
    $content .= "<td><em>If you upload a Genbank file and wish to keep the genecalls, check this option. Otherwise, the genes will be recalled by our pipeline.</em></td></tr>";
    $content .= "<tr><td>Automatically fix errors?</td><td><input type='checkbox' checked='checked' name='fix_errors' value='1' id='fix_errors'><br></td>";
    $content .= "<td><em>The automatic annotation process may run into problems, such as gene candidates overlapping RNAs, or genes embedded inside other genes. To automatically resolve these problems (even if that requires deleting some gene candidates), please check this box.</em></td></tr>";
    $content .= "<tr><td>Fix frameshifts?</td><td><input type='checkbox' name='fix_frameshifts' id='fix_frameshifts'><br></td>";
    $content .= "<td><em>If you wish for the pipeline to fix frameshifts, check this option. Otherwise frameshifts will not be corrected.</em></td></tr>";
    $content .= "<tr><td>Backfill gaps?</td><td><input type='checkbox' name='backfill_gaps' checked='checked' value='1' id='backfill_gaps'><br></td>";
    $content .= "<td><em>If you wish for the pipeline to blast large gaps for missing genes, check this option.</em></td></tr>";
    $content .= "</table></fieldset>";
    $content .= "<input type='hidden' name='taxonomy_data' id='taxonomy_data' value='Bacteria'>";
    $content .= "<p>By filling answering the following questions you will help us improve our ability to track problems in processing your genome. A future version will be using the parameters to optimize the pipeline.</p>";
    $content .= "<fieldset><legend>Optional information:</legend>";
    $content .= "<table>";
    $content .= "<tr><td>Genetic Code</td><td><select id='genetic_code' name='genetic_code'><option selected='selected' value='11'>11</option><option value='4'>4</option></select></td></tr>";
    $content .= "<tr><td>Sequencing Method</td><td><select name='sequencing_method'><option value='Sanger'>Sanger</option><option value='Sanger_454'>Mix of Sanger and Pyrosequencing</option><option value='454'>pyrosequencing</option><option value='other'>other</option></select></td></tr>";
    $content .= "<tr><td>Coverage</td><td><select name='coverage'><option value='unknown'>unknown</option><option value='lt4'>&lt; 4X</option><option value='4-6'>4-6 X</option><option value='6-8'>6-8 X</option><option value='gt8'>&gt;8 X</option></select></td></tr>";
   $content .= "<tr><td>Number of contigs</td><td><select name='contigs'><option value='unknown'>unknown</option><option value='1'>1</option><option value='2-10'>2-10</option><option value='11-100'>11-100</option><option value='101-500'>101-500</ooption><option value='501-1000'>501-1000</option><option value='1001+'>&gt; 1000</option></select></td></tr>";
    $content .= "<tr><td>Average Read Length</td><td><input type='text' name='average_read_length'>&nbsp;&nbsp;<i>(leave blank if unknown)</i></td></tr>";
    $content .= "</table></fieldset>";
    $content .= "<table><tr><td><input type=submit value='Upload'></td></tr></table>";
    $content .= "</form>";
  } else {
    $cgi->delete('action');
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

  my $content = "";
  
  if ($self->application->authorized(1)) {
    
    # get organism information
    my $genus = $cgi->param('genus');
    my $species = $cgi->param('species');
    my $strain = $cgi->param('strain') || "";
    unless ($genus && $species) {
      return "<span class='warning'>You need to provide both genus and species!</span>";
    }
    
    unless ($cgi->param('sequence_file')) {
      return "<span class='warning'>You need to provide a sequence file!</span>";
    }
    
    my $taxonomy_data = $cgi->param('taxonomy_data') || "";
    $taxonomy_data = $cgi->param('domain') unless ($taxonomy_data);
    my $taxonomy_id = $cgi->param('taxonomy_id') || "666666";
    my $jobdata = { 'taxonomy_id' => $taxonomy_id,
		    'genome'      => "$genus $species $strain",
		    'project'     => $session->user->login."_".$taxonomy_id,
		    'user'        => $session->user->login,
		    'taxonomy' => $taxonomy_data."; $genus $species $strain",
		    'meta' => {},
		    'genetic_code' => $cgi->param('genetic_code') || '11',
		    'sequence_file' => $cgi->param('sequence_file'),
		  };

    $jobdata->{'meta'}->{'submit.suggested'} = 1 if ($cgi->param('submit_seed'));
    $jobdata->{'meta'}->{'genome.genetic_code'} = $cgi->param('genetic_code') || '11';
    $jobdata->{'meta'}->{'genome.sequencing_method'} = $cgi->param('sequencing_method') || 'unknown';
    $jobdata->{'meta'}->{'genome.coverage'} = $cgi->param('coverage') || 'unknown';
    $jobdata->{'meta'}->{'genome.contigs'} = $cgi->param('contigs') || 'unknown';
    $jobdata->{'meta'}->{'genome.average_read_length'} = $cgi->param('genome.average_read_length') || 'unknown';
    $jobdata->{'meta'}->{'correction.automatic'} = 1 if ($cgi->param('fix_errors'));
    $jobdata->{'meta'}->{'keep_genecalls'} = 1 if ($cgi->param('keep_genecalls'));
    $jobdata->{'meta'}->{'correction.frameshifts'} = 1 if ($cgi->param('fix_frameshifts'));
    $jobdata->{'meta'}->{'correction.backfill_gaps'} = 1 if ($cgi->param('backfill_gaps'));
    
    my ($jobid, $msg) = Job48->create_new_job($jobdata);
    if ($jobid) {
      $content .= "<span class='info'>Your file has been uploaded and will be processed as job $jobid.</span><br/>";
      $content .= "<span class='info'>Go back to the <a href='".$self->application->url."?page=Upload'>upload page</a>".
	" to add another annotation job.</span><br/>";
      $content .= "<span class='info'>You can view the status of your projects on the ".
	"<a href='".$self->application->url."?page=Jobs'>status page</a></span><br/>";
    }
    else {
      return "<span class='warning'>There has been an error uploading your job: <br/> $msg</span>";
    }
    
  } 
  else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='".$self->application->url."'>login page</a>.";
  }
  return $content;
}
