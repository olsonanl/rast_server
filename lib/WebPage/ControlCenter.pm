package WebPage::ControlCenter;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );

use GenomeMeta;
use GD;
use MIME::Base64;
use Table;

use FIG_Config;

use Job48;

use GenomeBrowser;

1;

=pod

=head1 NAME

Genomes - an instance of WebPage which displays the list of genomes currently in pipeline and their status

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->title('Annotation Server - Import Jobs into SEED');

  my $content = '';

  # check if a user is logged in and admin
  if ($self->application->authorized(2)) {

    if ($self->application->cgi->param('find_related')) {
      $content = $self->find_related();
    }
    else {

      my @jobs = Job48::all_jobs();
      
      if ($self->application->cgi->param('accept')) {
	$self->set_include(\@jobs);
      }
      
      $content = $self->overview(\@jobs);
    }

  }
  
  # catch errors
  if ($self->application->error) {
    $content = "<p>An error has occured: ".$self->application->error().
      "<br/>Please return to the <a href='".$self->application->url."?page=Login'>login page</a>.</p>";
  }
  
  return $content;
}

=pod

=item * B<overview> ()

Returns the list of genomes currently in pipeline

=cut

sub overview {
  my ($self, $jobs) = @_;
  
  my $cgi = $self->application->cgi;
  
  my $content = '<h1>Import Genomes into SEED</h1>';
  $content .= '<p>The overview below list all genomes currently finished and ready for inclusion. A table entry consists of the RAST job number, the login of the user who submitted the genome, the genome id and name, the number of contigs in the genome and the reason why it\'s a candidate for the SEED.</p>';
  $content .= '<p>Select an import action to schedule the genome for inclusion into the SEED and/or the NMPDR. You may choose not to take an action and revisit an entry at some later time. If you select <em>Never show again</em> the entry will be removed without taking any action.</p>';
  
  # list of genomes:
  # suggested by user: submit.suggested
  # suggested by backend: submit.candidate, submit.candidate_reason
  
  my $show = [];
  my $tt_menu  = [];
  my $tt_info  = [];
  my $tt_title = [];
  my $show_ids = [];
  
  my %sort_by_organisms;
  my @export;
  
  foreach my $job (@$jobs) {
    
    next unless ($job->finished);
    
    
    my  $show_option = "suggested";
    $show_option = $cgi->param('show') if $cgi->param('show');
    
    if ($show_option eq "suggested"){
      next  if ( !($job->meta->get_metadata('submit.candidate')) );
      next  if ( $job->meta->get_metadata('submit.never') ); 
      next  if ( $job->meta->get_metadata('submit.seed')  );
      next  if ( $job->meta->get_metadata('submit.nmpdr')  );
      
    }
    elsif ($show_option eq "rejected"){
      next  if (!($job->meta->get_metadata('submit.never') ) );
    }
    elsif ($show_option eq "accepted"){
      next  if (!($job->meta->get_metadata('submit.seed') ) );
      next  if ( $job->meta->get_metadata('import.status')  and 
		 $job->meta->get_metadata('import.status') ne "not_started" 
	       );				  
    }
    elsif ($show_option eq "in_progress"){
      next  if (!($job->meta->get_metadata('submit.seed') ) );
      next  if ( !($job->meta->get_metadata('import.status'))  or 
		 ( $job->meta->get_metadata('import.status') eq "not_started" )
	       );
    }
    elsif ($show_option eq "installed"){
      next  if ( !($job->meta->get_metadata('import.status'))  or 
		 ( $job->meta->get_metadata('import.status') ne "installed" )
	       );
    } 
    elsif ($show_option eq "computed"){
      next  if ( !($job->meta->get_metadata('import.status'))  or 
		 ( $job->meta->get_metadata('import.status') ne "computed" )
	       );
    }
    elsif ($show_option eq "all"){
      next  if ( !($job->meta->get_metadata('submit.candidate')) );
    }
    else{
      print STDERR "Not a valid display option $show_option!\n";
      next;
    }
    
    #    next if ($job->meta->get_metadata('submit.never') and not ($show_option eq "all" or 
    # 							       $show_option eq "rejected") );
    #     next if ($job->meta->get_metadata('submit.seed') and not ( $show_option eq "all" or 
    # 							       $show_option eq "accepted" ) );
    #     next if ($job->meta->get_metadata('submit.nmpdr') and not ( $show_option eq "all" or 
    # 								$show_option eq "accepted" ) );
    
    #     next if (!($job->meta->get_metadata('submit.seed')) and $show_option eq "accepted" ); 
    #     next if (!($job->meta->get_metadata('submit.never')) and $show_option eq "rejected" );
    #     next if (!($job->meta->get_metadata('import.status')) and $show_option eq "import_status" );
    
    #  next if ($job->meta->get_metadata('submit.never') and not $cgi->param('show_all') );
    #     next if ($job->meta->get_metadata('submit.seed') and not ( $cgi->param('show_all') or 
    # 							       $cgi->param('accepted') ) );
    #     next if ($job->meta->get_metadata('submit.nmpdr') and not ( $cgi->param('show_all') or 
    # 								$cgi->param('accepted')) );
    #     next if (!($job->meta->get_metadata('submit.seed')) and $cgi->param('accepted') );
    
    my $jobuser = $job->getUserObject();
    die "Could not get user for job ".$job->id.".\n" unless ($jobuser);
    
    if (  $job->meta->get_metadata('submit.suggested') or
	  $job->meta->get_metadata('submit.candidate') or
	  $cgi->param('show_all') )  {
      
      
      my @contigs = $job->contigs;
      
      # some statistic from check script
      my $nr_contigs_for_name = '-';
      my $nr_contigs_for_tax_id = '-';
      my $nr_matched_contigs = "-";
      my ($potential_tax_id) = $job->genome_id =~ /(\d+).\d+/;
      
      $nr_contigs_for_name = $job->meta->get_metadata('v2c2.nr_contigs_for_name') if ($job->meta->get_metadata('v2c2.nr_contigs_for_name'));
      $nr_contigs_for_tax_id =  $job->meta->get_metadata('v2c2.nr_contigs_for_tax_id') if ($job->meta->get_metadata('v2c2.nr_contigs_for_tax_id')); 
      $nr_matched_contigs = $job->meta->get_metadata('v2c2.nr_matched_contigs') if ($job->meta->get_metadata('v2c2.nr_matched_contigs')); 
      
      # set genome id for genome replacement
      my $replace_genome = "-";
      $replace_genome = $job->meta->get_metadata('replace.seedID') if ($job->meta->get_metadata('replace.seedID')); 
      
      # set reason for import into seed
      my $reason = "no reason";
      if ($job->meta->get_metadata('submit.candidate')) {
	$reason = $job->meta->get_metadata('submit.candidate') 
      }
      else{
	$reason = 'suggested by user';
      }
      
      if  ($job->meta->get_metadata("v2c2.message")) {
	$reason .= "<br>".$job->meta->get_metadata("v2c2.message");
      }
      
      # set default for import comment
      my $reason_checked = '0';
      $reason_checked = $job->meta->get_metadata('v2c2.genome_checked') if $job->meta->get_metadata('v2c2.genome_checked');
      
      my $default = 'NOP';
      $default = 'SEED' if ($job->meta->get_metadata('submit.seed'));
      $default = 'SEED+NMPDR' if ($job->meta->get_metadata($show_option eq "accepted") and
				  $job->meta->get_metadata('submit.nmpdr')); 
      $default = 'DONT' if ($job->meta->get_metadata('submit.never'));
      
      my $default_import_reason = '0'; 
      $default_import_reason = $job->meta->get_metadata('v2c2.import_reason') if ($job->meta->get_metadata($show_option eq "accepted") );
      my $default_import_comment = ''; 
      $default_import_comment =  $job->meta->get_metadata('v2c2.import_comment') if ($job->meta->get_metadata('v2c2.import_comment'));

      push @export , [ $job->id , $jobuser->login , 
		     $job->genome_id , $job->genome_name ,
		     scalar(@contigs), $default ,
		     $replace_genome, $default_import_comment
		   ];
      
      push @$tt_title, [ undef, undef, undef, 'Genome', undef, undef, undef ];
      push @$tt_info,  [ undef, undef, undef, 'Click for actions menu!', undef, undef, undef ];
      push @$tt_menu,  [ undef, undef, undef,
			 " &raquo; <span>".$job->genome_name."</span><a target='_blank' href='".$self->application->url."?page=ControlCenter&find_related=".
			 $job->id."'>Find related genomes in the SEED </a><br/> ".
			 " &raquo; <a target='_blank' href='http://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=".
			 $potential_tax_id."'>Go to NCBI Taxonomy</a><br>".
			 #" &raquo; <a target='_blank' href='".$self->application->url."?page=GenomeStatistics&job=".
			 #$job->id."'>View quality comparison</a><br>".
			 " &raquo; <a target='_blank' href='".$self->application->url."?page=ModifyJob&change_name=".
			 $job->id."'>Change genome name</a></br>".
			 " &raquo; <a target='_blank' href='".$self->application->url."?page=CheckJob&job=".
			 $job->id."'>Check Genome</a><br>",
			 undef, undef, undef,
		       ];
      
      push @$show, [ #"<a title='click for details' target='_blank' href='".$self->application->url.
		    #"?page=JobDetails&job=".$job->id."'>".$job->id."</a>", 
		    "<a title='Browse Genome in SEED Viewer' target='_blank' ".
		    " href='seedviewer.cgi?action=ShowOrganism&initial=1&job=".$job->id."&genome=".$job->genome_id."'>"
		    .$job->id."</a>", 
		    $jobuser->login, 
		    
		    
		    
		    '<a title="Browse genome in SEED!" target="_blank" '.
		    'href="index.cgi?action=ShowOrganism&initial=1&genome='.$job->genome_id.'&job='.
		    $job->id.'">'.$job->genome_id.'</a>',
		    $job->genome_name, 
		    scalar(@contigs), 
		    "<a title=\"Number of contigs for this organism name in the SEED\">".$nr_contigs_for_name."</a>"."/". 
		    "<a title=\"Number of contigs for this taxonomy in the SEED\">".$nr_contigs_for_tax_id."/".
		    "<a title=\"Number of matched contigs in the  SEED and new contigs for this organism\">".$nr_matched_contigs,
		    
		    # 		     join('', $cgi->radio_group( -name    => $job->id.'_include',
		    # 						 -labels  => { 'SEED' => 'Import into SEED',
		    # 							       'SEED+NMPDR' => 'Import into SEED & NMPDR',
		    # 							       'NOP' => 'No action',
		    # 							       'IGNORE' => 'Never show again'
		    # 							     },
		    # 						 -values  => [ 'SEED', 'SEED+NMPDR', 'NOP', 'IGNORE' ],
		    # 						 -default => $default,
		    # 						 -linebreak => 'true',)).'</span>',
		    $reason,
		    
		    '<span style="white-space:nowrap;">'.
		    $cgi->popup_menu(-name    => $job->id.'_include',
				     -labels  => { 'SEED' => 'Import into SEED',
						   'SEED+NMPDR' => 'Import into SEED & NMPDR',
						   'NOP' => 'No action',
						   'IGNORE' => 'Never show again',
						   'DONT' => 'Don\'t import', 
						 },
				     -values  => [ 'SEED', 'SEED+NMPDR', 'NOP', 'IGNORE' ,'DONT' ],
				     -default => $default,).'</span>',
		    '<span style="white-space:nowrap;">'.
		    $cgi->popup_menu(-name    => $job->id.'_reason',
				     -labels  => { '0' => 'Not checked yet',
						   '1' => 'New genome',
						   '2' => 'Updated sequence',
						   '3' => 'New sequence project',
						   '4' => 'Same version in the SEED',
						   '5' => 'Too many contigs',
						   '6' => 'Bad quality',
						   '7' => 'Can\'t decide',
						   '8' => 'See comment',
						 },
				     -values  => [ '0' , '1', '2' , '3' , '4' , '5' , '6', '7' ,'8'],
				     -default => $default_import_reason,).'</span>',
		    $cgi->textfield( $job->id."_replace" , $replace_genome), 
		    $cgi->textarea( $job->id."_comment" , $default_import_comment , 3 , 20 ),
		   ];
      
      $sort_by_organisms{$job->genome_name} = 1;
      push @$show_ids, $job->id;
    }
    
  }
  
  my $col_hdrs = [ 'Job', 'Submitted by', 'Genome ID', 'Genome Name', 'Nr. contigs' , 'SEED', 'Reason' ,  'Import Action' , 'Import reason' , 'Replace<br>SEED Genome'  , 'Comment'];
  
  
  # pre sort rows
  #my @sorted = sort { my @a_fields = @$a; my @b_fields = @$b; $a_fields[1] cmp $b_fields[1] } @$show;
  my @sorted = sort { $a->[3] cmp $b->[3] } @$show;
  $show = \@sorted; 
  my @sorted_menu = sort { $a->[3] cmp $b->[3] } @$tt_menu;
  $tt_menu = \@sorted_menu;
  
  
  my $display_options = $cgi->popup_menu(-name    => "show",
					 -labels  => { 'suggested' => 'Suggested genomes',
						       'accepted' => 'Accepted genomes',
						       'rejected' => 'Rejected genomes', 						       
						       'in_progress' => 'Genomes in progress',
						       'computed' => 'Computed genomes for import',
						       'installed' => 'Installed genomes',
						       'all' => 'All',
						     },
					 -values  => [ 'suggested' , 'accepted', 'rejected','in_progress','computed','installed','all' ],
					 -default => "suggested" ,);


  $content .= "<table width=\"100%\"><tr><td align=\"left\">".$self->start_form() . $display_options . $cgi->submit(-name => 'show_options', -value => 'Show') ."<td align=\"right\">". $cgi->submit( -name => 'export' , -value => 'Export current list') ."</tr></table>".$self->end_form;
  $content .= "<h4>Possible jobs for inclusion:</h4>";
  
  if (scalar(@$show) ) {
    $content .= '<p>'.$self->start_form();
    $content .= $cgi->submit(-name => 'accept', -value => 'Accept import settings');
 
#    $content .= $cgi->hidden(-name => 'jobs', -value => join(',', @$show_ids ));
    $content .= "<input type='hidden' name='jobs' value='" . join(',', @$show_ids ) . "'>";
    $content .= Table::new({ data              => $show,
			     popup_menu        => { menus => $tt_menu, titles => $tt_title, infos => $tt_info },
			     columns           => $col_hdrs,
			     show_topbrowse    => 0,
			     show_bottombrowse => 0,
			     sortable          => 1,
			     sortcols          => { 'Job'         => 1,
						    'Submitted by'=> 1,
						    'Genome ID'   => 1,
						    'Genome Name' => 1,
						    'Reason' => 1,
						  },
			     table_width       => 900,
			     id                => "all",
			     show_filter       => 1,
			     operands          => { 'Job'         => 1,
						    'Submitted by'=> 1,
						    'Genome ID'   => 1,
						    'Genome Name' => 1,
						    'Reason' => 1,
						  },
			   });
    $content .= $cgi->submit(-name => 'accept', -value => 'Accept import settings');
    $content .= $self->end_form.'</p>';
  }
  else {
    $content .= "<p>No jobs found.</p>";
  }

  if ( $cgi->param('export') ){
    open (EXPORT , ">/tmp/v2c2.txt");
    foreach my $line ( @export ){
      my $tmp = join "\t" , @$line ;
      $tmp =~ s/(\r\n|\n|\r)/ /g;
      print EXPORT $tmp ,"\n";
    }
    close EXPORT;

    if (-f "/tmp/v2c2.txt") {
      open(FILE, "/tmp/v2c2.txt") or confess "Cannot open file /tmp/v2c2.txt.";
      my @lines = <FILE>;
      close(FILE);
      print "Content-Type:application/x-download\n";  
      print "Content-Disposition:attachment;filename="."v2c2.txt"."\n\n";
      print @lines; 
      exit;
    }
  }
  return $content;
}


