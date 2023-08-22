package RAST::WebPage::GenomeStatistics;

use base qw( WebPage );

use FIG_Config;

use strict;
use warnings;
use Data::Dumper;
use RAST::RASTShared qw( get_menu_job );

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

  $self->title('Genome Statistics');
  $self->application->register_component('Table', 'ComparisonTable');

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
  if (-f $organism_directory."/comp_target") {
    $secondary_link = `cat $organism_directory/comp_target`;
  }

  # open statistics file
  my $same = 0;
  my $identical = 0;
  my $different = 0;
  my $total_a = 0;
  my $total_b = 0;
  my $matched = 0;
  my $table_data = [];
  my $titles;
  my $infos;
  my $new_shorter = 0;
  my $new_longer = 0;
  my $added = 0;
  my $lost = 0;
  my $longer_100 = 0;
  my $longer_200 = 0;
  open(FH, $organism_directory."/comparison") or return "could not open comparison file";
  while (<FH>) {
    my $line = $_;
    chomp $line;
    my @row = split /\t/, $line;

    if ($row[0] ne '-') {
	$total_a++;
	$row[0] = "<a href='".$primary_link.$row[0]."' target=_blank>".$row[0]."</a>";
    }

    if ($row[3] ne '-') {
	$total_b++;
	$row[3] = "<a href='".$secondary_link.$row[3]."' target=_blank>".$row[3]."</a>";
    }

    # parse new column
    my $newcol = $row[7];
    $newcol =~ /^(\w+)\:\s+(\d+), (\d+), (-*\d+)/;
    my $what = $1;
    my $len_a = $2;
    my $len_b = $3;
    my $diff = $4;
    $row[7] = $what;
    $row[8] = $len_a;
    $row[9] = $len_b;
    $row[10] = $diff;

    # count new column stuff
    if ($what eq 'new_shorter') {
      $new_shorter++;
    } elsif ($what eq 'new_longer') {
      $new_longer++;
    } elsif ($what eq 'added') {
      $added++;
      if ($len_b > 200) {
	$longer_200++;
      } elsif ($len_b > 100) {
	$longer_100++;
      }
    } elsif ($what eq 'lost') {
      $lost++;
    }

    # push the row into the table data
    push(@$table_data, \@row);

    # count some more
    if ($row[6] eq 'same') {
      $identical++;
      $matched++;
    } elsif ($row[6] eq 'same_func') {
      $same++;
      $matched++;
    } elsif ($row[6] eq 'different') {
      $different++;
      $matched++;
    }
  }
  close FH;

  # start content
  my $html = "<h2>Genome Statistics for $genome_name</h2>";
  $html .= "<table>";
  $html .= "<tr><th><b>Total #features in RAST A</b></th><td>" . $total_a . "</td></tr>";
  $html .= "<tr><th><b>Total #features in RAST B</b></th><td>" . $total_b . "</td></tr>";
  $html .= "<tr><th><b>#matched features</b></th><td><b>Total: </b>" . $matched . " <b>new shorter: </b>" . $new_shorter . " <b>new longer: </b>" . $new_longer . "</td></tr>";
  $html .= "<tr><th><b>#identical function</b></th><td>$identical</td></tr>";
  $html .= "<tr><th><b>#same function</b></th><td>$same</td></tr>";
  $html .= "<tr><th><b>#different function</b></th><td>$different</td></tr>";
  $html .= "<tr><th>lost features</th><td>" . $lost . "</td></tr>";
  $html .= "<tr><th>new features</th><td>" . $added . "</td></tr>";
  $html .= "<tr><th>new features between 100bp and 200bp</th><td>" . $longer_100 . "</td></tr>";
  $html .= "<tr><th>new features >200bp</th><td>" . $longer_200 . "</td></tr>";
  $html .= "</table>";

  $html .= "<br><br>";

  my $table = $application->component('ComparisonTable');
  $table->data( $table_data );
  $table->show_select_items_per_page(1);
  $table->items_per_page(20);
  $table->show_top_browse(1);
  $table->show_bottom_browse(1);
  $table->columns( [ { name => 'RAST A ID', filter => 1, sortable => 1 },
		     { name => 'Function RAST A', filter => 1, sortable => 1 },
		     { name => '#SS', filter => 1, sortable => 1 },
		     { name => 'RAST B ID', filter => 1, sortable => 1 },
		     { name => 'Function RAST B', filter => 1, sortable => 1 },
		     { name => '#SS', filter => 1, sortable => 1 },
		     { name => 'Comp', filter => 1, sortable => 1, operator => 'combobox' },
		     { name => 'Comp2', filter => 1, sortable => 1, operator => 'combobox' },
		     { name => 'len a', filter => 1, sortable => 1 },
		     { name => 'len b', filter => 1, sortable => 1 },
		     { name => 'diff', filter => 1, sortable => 1 }] );

  $html .= $table->output();
  
  # return content
  return $html;

}

=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], [ 'debug' ] ];
  push @$rights, [ 'edit', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}
