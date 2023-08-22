package RAST::WebPage::JobImport;

use strict;
use warnings;

use POSIX;

use base qw( WebPage );
use WebConfig;

use Job48;
1;


=pod

=head1 NAME

JobImport - an instance of WebPage which displays import options for a job

=head1 DESCRIPTION

Job Import page 

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  my $fig = new FIG;
  $self->data('FIG', $fig);

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  $self->data('job', $job);

  # sanity check on import 

  my $import = $self->app->data_handle('RAST')->Import->init({ job => $job });
  unless (ref $import) {
    $self->app->error("RAST job $id has not been suggested for import.");
  }

  $self->data('import', $import);

  # gather data
  my $seed_organism = $self->get_seed_organism_list();
  $self->data('SeedOrganism' , $seed_organism);

  # register components

  $self->title("Control Center - Job Import");
  $self->application->register_component('Table', 'GenomeDetails');
  $self->application->register_component('Table', 'GenomeNames');
  $self->application->register_component('TabView', 'Overview');
  
  $self->application->register_component('FilterSelect', 'SeedGenome');

  # add some links
  if ($job) {
    my $jobmenu = 'Job #'.$id;
    $self->app->menu->add_category($jobmenu, "?page=JobDetails&job=".$id);
    $self->app->menu->add_entry($jobmenu, 'Debug this job', 'rast.cgi?page=JobDebugger&job='.$id, undef, [ 'debug' ]);
    $self->app->menu->add_entry($jobmenu, 'Delete this job', 'rast.cgi?page=JobDelete&job='.$id, undef, 
				[ 'delete', 'genome', $job->genome_id ]);
  }

  # register actions
  $self->application->register_action($self, 'set_import_action', 'Set import action');
  $self->application->register_action($self, 'set_genome_name', 'Change name');

  return 1;

}
 

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  my $job = $self->data('job');

  my $content = '<h1>Jobs Details #'.$job->id.'</h1>';
  $content .= '<h5>'.$job->genome_name.'</h5>';
  $content .= "<p> &raquo <a href='?page=ControlCenter'>Back to the Import Overview</a></p>";
  $content .= '<p> &raquo; <a href="?page=JobDetails&job='.$job->id.
   '">Go to the Job Details page</a> '; 

  unless ($job->viewable) {
    $content .= "<p><em>This RAST job is not yet finished. No import options available at this stage.</p>";
    return $content;
  }

  $content .= '<p> &raquo; <a target="_blank" href="seedviewer.cgi?page=Organism&organism='.
    $job->genome_id.'">Browse annotated genome in SEED Viewer</a></p>';


  # do lots of useful stuff here
  # $content .= "<p>Useful stuff</p>";

  my $overview = $self->application->component('Overview');
#$overview->width(600);
#$overview->height(180);
my $compare_by_names = $self->create_name_table();


#$overview->add_tab('Import Action', $self->create_import_action_table );
#$overview->add_tab('Tabulator C', 'This is the content of tab c');
$overview->add_tab('Genome Statistic',  $self->create_import_info_table );
$overview->add_tab('Compare by names ('.$job->genome_name.')',  $compare_by_names);
$overview->add_tab('Change name', $self->create_change_name);
$content .= $overview->output();

  return $content;

}


=pod

=item * B<supported_rights>()

Returns a reference to the array of supported rights. This adds the 'import, *, *'
right the RAST admin scope. That right is used to check visibility of the pages
concerned with import. To actually import genomes, 'import, genome, id' rights are
required.

=cut

sub supported_rights {
  return [ [ 'import', '*', '*' ] ];
}



=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], [ 'import' ] ];
  push @$rights, [ 'import', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}




sub create_import_action_table{
  my ($self) = @_;
  my $content = "<p>In progress</p>";


  return $content;
}

