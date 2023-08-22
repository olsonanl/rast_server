package RAST::WebPage::PublishGenome;

use strict;
use warnings;

use POSIX;
use File::Basename;
use XML::Simple;
use Data::Dumper;
use Mail::Mailer;

use WebConfig;
use base qw( WebPage );

1;


=pod

=head1 NAME

MetaData - collects meta information for uploaded genome or metagenome

=head1 DESCRIPTION

Page for collecting meta data for genomes or metagenomes

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my $self = shift;
  
  $self->title("Make genome publicly accessible");

  # register components

  $self->application->register_component('TabView', 'Tabs');

  $self->application->register_component('Table' , 'PublishingTable');
  $self->application->register_component('Ajax', 'Display_Ajax');
  $self->application->register_component('Hover', 'MIGS_Hover');


  my $hover = $self->application->component('MIGS_Hover');
  $self->data('hover' , $hover);
  

  # init data
  my $user   = $self->application->session->user;
  my $uname  = $user->firstname." ".$user->lastname;
  my $uemail = $user->email;

  # get/set data for input 
  my $contact       = $self->app->cgi->param('meta.contact') || $uname; 
  my $email         = $self->app->cgi->param('meta.email')   || $uemail;
  my $note          = $self->app->cgi->param('meta.note')    || '';
  my $url           = $self->app->cgi->param('meta.url')     || '';  
  my $pubmedID      = $self->app->cgi->param('meta.PMID')  || '';
  my $rhost         = $self->app->cgi->remote_host;
  
  my $param2name = [
		     [ "meta.contact" ,"Contact person for this metagenome" ,   $contact ], 
		     [ "meta.email",   "Email address for contact",             $email ],
		     [ "meta.PMID",    "Please insert a PubMed ID if possible", $pubmedID ],
		     [ "meta.url",     "Do you have a URL we can link to",      $url ],
		     [ "meta.note",    "Note", $note ],
		   ];
  $self->data('param2name' , $param2name);
  

  # sanity check on job
  my $id = $self->application->cgi->param('job') ;
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  $self->data('job'     , $job);
  $self->data('linkin' , "http://mg-rast.mcs.anl.gov/mg-rast/FIG/linkin.cgi?metagenome=".$self->data('job')->genome_id);
  # register actions
  $self->application->register_action($self, 'reset_params', 'Reset'); 
  $self->application->register_action($self, 'publish', 'Make Public');

 
}


=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  # init
  $self->data('done', 0);
  my $cgi = $self->application->cgi;

  my $tab_view = $self->application->component('Tabs');
  $tab_view->width(800);
  $tab_view->height(180);
 
  my $user   = $self->application->session->user;
  my $uname  = $user->firstname." ".$user->lastname;
  
  # set output
  my $content = '';
  $content .= $self->application->component('Display_Ajax')->output();

  unless($self->data('job')->public()){
    $content .= '<h1>Make my genome publicly accessible  (job '.$self->data('job')->id.' , ID '.$self->data('job')->genome_id.')</h1>';
    $content .= "<p style='width:800px; text-align: justify;'>Please note: You will not be able to make your genome private again from this website. In order to do so you will have to contact mg-rast\@mcs.anl.gov. Additionally you will ask that you provide additional information about your genome in order to help us better server as a community resource. We are in the process of becoming MIGS compliant and you will be required upload addition information once that is complete.</p>";
  

    $content .= "<div id='display_div'></div>";
    $content .= "<img src='./Html/clear.gif' onload='execute_ajax(\"meta_info\", \"display_div\", \"job=".$self->data('job')->id."\");'>";
  } else {
    $content .= '<h1>Genome (job '.$self->data('job')->id.' , ID '.$self->data('job')->genome_id.') is publicly accessible.</h1>';
    $content .= "<p>Dear ".$uname.", thank you for making your genome publicly available. You can link to your public metagenome using this link: <a href='".$self->data('linkin')."'>".$self->data('linkin')."</a>. If you believe this is a mistake please contact mg-rast\@mcs.anl.gov.</p>";
  }
  
  return $content;
}



#############
#
# output methods
#
#############

