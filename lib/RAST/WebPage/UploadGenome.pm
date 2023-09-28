package RAST::WebPage::UploadGenome;

use strict;
use warnings;

use FIG_Config;
use CGI::FormBuilder::Multi;
use Data::Dumper;
use Module::Metadata;

use JobUpload;

use POSIX;
use File::Basename;
use LWP::UserAgent;
use IO::File;
use File::Temp 'tempdir';
use ANNOserver;
use Bio::KBase::GenomeAnnotation::Client;

#
# See if Bio::P3::GenomeAnnotationApp::GenomeAnnotationCore is present.
# This is the BV-BRC annotation application and holds the default
# workflow document used there.
#
# If it is present, prefer that to trying to invoke the annotation service.
#
our $bvbrc_default_workflow;
eval { 
    require Bio::P3::GenomeAnnotationApp::GenomeAnnotationCore;
    $bvbrc_default_workflow = Bio::P3::GenomeAnnotationApp::GenomeAnnotationCore->default_workflow;
};

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

Called when the web page is instantiated.

=cut

sub init {
  my $self = shift;

  $self->title("Upload a new genome");
  $self->application->register_component('Ajax', 'Ajax');

}

sub require_javascript
{
    return [
	    "//code.jquery.com/ui/1.11.1/jquery-ui.js",
	    "$FIG_Config::cgi_url/Html/jquery-1.11.1.js",
	    ];
}

sub require_css
{
    return ["//code.jquery.com/ui/1.11.1/themes/smoothness/jquery-ui.css"];
}

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->data('done', 0);

  my $cgi = $self->application->cgi;
  my $step = $cgi->param('step') || 3;

