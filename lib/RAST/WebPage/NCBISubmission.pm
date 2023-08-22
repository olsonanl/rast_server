package RAST::WebPage::NCBISubmission;

use strict;
use warnings;

use POSIX;

use base qw( WebPage );
use WebConfig;

use RAST::RASTShared qw( get_menu_job );

1;


=pod

=head1 NAME

Genome - displays detailed information about a genome job

=head1 DESCRIPTION

Job Details (Genome) page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title( "NCBI UPLOAD" );
  $self->{ 'cgi' } = $self->application->cgi;

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  $self->data('job', $job);

  # add links
  &get_menu_job($self->app->menu, $job);

#  # register quality revision actions
  $self->application->register_component( 'Table', 'PseudoTable' );
  $self->application->register_component( 'Table', 'WarningTable' );
  $self->application->register_component( 'Table', 'ErrorTable' );
  $self->application->register_component( 'TabView', 'functionTabView' );

}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ( $self ) = @_;

  # check for PrivateOrganismPreferences
  my $application = $self->application;
  my $user = $application->session->user;
  my $job_id = $application->cgi->param( 'job' );
  my $comment = '';
  my $error = '';
  my $rast = $application->data_handle('RAST');

  my $job = $rast->Job->init( { id => $job_id } );
  unless ( $job ) {
    return "No Job given";
  }

  $application->cgi->param( 'organism', $job->genome_id );
  $self->{ 'fig' } = $self->application->data_handle( 'FIG' );
  
  my $running = '';
  my $notparsed;
  my $template_form;
  my $defaulttab = 0;
  my $pseudos;
  my $takechecks = 0;
  my $hiddenpseudos;
  my $errorhiddens;

  if ( $application->cgi->param( 'CREATE_TBL' ) ) {

    $pseudos = $self->find_pseudos( $job, 1 );
    my ( $putcomment, $puterror ) = $self->run_tbl( $job );
    $comment .= $putcomment;
    
    if ( ! defined( $puterror ) || $puterror eq '' ) {
      $comment .= "<I>tbl</I> file created<BR><BR>";
    }
    $defaulttab = 2;
  }
  elsif ( $application->cgi->param( 'CREATE_TEMPLATE' ) ) {

    $pseudos = $self->find_pseudos( $job, 1 );
    my ( $putcomment, $puterror ) = $self->write_template_file( $job );
    $comment .= $putcomment;
    $error .= $puterror;

    if ( ! defined( $puterror ) || $puterror eq '' ) {
      $comment .= "Template file successfully created<BR><BR>";
    }
    if ( defined( $puterror ) ) {
      $defaulttab = 2;
    }
    else {
      $defaulttab = 3;
    }
  }
  elsif ( $application->cgi->param( 'GET_VALIDATION' ) ) {

    $pseudos = $self->find_pseudos( $job, 1 );
    my ( $putcomment, $puterror ) = $self->write_seq_file( $job );
    $comment .= $putcomment;
    $error .= $puterror;

    ( undef, undef, $notparsed, $errorhiddens ) = $self->read_val_file( $job );
    $defaulttab = 3;

  }
  elsif ( $application->cgi->param( 'DOWNLOAD' ) ) {

    $self->download_seq( $job );
   
  }
  elsif ( $application->cgi->param( 'GET_PSEUDOS' ) ) {

    $pseudos = $self->find_pseudos( $job );

  }
  elsif ( $application->cgi->param( 'Confirm and Process Selected as Pseudogenes' ) ) {

    $takechecks = 1;
    $pseudos = $self->find_pseudos( $job );
    my $pnum = 0;
    ( $pnum, $hiddenpseudos ) = $self->write_pseudos( $job, $pseudos );
    $comment .= "$pnum pseudogenes saved.<BR>";
    $defaulttab = 1;

  }
  elsif ( $application->cgi->param( 'Make Selected Genes Partial Genes' ) ) {

    my ( $errorhash, $warninghash, $handlepegs );
    my @checks4 = $self->{ 'cgi' }->param( 'ic4' );
    ( $errorhash, $warninghash, $notparsed, $errorhiddens, $handlepegs ) = $self->read_val_file( $job, \@checks4 );
    $defaulttab = 3;
    my ( $putcomment, $puterror ) = $self->handle_pegs( $job, $handlepegs );
    ( $errorhash, $warninghash, $notparsed, $handlepegs ) = $self->read_val_file( $job, \@checks4 );
    
  }
  
  my $handle_pseudos_div = $self->handle_pseudos_div( $pseudos, $takechecks );
  my $create_tbl_div = $self->create_tbl_div();
  my $create_template_div = $self->create_template_div( $job );
  my $create_sqn_div = $self->create_seqfile_div( $notparsed, $job, $errorhiddens );

  my $hiddenvalues;
  $hiddenvalues->{ 'job' } = $job_id;

  my $content = '<h1>NCBI Submission Support for Job #'.$job_id.', genome '.$job->{ 'genome_name' }.'</h1>';

  ####################
  # Display comments #
  ####################

  my $tabview = $self->application->component( 'functionTabView' );
  $tabview->width( 900 );
  $tabview->add_tab( '<H2>&nbsp; Handle Pseudogenes &nbsp;</H2>', "$handle_pseudos_div" );
  $tabview->add_tab( '<H2>&nbsp; Compute tbl file &nbsp;</H2>', "$create_tbl_div" );
  $tabview->add_tab( '<H2>&nbsp; Create template file &nbsp;</H2>', "$create_template_div" );
  $tabview->add_tab( '<H2>&nbsp; Compute sqn file &nbsp;</H2>', "$create_sqn_div" );
  $tabview->default( $defaulttab );

  $content .= $self->start_form( 'form', $hiddenvalues );
  $content .= $running;
  $content .= $tabview->output();

  $content .= $self->end_form();
  
  ###############################
  # Display errors and comments #
  ###############################
 
  if ( defined( $error ) && $error ne '' ) {
    $self->application->add_message( 'warning', $error );
  }

  if ( defined( $comment ) && $comment ne '' ) {
    $self->application->add_message( 'info', $comment );
#    my $info_component = $self->application->component( 'CommentInfo' );
    
#    $info_component->content( $comment );
#    $info_component->default( 0 );
#    $content .= $info_component->output();
  }

  return $content;
}