=pod

=item * B<set_include> ()

Update the import settings for the jobs

=cut

sub set_include {
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  my $user = $self->application->session->user->login;

  my @update = split(',',$cgi->param('jobs'));

  foreach my $id (@update) {
    my $job = Job48->new($id);
    
    if ($cgi->param($id.'_include') eq 'NOP') {
      if ($job->meta->get_metadata('submit.seed') eq 1 or
	  $job->meta->get_metadata('submit.nmpdr') eq 1) {
	$job->meta->set_metadata('submit.seed', 0);
	$job->meta->set_metadata('submit.nmpdr', 0);
	$job->meta->add_log_entry("submit", "set to no action by $user.");
      }
    }
    elsif ($cgi->param($id.'_include') eq 'SEED') {
      $job->meta->set_metadata('submit.seed', 1);
      $job->meta->set_metadata('submit.nmpdr', 0);
      $job->meta->add_log_entry("submit", "set to SEED only by $user.");
    }
    elsif ($cgi->param($id.'_include') eq 'SEED+NMPDR') {
      $job->meta->set_metadata('submit.seed', 1);
      $job->meta->set_metadata('submit.nmpdr', 1);
      $job->meta->add_log_entry("submit", "set to SEED and NMPDR by $user.");
    }
    elsif ($cgi->param($id.'_include') eq 'IGNORE') {
      $job->meta->set_metadata('submit.never', 1);
      $job->meta->set_metadata('submit.nmpdr', 0);
      $job->meta->set_metadata('submit.seed', 0);
      $job->meta->add_log_entry("submit", "set to never by $user.");
    }
    elsif ($cgi->param($id.'_include') eq 'DONT') {
      $job->meta->set_metadata('submit.never', 1);
      $job->meta->set_metadata('submit.nmpdr', 0);
      $job->meta->set_metadata('submit.seed', 0);
      $job->meta->add_log_entry("submit", "set to don't import by $user.");
    }

    else {
      die "Unknown import settings '".$cgi->param($id.'_include')."' for Job $id.";
    }

    if  ( $cgi->param($id.'_reason') ){
      if ( $cgi->param($id.'_reason') ne $job->meta->get_metadata('v2c2.import_reason') ){
	$job->meta->set_metadata('v2c2.import_reason', $cgi->param($id.'_reason') );
      }
    } 
    if  ( $cgi->param($id.'_comment') ){
      if ( $cgi->param($id.'_comment') ne $job->meta->get_metadata('v2c2.import_comment') ){
	$job->meta->set_metadata('v2c2.import_comment', $cgi->param($id.'_comment') );
      }
    }
     if  ( $cgi->param($id.'_replace') and ( $cgi->param($id.'_replace') =~ /\d+\.\d+/ ) ){
       if ( $cgi->param($id.'_replace') ne $job->meta->get_metadata('replace.seedID') ){
	 $job->meta->set_metadata('replace.seedID', $cgi->param($id.'_replace') );
       }
     } 
  }
}