#  print STDERR Dumper($cgi);

  $self->{template_data} = {};

  my $content;

  $self->{domains} = [qw(Bacteria Archaea Viruses)];
  $self->{genetic_codes} = [qw(11 4)];
	  
  if ($FIG_Config::rast_euk_users->{$self->app->session->user->login})
  {
      $self->{is_euk_user} = 1;
      push(@{$self->{domains}}, "Eukaryota");
      push(@{$self->{genetic_codes}}, 1);
  }

  #
  # This is always allowed now.
  #
  #  if ($FIG_Config::rast_model_users->{$self->app->session->user->login})
  if (1)
  {
      $self->{is_model_user} = 1;
      $self->{template_data}->{allow_model_building} = 1;
  }

  if ($self->app->session->user->is_admin($self->app->backend))
  {
      $self->{is_admin} = 1;
      $self->{template_data}->{user_is_admin} = 1;
  }

  if ($FIG_Config::rast_advanced_users->{$self->app->session->user->login})
  {
      $self->{is_advanced} = 1;
      $self->{template_data}->{user_is_advanced} = 1;
  }

  my $stages = [
	    { name => 'call-features-rRNA-SEED' },
	    { name => 'call-features-tRNA-trnascan' },
	    {
		name => 'call-features-repeat-region-SEED',
		parameters_name => 'repeat_region_SEED_parameters',
		parameters => [
			   {
			       name => 'min_identity',
			       caption => 'Minimum identity',
			       default => 95,
			       validate => 'INT',
			   },
			   {
			       name => 'min_length',
			       caption => 'Minimum length',
			       default => 100,
			       validate => 'INT',
			   },
			       ],
	    },
	    { name => 'call-selenoproteins' },
	    { name => 'call-pyrrolysoproteins' },
#	    { name => 'call-features-insertion-sequences' },
	    { name => 'call-features-strep-suis-repeat' },
	    { name => 'call-features-strep-pneumo-repeat' },
	    { name => 'call-features-crispr' },
	    {
		name => 'call-features-CDS-glimmer3',
		parameters_name => 'glimmer3_parameters',
		parameters => [
			   {
			       caption => 'Minimum training length',
			       default => 2000,
			       name => 'min_training_len',
			       validate => 'INT',
			   }
			       ],
	    },
	    { name => 'call-features-CDS-prodigal' },
	    { name => 'call-features-CDS-genemark' },
	    { name => 'prune_invalid_CDS_features',
		  parameters_name => 'prune_invalid_CDS_features_parameters',
		  parameters => [
			     {
				 name => 'minimum_contig_length',
				 caption => '',
				 default => 0,
				 validate => 'INT',
			     },
			     {
				 name => 'max_homopolymer_frequency',
				 caption => '',
				 default => '0.9',
				 validate => 'FLOAT',
			     },
				 ],
	  },
	    {
		name => 'annotate-proteins-kmer-v2',
		parameters_name => 'kmer_v2_parameters',
		parameters => [
			   {
			       name => 'min_hits',
			       caption => 'Minimum kmer hits required',
			       default => 5,
			       validate => 'INT',
			   },
			   {
			       name => 'annotate_hypothetical_only',
			       caption => 'Only annotate hypothetical proteins',
			       default => '0',
			       options => [['1', 'Yes']],
			   },
			       ],
	    },
	    {
		name => 'annotate-proteins-phage',
		parameters_name => 'phage_parameters',
		parameters => [
			   {
			       name => 'annotate_hypothetical_only',
			       caption => 'Only annotate hypothetical proteins',
			       default => 1,
			       options => [['1', 'Yes']],
			   },
			       ],
	    },
	    { name => 'resolve-overlapping-features',
	      parameters_name => 'resolve_overlapping_features_parameters',
	      parameters => [],
	      },
	    { name => 'classify_amr' },
	    { name => 'annotate-special-proteins' },
	    { name => 'annotate-families_patric' },
	    { name => 'find-close-neighbors' },
	    { name => 'annotate-strain-type-MLST' },
	    { name => 'call-features-prophage-phispy' },
	    { name => 'compute_genome_quality_control',
	      },
	    { name => 'evaluate_genome',
		  parameters_name => 'evaluate_genome_parameters',
		  parameters => [],
	      },
		];
  $self->{template_data}->{stages} = $stages;


  my $default_workflow;
  if ($bvbrc_default_workflow)
  {
      $default_workflow = $bvbrc_default_workflow;
      #print STDERR Dumper(LOCAL_DEFAULT => $default_workflow);
  }
  else
  {
      my $gc = Bio::KBase::GenomeAnnotation::Client->new($FIG_Config::genome_annotation_service);
      $default_workflow = $gc->default_workflow();
      print STDERR Dumper(SVC_DEFAULT => $default_workflow);
  }

  my %default_workflow;
  if (ref($default_workflow))
  {
      $default_workflow{$_->{name}} = $_ foreach @{$default_workflow->{stages}}
  }

  my(@field_stages, @field_stage_params);
  my $num = 0;
  for my $s (@$stages)
  {
      $s->{id} = "stage_$num";
      $num++;
      push(@field_stages, $s->{name});
      for my $p (@{$s->{parameters}})
      {
	  my $fs = $s->{name} . "-" . $p->{name};
	  $p->{field_name} = $fs;
	  push(@field_stage_params, $fs);
      }

      my $n = $s->{name};
      $n =~ s/-/_/g;
      my $def = $default_workflow{$n};
      if ($def)
      {
	  $s->{default} = 1;
	  $s->{condition} = $def->{condition} if $def->{condition};
	  $s->{failure_is_not_fatal} = $def->{failure_is_not_fatal} if exists $def->{failure_is_not_fatal};
      }
  }

  # print STDERR Dumper(\@field_stages, \@field_stage_params);


  my $template_dir = dirname(Module::Metadata->find_module_by_name(__PACKAGE__));
  my $multi = CGI::FormBuilder::Multi->new (
					{
					    fields => [qw(sequences_file)],
					    template => {
						type => 'TT2',
						template => "$template_dir/Upload3p1.tt2",
						variable => 'form',
						data => $self->{template_data},
						engine => { ABSOLUTE => 1 },
					    },
					    submit => "Use this data and go to step 2",
					},
					{
					    fields => [qw(taxonomy_id taxonomy_string domain
							  genus species strain genetic_code
							  ajax_url)],
					    validate => {
						taxonomy_id => 'INT',
					    },
					    required => [qw(domain genus species genetic_code)],
					    template => {
						type => 'TT2',
						template => "$template_dir/Upload3p2.tt2",
						variable => 'form',
						data => $self->{template_data},
						engine => { ABSOLUTE => 1 },
					    },
					    submit => "Use this data and go to step 3",
					},
					{
					    fields => [qw(sequencing_method coverage number_of_contigs read_length
							  submit_seed annotation_scheme rasttk_customize_pipeline gene_caller figfam_version
							  fix_errors fix_frameshifts backfill_gaps build_models
							  determine_family
							  compute_sims
							  enable_debug
							  verbose_level
							  disable_replication
							  ajax_url
							  stage_sort_order
							  ), @field_stages, @field_stage_params],
					    validate => {
						verbose_level => 'INT',
					    },
					    template => {
						type => 'TT2',
						template => "$template_dir/Upload3p3.tt2",
						variable => 'form',
						data => $self->{template_data},
						engine => { ABSOLUTE => 1 },
					    },
					    submit => "Finish the upload",
					},
					    
					    params => $cgi,
					    keepextras => 1,
					    'accept-charset' => 'UTF-8',
					    method => 'post',
					    id => "upload_form",
					    enctype => 'multipart/form-data',
					    );

  my $form = $multi->form;

  if ($form->submitted && $form->validate)
  {
      #
      # Dispatch to the app code for handling the various submissions.
      #
      if ($multi->page == 1)
      {
	  $self->handle_file_upload($multi);
      }
      elsif ($multi->page == 2)
      {
	      #print STDERR Dumper(SUBMIT2 => $cgi->param("taxonomy_string"));

	  my $tax = $cgi->param("taxonomy_string");
	  my @tax = split(/;\s*/, $tax);
	  my $domain = $tax[0] // "";


	  if ($domain =~ /^\s*$/)
	  {
	      $content .= "<h2>Input error</h2>\n";
	      $content .= <<END;
You have not entered any data into the "Taxonomy string" field.
<p>
The Taxonomy string begins with the three valid values,
"Bacteria; ", "Archaea; ", or "Viruses; ".
<p>
The safest way to ensure that the "Taxonomy string" field is filled in correctly
is to look up the NBCI taxonomy-ID for your genome via
the <a href="http://www.ncbi.nlm.nih.gov/Taxonomy/taxonomyhome.html">the NCBI taxonomy site</a>,
enter that ID into the taxonomy-ID box, and click "Fill in form based on NCBI Taxonomy-ID".
<p>
If you do not know your genome's species, you can enter the ID for Genus, Family,
Order, Class, Phylum, or Domain. For example, if you have entered "Streptococcus sp."
into the "Genus" and "Species" fields, you can enter '1301', the Taxonomy-ID
for genus Streptococcus, into the Taxonomy-ID box and click the fill-in button.
The Taxonomy string field will be filled in with a valid taxonomy.
END
	      $content .= "<p>Use the browser's back button to go back to the submission form and correct this error.\n";
	      return $content;
	  }
	  elsif (! grep { $_ eq $domain } @{$self->{domains}})
	  {
	      $content .= "<h2>Input error</h2>\n";
	      $content .= "<p><i>$domain</i> is not a valid domain for the beginning of the taxonomy string which was specified as <i>$tax</i>. It must be one of the following values: <i>@{$self->{domains}}</i>.</p>\n";
	      $content .= "<p>Use the browser's back button to go back to the submission form and correct this error.\n";
	      return $content;
	  }
	  #
	  # Nothing really to do here. The selections get carried thru
	  # because we chose keepextras on the FormBuilder config.
	  #
	  $multi->page++;
      }
      elsif ($multi->page == 3)
      {

	  #
	  # We are good to go. Commit the job to rast.
	  #
	  
	  $content = $self->commit_upload($multi, $stages, $default_workflow);
	  return $content;
      }

      $form = $multi->form;
  }

  print STDERR "here, page=" . $multi->page . "\n";

  if ($multi->page == 1)
  {
      $form->field(name => 'sequences_file',
		   type => 'file');
  }
  elsif ($multi->page == 2)
  {
      #
      # Ick ick ick. This logic needs to get pulled out somewhere. It's in
      # Ajax.pm too.
      #
      my $ajax_url;
      if ($FIG_Config::nmpdr_site_url or $FIG_Config::force_ajax_to_cgi_url) {
	  $ajax_url = "$FIG_Config::cgi_url/ncbi.cgi";
      } else {
	  $ajax_url = $cgi->url( -rewrite => 0 );
	  $ajax_url =~ /(.+)\//;
	  $ajax_url = $1."/ncbi.cgi";
	  $ajax_url =~ s/(http\:\/\/[^\/]+)\:\d+/$1/;
      }
      # warn "set ajax url to $ajax_url\n";

      $form->field(name => "ajax_url",
		   value => $ajax_url,
		   type => 'hidden');
      $form->field(name => 'domain',
		   options => $self->{domains});

      my %gc_explanations = (11 => "11 (Archaea, most Bacteria, most Virii, and some Mitochondria)",
			     4 =>  "4 (Mycoplasmaea, Spiroplasmaea, Ureoplasmaea, and Fungal Mitochondria)",
			     1 =>  "1  (Eukaryotic nuclei)");
      
      $form->field(name => 'genetic_code',
		   options => [ map { [$_, $gc_explanations{$_} ] } @{$self->{genetic_codes}}],
		   type => 'radio',
		   columns => 1);
      $form->field(name => 'taxonomy_string',
		   type => 'textarea',
		   rows => 3,
		   cols => 80);
      #
      # The fancy NCBI lookup stuff wants to destroy the form, we need to have
      # a version that modifies the form variables, not replaces the form.
      #
      # $form->field(name => 'taxonomy_id',
      # onblur => 'execute_ajax("ncbi_lookup","organism","taxonomy_info","Checking NCBI for taxonomy data, please wait.");');
      # my $aj = $self->application->component('Ajax')->output();
      # print STDERR "aj=$aj\n";
      # $self->{template_data}->{ajax_component} = $aj;

  }
  elsif ($multi->page == 3)
  {

      $form->field(name => 'sequencing_method',
		   options => [["Sanger", "Sanger"],
			       ["Sanger_454", "Mix of Sanger and Pyrosequencing"],
			       ["454", "Pyrosequencing"],
			       ["other", "other"]]);
      $form->field(name => 'coverage',
		   options => [['unknown', 'unknown'],
			       ['lt4', '<4X'],
			       ['4-6', '4-6 X'],
			       ['6-8', '6-8 X'],
			       ['gt8', '>8X']],
		   value => 'unknown');
      $form->field(name => 'number_of_contigs',
		   options => [['unknown', 'unknown'],
			       ['1', '1'],
			       ['2-10', '2-10'],
			       ['11-100', '11-100'],
			       ['101-500', '101-500'],
			       ['501-1000', '501-1000'],
			       ['1001+', '> 1000']],
		   value => 'unknown');
      $form->field(name => 'submit_seed',
		   options => [[1, 'Yes']]);
      $form->field(name => 'fix_errors',
		   options => [[1, 'Yes']],
		   value => 1);
      $form->field(name => 'fix_frameshifts',
		   options => [[1, 'Yes']]);
      $form->field(name => 'build_models',
		   options => [[1, 'Yes']]);
      $form->field(name => 'determine_family',
		   options => [[1, 'Yes']]);
      $form->field(name => 'backfill_gaps',
		   options => [[1, 'Yes']],
		   value => 1);
      $form->field(name => 'compute_sims',
		   options => [[1, 'Yes']]);
      $form->field(name => 'enable_debug',
		   options => [[1, 'Yes']]);
      $form->field(name => 'disable_replication',
		   options => [[1, 'Yes']],
		   value => 0);
      $form->field(name => 'verbose_level',
		   value => 0);

      $form->field(name => 'stage_sort_order',
		   type => 'hidden');
      $form->field(name => 'rasttk_customize_pipeline',
		   options => [[1, 'Yes']],
		   value => 0,
		   jsclick => 'check_annotation_scheme(this.form)'
		  );
      $form->field(name => 'annotation_scheme',
		   type => "select",
		   options => [['ClassicRAST', 'Classic RAST'],
			       ['RASTtk', 'RASTtk']],
		   #
		   # This sets the default pipeline in the webpage
		   #
		   value => 'RASTtk',
#		   value => 'ClassicRAST',
		   jsclick => 'check_annotation_scheme(this.form)');

      for my $stage (@$stages)
      {
	  my $cname = $stage->{name} . "-condition";
	  $stage->{condition_name} = $cname;
	  $form->field(name => $stage->{name},
		       comment => '',
		       value  => $stage->{default},
		       options => [[1, 'Yes']]);
	  $form->field(name => $cname,
		       type => 'textarea',
		       rows => 1,
		       value  => $stage->{condition});

	  for my $p (@{$stage->{parameters}})
	  {
	      # print STDERR Dumper($p);
	      $form->field(name => $p->{field_name},
			   value => $p->{default},
			   ($p->{validate} ? (validate => $p->{validate}) : ()),
			   ($p->{options} ? (options => $p->{options}) : ()),
			   comment => $p->{caption});
	      # print STDERR Dumper($form);
	  }
      }

      #
      # Now for some special default settings based on the
      # form of our upload.
      #

      my $upload_job = new JobUpload($form->cgi_param("upload_dir"));
      my $meta  = $upload_job->meta;

      my @gene_caller_options;

      my $tax_string = $form->cgi_param('taxonomy_string');
      $tax_string =~ s/\s+/ /g;

      my $domain = $form->cgi_param('domain');
      $self->{template_data}->{domain} = $domain;

#       my $tfile = $upload_job->orgdir . "/TAXONOMY";
#       my $is_euk = 0;
#       if (open(TAX, "<", $tfile))
#       {
# 	  my $t = <TAX>;
# 	  if (defined($t) && $t =~ /^\s*euk/i)
# 	  {
# 	      $is_euk++;
# 	  }
# 	  close(TAX);
#       }

      my $is_euk = $domain =~ /^e/i;
      print STDERR "is_euk=$is_euk\n";

      my $value = 'keep';
      if ($is_euk)
      {
	  $form->field(name => 'backfill_gaps', value => 0);
      }
      else
      {
	  @gene_caller_options = (['rast', 'RAST'],
				  ['glimmer3', 'GLIMMER-3']);
	  $value = 'rast';
      }

      my $feature_counts = $meta->get_metadata('feature_counts');
      if (ref($feature_counts) && $feature_counts->{peg} > 0)
      {
	  push(@gene_caller_options, ['keep', 'Preserve original genecalls']);
      }

      $form->field(name => 'gene_caller',
		   options => \@gene_caller_options,
		   type => "select",
		   value => $value,
		   jsclick => 'check_gene_caller(this.form);');


      #
      # Determine the set of available Kmers
      #
      my $anno = ANNOserver->new();
      my $ds = $anno->get_active_datasets();
      my($default, $sets) = @$ds;
      my @setnames = sort { $a cmp $b } keys %$sets;
      $form->field(name => 'figfam_version',
		   options => \@setnames,
		   type => "select",
		   value => $default);
  }
				
  $content .= $form->render();

  return $content;
}