sub run_tbl {
  my ( $self, $job ) = @_;

  my $thiscomment;

  my $org_dir = $job->org_dir();

  ###                                               ###
  # First, we need to have an assigned_functions file #
  ###                                               ###

  my $ass_func = $org_dir . '/assigned_functions';

  if ( -e $ass_func ) {
    $thiscomment .= "Found assigned_functions<BR>";
  }
  else {
    system "$FIG_Config::bin/merge_assignments $org_dir"; 
    $thiscomment .= "No assigned_functions yet, creating... DONE<BR><BR>";
  }

  ###                                        ###
  # Delete already existing constructed files  #
  ###                                        ###

  my $expdir = $org_dir.'/NCBI_EXP/';
  $self->{ 'fig' }->verify_dir( $expdir );

  opendir ( DIR, $expdir );
  my @files = grep { /(.*)\.tbl/ } readdir DIR;
  closedir DIR;
  foreach my $aef ( @files ) {
    if ( $aef =~ /(.*)\..*/ ) {
      my $this = $1;
      $this .= '.*';
      $this = $expdir.$this;
      print STDERR "rm $this\n";
      system "rm $this";
      print STDERR "removed...\n";
    }
  }

  ###                                     ###
  # Now run the script to create a tbl file #
  ###                                     ###

  my $s = $self->application->cgi->param( 'PP' );
  my $l = $s;

  if ( !defined( $s ) ) {
    $s = 'TEST';
  }
  if ( !defined( $l ) ) {
    $l = 'TEST';
  }
  my $c = $l.".fsa";
  my $r = $l.".tbl";
  $l .= '_';
  $r = $expdir.$r;
  my $pseudofile = $expdir.'pseudos.csv';
  my $partialfile = $expdir.'partials.csv';

  my $bad_ecs = "$FIG_Config::global/ECs_deleted_and_transferred.txt";

  my $params = "-o $org_dir -s $s -l $l -r $r -e $bad_ecs";
  if ( -f $pseudofile ) {
    $params .= " -p $pseudofile";
  }
  if ( -f $partialfile ) {
    $params .= " -a $partialfile";
  }

  system "$FIG_Config::bin/seed2tbl $params";
#  $thiscomment .= "Running seed2tbl $params<BR><BR>";
  
  my ( $prots, $rnas, $pseudos ) = ( 0, 0, 0 );
  # look at the file
  open ( TBLFILE, "$r" );
  while ( <TBLFILE> ) {
    if ( $_ =~ /.*\_rna/ ) {
      $rnas++;
    }
    elsif ( $_ =~ /^\s+pseudo\s*$/ ) {
      $pseudos++;
    }
    elsif ( $_ =~ /\d+\s+\d+\s+CDS/ ) {
      $prots++;
    }
  }
  close TBLFILE;
  $thiscomment .= "The tbl file created includes<BR>";
  $thiscomment .= "  - $prots proteins<BR>";
  $thiscomment .= "  - $rnas RNAs<BR>";
  $thiscomment .= "  - $pseudos pseudogenes<BR>";

  # construct the contigs file #
  my $fsafile = $expdir.$c;
  if ( ! -e $fsafile ) {
    
    open ( CONTIGS, $org_dir.'/contigs' );
    open ( NEWCON, ">$fsafile" );
    
    while ( <CONTIGS> ) {
      chomp;
      if ( $_ =~ /^(>.*)$/ ) {
	my $line = $1;
	$line .= ' [gcode=11]';
	print NEWCON $line."\n";
      }
      else {
	print NEWCON $_."\n";
      }
    }
    close CONTIGS;
    close NEWCON;
  }

  return $thiscomment;
}

sub handle_pseudos_div {
  my ( $self, $results, $takechecks ) = @_;

  my @checks = $self->{ 'cgi' }->param( 'ic0' );

  my $hpd = '<P>Depending on the sequence quality, there may be a number of pseudogenes in the genome. These are genes that are interrupted by stop codons, or frameshifts. NCBI wants them to be handled as regions, not CDSs. The region will span all pieces of the interruped gene.<BR><BR>For finding pseudogenes, here we use the somewhat crude approach to look for consecutive genes that have the same annotation. These are listed in the table that will result from pressing the <I>Get Pseudogenes</I> button.<BR><BR>Fragments of genes can be marked as pseudogenes by their annotation. To do this, use the comment <I># fragment</I> for all parts of the gene. This will pre-select the pseudogene as such in the table.<BR><BR>After marking all pseudogenes, press the button <I>Confirm and Process Selected as Pseudogenes</I>. This will save them in a file that will be used in later steps of the process.</P>';
  my $get_pseudos_button = "<INPUT TYPE=SUBMIT NAME='GET_PSEUDOS' ID='GET_PSEUDOS' VALUE='Get Pseudogenes'>";
  my $hypo_checked = defined( $self->{ 'cgi' }->param( 'hypo_checkbox' ) ) ? 1 : 0;

  my $hypo_checkbox = $self->{ 'cgi' }->checkbox( -name     => 'hypo_checkbox',
						  -id       => "hypo_checkbox",
						  -label    => 'Ignore hypothetical proteins',
						  -checked  => $hypo_checked,
						  -override => 1, );

  $hpd .= $get_pseudos_button." ".$hypo_checkbox."<BR><BR>";

  if ( $results ) {
    my $outtab = $self->application->component( 'PseudoTable' );
    my $table_columns = [ { name => 'Mark', input_type => 'checkbox' },
			  { name => 'IDs', filter => 1, sortable => 1 }, 
			  { name => 'Current Annotations', filter => 1, sortable => 1 }, 
		      ];

    my $data = [];
    my $c = 0;
    foreach my $r ( @$results ) {
      my $anno;
      my $check = 1;

      if ( $takechecks ) {
	unless ( $checks[$c] ) {
	  $check = 0;
	}
      }
      foreach my $a ( @$r ) {
	my $thisa = $self->{ 'fig' }->function_of( $r->[0] );
	$anno = $thisa;
	unless ( $takechecks ) {
	  if ( $thisa !~ /.*\# fragment/ ) {
	    $check = 0;
	  }
	}
      }

      my @fidlinks;
      foreach my $f ( @$r ) {	
	my $figlink = $self->fid_link( $f );
	push @fidlinks, "<A HREF='$figlink' target=_blank>$f</A>";
      }

      push @$data, [ $check, join( ', ', @fidlinks ), $anno ];
      $c++;
    }

    $outtab->columns( $table_columns );
    $outtab->data( $data );
    $outtab->show_top_browse( 1 );
    $outtab->show_select_items_per_page( 1 );
    $outtab->items_per_page( 10 );
    my $write_pseudos_button = $outtab->submit_button( { 'form_name' => 'form',
							 'button_name' => 'Confirm and Process Selected as Pseudogenes',
							 'submit_all' => '1' } );

    $hpd .= $outtab->output();
    $hpd .= "<BR>";
    $hpd .= $write_pseudos_button;
  }
  return $hpd;
}