sub create_import_info_table{
  my ( $self) = @_;
  my $job_dir = $FIG_Config::rast_jobs . "/" . $self->data("job")->id;
  
  # get components
  my $table         = $self->application->component('GenomeDetails');
  my $select_genome = $self->application->component('SeedGenome');

  my $content;
  
  
  # get data and init select box for genome to be replaced
  my $genome_ids = $self->data('SeedOrganism');
  
  my $idlist = $genome_ids->{ ids };
  unshift @$idlist , "none" ;
  
  my $orglist = $genome_ids->{ orgs };
  unshift @$orglist , "none" ;
  
  $select_genome->labels( $idlist );
  $select_genome->values( $idlist );
  $select_genome->size(10);
  $select_genome->width(250);
  $select_genome->name('replace_genome');
  my $default = $self->data('import')->replaces() || "none";
  $select_genome->default($default);
  
 


  unless (-f  $job_dir."/import_info.txt" ){
    `check_rast_genome -d $job_dir`;
  }

  open (FILE , $job_dir."/import_info.txt") or warn "Can't open $job_dir/import_info.txt \n";

  my @data;
  my %import;
  while (<FILE>){
    my ($key, $value) = split "\t" , $_;
    $import{$key} = $value;

    if ($key eq "SEED_ID" ){

     my $seed_tax = $self->data('FIG')->get_taxonomy_id_of( $value );
   
    }
    else{
      # push @data , [ $key , $value ] ;
    }
  }

  close (FILE);

  my ($rast_tax_id) =  $self->data('job')->genome_id =~/(\d+)\.\d+/;
  my $seed_tax = "none";
  $seed_tax = $self->data('FIG')->get_taxonomy_id_of( $import{SEED_ID} ) if $import{SEED_ID};

  my $url_name = $self->data('job')->genome_name;
  $url_name =~ s/\s+/\+/g;

  $import{TAX_ID_TO_NCBI_GENOME} = "none" unless $import{TAX_ID_TO_NCBI_GENOME};
  my $ncbi_genome = $import{TAX_ID_TO_NCBI_GENOME};
  $ncbi_genome =~ s/\s+/\+/g;
  
  $import{SEED_ID} = "none" unless $import{SEED_ID};

  my $url = "http://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?name=$url_name";

  push @data , [ "Rast genome name" , "<a target='_blank' href='$url'>" . $self->data('job')->genome_name . "</a>" ];
  push @data , [ "Taxonomy ID for Rast genome" , "<a target='_blank' href='http://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?mode=Info&id=$rast_tax_id'>$rast_tax_id</a>" ];
  push @data , [ "Number of contigs for this genome in Rast" , $import{NR_RAST_CONTIGS} ]; 
  push @data , [ "Number of contigs for this genome name in SEED" , $import{NR_SEED_CONTIGS} ];
  push @data , [ "Number of matched contigs for this genome in SEED and Rast" , $import{NR_MATCHED_CONTIGS} ];
  push @data , [ "Found genomes in SEED with same taxonomy id" , $import{TAX_ID_TO_FIG_IDS} ];
  push @data , [ "Found genome in SEED with same name" ,"<a target='_blank' href='seedviewer.cgi?page=Organism&organism=".$import{SEED_ID}."'>".$import{SEED_ID}."</a> (<a target='_blank' href='http://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?mode=Info&id=$seed_tax&lvl=3&lin=f&keep=1&srchmode=1&unlock'>NCBI Taxonomy</a>)" ];
  push @data , [ "Found NCBI organism for taxonomy id $rast_tax_id" , "<a target='_blank' href='http://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?name=$ncbi_genome'>" . $import{TAX_ID_TO_NCBI_GENOME} . "</a>" ];
  push @data , [ "Number of contigs for NCBI organism" , $import{NR_NCBI_CONTIGS} ];
  push @data , [ "Number of genome projects for NCBI organism" , $import{NR_NCBI_GENOME_PROJECTS} ];
  push @data , [ "Note" , $import{NOTE} ];
  push @data , [ "Error" , $import{ERROR} ];
  
  

  $table->width(800);
  if (scalar(@data) > 50) {
    $table->show_top_browse(1);
    $table->show_bottom_browse(1);
    $table->items_per_page(50);
    $table->show_select_items_per_page(1);
  }

   $table->columns([ { name => '', sortable => 1 }, 
 		    { name => '', sortable => 1 },
 		  ]);
  
  $table->data(\@data);
  $content .= $table->output();
  
  $content .= "\n";

  # add the form
  $content .= '<p>'.$self->start_form(undef, { 'job' => $self->data("job")->id ,
					       page => "ControlCenter" ,
					     });
  $content .= "<h4>Import settings:</h4><br>";
  $content .= "Action:".$self->app->cgi->popup_menu( -name      => 'what',
					   -values    => [ 'import', 'rejected', 'pending' ],
					   -labels    => { 'import' => 'import', 
							   'rejected' => 'reject',
							   'pending' => 'decide later'
							 }, 
					   -default   =>  $self->data('import')->action,
					 ); 

  my $priority = $self->data('import')->priority() || '5' ;
  $content .= " Priority:".$self->app->cgi->popup_menu( -name      => 'priority',
					   -values    => [ '2', '5', '8' ],
					   -labels    => { '2' => 'low', 
							   '5' => 'normal',
							   '8' => 'high'
							 }, 
					   -default   =>  $priority,
					 );
  $content .= " Comment:".$self->app->cgi->textfield( -name => 'comment',
					  -size => 50 ,
					  -default =>  $self->data('import')->comment,
					  -rows => 3,
					);

  $content .= "</p><p><table><tr><th>Select new SEED genome to be replaced:<br><hr>";
  $content .= "<table><tr><td>Current genome to be replaced:<td> "."</tr>";
  $content .= "<tr><td>". $genome_ids->{ id2org }->{ $self->data('import')->replaces() } ."<td>".$self->data('import')->replaces()."</tr></table>";
  $content .= "<td>" . $select_genome->output() ."</tr></table>\n";
  $content .= "</p><p>".$self->app->cgi->submit(-name => 'action', -value => 'Set import action');
  $content .= $self->end_form.'</p>';  

  return $content;
}