=item * B<handle_file_upload> ()

If we haven't been here before, returns the file upload page parts for metagenomes.
If we have been here before, it will process the uploaded file via the JobUpload
module.

=cut

sub handle_file_upload {
    my ($self, $multi) = @_;
    
    my $form = $multi->form;
    my $upload_file = $form->cgi_param("sequences_file");
    
    my ($fn, $dir, $ext) = fileparse($upload_file, qr/\.[^.]*/);
    my $login_part = $self->app->session->user->login;
    $login_part =~ s/\s+/_/g;
    my $day = strftime("%Y-%m-%d", localtime);
    my $dir_base = "$FIG_Config::rast_jobs/incoming/$day";
    &FIG::verify_dir($dir_base);
    my $workdir = tempdir($login_part . '_' .
			  $self->app->session->session_id . '_XXXXXXX',
			  DIR => $dir_base);
    chmod 0755, $workdir;
    my $upload_job = new JobUpload($workdir);
    my $ok;
    my $errors = [];
    eval {
	$ok = $upload_job->create_from_filehandle($self->application->cgi->upload('sequences_file'), "$fn$ext",
						  $errors);
    };
  
    if ($@ || !$ok)
    {
	#
	# Bad parse.
	#
	# Populate the error-page template, and include a link back to the upload page.
	#
	my $txt = $self->application->cgi->escapeHTML($@);
	$txt .= $self->application->cgi->escapeHTML($_ ) . "<p>\n" for @$errors;
	
	$self->{template_data}->{errors} = "<pre>\n" .
	    join("", map { $self->application->cgi->escapeHTML($_) . "\n" } $@, @$errors) .
	    "</pre>\n";
	
	return;
    }
    
    
    # Good parse.
    $self->application->cgi->param("upload_dir", $workdir);
    
    
    # The upload has completed successfully.
    # Report on the status of the upload.
    $upload_job = new JobUpload(scalar $self->application->cgi->param("upload_dir"));
    my $meta = $upload_job->{meta};
    

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Perform other error checking to find early errors.
#-----------------------------------------------------------------------
    my ($stats, $stats_contigs, $chars, $seqs, $N50, $s);

# Ensure there is any sequence data.
    {
	$stats = $upload_job->meta->get_metadata("stats_split_contigs");
	if ($stats->{chars} == 0)
	{
	    $self->{template_data}->{errors} = "<p>Your genome did not contain any sequence data.</p>\n" .
		$upload_job->html_report();
	    
	    return;
	}
    }

#
# Reject tiny fragments
#
    $stats_contigs = $meta->get_metadata("stats_contigs");
    print STDERR Dumper($stats_contigs);
    
    $chars = $stats_contigs->{chars};
    $seqs  = $stats_contigs->{seqs};
    $s = ($seqs == 1) ? 's' : '';
    
    if ($chars < 4000)
    {
	$self->{template_data}->{errors} = <<END_META;
<p>We are sorry, but your job appears to be too small for RAST to analyze.<br>
<p>Please note that RAST is not a BLAST-like service.
 RAST is designed to annotate complete or nearly complete assembled prokaryotic genomes,
 not small fragments.<br>
<p>Your upload contained $chars bases in $seqs contig$s.
Since a typical prokaryotic protein-encoding gene is about 
1 kbp long, your contigs is far too short to have a significant
probability of containing enough highly conserved genes
for RASTto self-train on.
<p>
We recommend that a user submit enough sequence data in a job
to provide at least 100 untruncated, highly conserved genes, 
and ideally a genome that is at least 97% completely sequenced
and assembled, with more than 70% of its data in contigs 
longer than 20 kbp, i.e., an "N70" of at least 20,000.
<p>
While we have added code to RAST that attempts to support
isolated plasmids, modest-sized fragments, and phages, it is still best
to provide as much sequence data as you have available 
for your entire genome, even if you are only interested
in this one contig. The more sequence data you provide,
and the more complete your genome is, the better RAST&rsquo;s analysis
will be.
<p>
If your submission is a complete plasmid, and you do not have 
the sequence for the main chromosome of the host genome,
RAST will sometimes succeed if you include the main chromosome
of a closely related strain. 
<p>Again, we are sorry that RAST had problems with your job.
 We hope that should you have a complete or nearly complete assembled whole genome,
 you will again consider using RAST to annotate your genome.<br>
<p>Would you like to upload another file?<br>
END_META
      
        $upload_job->html_report();
	return;
    }


#
# Reject probable metgagenomes
#
    $stats_contigs = $meta->get_metadata("stats_contigs");
    print STDERR Dumper($stats_contigs);
    
    $chars = $stats_contigs->{chars};
    $seqs  = $stats_contigs->{seqs};
    $N50 = ($seqs == 1) ? $stats_contigs->{chars} : $stats_contigs->{N50};
    
    $s = ($seqs == 1) ? '' : 's';
    
    if (($chars > 20_000_000) || ($seqs > 5_000) || ($N50 < 2000))
    {
	$self->{template_data}->{errors} = <<END_META;
<p>We are sorry, but your job appears to still be too low quality for RAST to analyze.<br>

<p>Please note that RAST is not a BLAST-like service.
 RAST is designed to annotate complete or nearly complete assembled prokaryotic genomes,
 not metagenomes or unassembled raw reads.<br>

<p>Your upload contained $chars bases in $seqs contig$s, and an N50 of $N50,
 which are more typical of a metagenome or unassembled reads than an assembled genome.<br>

<p>Since your assembly more nearly resembles a metagenome rather than a finished genome,
 we recommend that at a minimum you delete contigs shorter than 2 kbp,
 and that you consider resubmitting it to one of our sister services,
 the <A HREF=\"https://docs.patricbrc.org//tutorial/metagenomic_binning/metagenomic_binning.html\">PATRIC Metagenome binning service,</A>
 or <A HREF=\"http://metagenomics.anl.gov/\">MG-RAST</A>
 or <A HREF=\"http://edwards.sdsu.edu/rtmg/\">Real-Time Metagenomics</A>,
 or that you use the
 <A HREF=\"http://blog.theseed.org/servers/installation/distribution-of-the-seed-server-packages.html\">myRAST</A>
 recipe located
 <A HREF=\"http://blog.theseed.org/servers/2010/09/an-etude-relating-to-a-metagenomics-sample.html\">here</A>.<br>

<p>If your jobs consists of unassembled reads, please consider using the
<A HREF=\"https://docs.patricbrc.org/tutorial/genome_assembly/assembly.html\">PATRIC automated genome assembly service</A>.<br>

<p>Again, we are sorry that RAST had problems with your job.
 We hope that, should you have a complete or nearly complete assembled whole genome,
 you will again consider using RAST to annotate your genome.<br>

<p>Would you like to upload another file?<br>
END_META
      
        $upload_job->html_report();
	return;
    }


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Ensure there at least 100k chars in sequences longer than 2k
# in the split contigs.
# Currently disabled because the required metadata are not yet available
#-----------------------------------------------------------------------
    if (0) {
	my $seq_over_2k = $upload_job->meta->get_metadata("bp_in_seqs_over_2k_split_contigs");
	if ($seq_over_2k < 100_000)
	{
	    my $str = $seq_over_2k == 0 ? "had no" : "only had $seq_over_2k";
	    $self->{template_data}->{errors} = <<END_TOO_SMALL;
<p>In order for RAST to process your data, it must contain at least 100,000 characters
 in contigs longer than 2,000 characters.
 Your upload $str characters in contigs longer than 2,000 characters.</p>
END_TOO_SMALL
            $upload_job->html_report();
	
	    return;
	}
    }


  #
  # Compute taxonomy string.
  #
  # Hm, this was already available in TAXONOMY file.
  #

#   my $tax_id = $meta->get_metadata('taxonomy_id');
#   my $tax_string;
#   if (defined($tax_id))
#   {
#       my $tax_info = $self->get_taxonomy_data($tax_id);
#       $tax_string = $tax_info->{taxonomy};
#       if ($tax_string ne '')
#       {
# 	  $meta->set_metadata("taxonomy_string", $tax_string);
# 	  if (open(T, ">", $upload_job->orgdir . "/TAXONOMY"))
# 	  {
# 	      print T "$tax_string\n";
# 	  }
#       }
#   }

  my $txt = $upload_job->html_report();
  $self->{template_data}->{statistics} = $txt;

  $self->application->cgi->param("upload_check", $txt);

  $multi->page++;

  $form = $multi->form;

  #
  # Fill in defaults from the job.
  #

  my $gc = $meta->get_metadata('genetic_code');
  
  my $tax_string;
  if (open(T, $upload_job->orgdir . "/TAXONOMY"))
  {
      $tax_string = <T>;
      if (defined($tax_string) && $tax_string =~ /^\s*(\w)/)
      {
	  my $d;
	  $d = 'Bacteria' if uc($1) eq 'B';
	  $d = 'Archaea' if uc($1) eq 'A';
	  $d = 'Virus' if uc($1) eq 'V';
	  $d = 'Eukaryota' if uc($1) eq 'E' && $self->{is_euk_user};
	  $form->field(name => 'domain', value => $d);
	  if (!defined($gc) && $d eq 'Eukaryota')
	  {
	      $gc = 1;
	      $meta->set_metadata("genetic_code", $gc);
	  }

      }
      close(T);
  }

  $form->field(name => 'genus',
	       validate => '/^[\x00-\x7f]*$/',
	       value => ($meta->get_metadata('genus') || 'Unknown'));
  $form->field(name => 'species',
	       validate => '/^[\x00-\x7f]*$/',
	       value => ($meta->get_metadata('species') || 'sp.'));
  $form->field(name => 'strain',
	       validate => '/^[\x00-\x7f]*$/',
	       value => $meta->get_metadata('strain'));
  $form->field(name => 'taxonomy_id',
	       validate => '/^\d*$/',
	       value => $meta->get_metadata('taxonomy_id'));
  $form->field(name => 'taxonomy_string',
	       validate => '/^[\x00-\x7f]*$/',
	       value => $tax_string);

  $form->field(name => 'genetic_code',
	       value => $gc);

}