sub create_tbl_div {
  my ( $self ) = @_;

  my $ctd = '<P>The tbl file is one of the input files for creating the sqn file that can be submit to the NCBI. The prefix is the prefix used for naming the genes and proteins in the output file. Click this button to create the tbl file from the current annotations of the genome.</P>';

  my $pp = $self->application->cgi->param( 'PP' );
  if ( !defined( $pp ) ) {
    $pp = '';
  }
  my $protein_prefix = "<INPUT TYPE=TEXT ID='PP' NAME='PP' VALUE='$pp' SIZE=4>";
  
  $ctd .= "<TABLE><TR><TD>Prefix:</TD><TD>$protein_prefix</TD></TR></TABLE>";

  my $create_tbl_button = "<INPUT TYPE=SUBMIT NAME='CREATE_TBL' ID='CREATE_TBL' VALUE='Compute TBL File'>";
  $ctd .= $create_tbl_button;
  return $ctd;
}

sub create_template_div {
  my ( $self, $job ) = @_;

  my $ctd = '<P>The template file is one of the input files for creating the sqn file that can be submit to the NCBI. It includes personal information of the contact, the authors and the consortium responsible for sequencing and/or annotation. Fill out the form and click the button to create a template file.</P>';

  my $org_dir = $job->org_dir();

  my $expdir = $org_dir.'/NCBI_EXP/';
  $self->{ 'fig' }->verify_dir( $expdir );
  my $tempfile = $expdir.'/template.sbt';

  my $infohash;
  if ( -f $tempfile ) {
    $ctd .= "<P>A template file was already created. You can change it using the following form.</P>";
    $infohash = $self->get_template_data( $tempfile );
  }

  my $contact_firstname = "<INPUT TYPE=TEXT ID='CFN' NAME='CFN' VALUE='".( $infohash->{ 'CFN' } || '' ) ."' SIZE=18>";
  my $contact_lastname = "<INPUT TYPE=TEXT ID='CLN' NAME='CLN' VALUE='".( $infohash->{ 'CLN' } || '' ) ."' SIZE=19>";
  my $contact_initials = "<INPUT TYPE=TEXT ID='CIN' NAME='CIN' VALUE='".( $infohash->{ 'CIN' } || '' ) ."' SIZE=2>";
  my $contact_affiliation = "<INPUT TYPE=TEXT ID='AFFIL' VALUE='".( $infohash->{ 'AFFIL' } || '' ) ."' NAME='AFFIL' SIZE=64>";
  my $contact_email = "<INPUT TYPE=TEXT ID='EMAIL' NAME='EMAIL' VALUE='".( $infohash->{ 'EMAIL' } || '' ) ."' SIZE=64>";
  my $contact_city = "<INPUT TYPE=TEXT ID='CITY' NAME='CITY' VALUE='".( $infohash->{ 'CITY' } || '' ) ."' SIZE=15>";
  my $contact_country = "<INPUT TYPE=TEXT ID='COUNTRY' NAME='COUNTRY' VALUE='".( $infohash->{ 'COUNTRY' } || '' ) ."' SIZE=15>";
  my $contact_sub = "<INPUT TYPE=TEXT ID='SUB' NAME='SUB' VALUE='".( $infohash->{ 'SUB' } || '' ) ."' SIZE=1>";
  my $contact_street = "<INPUT TYPE=TEXT ID='STREET' NAME='STREET' VALUE='".( $infohash->{ 'STREET' } || '' ) ."' SIZE=64>";
  my $contact_zip = "<INPUT TYPE=TEXT ID='ZIP' NAME='ZIP' VALUE='".( $infohash->{ 'ZIP' } || '' ) ."' SIZE=4>";
  my $author1_firstname = "<INPUT TYPE=TEXT ID='A1FN' VALUE='".( $infohash->{ 'A1FN' } || '' ) ."' NAME='A1FN' SIZE=18>";
  my $author1_lastname = "<INPUT TYPE=TEXT ID='A1LN' VALUE='".( $infohash->{ 'A1LN' } || '' ) ."' NAME='A1LN' SIZE=19>";
  my $author1_initials = "<INPUT TYPE=TEXT ID='A1IN' VALUE='".( $infohash->{ 'A1IN' } || '' ) ."' NAME='A1IN' SIZE=2>";
  my $author2_firstname = "<INPUT TYPE=TEXT ID='A2FN' VALUE='".( $infohash->{ 'A2FN' } || '' ) ."' NAME='A2FN' SIZE=18>";
  my $author2_lastname = "<INPUT TYPE=TEXT ID='A2LN' VALUE='".( $infohash->{ 'A2LN' } || '' ) ."' NAME='A2LN' SIZE=19>";
  my $author2_initials = "<INPUT TYPE=TEXT ID='A2IN' VALUE='".( $infohash->{ 'A2IN' } || '' ) ."' NAME='A2IN' SIZE=2>";
  my $author3_firstname = "<INPUT TYPE=TEXT ID='A3FN' VALUE='".( $infohash->{ 'A3FN' } || '' ) ."' NAME='A3FN' SIZE=18>";
  my $author3_lastname = "<INPUT TYPE=TEXT ID='A3LN' VALUE='".( $infohash->{ 'A3LN' } || '' ) ."' NAME='A3LN' SIZE=19>";
  my $author3_initials = "<INPUT TYPE=TEXT ID='A3IN' VALUE='".( $infohash->{ 'A3IN' } || '' ) ."' NAME='A3IN' SIZE=2>";

  my ( $com, $dnas, $cov ) = ( '', '', '' );
  if ( defined( $infohash->{ 'COMMENT' } ) ) {
    my @comarr = split( '~', $infohash->{ 'COMMENT' } );
    foreach my $ca ( @comarr ) {
      if ( $ca =~ /DNA Source: (.*)/ ) {
	$dnas = $1;
      }
      elsif ( $ca =~ /Genome coverage: (.*)[xX]/ ) {
	$cov = $1;
      }
      else {
	$com = $ca;
      }
    }
  }

  my $comment_field = "<INPUT TYPE=TEXT ID='COMMENT' VALUE='".( $com || '' ) ."' NAME='COMMENT' SIZE=62>";
  my $dnasource_field = "<INPUT TYPE=TEXT ID='DNASOURCE' VALUE='".( $dnas || '' ) ."' NAME='DNASOURCE' SIZE=40>";
  my $coverage_field = "<INPUT TYPE=TEXT ID='COVERAGE' VALUE='".( $cov || '' ) ."' NAME='COVERAGE' SIZE=2>";
  my $consortium_field = "<INPUT TYPE=TEXT ID='CONSORTIUM' VALUE='".( $infohash->{ 'CONSORTIUM' } || '' ) ."' NAME='CONSORTIUM' SIZE=64>";
  
  my $template_form = "<H2>Contact</H2>";

  $template_form .= "<TABLE><TR><TD>Firstname:</TD><TD>$contact_firstname</TD><TD>Initials:</TD><TD>$contact_initials</TD><TD>Lastname:</TD><TD>$contact_lastname</TD></TR></TABLE>";

  $template_form .= "<H2>Affiliation</H2>";
  $template_form .= "<TABLE><TR><TD>Affiliation:</TD><TD COLSPAN=7>$contact_affiliation</TD></TR>";
  $template_form .= "<TR><TD>Street:</TD><TD COLSPAN=7>$contact_street</TD></TR>";
  $template_form .= "<TR><TD>City:</TD><TD>$contact_city</TD><TD>ZIP:</TD><TD>$contact_zip</TD><TD>Sub:</TD><TD>$contact_sub</TD><TD>Country:</TD><TD>$contact_country</TD></TR>";
  $template_form .= "<TR><TD>Email:</TD><TD COLSPAN=7>$contact_email</TD></TR></TABLE>";
  
  $template_form .= "<H2>Authors</H2>";

  $template_form .= "<TABLE><TR><TD>Firstname:</TD><TD>$author1_firstname</TD><TD>Initials:</TD><TD>$author1_initials</TD><TD>Lastname:</TD><TD>$author1_lastname</TD></TR>";
  $template_form .= "<TR><TD>Firstname:</TD><TD>$author2_firstname</TD><TD>Initials:</TD><TD>$author2_initials</TD><TD>Lastname:</TD><TD>$author2_lastname</TD></TR>";
  $template_form .= "<TR><TD>Firstname:</TD><TD>$author3_firstname</TD><TD>Initials:</TD><TD>$author3_initials</TD><TD>Lastname:</TD><TD>$author3_lastname</TD></TR>";
  $template_form .= "<TR><TD>Consortium:</TD><TD COLSPAN=7>$consortium_field</TD></TR></TABLE>";

  $template_form .= "<H2>Comment</H2>";
  $template_form .= "<TABLE><TR><TD>Comment:</TD><TD COLSPAN=5>$comment_field</TD></TR>";
  $template_form .= "<TR><TD>DNA Source:</TD><TD>$dnasource_field</TD><TD>Coverage:</TD><TD>$coverage_field X</TD></TR></TABLE>";

  my $create_template_button = "<INPUT TYPE=SUBMIT NAME='CREATE_TEMPLATE' ID='CREATE_TEMPLATE' VALUE='Compute TEMPLATE File'>";

  $ctd .= $template_form;
  $ctd .= $create_template_button;
  return $ctd;
}