sub meta_info {
  my ($self) = @_;
  
  my $cgi    = $self->application->cgi;
  my $user   = $self->application->session->user;
  my $uname  = $user->firstname." ".$user->lastname;
  my $uemail = $user->email;
  my $rhost  = $cgi->remote_host;
  my $content;
  
  $content .= $self->start_form('MetaInfo', 1);

  # get/set data for input 
  my $contact       = $self->app->cgi->param('contact') || $uname; 
  my $contact_email = $self->app->cgi->param('email')   || $uemail;
  my $note          = $self->app->cgi->param('note')    || '';
  my $url           = $self->app->cgi->param('url')     || '';  
  my $pubmedID      = $self->app->cgi->param('PMID')  || '';
  
  # set hidden values
  $content .="<input type=hidden name=meta.remote_host value=$rhost>";


  # html
  $content .= "<h3>Step 1 of 2</h3>";
  $content .= '<p><strong>Dear '.$uname.', please provide us with the following information where possible:</strong></p>';
  
 
  $content .= "<fieldset style='width: 700px'><legend>Required data: </legend>";
  
  
  $content .= "<table>";
  
  my $p2n =  $self->data('param2name');
  foreach my $p ( @$p2n ){
    if ( $p->[0] ne "meta.note"){
      $content .= "<tr><td>".$p->[1].":</td>".
	"<td><input type='text' name='".$p->[0]."' value='".$p->[2]."'></td></tr>\n";
    }
    else{
      $content .= "<tr><td>".$p->[1].":</td><td><textarea cols='50' rows=15 name='".$p->[0]."' wrap='hard'>".$p->[3]."</textarea></td></tr>\n";
    }
  }
  
   $content .= "</table></fieldset>";
 
  
  
  
  my $seq_type   = "Metagenome";
  my $project_id = 1;
  
  
  $content .= $self->end_form();  
  $content .= "<p><button style='border:1px outset black;' onclick='execute_ajax(\"display_info\", \"display_div\", \"MetaInfo\");'>Next</button></p>";
  return $content; 
}

sub display_info{
 my ($self)   = @_;
 
 my $cgi      = $self->application->cgi;
 my $user     = $self->application->session->user;
 my $uname    = $user->firstname." ".$user->lastname;
 my $content;
 
 my @params       = $cgi->param;
 my $meta_list     = $self->data('param2name');
 my @table_data;
 
 # get all meta info 
 my %meta_info;
 foreach my $param (@params){
   if (my ($var,$key) = $param =~/(meta)\.([^\s]+)/) {
     $meta_info{$param} =  $cgi->param($param);   
   }  
   else{
     # $self->app->add_message('info' , "$param not in list" );
   }
 }
 
 foreach my $entry ( @$meta_list ){
   if ( $meta_info{$entry->[0] } ) {
     push @table_data , [  $entry->[1]  , $cgi->param( $entry->[0] ) ] ;
   } 
 }
 
 my $table = $self->application->component('PublishingTable');
 $table->width(800);
 
 if (scalar(@table_data) > 50) {
   $table->show_top_browse(1);
   $table->show_bottom_browse(1);
   $table->items_per_page(50);
   $table->show_select_items_per_page(1); 
 }
 
 $table->columns([ { name => '' }, 
		   { name => '' }, 
		 ]);
 
 $table->data(\@table_data);

 $content .= $self->start_form('PublishGenome', 1);

 $content .= "<h3>Step 2 of 2</h3>";
 $content .= "<p><table>";
 $content .= "<tr><th colspan=2><p>Dear $uname, please verify your data below. These data will be used to describe and query for your metagenome.</p></th></tr>";

 $content .= "<tr><td colspan=2>".$table->output() if (scalar @table_data)."</td></tr>";
$content .= "<tr><td style='height: 10px'></td></tr><tr><td align=center>I do not agree, <button style='border:1px outset black;background:#E90100 none repeat scroll 0% 0%;'>Cancel</button></td><td align=center>I agree, <input type='submit' style='background:#86D392 none repeat scroll 0% 0%;border:1px outset black;' name='action' value='Make Public'></td></tr>";
 $content .= "</table></p>";
 $content .= $self->end_form;
 return $content;
}

sub publish_genome{
  my ($self) = @_;
  my $content = "";
  my $user     = $self->application->session->user;
  my $uname    = $user->firstname." ".$user->lastname;
  
  my $cgi = $self->application->cgi;
  my @params = $cgi->param;
  
  $content .= "<h3>Done</h3>";  
 
  
  return $content;
}

###########
#
# supporting functions
#
###########

