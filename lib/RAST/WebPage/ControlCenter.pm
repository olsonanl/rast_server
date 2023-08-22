package RAST::WebPage::ControlCenter;

use strict;
use warnings;

use base qw( WebPage );

1;


=pod

=head1 NAME

ControlCenter - overview of the control center page

=head1 DESCRIPTION

Overview page for the job import

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;

  $self->title("RAST Server - Control Center");
  $self->application->register_component('Table', 'Jobs');
  
  
  $self->application->register_action($self, 'set_import_action', 'Set import action');
}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  my $content = '<h1>Import Overview</h1>';

  $content .= '<p>The overview below list all genomes currently processed and ready for import into the seed.</p>';

  $content .= '<h2>Jobs ready for import:</h2>';

  my $data = [];
  my $jobs;
  eval { 
#    $jobs = $self->app->data_handle('RAST')->Job->get_jobs_for_user($self->application->session->user, 'import', 1);
  };

  print STDERR "Retrieving jobs\n";
  my $get_options = {};
  $get_options->{viewable} = 1 if (1);
  my $imports = $self->app->data_handle('RAST')->Import->get_objects();

  print STDERR scalar @$imports . " jobs found\n";

  unless (defined $imports) {
    $self->app->error("Unable to retrieve the import overview.");
    return '';
  }

  if (scalar(@$imports)) {

      my @tmp;
      foreach my $i (@$imports){
	  my $j = 0 ;
	  eval { $j = $i->job };
	  push @tmp , $i if ($j) ;
	  }
      print STDERR "Sorting\n";
    @$imports = sort { $b->job->id <=> $a->job->id } @tmp;
      print STDERR "Getting data\n";
    foreach my $import (@$imports) {
      
      my $job = $import->job;
      unless (ref $job) {
	  print STDERR "No job for Import\n";
	  next;
      };

      my $import_action  = $import->action || "none" ;
      my $import_comment = "comment disabled" || $import->comment || "none";

      push @$data, [ "<a href='?page=JobDetails&job=".$job->id."'>".$job->id.'</a>', 
		     "<a target='_blank' href='seedviewer.cgi?page=Organism&organism='".
		     $job->genome_id.'">'.$job->genome_id.'</a>',
		     $job->genome_name,
		     ($import->suggested_by == 1) ? 'user' : 'batch',
		     "none" || $job->owner->lastname.', '.$job->owner->firstname,
		     $import->priority,
		    
		     {
		      data => $import->reason,
		      #tooltip => $import_comment,
		      },
		     {
		      data => "<a href='?page=JobImport&job=".$job->id."'>".$import_action.'</a>',
		      #onclick => "<a href='?page=JobImport&job=".$job->id."'>". ,
		      #tooltip => "click here to go to the Import Details page",
		      tooltip => "Comment: ".$import_comment,
		     },
		     $import->status,
		   ];
    }
 #  "<a href='?page=JobImport&job=".$job->id."'>".$import_action.'</a>
    # create table

      print STDERR "Drawing table\n"; 

    my $table = $self->application->component('Jobs');
    $table->width(800);
    if (scalar(@$data) > 50) {
      $table->show_top_browse(1);
      $table->show_bottom_browse(1);
      $table->items_per_page(50);
      $table->show_select_items_per_page(1);
    }
    $table->show_clear_filter_button(1);
    $table->columns([ { name => 'Job', filter => 1, sortable => 1 }, 
		      { name => 'Genome&nbsp;ID', sortable => 1 , filter => 1 },	     
		      { name => 'Genome Name', sortable => 1 , filter => 1 },
		      { name => 'Who?', sortable => 1, filter => 1, operator => 'combobox' },
		      { name => 'Owner', filter => 1, },     
		      { name => 'Prio', sortable => 1 , filter => 1 , operator => 'combobox' },
		      { name => 'Suggested', sortable => 1, filter => 1, operator => 'combobox' },
		      { name => 'Action', sortable => 1, filter => 1, operator =>'combobox' },
		      { name => 'Status', sortable => 1, filter => 1, operator => 'combobox' },   
		     
		    ]);
    $table->data($data);
    $content .= $table->output();
  }
  else {
    $content .= "<p>No jobs found.</p>";
    $content .= "<p> &raquo <a href='?page=Jobs'>Back to the jobs overview</a></p>";
  }
    

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
  return [ [ 'login' ], [ 'import' ],
	 ];
}




# Parameter are set in JobImport.pm

sub set_import_action {
  my ($self) = @_;


  my $id = $self->application->cgi->param('job') || '';

  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }

  my $import = $self->app->data_handle('RAST')->Import->init({ job => $job });
  unless (ref $import) {
    $self->app->error("RAST job $id has not been suggested for import.");
  }
  $self->data('import', $import);


  my $comment  = $self->app->cgi->param('comment') || '';
  my $action   = $self->app->cgi->param('what') || '';  
  my $priority = $self->app->cgi->param('priority') || '5';
  my $replace  = $self->app->cgi->param('replace_genome') || 'none';

  print STDERR "SET_IMPORT_ACTION: $action , $comment , $priority";

  # set params in db and file
  $self->data('import')->comment($comment);
  $self->data('import')->action($action);
  $self->data('import')->priority($priority);
  $self->data('import')->replaces($replace) unless( $replace eq "none" );

  if   ($self->data('import')->action and $self->data('import')->action eq $action){
    
    $self->app->add_message('info', "Set import action to $action and priority to $priority for job $id");
    $self->app->add_message('info', $self->data('import')->comment() );
    $self->app->add_message('info', "Replace SEED genome with ID $replace");
  }
  else{
     $self->app->add_message('warning', "Can not set import action to $action. Import action is still ".$self->data('import')->action);
  }
}