sub create_seqfile_div {

  my ( $self, $notparsed, $job, $errorhiddens ) = @_;

  my $csd = "<P>The sqn file is created using NCBI's tbl2asn software. Click the button to create a sqn file for your genome.</P>";
  my $create_seqfile_button = "<INPUT TYPE=SUBMIT NAME='GET_VALIDATION' ID='GET_VALIDATION' VALUE='Compute sqn file'>";
  $csd .= $create_seqfile_button;

  if ( $self->application->cgi->param( 'GET_VALIDATION' ) || $self->application->cgi->param( 'Make Selected Genes Partial Genes' ) ) {
    $csd .= "<H2>Errors - need to be handled</H2>";
    my $errortab = $self->application->component( 'ErrorTable' );
    if ( $errortab->output() ne 'No data passed to table creator!' ) {
      my $handle_errors_button = $errortab->submit_button( { 'form_name' => 'form',
							     'button_name' => 'Make Selected Genes Partial Genes',
							     'submit_all' => '1' } );
      $csd .= $errortab->output();
      $csd .= $handle_errors_button;
      $csd .= $errorhiddens;
    }
    else {
      $csd .= "There are no errors.";
    }
    $csd .= "<H2>Warnings</H2>";
    my $warningtab = $self->application->component( 'WarningTable' );
    $csd .= $warningtab->output();
    if ( defined( $notparsed ) ) {
      $csd .= "<H2>Not Parsed</H2>\n";
      $csd .= "<P>";
      foreach my $s ( @$notparsed ) {
	$csd .= $s."<BR>";
      }
      $csd .= "</P>";
    }

    my $download_button = "<INPUT TYPE=SUBMIT NAME='DOWNLOAD' ID='DOWNLOAD' VALUE='Download SEQ File'>";
    $csd .= $download_button;
  }

  return $csd;
}

