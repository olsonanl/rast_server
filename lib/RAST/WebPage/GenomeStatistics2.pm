package RAST::WebPage::GenomeStatistics2;

use base qw( WebPage );

use FIG_Config;

use strict;
use warnings;
use Data::Dumper;

1;

=pod

=head1 NAME

GenomeStatistics - an instance of WebPage which displays a comparison for a genome run through two versions of RAST

=head1 DESCRIPTION

Display information about an a comparison for a genome run through two versions of RAST

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instanciated.

=cut

sub init {
  my ($self) = @_;

  $self->title('Genome Statistics 2');
  $self->application->register_component('Table', 'ComparisonTable');

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  unless ($job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  $self->data('job', $job);

  return 1;
}

=item * B<output> ()

Returns the html output of the Annotation page.

=cut

sub output {
  my ($self) = @_;

  my $application = $self->application;
  my $cgi = $application->cgi;
  my $job = $self->data('job');
  my $basedir = $FIG_Config::rast_jobs."/".$job->id();
  my $genome_id = $job->genome_id();
  my $genome_name = $job->genome_name();
  my $organism_directory = $basedir . "/rp/" . $genome_id;

  my $primary_link = "seedviewer.cgi?page=Annotation&feature=";
  my $secondary_link = "http://anno-3.nmpdr.org/anno/FIG/protein.cgi?user=master&prot=";
  my $tertiary_link = "http://anno-3.nmpdr.org/anno/FIG/protein.cgi?user=master&prot=";
  if (-f $organism_directory."/comp_target_a") {
    $primary_link = `cat $organism_directory/comp_target_a`;
  }
  if (-f $organism_directory."/comp_target_b") {
    $secondary_link = `cat $organism_directory/comp_target_b`;
  }
  if (-f $organism_directory."/comp_target_c") {
    $tertiary_link = `cat $organism_directory/comp_target_c`;
  }

  # open statistics file
  my $table_data = [];
  open(FH, $organism_directory."/comparison2") or return "could not open comparison file";
  while (<FH>) {
    my $line = $_;
    chomp $line;
    my @row = split /\t/, $line;

    # create readable variable names
    my $id_a = $row[0];
    my $func_a = $row[1];
    my $num_subsys_a = $row[2];
    my $id_b = $row[3];
    my $func_b = $row[4];
    my $num_subsys_b = $row[5];
    my $func_ab = $row[6];
    my $lenstr_ab = $row[7];
    my $id_c = $row[8];
    my $func_c = $row[9];
    my $num_subsys_c = $row[10];
    my $func_ac = $row[11];
    my $lenstr_ac = $row[12];

    if ($id_a ne '-' && $primary_link) {
	$id_a = "<a href='".$primary_link.$id_a."' target=_blank>".$id_a."</a>";
    }

    if ($id_b ne '-' && $secondary_link) {
	$id_b = "<a href='".$secondary_link.$id_b."' target=_blank>".$id_b."</a>";
    }

    if ($id_c ne '-' && $tertiary_link) {
	$id_c = "<a href='".$tertiary_link.$id_c."' target=_blank>".$id_c."</a>";
    }

    my $len_ab = "-";
    my $len_a = "0";
    my $len_b = "0";
    my $len_diff_ab = "-";
    if ($lenstr_ab) {
      $lenstr_ab =~ /^(\w+)\:\s+(\d+), (\d+), (-*\d+)/;
      $len_ab = $1;
      $len_a = $2;
      $len_b = $3;
      $len_diff_ab = $4;
    }

    my $len_ac = "-";
    my $len_c = "0";
    my $len_diff_ac = "-";
    if ($lenstr_ab) {
      $lenstr_ac =~ /^(\w+)\:\s+(\d+), (\d+), (-*\d+)/;
      $len_ac = $1;
      $len_c = $3;
      $len_diff_ac = $4;
    }

    my $len_diff_bc = $len_b - $len_c;

    # push the row into the table data
    push(@$table_data, [ $id_a, $func_a, $id_b, $func_b, $id_c, $func_c, $func_ab, $func_ac, $len_ab, $len_ac, $len_a, $len_b, $len_c, $len_diff_ab, $len_diff_ac, $len_diff_bc ]);
  }
  close FH;

  # start content
  my $html = "<h2>Genome Statistics 2</h2>";

  my $table = $application->component('ComparisonTable');
  $table->data( $table_data );
  $table->show_select_items_per_page(1);
  $table->items_per_page(20);
  $table->show_top_browse(1);
  $table->show_bottom_browse(1);
  $table->columns( [ { name => 'RAST A ID', filter => 1, sortable => 1 },
		     { name => 'Function RAST A', filter => 1, sortable => 1 },
		     { name => 'RAST B ID', filter => 1, sortable => 1 },
		     { name => 'Function RAST B', filter => 1, sortable => 1 },
		     { name => 'RAST C ID', filter => 1, sortable => 1 },
		     { name => 'Function RAST C', filter => 1, sortable => 1 },
		     { name => 'Func A-B', filter => 1, sortable => 1, operator => 'combobox' },
		     { name => 'Func A-C', filter => 1, sortable => 1, operator => 'combobox' },
		     { name => 'Len A-B', filter => 1, sortable => 1, operator => 'combobox' },
		     { name => 'Len A-C', filter => 1, sortable => 1, operator => 'combobox' },
		     { name => 'Len A', filter => 1, sortable => 1 },
		     { name => 'Len B', filter => 1, sortable => 1 },
		     { name => 'Len C', filter => 1, sortable => 1 },
		     { name => 'Diff A-B', filter => 1, sortable => 1 },
		     { name => 'Diff A-C', filter => 1, sortable => 1 },
		     { name => 'Diff B-C', filter => 1, sortable => 1 }, ] );

  $html .= $table->output();
  
  # return content
  return $html;

}

=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], ];
  push @$rights, [ 'edit', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}
