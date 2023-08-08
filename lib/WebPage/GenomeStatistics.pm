package WebPage::GenomeStatistics;

use base qw( WebApp::WebPage );

1;

use FIG;
use FIGV;
use FIG_Config;
use CGI;
use Table;

=pod

=head1 NAME

GenomeStatistics - display statistics about a new genome

=head1 DESCRIPTION

WebPage module to display statistics about a new genome, e.g. comparison to another version
of this organism already in the seed.

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  # initialize objects
  my $app = $self->application();
  my $cgi = new CGI;
  my $job = $cgi->param('job');
  my $basedir = $FIG_Config::rast_jobs . "/" . $job;
  my $genome_id = `cat $basedir/GENOME_ID`;
  my $genome_name = `cat $basedir/GENOME`;
  chomp $genome_id;
  my $organism_directory = $basedir . "/rp/" . $genome_id;
  my $fig = FIGV->new($organism_directory);

  # open statistics file
  my $same = 0;
  my $identical = 0;
  my $different = 0;
  my $table_data;
  my $seed_genome_id = undef;
  my $titles;
  my $infos;
  open(FH, $basedir."/rp/".$genome_id."/comparison") or return "could not open comparison file";
  while (<FH>) {
    my $line = $_;
    chomp $line;
    my @row = split /\t/, $line;

    # determine seed genome id
    unless (defined($seed_genome_id)) {
      my $peg_id_2 = $row[3];
      $peg_id_2 =~ /^fig\|(\d+\.\d+)/;
      $seed_genome_id = $1;
    }

    # create popup menu
    push(@$titles, [ undef, undef, 'Subsystems', undef, undef, 'Subsystems', undef ]);
    my $info1 = join('<br>', split(/~/, $row[2]));
    if ($info1 eq "0") {
      $info1 = "- none -"
    }
    my $info2 = join('<br>', split(/~/, $row[5]));
    if ($info2 eq "0") {
      $info2 = "- none -"
    }
    push(@$infos, [ undef, undef, $info1, undef, undef, $info2, undef ]);

    # create feature links
    $row[0] = "<a href='seedviewer.cgi?action=ShowAnnotation&job=$job&prot=" . $row[0] . "' target='seed_viewer'>" . $row[0] . "</a>";
    $row[3] = "<a href='http://anno-3.nmpdr.org/anno/FIG/protein.cgi?user=master&prot=" . $row[3] . "' target='anno_seed'>" . $row[3] . "</a>";

    # count subsystems
    unless ($row[2] eq '0') {
      $row[2] = scalar(split /~/, $row[2]);
    }
    unless ($row[5] eq '0') {
      $row[5] = scalar(split /~/, $row[5]);
    }

    # push the row into the table data
    push(@$table_data, \@row);

    # count some more
    if ($row[6] eq 'same') {
      $identical++;
    } elsif ($row[6] eq 'samefunc') {
      $same++;
    } elsif ($row[6] eq 'different') {
      $different++;
    }
  }
  close FH;
  my $seed_genome_name = $fig->orgname_of_orgid($seed_genome_id);

  # get feature information
  my $features_rast = $fig->all_features_detailed_fast($genome_id);
  my $features_seed = $fig->all_features_detailed_fast($seed_genome_id);

  # set page title
  $self->title('Genome Statistics');

  # start content
  my $html = "<h2>Genome Statistics for $genome_name</h2>";
  $html .= "<p><b>RAST: $genome_name ($genome_id)</b> has been compared to <b>SEED: $seed_genome_name ($seed_genome_id)</b></p>";
  $html .= "<table>";
  $html .= "<tr><th><b>Total #features in RAST</b></th><td>" . scalar(@$features_rast) . "</td></tr>";
  $html .= "<tr><th><b>Total #features in SEED</b></th><td>" . scalar(@$features_seed) . "</td></tr>";
  $html .= "<tr><th><b>#matched features</b></th><td>" . scalar(@$table_data) . "</td></tr>";
  $html .= "<tr><th><b>#identical features</b></th><td>$identical</td></tr>";
  $html .= "<tr><th><b>#same features</b></th><td>$same</td></tr>";
  $html .= "<tr><th><b>#different features</b></th><td>$different</td></tr>";
  $html .= "</table>";

  $html .= "<br><br>";

  my $table = Table::new( { data => $table_data,
			    columns => ['RAST ID','Function RAST','#SS','SEED ID','Function SEED','#SS','Comp'],
			    show_perpage => 1,
			    perpage => 20,
			    show_topbrowse => 1,
			    show_bottombrowse => 1,
			    sortable => 1,
			    popup_menu => { titles => $titles, infos => $infos },
			    operands => { 'RAST ID' => 1,
					  'Function RAST' => 1,
					  'SEED ID' => 1,
					  'Function SEED' => 1,
					  'Comp' => 1 } } );

  $html .= $table;
  
  # return content
  return $html;
}