sub write_template_file {

  my ( $self, $job, $rel_date ) = @_;

  my $cgi = $self->{ 'cgi' };
  my $error = '';

  my $firstname = $cgi->param( 'CFN' );
  if ( !defined( $firstname ) || $firstname eq '' ) {
    $error .= 'No first name given for contact information<BR>';
  }

  my $lastname = $cgi->param( 'CLN' );
  if ( !defined( $lastname ) || $lastname eq '' ) {
    $error .= 'No last name given for contact information<BR>';
  }

  my $initials = $cgi->param( 'CIN' );

  my $email = $cgi->param( 'EMAIL' );
  if ( !defined( $email ) || $email eq '' ) {
    $error .= 'No email given for contact information<BR>';
  }

  my $affil = $cgi->param( 'AFFIL' );
  if ( !defined( $affil ) || $affil eq '' ) {
    $error .= 'No affiliation given for contact information<BR>';
  }

  my $city = $cgi->param( 'CITY' );
  if ( !defined( $city ) || $city eq '' ) {
    $error .= 'No city given for contact information<BR>';
  }

  my $sub = $cgi->param( 'SUB' );
  if ( !defined( $sub ) || $sub eq '' ) {
    $error .= 'No sub given for contact information<BR>';
  }

  my $country = $cgi->param( 'COUNTRY' );
  if ( !defined( $country ) || $country eq '' ) {
    $error .= 'No country given for contact information<BR>';
  }

  my $street = $cgi->param( 'STREET' );
  if ( !defined( $street ) || $street eq '' ) {
    $error .= 'No street given for contact information<BR>';
  }

  my $zip = $cgi->param( 'ZIP' );
  if ( !defined( $zip ) || $zip eq '' ) {
    $error .= 'No zip given for contact information<BR>';
  }

  my $consortium = $cgi->param( 'CONSORTIUM' );
  if ( !defined( $consortium ) || $consortium eq '' ) {
    $error .= 'No consortium given for contact information<BR>';
  }

  my $comment_seq;
  my $DNA_source = $cgi->param( 'DNASOURCE' );
  my $coverage = $cgi->param( 'COVERAGE' );
  my $comment_it = $cgi->param( 'COMMENT' );
  if ( defined( $DNA_source ) && $DNA_source ne '' ) {
    $comment_seq = 'DNA Source: '.$DNA_source;
  }
  if ( defined( $comment_it ) && $comment_it ne '' ) {
    if ( defined( $comment_seq ) ) {
      $comment_seq .= '~'.$comment_it;
    }
    else  {
      $comment_seq = $comment_it;
    }
  }
  if ( defined( $coverage ) && $coverage ne '' ) {
    if ( defined( $comment_seq ) ) {
      $comment_seq .= '~Genome coverage: '.$coverage.'x';
    }
    else  {
      $comment_seq = '~Genome coverage: '.$coverage.'x';
    }
  }
  if ( !defined( $comment_seq ) || $comment_seq eq '' ) {
    $error .= 'No comment given for your sequences<BR>';
  }

  my $author1_firstname = $cgi->param( 'A1FN' );
  if ( !defined( $author1_firstname ) || $author1_firstname eq '' ) {
    $error .= 'No first name given for author information<BR>';
  }

  my $author1_lastname = $cgi->param( 'A1LN' );
  if ( !defined( $author1_lastname ) || $author1_lastname eq '' ) {
    $error .= 'No last name given for author information<BR>';
  }

  my $author1_initials = $cgi->param( 'A1IN' );

  my $authors = [ { lastname => $author1_lastname,
		 firstname => $author1_firstname,
		 initials => $author1_initials } ];

  my $author2_firstname = $cgi->param( 'A2FN' );
  my $author2_lastname = $cgi->param( 'A2LN' );
  my $author2_initials = $cgi->param( 'A2IN' );
  my $author3_firstname = $cgi->param( 'A3FN' );
  my $author3_lastname = $cgi->param( 'A3LN' );
  my $author3_initials = $cgi->param( 'A3IN' );

  if ( defined( $author2_firstname ) && defined( $author2_lastname ) ) {
    push @$authors, { lastname => $author2_lastname,
		      firstname => $author2_firstname,
		      initials => $author2_initials };
  }
  if ( defined( $author3_firstname ) && defined( $author3_lastname ) ) {
    push @$authors, { lastname => $author3_lastname,
		      firstname => $author3_firstname,
		      initials => $author3_initials };
  }

  if ( defined( $error ) && $error ne '' ) {
    return ( '', $error );
  }

  my $t = time;
  my $date = &FIG::epoch_to_readable( $t );
  my ( $day, $month, $year ) = ( $date =~ /(\d+)\-(\d+)\-(\d+)\:/ );

  unless ( defined( $rel_date ) ) {
    $rel_date = { day => $day,
		 month => $month,
		 year => $year }
  }

  my $string = 'Seq-submit ::= {
  sub {
    contact {
      contact {
        name
          name {
            last "'.$lastname.'" ,
            first "'.$firstname.'" ,
            initials "'.$initials.'" } ,
        affil
          std {
            affil "'.$affil.'" ,
            city "'.$city.'" ,
            sub "'.$sub.'" ,
            country "'.$country.'" ,
            street "'.$street.'" ,
            email "'.$email.'" ,
            postal-code "'.$zip.'" } } } ,
    cit {
      authors {
        names
          std {';

  foreach my $auth ( @$authors ) {
    $string .= '
            {
              name
                name {
                  last "'.$auth->{ 'lastname' }.'" ,
                  first "'.$auth->{ 'firstname' }.'" ,
                  initials "'.$auth->{ 'initials' }.'" } } ,';
  }
  if ( defined( $consortium ) ) {
    $string .= '            {
              name
                consortium "'.$consortium.'" } } ,';
  }
  $string .= '
        affil
          std {
            affil "'.$affil.'" ,
            city "'.$city.'" ,
            sub "'.$sub.'" ,
            country "'.$country.'" ,
            street "'.$street.'" ,
            email "'.$email.'" ,
            postal-code "'.$zip.'" } } ,
      date
        std {
          year '.$year.' ,
          month '.$month.' ,
          day '.$day.' } } ,
    hup TRUE ,
    reldate
      std {
        year '.$rel_date->{ 'year' }.' ,
        month '.$rel_date->{ 'month' }.' ,
        day '.$rel_date->{ 'day' }.' } ,
    subtype new ,
    tool "Sequin 9.00 - MAC 386 on OS 10.4" } ,
  data
    entrys {
      set {
        descr {
          source {
            org {
              taxname "'.$job->{ 'genome_name' }.'" } } ,
          comment "'.$comment_seq.'" } ,
        seq-set {
           } } } }
Seqdesc ::= comment "'.$comment_seq.'"
';

  my $org_dir = $job->org_dir();

  my $expdir = $org_dir.'/NCBI_EXP/';
  $self->{ 'fig' }->verify_dir( $expdir );
  my $tempfile = $expdir.'/template.sbt';
  open ( TEMPLATE, ">$tempfile" ) or return ( '', "Cannot open $tempfile" );
  print TEMPLATE $string;
  close TEMPLATE;
  return ( "Wrote Template File<BR>" );
}