=pod

=item * B<find_related> ()

Find similar genomes and present them in a table.

=cut




sub find_related {
  my $self = shift;

  my $job_id = $self->application->cgi->param('find_related');
  my $job = Job48->new($job_id);
  my $fig = FIGV->new($job->dir);
  
  my $id = $job->genome_id;
  my $name = $job->genome_name;

  # build search term
  my @terms = split(' ',$name);
  my $search = $terms[0];

  # search the database
  my $result = $fig->db_handle->SQL("SELECT genome, gname FROM genome WHERE gname like '$search%'");
  
  my $content = "<h1>Find related for $name ($id)</h1>";

  $content .= "<p> &raquo <a href='".$self->application->url."?page=ControlCenter'>Return to Import Genomes Into SEED</a></p>";
  $content .= "<p> &raquo <a target='_blank' href='index.cgi'>Go to the SEED Viewer to search for organisms</a></p>";

  $content .= "<p>Searching the organisms currently in the SEED for '$search' has returned the following results:</p>";

  if (scalar(@$result) ) {

    $content .= Table::new({ data              => $result,
			     columns           => [ 'Genome ID', 'Genome Name' ],
			     show_topbrowse    => 0,
			     show_bottombrowse => 0,
			     sortable          => 1,
			     sortcols          => { 'Genome ID'   => 1,
						    'Genome Name' => 1,
						  },
			     table_width       => 900,
			     id                => "all",
			     show_filter       => 1,
			     operands          => { 'Genome ID'   => 1,
						    'Genome Name' => 1,
						  },
			   });
  }
  else {
    $content .= "<p>No genomes found in the SEED that start with '$search'.</p>";
  }

  my $fig_org = new FIG;

  my $parameters = { fig => $fig_org, 
		     cgi => $self->application->cgi,
		     genome => "224911.1",
		     #simple => 0,
		     #data => [],
		     #
		     id  => 'genome_browser',
		     #arrow_zoom_level => 100000,
		     #start => 1,
		     #end => 300,
		 };

  $self->application->cgi->param('genome',"224911.1");
  #$self->application->cgi->param('start',"1");
  #$self->application->cgi->param('end',"300");
  $self->application->cgi->param('initial',"1");
  $self->application->cgi->param('frame_num',"2");

  print STDERR "Debug: ".$self->application->cgi->param('genome'),"\n";
  my $browser_1 = GenomeBrowser::new( $parameters );

  $parameters->{genome} = "393595.12";
  my $browser_2 = GenomeBrowser::new( $parameters );

  $content .= $browser_1 if ( $browser_1);
  $content .= $browser_2 if ( $browser_2);
  return $content;
}