sub publish{
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  $self->application->cgi->param('Step' , 'make genome public'); 
  $self->data('publish' , $self->data('job')->genome_id);

  $self->save_meta_data();
  $self->grant_right;

  my $user     = $self->application->session->user;
  my $uname    = $user->firstname." ".$user->lastname;
  my $to       = $user->email;
  my $from     = 'mg-rast@mcs.anl.gov';

  my $subject = "Your genome ". $self->data('publish') . " is now publicly available." ;
  my $body    = "Dear $uname, your genome is now public. You can link to the genome using " . $self->data('linkin') . ".";
    
  $self->send_email($to , $from, $subject, $body); 

  $subject = '(Job '.$self->data('job')->id.' , ID '.$self->data('job')->genome_id.") .  is now publicly available.";
  $body    = $uname." (".$user.") has made the genome public. Link provided: " . $self->data('linkin') . ".";
    
  $self->send_email( $from , $from, $subject, $body);
  
}

sub grant_right {
  my ($self) = @_;
  
  # get necessary objects
  my $application = $self->application();
  my $cgi         = $application->cgi();
  my $master      = $application->dbmaster();
  my $user        = $self->application->session->user;

  # check cgi parameters
  # my $right_target = $cgi->param('right_target');
 
  my $data_id      = $self->data('publish');

  # define right and data type for public genomes
  my $right     = "view";
  my $data_type = "genome";
  my $app       = undef ;
  my $right_target = "group|Public";
 

  unless (defined($right) && defined($data_type) && defined($data_id)) {
    $application->add_message('warning', 'You must select a data type, a right and a data id, aborting.');
    return 0;
  }

    
  unless (defined($right_target)) {
    $application->add_message('warning', 'No user or group selected, aborting.');
    return 0;
  }

  # determine target scope
  my $scope_object;
  my $scope_object_name = "";
  my ($type, $target) = split(/\|/, $right_target);
  if ($type eq 'group') {
    $scope_object = $master->Scope->get_objects( { name => $target} )->[0];
    $scope_object_name = "group " . $scope_object->name();
  } else {
    $application->add_message('warning', 'Wrong scope type.');
    return 0;
  }

  # check if the right already exists
  my $right_object;
  my $right_objects = $master->Rights->get_objects( { 'application' => $app,
						      'name' => $right,
						      'data_type' => $data_type,
						      'data_id' => $data_id,
						      'scope' => $scope_object } );
  
  # some right exists
  if (scalar(@$right_objects)) {
    $right_objects->[0]->granted(1);
    $right_object = $right_objects->[0];
  } else {
    $right_object = $master->Rights->create( { 'application' => $app,
					       'granted' => 1,
					       'name' => $right,
					       'data_type' => $data_type,
					       'data_id' => $data_id,
					       'scope' => $scope_object } );
  }
  
 
  $right_object->delegated(1);

  $application->add_message('info', "Right $right - $data_type - $data_id granted to $scope_object_name.") if $user->is_admin;
  
  return 1;
}

# meta data handling

sub save_meta_data{
 my ($self) = @_;
 my $content = "";
 
 my $cgi     = $self->application->cgi;
 my @params = $cgi->param;
 my $user    = $self->application->session->user;
 my $job     = $self->data('job');


 my @table_data;

 # create dir and file
 
 unless( $job->dir and -d $job->dir ){
   $self->app->add_message('warning', "Can't write meta data, no directory or job!");
   print STDERR "PublishGenome.pm : Can't write meta data, no directory or job\n";
   return -1;
 }

 my $meta_archive_dir = $job->dir;
 my $file       = $meta_archive_dir."/PUBLIC";
 

 rename ( $file , $file.".".time ) if (-f $file);

 open (META , ">$file") or die "Can't open $file!";

 foreach my $param (@params){
   if (my ($var,$key) = $param =~/(meta)\.([^\s]+)/) {
     my $line =  $cgi->param($param);
     $line =~ s/\n/\\n/g;
     print META $key ,"\t" , $line , "\n";
   }
   
 }

 close (META);

 $self->application->add_message('info', "Meta data saved!") if $user->is_admin;
 
 return 1;
}

sub reset_params{}

sub send_email {
  my ($self, $to , $from, $subject, $body) = @_;

  my $mailer = Mail::Mailer->new();
  $mailer->open({ From    => $from,
                  To      => $to,
                  Subject => $subject,
                })
    or die "Can't open Mail::Mailer: $!\n";
  print $mailer $body;
  $mailer->close();
  
  return 1;

}

sub required_rights {
  return [ [ 'login' ], ];
}