sub write_seq_file {

  my ( $self, $job ) = @_;

  my $org_dir = $job->org_dir();
  my $expdir = $org_dir.'/NCBI_EXP/';

  my $call = "$FIG_Config::ext_bin/tbl2asn -t ".$expdir.'template.sbt -V vb -a s -p '.$expdir;
  system "$call";

  return ( "The SQN file was successfully created!<BR>" );

}

sub read_val_file {

  my ( $self, $job, $checks4 ) = @_;

  my $org_dir = $job->org_dir();
  my $expdir = $org_dir.'/NCBI_EXP/';
  my ( $errorhash, $warninghash, $notparsed ) = $self->read_validation( $expdir );
  my $errorhiddens = '';

  my $figpref = 'fig|'.$job->genome_id.'.peg.';
  my $warningtab = $self->application->component( 'WarningTable' );
  my $data;
  foreach my $wh ( keys %$warninghash ) {
    foreach my $wwh ( keys %{ $warninghash->{ $wh } } ) {
      my $figid = $wwh;
      if ( $wwh =~ /^0*(\d+)/ ) {
	$figid = $1;
      }
      $figid = $figpref.$figid;
      my $figlink = $self->fid_link( $figid );
      push @$data, [ $wh, "<A HREF='$figlink' target=_blank>$figid</A>", $warninghash->{ $wh }->{ $wwh }->[0], $warninghash->{ $wh }->{ $wwh }->[1] ];
    }
  }

  my $errortab = $self->application->component( 'ErrorTable' );
  my $data2;
  my $c4 = 0;
  my $whichpegs;
  foreach my $wh ( keys %$errorhash ) {
    foreach my $wwh ( keys %{ $errorhash->{ $wh } } ) {
      my $figid = $wwh;
      if ( $wwh =~ /^0*(\d+)/ ) {
	$figid = $1;
      }
      $figid = $figpref.$figid;
      my $figlink = $self->fid_link( $figid );

      my $inc = $wh.$figid;
      my $num = $self->{ 'cgi' }->param( "$inc" );
      my $check4 = 0;
      if ( defined( $num ) && $checks4->[$num] ) {
	$check4 = 1;
      }

      push @$data2, [ $wh, "<A HREF='$figlink' target=_blank>$figid</A>", $errorhash->{ $wh }->{ $wwh }->[0], $errorhash->{ $wh }->{ $wwh }->[1], $check4 ];
      $errorhiddens .= "<INPUT TYPE=HIDDEN NAME='".$wh.$figid."' VALUE='$c4'>";
      if ( $checks4->[$num] && $checks4->[$num] eq '1' ) {
	$whichpegs->{ $figid }->{ $errorhash->{ $wh }->{ $wwh }->[0] } = $errorhash->{ $wh }->{ $wwh }->[1];
      }
      $c4++;
    }
  }

  my $table_columns = [ { name => 'Error Type', filter => 1, sortable => 1 },
			{ name => 'ID', filter => 1, sortable => 1 }, 
			{ name => 'Warning', filter => 1, sortable => 1 }, 
			{ name => 'Current Annotation', filter => 1, sortable => 1 },
		      ];
  $warningtab->columns( $table_columns );
  $warningtab->data( $data );
  $warningtab->show_top_browse( 1 );
  $warningtab->show_select_items_per_page( 1 );
  $warningtab->items_per_page( 10 );

  my $table_columns2 = [ { name => 'Warning Type', filter => 1, sortable => 1 },
			 { name => 'ID', filter => 1, sortable => 1 }, 
			 { name => 'Warning', filter => 1, sortable => 1 }, 
			 { name => 'Current Annotation', filter => 1, sortable => 1 }, 
			 { name => 'Mark', input_type => 'checkbox' },
		       ];

  $errortab->columns( $table_columns2 );
  $errortab->data( $data2 );
  $errortab->show_top_browse( 1 );
  $errortab->show_select_items_per_page( 1 );
  $errortab->items_per_page( 10 );

  return ( $errorhash, $warninghash, $notparsed, $errorhiddens, $whichpegs );
}

sub fid_link {
    my ( $self, $fid ) = @_;
    my $n;
    my $seeduser = $self->{ 'seeduser' };
    if ( !defined( $seeduser ) ) {
      $seeduser = '';
    }

    if ($fid =~ /^fig\|\d+\.\d+\.([a-zA-Z]+)\.(\d+)/) {
      if ( $1 eq "peg" ) {
	  $n = $2;
	}
      else {
	  $n = "$1.$2";
	}
    }

#    return "./protein.cgi?prot=$fid&user=$seeduser\&new_framework=0";
    return qq~./seedviewer.cgi?page=Annotation&feature=$fid&user=$seeduser~;
}

sub download_seq {
  my ( $self, $job ) = @_;

  my $org_dir = $job->org_dir();
  my $expdir = $org_dir.'/NCBI_EXP/';

  opendir ( DIR, $expdir );
  my @files = grep { /(.*)\.sqn/ } readdir DIR;
  closedir DIR;

  if ( scalar( @files ) == 1 ) {
    my $filename = $files[0];
    my $file = $expdir.$filename;

    if (-f $file) {
      open( FILE, $file ) or $self->app->error("Unable open export file");
      print "Content-Type:application/x-download\n"; 
      print "Content-Length: " . (stat($file))[7] . "\n";
      print "Content-Disposition:attachment;filename=".$filename."\n\n";
      while(<FILE>) {
	print $_;
      }
      close(FILE);
      die 'cgi_exit';
    }
    else {
      $self->app->error( "Unable find file" );
    }
    return;
  }
  else {
    $self->app->error( "No sqn file found" ) 
  }
}