sub set_import_action {
  my ($self) = @_;

  my $comment = $self->app->cgi->param('comment') || '';
  my $action = $self->app->cgi->param('what') || '';

  #print STDERR "SET_IMPORT_ACTION: $action , $comment";

  # fancy input checks!
  $self->data('import')->comment($comment);
  $self->data('import')->action($action);

  if   ($self->data('import')->action and $self->data('import')->action eq $action){
    
    $self->app->add_message('info', "Set import action to : $action");
  }
  else{
     $self->app->add_message('warning', "Can not set import action to $action. Import action is still ".$self->data('import')->action);
  }

  

  return 1;

} 


sub set_genome_name {
  my ($self) = @_;

  my $genome_name = $self->app->cgi->param('genome_name') || '';


  # fancy input checks!
  
  my $import = $self->data('import');
  my $job    = $self->data('job');
  my $job48  = Job48->new( $job->id );

  unless ( $job48 ){
    $self->app->add_message('warning', "Can't get job for ".$job->id .". Genome name not changed.");
    return 0;
  }

  my $old_name = $job48->genome_name;
  my $changed_name = $job48->set_genome_name( $genome_name );

  if   ( $changed_name eq $genome_name ){
    
    $self->app->add_message('info', "Name changed from $old_name to $changed_name.");
  }
  else{
     $self->app->add_message('warning', "Can't change name to $genome_name");
  }

  return 1;

} 
  

sub create_change_name{

  my ($self) = @_;
  my $job = $self->data('job');

  my $content = " <h1> Change Genome Name</h1>  <p>Change genome name for <b>".$job->genome_name . "</b> from user ". $job->owner->firstname ." ". $job->owner->lastname. ".</p>";

    # add the form
  $content .= '<p>'.$self->start_form(undef, { 'job' => $job->id });
  
  $content .= "New name: ".$self->app->cgi->textfield( -name => 'genome_name', -size => 70 );
  $content .= "</p><p>".$self->app->cgi->submit(-name => 'action', -value => 'Change name');
  $content .= $self->end_form.'</p>';  



  return $content;

}

sub create_name_table{
  my ( $self) = @_;
  
 
  # init/set variables
  my @data;
  my $content;
  my $fig = new FIG; 
  
  my $myjob =  $self->data("job");
  my $table = $self->application->component('GenomeNames');
  

  # create list of genomes with similar names
  # get RAST genomes first

  # get partial names
  my $genome_name_for_current_job = $myjob->genome_name;

  # remove special characters used in regexps
  $genome_name_for_current_job =~ s/[\(\)\[\]]/ /g ;

  my @fields = split " " , $genome_name_for_current_job ;
  
  # get all RAST jobs
  my $jobs = $self->app->data_handle('RAST')->Job->get_jobs_for_user($self->application->session->user, 'import', 1);

  foreach my $job (@$jobs) {
    
    my $import = $self->app->data_handle('RAST')->Import->init({ job => $job });
    next unless $import;

    my $genome_name = $job->genome_name;
    my $found = 0;
    foreach my $field (@fields){
      if (  $genome_name =~ s/$field/<b>$field<\/b>/ ){
	$found = 1;
      } 
    }
    my $import_status = $import->status || "none";
    my $import_action = $import->action || "none";
    push @data, [ $genome_name, $job->genome_id , "RAST (job ".$job->id.")", $import_action."/".$import_status ] if ($found);
  }


  # get all SEED genomes
  #my @genomes = $fig->genomes();


  my $genomes = $self->data('SeedOrganism');
  my $org2id  = $genomes->{ org2id };

  foreach my $genome_name ( @{ $genomes->{ orgs } } ){
    #my $genome_name = $fig->genus_species( $genome );
    
    my $genome_id = $org2id->{ $genome_name } || "not found";
    my $found = 0;
    foreach my $field (@fields){
      if (  $genome_name =~ s/$field/<b>$field<\/b>/ ){
	$found = 1;
      } 
    }

    
    push @data, [ $genome_name, $genome_id  , "SEED" , "installed" ] if ($found);


  }
  
  $table->width(800);
  if (scalar(@data) > 50) {
    $table->show_top_browse(1);
    $table->show_bottom_browse(1);
    $table->items_per_page(50);
    $table->show_select_items_per_page(1);
  }
  $table->show_clear_filter_button(1);
  $table->columns([ { name => 'Genome Name', filter => 1, sortable => 1 }, 
		    { name => 'Genome ID', filter => 1 },
		    { name => 'Location' , filter => 1 },
		    { name => 'Status' , filter => 1 },
		  ]);
  $table->data(\@data);
  $content .= $table->output();
  
  
  return $content;
}


# returns an anonymous hash with sorted ids and orgs as keys
# ids is reference on a sorted list of genome ids and orgs is 
# the a list of organism names. The positions of id and organism 
# correspond to each other

sub get_seed_organism_list{
  my ($self) = @_;
  
  my $fig   = $self->data('FIG');
  my @ids   = sort {$a<=>$b} $fig->genomes;

  my $id2org = {};
  my $org2id = {};
  my @orgs;

  foreach my $id (@ids){
    my $org = $fig->genus_species( $id );
    $id2org->{ $id }  = $org;
    $org2id->{ $org } = $id;
    push @orgs , $org;
  }

  return { ids    => \@ids ,
	   orgs   => \@orgs,
	   id2org => $id2org,
	   org2id => $org2id,
	 };
}