=item * B<commit_upload> ()

Finalizes the upload by creating the job directory.

=cut

sub commit_upload  {
    my ($self, $multi, $stages, $default_workflow) = @_;

    my $form = $multi->form;

    my $cgi = $self->application->cgi;

    if (0) {

        open(L, ">", "/tmp/out.$$");
        print L Dumper($form, $cgi);
        close(L);
    }
    
    my $genus = $cgi->param('genus');
    my $species = $cgi->param('species');
    my $strain = $cgi->param('strain') || "";  
  
    unless ($genus && $species) {
	# something broke
    }

    # get the taxonomy info
    my $taxonomy_data = $cgi->param('taxonomy_string');
    $taxonomy_data =~ s/\s+/ /g;
	
    $taxonomy_data = $cgi->param('domain') unless ($taxonomy_data);
    my $taxonomy_id = $cgi->param('taxonomy_id') || "6666666";

    my $genome = join(" ", $genus, $species, (defined($strain) && $strain ne '') ? $strain : ());

    my $full_taxonomy = "$taxonomy_data; $genome";


    # assemble job data
    my $job = {
	'genome'       => $genome,
	'project'      => $self->app->session->user->login."_".$taxonomy_id,
	'user'         => $self->app->session->user->login,
	'taxonomy'     => $full_taxonomy,
	'taxonomy_id'  => $taxonomy_id,
	'genetic_code' => $cgi->param('genetic_code') || 'unknown',
	'genus'	       => $genus,
	'species'      => $species,
	'strain'       => $strain,
	'meta' => {
	}
    };

    my $upload_job = new JobUpload(scalar $self->application->cgi->param("upload_dir"));
    my $meta = $upload_job->meta;

    #
    # This triggers RAST to use the created upload directory as the source of
    # the job. It will need to renumber the job into the genome ID that
    # was allocated by the clearinghouse.
    #
    $job->{upload_dir} = $self->application->cgi->param("upload_dir");

    for my $key (qw(upload_filename original_genbank clean_genbank original_fasta clean_fasta))
    {
	my $val = $meta->get_metadata($key);
	if (defined($val))
	{
	    $job->{meta}->{$key} = $val;
	}
    }
    $job->{meta}->{incoming_data_dir} = $job->{upload_dir};

    for my $key (qw(genbank_org_list stats_contigs stats_split_contigs feature_counts))
    {
	my $val = $meta->get_metadata($key);
	if (defined($val))
	{
	    $job->{meta}->{"genome.$key"} = $val;
	}
    }

    for my $key (qw(genetic_code sequencing_method coverage contigs average_read_length))
    {
	my $val = $cgi->param($key);
	$job->{meta}->{"genome.$key"} = $val || 'unknown';
    }
    my $stats = $meta->get_metadata("stats_split_contigs");
    $job->{meta}->{"genome.gc_content"} = $stats->{gc};
    $job->{meta}->{"genome.N50"} = $stats->{N50};
    $job->{meta}->{"genome.L50"} = $stats->{L50};
    $job->{meta}->{"genome.bp_count"} = $stats->{chars};
    $job->{meta}->{"genome.contig_count"} = $stats->{seqs};
    $job->{meta}->{"genome.ambig_count"} = $stats->{ambigs};
    $job->{meta}->{"genome.domain"} = $cgi->param('domain');
    $job->{meta}->{"genome.taxonomy"} = $full_taxonomy;
    $job->{meta}->{"import.candidate"} = $cgi->param('submit_seed') || 0;

    $job->{meta}->{annotation_scheme} = $cgi->param('annotation_scheme');

    if ($cgi->param('domain') eq 'Virus')
    {
	$cgi->param('fix_errors', 0);
	$job->{meta}->{'correction.disabled'} = 1;
    }

    if ($cgi->param('gene_caller') eq 'glimmer3')
    {
	$job->{meta}->{'keep_genecalls'} = 1;
	$job->{meta}->{'use_glimmer'} = 1;
	$cgi->param('fix_errors', 0);
	$cgi->param('fix_frameshifts', 0);
	$cgi->param('backfill_gaps', 0);
	$cgi->param('determine_family', 0);
    }
    elsif ($cgi->param('gene_caller') eq 'keep')
    {
	$job->{meta}->{'keep_genecalls'} = 1;
	$cgi->param('fix_errors', 0);
	$cgi->param('fix_frameshifts', 0);
	$cgi->param('backfill_gaps', 0);
	$job->{meta}->{'correction.disabled'} = 1;
    }

    $job->{meta}->{'correction.automatic'} = $cgi->param('fix_errors') || 0;
    $job->{meta}->{'correction.frameshifts'} = $cgi->param('fix_frameshifts') || 0;
    $job->{meta}->{'correction.backfill_gaps'} = $cgi->param('backfill_gaps') || 0;
    $job->{meta}->{'disable_cache'} = $cgi->param('disable_replication') || 0;
    $job->{meta}->{'env.debug'} = $cgi->param('enable_debug') || 0;
    $job->{meta}->{'skip_sims'} = $cgi->param('compute_sims') ? 0 : 1;
    $job->{meta}->{'env.verbose'} = $cgi->param('verbose_level') || 0;
    $job->{meta}->{'model_build.enabled'} = $cgi->param('build_models') || 0;
    $job->{meta}->{'options.determine_family'} = $cgi->param('determine_family') || 0;
    $job->{meta}->{'options.figfam_version'} = $cgi->param('figfam_version');

    #
    # If this is a RASTtk job and we are submitting custom workflow, construct
    # the workflow document.
    #

    if ($cgi->param('annotation_scheme') eq 'RASTtk')
    {
	my $workflow = $default_workflow;
	if ($FIG_Config::rast_use_patric{$self->app->session->user->login})
	{
	    # we want to take the default PATRIC workflow
	    undef $workflow;
	}

	if ($cgi->param('rasttk_customize_pipeline'))
	{
	    my %by_name = map { $_->{name}, $_} @$stages;
	    
	    #
	    # Construct workflow.
	    #
	    my $wfstages = [];
	    $workflow = { stages => $wfstages };

	    my @stage_names = grep { $_ } split(/,/, $cgi->param('stage_sort_order'));
	    if (@stage_names == 0)
	    {
		@stage_names = map { $_->{name} } @$stages;
	    }
	

	    for my $name (@stage_names)
	    {
		my $val = $cgi->param($name);
		
		next unless $val;
		
		my $cond = $cgi->param("$name-condition");
		
		my $stage = $by_name{$name};
		
		(my $wname = $name) =~ s/-/_/g;
		my $item = { name => $wname };
		$item->{condition} = $cond if $cond;
		
		my $vals = {};
		for my $p (@{$stage->{parameters}})
		{
		    my $k = "$name-$p->{name}";
		    my $pv = $cgi->param($k);
		    if (defined($pv))
		    {
			$vals->{$p->{name}} = $pv;
			# print "   $k = $pv\n";
		    }
		}
		if (exists $stage->{failure_is_not_fatal})
		{
		    $item->{failure_is_not_fatal} = $stage->{failure_is_not_fatal};
		}
		if ($stage->{parameters_name})
		{
		    $item->{$stage->{parameters_name}} = $vals;
		}
		push(@$wfstages, $item);
	    }
	}
	$job->{meta}->{rasttk_workflow} = $workflow;
    }


    # create the job
    
    my ($jobid, $msg) = Job48->create_new_job($job);;
    my $content = '';
    
    if ($jobid) {
	my $upload_jobnumber_file = $job->{upload_dir}.'/JOBNUMBER';
	if (open(JOBNUMBER, '>', $upload_jobnumber_file)) {
	   print JOBNUMBER ($jobid, "\n");
	   close(JOBNUMBER);
	}
	else {
	    $self->app->add_message('warning', "Could not write-open '$upload_jobnumber_file'");
	}
	
	my $upload_genome_id_file = $job->{upload_dir}.'/GENOME_ID';
	if (open(GENOME_ID, '>', $upload_genome_id_file)) {
	   print GENOME_ID ($job->{taxonomy_id}, "\n");
	   close(GENOME_ID);
	}
	else {
	    $self->app->add_message('warning', "Could not write-open '$upload_genome_id_file'");
	}
	
	
	
	# sync job
	my $sync;
	eval { $sync = $self->app->data_handle('RAST')->Job->init({ id => $jobid }); };
	unless ($sync) {
	    warn "Error syncing job $jobid.";
	}
	#
	$self->app->session->user->flush_cache_has_right_to(undef, 'view', 'genome');
	$self->app->session->user->flush_cache_has_right_to(undef, 'edit', 'genome');
    
	# print success
	$content .= '<p><strong>Your upload will be processed as job '.$jobid.'.</strong> ';
	$content .= "<a href='?page=JobDetails&job=$jobid'>View job status</a></p>";
	$content .= "<p>Go back to the <a href='?page=UploadGenome'>genome upload page</a>".
	    " to add another annotation job.</p>";
	$content .= "<p>You can view the status of your project on the <a href='?page=Jobs'>status page</a>.</p>";

	#
	# Write the submitted job ID to the incoming directory.
	#
	if (open(RJ, ">", "$job->{upload_dir}/RAST_JOB"))
	{
	    print RJ "$jobid\n";
	    close(RJ);
	}
	else
	{
	    warn "Could not write $job->{upload_dir}/RAST_JOB: $!";
	}
    }
    else {
	$self->app->add_message('warning', "There has been an error uploading your jobs: <br/> $msg");
	$content .= "<p><em>Failed to upload your job.</em></p>";
	$content .= "<p> &raquo <a href='?page=UploadGenome'>Start over the genome upload</a></p>";
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
	
	# print "curmax=$curmax\n";
	my $id = $curmax + 1;
	my $job;
	eval {
	    $job = $backend->Job->create({id => $id});
	};
	if ($@)
	{
	    # print "Failed\n$@\n";
	    sleep 2;
	    next;
	}
	
	# print "Created new job $job " . $job->id . "\n";
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

#
# Borrowed from RAST_submission.pm. Probably should go into SeedUtils or something.
#

sub get_taxonomy_data
{
    my($self, $tax_id) = @_;

    my $ua = LWP::UserAgent->new();

    my $res = $self->url_get($ua, "http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=taxonomy&id=$tax_id&report=sgml&mode=text");
    if ($res->is_success)
    {
	my $ent = {};
	my $doc = XML::LibXML->new->parse_string($res->content);
	
	my $lin = $doc->findvalue('//Taxon/Lineage');
	$lin =~ s/^cellular organisms;\s+//;
	my $domain = $lin;
	$domain =~ s/;.*$//;
	my $code = $doc->findvalue('//Taxon/GeneticCode/GCId');
	
	$ent->{domain} = $domain;
	$ent->{taxonomy} = $lin;
	$ent->{genetic_code} = $code;
	return $ent;
    }
    return undef;
}

=head3 url_get

Use the LWP::UserAgent in $self to make a GET request on the given URL. If the
request comes back with one of the transient error codes, retry.

=cut

sub url_get
{
    my($self, $ua, $url) = @_;

    my @retries = (1, 5, 20);

    my %codes_to_retry = map { $_ => 1 } qw(408 500 502 503 504);

    my $res;
    while (1)
    {
	my $now = time;
	if ($self->{last_url_request} > 0)
	{
	    my $delay = $now - $self->{last_url_request};
	    if ($delay < 3)
	    {
		my $sleep = 3 - $delay;
		print STDERR "Sleeping $sleep to pace requests\n";
		sleep($sleep);
	    }
	}
	$self->{last_url_request} = $now;
	$res = $ua->get($url);

	if ($res->is_success)
	{
	    return $res;
	}

	my $code = $res->code;
	if (!$codes_to_retry{$code})
	{
	    return $res;
	}

	if (@retries == 0)
	{
	    return $res;
	}
	my $retry_time = shift(@retries);
	print STDERR "Request failed with code=$code, sleeping $retry_time and retrying $url\n";
	sleep($retry_time);
    }
    return $res;
}