#################################################
# very crude way to find possible broken genes  #
# just looks for 2 genes that follow each other #
# and have the same annotation.                 #
#################################################
sub find_pseudos {
  my ( $self, $job, $hidden ) = @_;

  my $genes = $self->{ 'fig' }->all_features_detailed_fast( $job->genome_id );
  my $ignore_hypos = $self->{ 'cgi' }->param( 'hypo_checkbox' );

  my $anno_bef = '';
  my @pseudos = ();
  my $curr_pseudo = [];
  my $opened = 0;

  my $count = 0;
  foreach my $peg ( sort { &FIG::by_fig_id($a->[0],$b->[0]) } @$genes ) {
    next if ( $peg->[0] !~ /peg/ );
    $count++;

    my $this_anno = $self->{ 'fig' }->function_of( $peg->[0] );
    if ( defined( $ignore_hypos ) && $this_anno eq 'hypothetical protein' ) {
      $anno_bef = $this_anno;
      next;
    }
    if ( $anno_bef eq $this_anno ) {
      push @$curr_pseudo, $peg->[0];
      $opened = 1;
    }
    else {
      if ( $opened ) {
	push @pseudos, $curr_pseudo;
	$opened = 0;
	$anno_bef = $this_anno;
      }
      else {
	$anno_bef = $this_anno;
      }
      $curr_pseudo = [ $peg->[0] ];
    }
  }

  return \@pseudos;
}

sub write_pseudos {
  my ( $self, $job, $pseudos ) = @_;

  my @checks = $self->{ 'cgi' }->param( 'ic0' );
  
  my $org_dir = $job->org_dir();

  my $expdir = $org_dir.'/NCBI_EXP/';
  $self->{ 'fig' }->verify_dir( $expdir );
  my $pfile = $expdir.'/pseudos.csv';
  open ( PFILE, ">$pfile" ) or return ( '', "Cannot open $pfile" );

  my $c = 0;
  my $pnum = 0;
  my $hiddenpseudos = '';
  foreach my $p ( @$pseudos ) {
    if ( $checks[$c] ) {
      $pnum++;
      print PFILE join( "\t", @$p )."\n";
      $hiddenpseudos .= "<INPUT TYPE=HIDDEN NAME='HP' VALUE='$c'><BR>";
    }
    $c++;
  }
  close PFILE;

  return ( $pnum, $hiddenpseudos );
}

sub get_template_data {
  my ( $self, $file ) = @_;
  my $infohash;

  my $state = '';
  if ( open ( FILE, $file ) ) {
    while ( <FILE> ) {
      if ( $_ =~ /^    contact {/ ) {
	$state = 'contact';
      }
      elsif ( $_ =~ /^    contact {/ ) {
	$state =  'cit';
      }
      elsif ( $_ =~ /^    reldate/ ) {
	$state =  'reldate';
      }
      elsif ( $_ =~ /^    entrys {/ ) {
	$state =  'entrys';
      }
      elsif ( $_ =~ /^        name/ ) {
	if ( $state eq 'contact' ) {
	  $state = 'contact-name';
	}
      }
      elsif ( $_ =~ /^        affil/ ) {
	if ( $state =~ /^contact/ ) {
	  $state = 'contact-affil';
	}
      }
      elsif ( $_ =~ /^      authors {/ ) {
	$state = 'authors';
      }
      elsif ( $_ =~ /^            last \"(.*)\" ,/ ) {
	if ( $state eq 'contact-name' ) {
	  $infohash->{ 'CLN' } = $1;
	}
      }
      elsif ( $_ =~ /^            first \"(.*)\" ,/ ) {
	if ( $state eq 'contact-name' ) {
	  $infohash->{ 'CFN' } = $1;
	}
      }
      elsif ( $_ =~ /^            initials \"(.*)\" } ,/ ) {
	if ( $state eq 'contact-name' ) {
	  $infohash->{ 'CIN' } = $1;
	}
      }
      elsif ( $_ =~ /^            affil \"(.*)\" ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'AFFIL' } = $1;
	}
      }
      elsif ( $_ =~ /^            city \"(.*)\" ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'CITY' } = $1;
	}
      }
      elsif ( $_ =~ /^            email \"(.*)\" ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'EMAIL' } = $1;
	}
      }
      elsif ( $_ =~ /^            sub \"(.*)\" ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'SUB' } = $1;
	}
      }
      elsif ( $_ =~ /^            country \"(.*)\" ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'COUNTRY' } = $1;
	}
      }
      elsif ( $_ =~ /^            street \"(.*)\" ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'STREET' } = $1;
	}
      }
      elsif ( $_ =~ /^            postal-code \"(.*)\" } } } ,/ ) {
	if ( $state eq 'contact-affil' ) {
	  $infohash->{ 'ZIP' } = $1;
	}
      }
      elsif ( $_ =~ /^                  last \"(.*)\" ,/ ) {
	if ( $state eq 'authors' ) {
	  $state = 'authors1';
	  $infohash->{ 'A1LN' } = $1;
	}
	elsif ( $state eq 'authors1' ) {
	  $state = 'authors2';
	  $infohash->{ 'A2LN' } = $1;
	}
	elsif ( $state eq 'authors2' ) {
	  $state = 'authors3';
	  $infohash->{ 'A3LN' } = $1;
	}
      }
      elsif ( $_ =~ /^                  first \"(.*)\" ,/ ) {
	if ( $state eq 'authors1' ) {
	  $infohash->{ 'A1FN' } = $1;
	}
	elsif ( $state eq 'authors2' ) {
	  $infohash->{ 'A2FN' } = $1;
	}
	elsif ( $state eq 'authors3' ) {
	  $infohash->{ 'A3FN' } = $1;
	}
      }
      elsif ( $_ =~ /^                  initials \"(.*)\" } } ,/ ) {
	if ( $state eq 'authors1' ) {
	  $infohash->{ 'A1IN' } = $1;
	}
	elsif ( $state eq 'authors2' ) {
	  $infohash->{ 'A2IN' } = $1;
	}
	elsif ( $state eq 'authors3' ) {
	  $infohash->{ 'A3IN' } = $1;
	}
      }
      elsif ( $_ =~ /^                consortium \"(.*)\" } } ,/ ) {
	$infohash->{ 'CONSORTIUM' } = $1;	
      }
      elsif ( $_ =~ /^                consortium \"(.*)/ ) {
	$state = 'consortium';
	$infohash->{ 'CONSORTIUM' } = $1;
      }
      elsif ( $_ =~ /^Seqdesc ::= comment \"(.*)\"/ ) {
	$infohash->{ 'COMMENT' } = $1;	
      }
      elsif ( $_ =~ /^Seqdesc ::= comment \"(.*)/ ) {
	$state = 'comment';
	$infohash->{ 'COMMENT' } = $1;	
      }
      elsif ( $_ =~ /(.*)\" } } ,/ ) {
	if ( $state eq 'consortium' ) {
	  $infohash->{ 'CONSORTIUM' } .= $1;
	  $state = '';
	}
      }
      elsif ( $_ =~ /(.*)\"/ ) {
	if ( $state eq 'comment' ) {
	  $infohash->{ 'COMMENT' } .= $1;
	  $state = '';
	}
      }
      else {
	if ( $state eq 'consortium' ) {
	  chomp;
	  $infohash->{ 'CONSORTIUM' } .= $_;
	}
	elsif ( $state eq 'comment' ) {
	  chomp;
	  $infohash->{ 'COMMENT' } .= $_;
	}
      }
    }
  }

  return $infohash;
}

sub read_validation {
  my ( $self, $expdir ) = @_;
  my $errorhash;
  my $warninghash;
  my $notparsed;

  opendir ( DIR, $expdir );
  my @files = grep { /(.*)\.val/ } readdir DIR;
  closedir DIR;

  if ( scalar( @files ) == 1 ) {
    my $f = $expdir.$files[0];

    if ( open ( VAL, $f ) ) {
      while ( <VAL> ) {
	if ( $_ =~ /^(\w+)\: \w+ \[([^\]]+)\] (.+) FEATURE\: (.+) \-\> \[.+\_(\d+).*\]/ ) {
	  my ( $one, $two, $three, $four, $five ) = ( $1, $2, $3, $4, $5 );
	  if ( $one eq 'WARNING' ) {
	    next if ( $two eq 'SEQ_FEAT.NotSpliceConsensusAcceptor' );
	    next if ( $two eq 'SEQ_FEAT.NotSpliceConsensusDonor' );
	    $warninghash->{ $two }->{ $five } = [ $three, $four ];
	    if ( $four =~ /Prot: (.*) \[gnl\|.*\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	    elsif ( $four =~ /CDS: (.*) \[lnl\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	  }
	  elsif ( $one eq 'ERROR' ) {
	    $errorhash->{ $two }->{ $five } = [ $three, $four ];
	    if ( $four =~ /Prot: (.*) \[gnl\|.*\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	    elsif ( $four =~ /CDS: (.*) \[lnl\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	  }
	}
	elsif ( $_ =~ /^(\w+)\: \w+ \[([^\]]+)\] (.+) FEATURE\: (.+) \[.+\_(\d+).*\]/ ) {
	  my ( $one, $two, $three, $four, $five ) = ( $1, $2, $3, $4, $5 );
	  if ( $one eq 'WARNING' ) {
	    next if ( $2 eq 'SEQ_FEAT.NotSpliceConsensusAcceptor' );
	    next if ( $2 eq 'SEQ_FEAT.NotSpliceConsensusDonor' );
	    $warninghash->{ $two }->{ $five } = [ $three, $four ];
	    if ( $four =~ /Prot: (.*) \[gnl\|.*\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	    elsif ( $four =~ /CDS: (.*) \[lnl\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	  }
	  elsif ( $one eq 'ERROR' ) {
	    $errorhash->{ $two }->{ $five } = [ $three, $four ];
	    if ( $four =~ /Prot: (.*) \[gnl\|.*\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	    elsif ( $four =~ /CDS: (.*) \[lnl\|.*\]$/ ) {
	      $warninghash->{ $two }->{ $five }->[1] = $1;
	    }
	  }
	}

	elsif ( $_ =~ /^(\w+)\: \w+ \[([^\]]+)\] (.+) \(\w+\_(\d+) \- (.*)\) BIOSEQ\:.*$/ ) {
	  my ( $one, $two, $three, $four, $five ) = ( $1, $2, $3, $4, $5 );
	  if ( $one eq 'ERROR' ) {
	    $errorhash->{ $two }->{ $four } = [ $three, $five ];
	  }
	}
	else {
	  push @$notparsed, $_;
	}
      }
      close VAL;
    }
    else {
      print STDERR "Could not open $f\n";
    }
  }
  return ( $errorhash, $warninghash, $notparsed );
}

sub handle_pegs {
  my ( $self, $job, $handlehash ) = @_;

  my ( $comment, $error ) = ( '', '' );

  my $org_dir = $job->org_dir();
  
  my $expdir = $org_dir.'/NCBI_EXP/';
  $self->{ 'fig' }->verify_dir( $expdir );
  my $pfile = $expdir.'/partials.csv';

  my $parthash;

  if ( open ( PFILE, $pfile ) ) {
    while ( <PFILE> ) {
      chomp;
      my ( $fid, $st, $num ) = split( "\t", $_ );
      $parthash->{ $fid }->{ $st } = $num;
    }
    close PFILE;
  }

  foreach my $hp ( keys %$handlehash ) {
    foreach my $k ( keys %{ $handlehash->{ $hp } } ) {
      if ( $k eq 'Missing stop codon' ) {
	my $anno = $handlehash->{ $hp }->{ $k };
	if ( $anno =~ /\[lcl\|.+\:(c?)(\d+)\-(\d+)\]/ ) {
	  if ( $1 eq 'c' ) {
	    $parthash->{ $hp }->{ 'stop' } = '<1';
	  }
	  else {
	    $parthash->{ $hp }->{ 'stop' } = ">$2";
	  }
	}
      }
      elsif ( $k eq 'Illegal start codon used. Wrong genetic code [11] or protein should be partial' ) {
	my $anno = $handlehash->{ $hp }->{ $k };
	if ( $anno =~ /\[lcl\|.+\:(c?)(\d+)\-(\d+)\]/ ) {
	  if ( $1 eq 'c' ) {
	    $parthash->{ $hp }->{ 'start' } = ">$2";
	  }
	  else {
	    $parthash->{ $hp }->{ 'start' } = '<1';
	  }
	}
      }
    }
  }

  # construct string #
  my $string = '';

  foreach my $fi ( keys %$parthash ) {
    foreach my $k ( keys %{ $parthash->{ $fi } } ) {
      $string .= "$fi\t$k\t".$parthash->{ $fi }->{ $k }."\n";
    }
  }

  if ( $string ne '' ) {

    if ( open ( PFILE, ">$pfile" ) ) {
      print PFILE $string;
      close PFILE;

      my ( $putcomment, $puterror ) = $self->run_tbl( $job );
      $error .= $puterror;
      $comment .= $putcomment;
      ( $putcomment, $puterror ) = $self->write_seq_file( $job );
      $error .= $puterror;
      $comment .= $putcomment;
    }
  }
  return ( $comment, $error );
}
