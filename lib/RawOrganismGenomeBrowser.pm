package RawOrganismGenomeBrowser;

use strict;
use warnings;
use URI::Escape;

1;

use CGI qw(:standard);
use Data::Dumper;
use FIG;

use GD;
use GD::Polyline;
use Math::Trig;
use List::Util;
use MIME::Base64;

sub new {
    my ($parameters) = @_;

    my $cgi              = new CGI;
    my $id               = $parameters->{id} || 'genome_browser';
    my $arrow_zoom_level = $parameters->{arrow_zoom_level} || 100000;

    my $genome_directory = $parameters->{genome_directory};
    my $genome           = $parameters->{genome_id};

    my $genome_name      = $parameters->{genome_name} || "";

    my $contig_lengths   = &get_contig_data($genome_directory);
    my $contig           = $cgi->param('contig') || (sort(keys(%$contig_lengths)))[0];

    # check what to display
    my $show_cds;
    if (defined($cgi->param('show_cds'))) {
      $show_cds = $cgi->param('show_cds');
    }
    my $show_rna;
    if (defined($cgi->param('show_rna'))) {
      $show_rna = $cgi->param('show_rna');
    }
    my $show_pp;
    if (defined($cgi->param('show_pp'))) {
      $show_pp = $cgi->param('show_pp');
    }
    my $show_pi;
    if (defined($cgi->param('show_pi'))) {
      $show_pi = $cgi->param('show_pi');
    }
    if (defined($cgi->param('initial'))) {
      $show_cds = 'on';
      $show_rna = 'on';
      $show_pp = 'on';
      $show_pi = 'on';
    }

    my $zoom_select;
    my $frame_select;
    my $curr_frames = $parameters->{frames} || 6;
    my $options;
    
    # determine zoom level
    my $curr_zoom = $contig_lengths->{$contig};
    if (defined($parameters->{zoom_level})) {
      $curr_zoom = $parameters->{zoom_level};
    }
    if ($cgi->param('zoom_level')) {
      $curr_zoom = $cgi->param('zoom_level');
    }
    
    # determine window to display
    my $start = $cgi->param('start') || 1;
    my $end = $cgi->param('end') || $curr_zoom;
    
    # get contig lengths
    my @contigs = sort(keys(%$contig_lengths));
    if (defined($cgi->param('contig'))) {
      $contig = $cgi->param('contig');
    }
    
    # sanity check start and end
    if ($start < 1) {
      $start = 1;
    }
    if ($end > $contig_lengths->{$contig}) {
      $end = $contig_lengths->{$contig};
    }
    
    # check for total view
    if ($curr_zoom eq $contig_lengths->{$contig}) {
      $start = 1;
      $end = $contig_lengths->{$contig};
    }
    
    # calculate window size
    my $window = $end - $start;
    
    # create zoom selector
    $zoom_select = $cgi->popup_menu(   -id => $id . "_zoom_select",
				       -name => "zoom_level",
				       -default => $curr_zoom,
				       -onchange => "browse(\"zoom\", \"" . $id . "\");",
				       -values => [$contig_lengths->{$contig}, '1000000', '500000', '100000', '20000', '10000', '1000'],
				       -labels => {$contig_lengths->{$contig} => 'all','1000000' => '1 Mbp', '500000' => '500 kbp', '100000' => '100 kbp', '20000' => '20 kbp', '10000' => '10 kbp', '1000' => '1 kbp'});
    
    # determine number of reading frames
    if ($cgi->param('frame_num')) {
      $curr_frames = $cgi->param('frame_num');
    }
    
    # create frame selector
    $frame_select =  $cgi->popup_menu(-id => $id . "_frame_select",
				      -name => "frame_num",
				      -default => $curr_frames,
				      -values => ['6', '2', '1'],
				      -labels => {'6' => 'all', '2' => '+/-', '1' => 'single'});
    
    # create options panel
    $options = "<table><tr style='display: none;'><td><b>Options</b></td></tr><tr><td>Reading Frames</td></tr><tr><td>" . $frame_select . "</td></tr><tr style='display: none;'><td>" . $cgi->checkbox(-name => 'show_cds', -checked => $show_cds, -label => '') . get_minibox(19). 'Show CDS'  . "</td></tr><tr style='display: none;'><td>" . $cgi->checkbox(-name => 'show_rna', -checked => $show_rna, -label => '') . get_minibox(0). 'Show RNA'  . "</td></tr><tr style='display: none;'><td>" . $cgi->checkbox(-name => 'show_pi', -checked => $show_pi, -label => '') . get_minibox(5) . 'Show Pathogenicity'  . "</td></tr><tr style='display: none;'><td>" . $cgi->checkbox(-name => 'show_pp', -checked => $show_pp, -label => ''). get_minibox(4) . 'Show Prophages'  . "</td></tr><tr><td><input type='submit' value='Refresh'></td></tr></table>";
    
    # id, location, aliases, type, minloc, maxloc, assigned_function, made_by, quality
    my $all_features = get_visible_features($genome_directory, $contig, $start, $end);
    unless (@$all_features) {
      $all_features = [];
    }

    # collect the data for the different frame options
    my $data_plus_frame_0;
    my $data_plus_frame_1;
    my $data_plus_frame_2;
    my $data_middle;
    my $data_minus_frame_0;
    my $data_minus_frame_1;
    my $data_minus_frame_2;
    my $data_plus;
    my $data_minus;
    my @overlay_resolved_data;

    my $data_all;
    my $peg_type = 'arrow';
    if (($end - $start) > $arrow_zoom_level) {
      $peg_type = 'box';
    }

    foreach my $feature (@$all_features) {
      # assign feature attributes
      my ($peg_id, $cds_start, $cds_end, $function, $subsystem) = @$feature;

      my $description = [];
      my $category = 1;
      my $name = "";
      my $title = '';
      my $zlayer = 1;
      my $strong = 0;
      my $type;
      my $featuretype;
      if ($peg_id =~ /peg/) { $featuretype = 'peg'; }
      elsif ($peg_id =~ /rna/) { $featuretype = 'rna'; }
      elsif ($peg_id =~ /pp/) { $featuretype = 'pp'; }
      elsif ($peg_id =~ /pi/) { $featuretype = 'pi'; }
      else { $featuretype = 'unknown'; }

      push(@$description, { title => 'ID', value => $peg_id || "" });

      my $no_frame = 0;
      if ($featuretype eq 'peg') {
	unless ($show_cds) { next; }
	$title = 'CDS Information';
	$zlayer = 2;
	$category = 0;
	if (defined($parameters->{clusters})) {
	  if (exists($parameters->{clusters}->{$peg_id})) {
	    $category = $parameters->{clusters}->{$peg_id};
	    $name = $category;
	  }
	}
	if (defined($parameters->{coupling})) {
	  if (exists($parameters->{coupling}->{$peg_id})) {
	    push(@$all_features, [ $peg_id, $feature->[1], $feature->[2], 'cluster', $feature->[4], $feature->[5], $function, $feature->[7], $feature->[8], $cds_start, $cds_end ]);
	  }
	}
	$type = $peg_type;
	push(@$description, { title => 'Function', value => $function || "" });
      } elsif ($featuretype eq 'rna') {
	unless ($show_rna) { next; }
	$title = 'RNA Information';
	$zlayer = 3;
	$category = 3;
	$type = 'box';
	$no_frame = 1;
      } elsif ($featuretype eq 'pp') {
	$zlayer = 1;
	unless ($show_pp) { next; }
	$title = 'Prophage Information';
	$category = 4;
	$type = 'box';
	$no_frame = 1;
      } elsif ($featuretype eq 'pi') {
	$zlayer = 2;
	unless ($show_pi) { next; }
	$title = 'Pathogenicity Island Information';
	$category = 5;
	$type = 'box';
	$no_frame = 1;
      } elsif ($featuretype eq 'cluster') {
	$zlayer = 1;
	$title = 'Clustered Gene';
	$category = 0;
	$type = 'bigbox';
	$no_frame = 0;
      } else {
	$zlayer = 1;
	$title = 'Unknown Entity';
	$category = 0;
	$type = 'box';
	$no_frame = 1;
      }
      push(@$description, { title => 'Contig', value => $contig },
	   { title => 'Start', value => $cds_start },
	   { title => 'Stop', value => $cds_end },
	   { title => 'Length', value => abs($cds_start - $cds_end) . ' bp' });

      my $links_list = [ { link => 'index.cgi?action=ShowAnnotation&prot=' . $peg_id, linktitle => 'View Annotation' }];
      
      push(@$links_list, { link => 'index.cgi?action=ShowOrganism&subaction=BrowseGenome&genome=' . $genome . '&start=' . ($cds_start - 5000) . '&end=' . ($cds_end + 5000) . '&initial=1&zoom_level=20000', linktitle => 'Zoom on Area' });
   
      # if the menu contains only one link, make it onclick instead of menu
      my $onclick;
      if (scalar(@$links_list) == 1) {
	$onclick = "location='" . $links_list->[0]->{link} . "';";
	$links_list = undef;
      }

      my $values = { start       => $cds_start,
		     end         => $cds_end,
		     title       => $title,
		     zlayer      => $zlayer,
		     name        => $name || "",
		     type        => $type,
		     category    => $category,
		     onclick     => $onclick,
		     links_list  => $links_list,
		     strong      => $strong,
		     description => $description };
      if (defined($feature->[11])) {
	$values->{highlight} = 1;
      }

      if ($curr_frames eq 'resolve') {
	my $not_inserted = 1;
	foreach my $overlay_line (@overlay_resolved_data) {
	  my $no_overlay = 1;
	  foreach my $item (@$overlay_line) {
	    if (
		(($cds_start > min($item->{start}, $item->{end})) && ($cds_start < max($item->{start}, $item->{end}))) ||
		(($cds_end > min($item->{start}, $item->{end})) && ($cds_end < max($item->{start}, $item->{end}))) ||
		((min($cds_start, $cds_end) < min($item->{start}, $item->{end})) && (max($cds_start, $cds_end) > max($item->{start}, $item->{end}))))
	      {
		$no_overlay = 0;
		last;
	      }
	  }
	  if ($no_overlay) {
	    push(@$overlay_line, $values);
	    $not_inserted = 0;
	    last;
	  }
	}
	if ($not_inserted) {
	  push(@overlay_resolved_data, [ $values ]);
	}
      }
      push(@$data_all, $values);
      if ($no_frame) {
	push(@$data_middle, $values);
      } else {
	if ($cds_start < $cds_end) {
	  push(@$data_plus, $values);
	  if (($cds_start % 3) == 0) {
	    push(@$data_plus_frame_0, $values);
	  } elsif (($cds_start % 3) == 1) {
	    push(@$data_plus_frame_1, $values);
	  } else {
	    push(@$data_plus_frame_2, $values);
	  }
	} else {
	  push(@$data_minus, $values);
	  if (($cds_end % 3) == 0) {
	    push(@$data_minus_frame_0, $values);
	  } elsif (($cds_end % 3) == 1) {
	    push(@$data_minus_frame_1, $values);
	  } else {
	    push(@$data_minus_frame_2, $values);
	  }
	}
      }
    }

    # determine number of frames to be displayed
    my $data;
    my $line_config;

    # adjust length of organism name to max. 15 characters
    my $organism_name = $parameters->{organism} || "";
    my $organism_short_name = $organism_name;
    if (length($organism_short_name) > 14) {
      my $cutoff = length($organism_short_name) - 13;
      $organism_short_name =~ /^(\w+)/;
      my $new_first = $1;
      if ((length($new_first) - $cutoff) < 3) {
	$new_first = substr($new_first, 0, 1) . ".";
	$organism_short_name =~ s/^(\w+)/$new_first/;
	$organism_short_name = substr($organism_short_name, 0, 14);
	  
      } else {
	$new_first = substr($new_first, 0, length($new_first) - $cutoff) . ".";
	$organism_short_name =~ s/^(\w+)/$new_first/;
      }
    }

    if ($curr_frames eq '6') {
      $data = [ $data_plus_frame_0,
		$data_plus_frame_1,
		$data_plus_frame_2,
		$data_middle,
		$data_minus_frame_0,
		$data_minus_frame_1,
		$data_minus_frame_2 ];
      $line_config = [ { height => 26, style => 'arrowline', title => "+2" },
		       { height => 26, style => 'arrowline', title => "+1" },
		       { height => 26, style => 'arrowline', title => "+0" },
		       { height => 26, style => 'arrowline', title => $organism_name, short_title => $organism_short_name , title_link => "" },
		       { height => 26, style => 'arrowline', title => "-0" },
		       { height => 26, style => 'arrowline', title => "-1" },
		       { height => 26, style => 'arrowline', title => "-2" } ];
    } elsif ($curr_frames eq '2') {
      $data = [ $data_plus,
		$data_middle,
		$data_minus ];
      unless ($organism_short_name) {
	$organism_short_name = "              ";
      }
      $line_config = [ { height => 26, style => 'arrowline', title => "$organism_name", short_title => $organism_short_name . " +", title_link => "" },
		       { height => 26, style => 'arrowline', title => $organism_name, short_title => $organism_short_name , title_link => "" },
		       { height => 26, style => 'arrowline', title => "               -" } ];
    }  elsif ($curr_frames eq 'resolve') {
      $data = [ @overlay_resolved_data ];
      my $first = 1;
      foreach (@overlay_resolved_data) {
	if ($first) {
	  $first = 0;
	  push(@$line_config, { height => 26, style => 'arrowline', title => "$organism_name", short_title => $organism_short_name, title_link => "" });
	} else {
	  push(@$line_config, { height => 26, style => 'arrowline', title => "" });
	}
      }
    } else {
      $data = [ $data_all ];
      $line_config = [ { height => 26, style => 'arrowline', title => "$organism_name", short_title => $organism_short_name, title_link => "" } ];
    }

    # initialize html variable
    my $html = "";

    # create contig select
    my $contig_select = "<td>Contig <select name='contig' onchange='genome_browser_form_" . $id . ".submit();'>";
    foreach my $contig_name (@contigs) {
      my $selected = "";
      if (defined($cgi->param('contig'))) {
	if ($cgi->param('contig') eq $contig_name) {
	  $selected = " selected=selected";
	}
      }
      $contig_select .= "<option value='$contig_name'$selected>$contig_name</option>";
    }
    $contig_select .= "</select></td>";
    if (scalar(@contigs) == 0) {
      $contig_select = "";
    }
    
    # start form
    $html .= "<div><form action='rast.cgi' method='post' id='" . $id . "_form' name='genome_browser_form_" . $id . "'>";
    $html .= "<input type=hidden name='page' value='BrowseGenome'>";
    $html .= "<input type=hidden name='gsize' id='" . $id . "_gsize' value='" . $contig_lengths->{$contig} . "'>";
    $html .= "<input type=hidden name='genome' value='" . ($cgi->param('genome') || "") . "'>";
    $html .= "<input type=hidden name='job' value='" . ($cgi->param('job') || "") . "'>";
    
    $html .= "<table><tr><td colspan=8 align=center>Show bases <input type='text' name='start' id='" . $id . "_start' value='$start'> to <input type='text' name='end' id='" . $id . "_end' value='$end'></td><td rowspan=4>" . $options . "</td></tr>";
    $html .="<tr><td align=center><input type='button' value='<<' onclick='browse(\"left_far\", \"" . $id . "\");'></td><td align=center><input type='button' value='<' onclick='browse(\"left\", \"" . $id . "\");'></td><td align=center><input type='button' value='zoom in' onclick='browse(\"zoom_in\", \"" . $id . "\");'></td><td>" . $zoom_select . "</td>" . $contig_select . "<td align=center><input type='button' value='zoom out' onclick='browse(\"zoom_out\", \"" . $id . "\");'></td><td align=center><input type='button' value='>' onclick='browse(\"right\", \"" . $id . "\");'></td><td align=center><input type='button' value='>>' onclick='browse(\"right_far\", \"" . $id . "\");'></td></tr>";
    $html .= "<input type=hidden name=genome value='" . $genome . "'><br/>";    
    
    # insert a navigation image
    $html .= "<tr><td colspan=8>" . getNavigation($contig_lengths->{$contig}, $start, $end - $start, 800, 25, $id) . "</td></tr>";
    
    $html .= "<tr><td colspan=8>";
    
    # produce the image
    $html .= get_image( {
			 data                  => $data,
			 start                 => $start,
			 end                   => $end,
			 line_config           => $line_config,
			 width                 => 625,
			 legend_width          => 100,
			 show_names_in_graphic => 1,
			 id => $id
			} );

    # close table
    $html .= "</td></tr></table></div>";
    
    # close form
    $html .= "</form>";
    
    # return the html
    return $html;
}

sub get_image {
    my ($params) = @_;

    # get mandatory values
    my $data  = $params->{data};
    my $start = $params->{start};
    my $end   = $params->{end};
    my $id    = $params->{id};

    # get optional values
    my $width            = $params->{width}            || 500;
    my $line_height      = $params->{line_height}      || 40;
    my $arrow_head_width = $params->{arrow_head_width} || 8;
    my $line_config      = $params->{line_config}      || undef;
    my $show_names_in_graphic = $params->{show_names_in_graphic};
    my $legend_width = $params->{legend_width} || 100;
    
    # calculate resulting values
    my $numlines = scalar(@$data);

    # check for line configurations
    unless (defined($line_config)) {
	for (my $i=0; $i<$numlines; $i++) {
	    push(@$line_config, { height => $line_height, style => 'line' } );
	}
    }

    my $height = 0;
    foreach my $line (@$line_config) {
	$height = $height + $line->{height};
    }
    my $scale_width = $width / ($end - $start);

    # initialize image and colors
    my $colorset = getColors();
    
    my $im = new GD::Image($width + $legend_width, $height);
    my $white = $im->colorResolve($colorset->[0]->[0], $colorset->[0]->[1], $colorset->[0]->[2]);
    
    my $item_colors = allocateColors($colorset, $im);

    $im->filledRectangle(1, 1, $width - 2, $height - 2, $item_colors->[0]);

    # create image map
    my $map = "<map name='imap_$id'>";
    my @maparray;

    # draw lines
    my $i = 0;
    my $y_offset = 0;
    my $x_offset = $legend_width;
    foreach my $line (@$data) {

	# check line-style
	if ($line_config->[$i]->{style} eq 'line') {
	    $im->line($x_offset, $y_offset + ($line_config->[$i]->{height} / 2), $width + $x_offset, $y_offset + ($line_config->[$i]->{height} / 2), $item_colors->[1]);
	} elsif (($line_config->[$i]->{style} eq 'arrowline') || ($line_config->[$i]->{style} eq 'scale')) {
	    $im->line($x_offset, $y_offset + 3 + ($line_config->[$i]->{height} / 2), $width + $x_offset, $y_offset + 3 + ($line_config->[$i]->{height} / 2), $item_colors->[1]);
	}

	# check for description of line
	if (defined($line_config->[$i]->{title})) {
	  my $short_title = undef;
	  if (defined($line_config->[$i]->{short_title})) {
	    $short_title = $line_config->[$i]->{short_title};
	  }
	  my $onclick = " ";
	  if (defined($line_config->[$i]->{title_link})) {
	    $onclick .= "onclick=\"" . $line_config->[$i]->{title_link} . "\"";
	  }
	  
	  my $tooltip = "onMouseover=\"javascript:if(!this.tooltip) this.tooltip=new Popup_Tooltip(this,'Organism','" . $line_config->[$i]->{title} . "','');this.tooltip.addHandler();return true;\"";
	  if (defined($short_title) || defined($line_config->[$i]->{title_link})) {
	    push(@maparray, '<area shape="rect" coords="' . join(',', 2, $y_offset, $x_offset, $y_offset + $line_config->[$i]->{height}) . "\" " . $tooltip . $onclick . ' onMouseout="window.status=\'\';hidetip();return true;">');
	  } else {
	    $short_title = $line_config->[$i]->{title};
	  }

	  $im->string(gdSmallFont, 2, $y_offset + ($line_config->[$i]->{height} / 2) - 4, $short_title, $item_colors->[1]);
	}

	# sort items according to z-layer
	if (defined($line)) {
	    my @sortline = sort { $a->{zlayer} <=> $b->{zlayer} } @$line;
	    $line = \@sortline;
	}

	# draw items
	foreach my $item (@$line) {
	    
	  if ($item->{type} eq "scale") {
	    $item->{start} = 0;
	    $item->{end} = 0;
	    $item->{name} = "-";
	    $item->{title} = "";
	  }
	  
	  # set to default fill color
	  my $fillcolor = $item_colors->[4];
	  my $framecolor = $item_colors->[1];
	  
	  if ($item->{type} eq "arrow") {
	    $fillcolor = $item_colors->[3];
	    if (defined($item->{highlight})) {
	      $fillcolor = $item_colors->[2];
	      $framecolor = $item_colors->[1];
	    }
	  } elsif ($item->{type} eq "box") {
	    $fillcolor = $item_colors->[5];
	  }
	  
	  # check for multi-coloring
	  if (defined($item->{category})) {
	    $fillcolor = $item_colors->[$item->{category} + 3];
	    if (defined($item->{highlight})) {
	      $fillcolor = $item_colors->[2];
	    }
	  }
	  
	  my $i_start = 0;
	  my $i_end = 0;
	  
	  # create params hash
	  my $item_params = {
			     start            => $scale_width * ($item->{start} - $start),
			     end              => $scale_width * ($item->{end} - $start),
			     ypos             => $y_offset,
			     image            => $im,
			     fillcolor        => $fillcolor,
			     framecolor       => $framecolor,
			     labelcolor       => $item_colors->[1],
			     item_height      => $line_config->[$i]->{height},
			     width            => $width,
			     x_offset         => $x_offset,
			     strong           => $item->{strong},
			     title            => $item->{title} || ""
			    };
	  
	  if ($show_names_in_graphic) {
	    $item_params->{label} = $item->{name} || "";
	  } else {
	    $item_params->{label} = "";
	  }
	  
	  # determine type of item to draw
	  unless (defined($item->{type})) {
	    
	  } elsif ($item->{type} eq "arrow") {
	    
	    # set item specific params
	    $item_params->{arrow_head_width} = $arrow_head_width;
	    
	    # call draw item function
	    ($im, $i_start, $i_end) = draw_arrow($item_params);
	  } elsif ($item->{type} eq "box") {
	    
	    # call draw item function
	    ($im, $i_start, $i_end) = draw_box($item_params);
	    
	  } elsif ($item->{type} eq "smallbox") {
	    
	    # call draw item function
	    ($im, $i_start, $i_end) = draw_smallbox($item_params);
	    
	  } elsif ($item->{type} eq "bigbox") {
	    
	    # call draw item function
	    ($im, $i_start, $i_end) = draw_bigbox($item_params);
	    
	  } elsif ($item->{type} eq "scale") {
	    
	    # set item specific params
	    $item_params->{scaleitems} = $item->{scaleitems} || 10;
	    
	    # call draw item function
	    $im = draw_scale($item_params);
	  } elsif ($item->{type} eq "ellipse") {
	    
	    # call draw item function
	    ($im, $i_start, $i_end) = draw_ellipse($item_params);
	  }
	  
	  # add item to image map
	  my $menu = "";
	  my $info = "<table>";
	  if (exists($item->{description})) {
	    foreach my $desc_item (@{$item->{description}}) {
	      $desc_item->{value} =~ s/(.{50})/$1<br\/>/g;
	      $desc_item->{value} =~ s/'/`/g;
	      $desc_item->{value} =~ s/"/``/g;
	      
	      $info .= "<tr><td style=&quot;vertical-align: top; padding-right: 10px;&quot;><b>" . $desc_item->{title} . "</b></td><td>" . $desc_item->{value} . "</td></tr>";
	    }
	  }
	  if (defined($item->{links_list})) {
	    $menu .= "<table>";
	    foreach my $link (@{$item->{links_list}}) {
	      $menu .= "<tr><td><a href=&quot;" . $link->{link} . "&quot;>" . $link->{linktitle} . "</a></td></tr>";
	    }
	    $menu .= "</table>";
	  }
	  $info .= "</table>";
	  my $tooltip = "onMouseover=\"javascript:if(!this.tooltip) this.tooltip=new Popup_Tooltip(this,'" . $item->{title} . "','".$info."','".$menu."');this.tooltip.addHandler();return true;\"";
	  
	  my $onclick = " ";
	  if ($item->{onclick}) {
	    $onclick .= "onclick=\"" . $item->{onclick} . "\"";
	  }
	  push(@maparray, '<area shape="rect" coords="' . join(',', $x_offset + $i_start, $y_offset, $x_offset + $i_end, $y_offset + $line_config->[$i]->{height}) . "\" " . $tooltip . $onclick . ' onMouseout="window.status=\'\';hidetip();return true;">');
	}
	
	# calculate y-offset
	$y_offset =  $y_offset + $line_config->[$i]->{height};
	
	# increase counter
	$i++;
    }

    # create inline gif
    my $encoded = MIME::Base64::encode($im->png());

    # finish image map
    $map .= join("\n", reverse(@maparray));
    $map .= "</map>";
    
    # create html
    my $image = qq~<img style="border: none;" src="data:image/gif;base64,~ . $encoded  . qq~" usemap="#imap_$id">~ . $map;
    
    # return image string
    return $image;
}

# supplementary drawing methods

# draw a scale
sub draw_scale {
    my ($params) = @_;
    
    # required parameters
    my $ypos        = $params->{ypos};
    my $im          = $params->{image};
    my $scaleitems  = $params->{scaleitems};
    my $item_height = $params->{item_height};
    my $width       = $params->{width};
    my $linecolor   = $params->{framecolor};
    my $x_offset    = $params->{x_offset};
    
    # optional parameters
    my $scaleheight = $params->{scaleheight} || 7;

    # precalculations
    my $padding = int($width / $scaleitems);
    $ypos = 3 + int($ypos + ($item_height / 2));
    my $y1 = $ypos - int($scaleheight / 2);
    my $y2 = $ypos + int($scaleheight / 2);

    # draw scales
    for (my $i=0; $i<$scaleitems; $i++) {
	my $xpos = $i * $padding + $x_offset;
	$im->line($xpos, $y1, $xpos, $y2, $linecolor);
    }
    
    return $im;
}

# draw an arrow
sub draw_arrow {
  my ($params) = @_;
  
  # required parameters
  my $start      = $params->{start};
  my $end        = $params->{end};
  my $ypos       = $params->{ypos};
  my $im         = $params->{image};
  my $fillcolor  = $params->{fillcolor};
  my $framecolor = $params->{framecolor};
  my $labelcolor = $params->{labelcolor};
  my $x_offset   = $params->{x_offset};
  my $strong     = $params->{strong};
  
  # optional parameters
  my $arrow_height     = $params->{item_height};
  my $arrow_head_width = $params->{arrow_head_width};
  my $label            = $params->{label} || "";
  my $linepadding      = $params->{linepadding} || 10;
  
  # precalculations
  my $direction = 1;
  if ($start > $end) {
    $direction = 0;
    my $x = $start;
    $start = $end;
    $end = $x;
  }
  if ($start < 0) {
    $start = 0;
  }
  if ($end < 0) {
    return ($im, $start, $end);
  }
  $arrow_height = $arrow_height - $linepadding;
  $ypos = $ypos + 8;
  my $boxpadding = $arrow_height / 5;
  my $fontheight = 12;
  
  # draw arrow
  my $arrowhead = new GD::Polygon;
  
  # calculate x-pos for title
  my $string_start_x_right = $x_offset + $start + (($end - $start - $arrow_head_width) / 2) - (length($label) * 6 / 2);
  my $string_start_x_left = $x_offset + $start + (($end - $start + $arrow_head_width) / 2) - (length($label) * 6 / 2);
  
  # check for arrow direction
  if ($direction) {
    
    # draw arrow box
    if ($arrow_head_width < ($end - $start)) {
      if ($strong) { $im->setThickness(2); }
      $im->rectangle($x_offset + $start,$ypos + $boxpadding,$x_offset + $end - $arrow_head_width,$ypos + $arrow_height - $boxpadding + 1, $framecolor);
      $im->setThickness(1);
    } else {
      $arrow_head_width = $end - $start;
    }
    
    # calculate arrowhead
    $arrowhead->addPt($x_offset + $end - $arrow_head_width, $ypos);
    $arrowhead->addPt($x_offset + $end, $ypos + ($arrow_height / 2));
    $arrowhead->addPt($x_offset + $end - $arrow_head_width, $ypos + $arrow_height);
    
    # draw label
    $im->string(gdSmallFont, $string_start_x_right, $ypos + $boxpadding - $fontheight - 2, $label, $labelcolor);
    
    # draw arrowhead
    $im->filledPolygon($arrowhead, $fillcolor);
    if ($strong) { $im->setThickness(2); }
    $im->polygon($arrowhead, $framecolor);
    $im->setThickness(1);
    
    # draw arrow content
    $im->filledRectangle($x_offset + $start + 1,$ypos + $boxpadding + 1,$x_offset + $end - $arrow_head_width,$ypos + $arrow_height - $boxpadding - $strong,$fillcolor);
    
  } else {
    
    # draw arrow box
    if ($arrow_head_width < ($end - $start)) {
      if ($strong) { $im->setThickness(2); }
      $im->rectangle($x_offset + $start + $arrow_head_width,$ypos + $boxpadding,$x_offset + $end,$ypos + $arrow_height - $boxpadding + 1, $framecolor);
      $im->setThickness(1);
    } else {
      $arrow_head_width = $end - $start;
    }
    
    # calculate arrowhead
    $arrowhead->addPt($x_offset + $start + $arrow_head_width, $ypos);
    $arrowhead->addPt($x_offset + $start, $ypos + ($arrow_height / 2));
    $arrowhead->addPt($x_offset + $start + $arrow_head_width, $ypos + $arrow_height);
    
    # draw label
    $im->string(gdSmallFont, $string_start_x_left, $ypos + $boxpadding - $fontheight - 2, $label, $labelcolor);
    
    # draw arrowhead
    $im->filledPolygon($arrowhead, $fillcolor);
    if ($strong) { $im->setThickness(2); }
    $im->polygon($arrowhead, $framecolor);
    $im->setThickness(1);
    
    # draw arrow content
    $im->filledRectangle($x_offset + $start + $arrow_head_width - 1,$ypos + $boxpadding + 1,$x_offset + $end - 1,$ypos + $arrow_height - $boxpadding - $strong,$fillcolor);
    
  }
  
  return ($im, $start, $end);
}

# draw a small box
sub draw_smallbox {
    my ($params) = @_;
    
    # required parameters
    my $start      = $params->{start};
    my $end        = $params->{end};
    my $ypos       = $params->{ypos};
    my $im         = $params->{image};
    my $fillcolor  = $params->{fillcolor};
    my $framecolor = $params->{framecolor};
    my $x_offset   = $params->{x_offset};

    # optional parameters
    my $linepadding = $params->{linepadding} || 10;
    my $box_height = $params->{item_height} - 2 - $linepadding;
    $ypos = $ypos + 10;
    my $boxpadding = $box_height / 5;
    $box_height = $box_height - 2;

    # precalculations
    if ($start > $end) {
	my $x = $start;
	$start = $end;
	$end = $x;
    }

    # draw box
    $im->rectangle($x_offset + $start,$ypos + $boxpadding,$x_offset + $end,$ypos + $box_height - $boxpadding, $framecolor);
    
    # draw box content
    $im->filledRectangle($x_offset + $start + 1,$ypos + $boxpadding + 1,$x_offset + $end - 1,$ypos + $box_height - 1 - $boxpadding,$fillcolor);
    
    return ($im, $start, $end);
}

# draw a big box
sub draw_bigbox {
    my ($params) = @_;
    
    # required parameters
    my $start      = $params->{start};
    my $end        = $params->{end};
    my $ypos       = $params->{ypos};
    my $im         = $params->{image};
    my $fillcolor  = $params->{fillcolor};
    my $framecolor = $params->{framecolor};
    my $x_offset   = $params->{x_offset};

    # optional parameters
    my $box_height = $params->{item_height} - 1;
    
    # precalculations
    if ($start > $end) {
	my $x = $start;
	$start = $end;
	$end = $x;
    }
    
    # draw box
    #$im->rectangle($x_offset + $start - 1,$ypos,$x_offset + $end + 1,$ypos + $box_height, $framecolor);
    
    # draw box content
    $im->filledRectangle($x_offset + $start-2,$ypos-2,$x_offset + $end+2,$ypos + $box_height+2,$fillcolor);
    
    return ($im, $start, $end);
}

# draw a box
sub draw_box {
    my ($params) = @_;
    
    # required parameters
    my $start      = $params->{start};
    my $end        = $params->{end};
    my $ypos       = $params->{ypos};
    my $im         = $params->{image};
    my $fillcolor  = $params->{fillcolor};
    my $framecolor = $params->{framecolor};
    my $x_offset   = $params->{x_offset};

    # optional parameters
    my $box_height = $params->{item_height} - 2;
    
    # precalculations
    if ($start > $end) {
	my $x = $start;
	$start = $end;
	$end = $x;
    }

    $ypos = $ypos + 8;
    $box_height = $box_height - 8;
    
    # draw box
    $im->filledRectangle($x_offset + $start,$ypos,$x_offset + $end,$ypos + $box_height,$fillcolor);
    
    return ($im, $start, $end);
}

# draw a ellipse
sub draw_ellipse {
    my ($params) = @_;

    # required parameters
    my $start      = $params->{start};
    my $end        = $params->{end};
    my $ypos       = $params->{ypos};
    my $im         = $params->{image};
    my $lineheight = $params->{item_height};
    my $fillcolor  = $params->{fillcolor};
    my $framecolor = $params->{framecolor};
    my $x_offset   = $params->{x_offset};
    
    # precalculations
    if ($start > $end) {
	my $x = $start;
	$start = $end;
	$end = $x;
    }
    $im->filledEllipse($x_offset + $start + ($end - $start),$ypos + ($lineheight / 2),$x_offset + $end - $start,$lineheight - 6,$fillcolor);
    $im->ellipse($x_offset + $start + ($end - $start),$ypos + ($lineheight / 2),$x_offset + $end - $start,$lineheight - 4,$framecolor);

    return ($im, $start, $end);
}

sub getColors {
  my $colorset = [ 
		  [ 255, 255, 255 ],
		  [ 0, 0, 0 ],
		  [ 235, 5, 40 ],
		  [ 200, 200, 200 ],
		  [ 170, 205, 120 ], #1
		  [ 50, 255, 50 ],
		  [ 60, 60, 190 ],
		  [ 145, 175, 160 ],
		  [ 255, 145, 60 ],
		  [ 0, 0, 155 ],
		  [ 255, 221, 0 ],
		  [ 0, 155, 155 ],
		  [ 200, 100, 200 ],
		  [ 27, 133, 52 ],
		  [ 135, 65, 65 ],
		  [ 0, 90, 255 ],
		  [ 95, 100, 100 ],
		  [ 80, 210, 150 ],
		  [ 225, 250, 160 ],
		  [ 170, 30, 145 ],
		  [ 255, 215, 125 ],
		  [ 140, 165, 210 ],
		  [ 160, 15, 250 ],
		  [ 45, 155, 185 ],
		 ];

    return $colorset;
}

sub allocateColors {
  my ($colorset, $im) = @_;

  my $colors;

  foreach my $triplet (@$colorset) {
    push(@$colors, $im->colorResolve($triplet->[0], $triplet->[1], $triplet->[2]));
  }

  return $colors;
}

sub getNavigation {
  my ($length, $position, $window, $width, $height, $id) = @_;
  
  my $nav = "";
  my $im = new GD::Image($width, $height);

  my $bg_color = $im->colorResolve(150, 150, 150);
  my $red = $im->colorResolve(255, 0, 0);
  my $black = $im->colorResolve(0,0,0);
  
  $im->rectangle(0,0,$width - 1, $height - 1, $black);

  my $factor = $width / $length;
  $position = $position * $factor;
  $window = $window * $factor;
  $im->rectangle($position + 1, 1, $position + $window - 2, $height - 2, $red);

  my $encoded = MIME::Base64::encode($im->png());
  
  $nav .= "<img style='border: none;' src='data:image/gif;base64," . $encoded  . "' id='" . $id . "'>";
  $nav .= "<script>document.getElementById('" . $id . "').onclick = navigate;</script>";
  
  return $nav;
}

sub get_minibox {
  my ($index) = @_;
  my $width = 11;
  my $im = new GD::Image($width, $width);
  my $colors = &allocateColors(&getColors(), $im);
  $im->filledRectangle(0,0,$width,$width, $colors->[$index]);
  my $encoded = MIME::Base64::encode($im->png());
  my $minibox = qq~<img src="data:image/gif;base64,~ . $encoded  . qq~">~;
  return $minibox;
}

sub min {
    shift if UNIVERSAL::isa($_[0],__PACKAGE__);
    my(@x) = @_;
    my($min,$i);

    (@x > 0) || return undef;
    $min = $x[0];
    for ($i=1; ($i < @x); $i++) {
        $min = ($min > $x[$i]) ? $x[$i] : $min;
    }
    return $min;
}

sub max {
    shift if UNIVERSAL::isa($_[0],__PACKAGE__);
    my(@x) = @_;
    my($max,$i);

    (@x > 0) || return undef;
    $max = $x[0];
    for ($i=1; ($i < @x); $i++) {
        $max = ($max < $x[$i]) ? $x[$i] : $max;
    }
    return $max;
}

=pod

=item * B<get_visible_features> (I<dir, contig, beg, end>)

Returns the data for the genome browser, retrieved from a single
organism directory.

Parameters:

dir - the directory the organism is in
contig - the name of the contig to be displayed
beg - the beginning base to be displayed
end - the end base to be displayed

=cut

sub get_visible_features {
    my($dir,$contig,$beg,$end) = @_;

    my @features = map { (($_ =~ /^(\S+)\t(\S+)_(\d+)_(\d+)\t/) &&
			  ($contig eq $2) && 
			  (&FIG::between($beg,$3,$end) || 
			   &FIG::between($beg,$4,$end) ||
			   ((&FIG::min($3,$4) < $beg) && (&FIG::max($3,$4) > $end)))) ? [$1,$3,$4] : ()
                       } `cat $dir/Features/*/tbl`;

    my %seek = map { $_->[0] => 1 } @features;
    my %func_of;
    my %in_sub;
    foreach my $tuple (map { (($_ =~ /^(\S+)\t(\S.*\S)/) && $seek{$1}) ? [$1,$2] : () } `cat $dir/proposed_functions`)
    {
	my($peg,$func) = @$tuple;
	$func_of{$peg} = $func;
    }

    foreach $_ (`cut -f1,3 $dir/Subsystems/bindings`)
    {
	if (($_ =~ /^([^\t]+)\t(\S+)/) && $func_of{$2})
	{
	    $in_sub{$2} = $1;
	}
    }

    my @complete_features = map { my ($peg,$beg1,$end1) = @$_; [$peg,$beg1,$end1,$func_of{$peg},$in_sub{$peg}] } @features;

    return \@complete_features;
}

=pod

=item * B<get_contig_data> (I<dir>)

Returns a hash with the contig names of a given organism as key
and it's length as the value. The data is retrieved from a single
organism directory.

Parameters:

dir - the directory the organism is in

=cut

sub get_contig_data {
    my($dir) = @_;

    my $lens = {};
    if (open(CONTIGS,"<$dir/contigs"))
    {
	$/ = "\n>";
	while ($_ = <CONTIGS>)
	{
	    chomp;
	    if ($_ =~ /^(\S+)[^\n]*\n(.*)/s)
	    {
		my $id = $1;
		my $seq = $2;
		$seq =~ s/\s//g;
		$id =~ s/^\>//;
		$lens->{$id} = length($seq);
	    }
	}
	$/ = "\n";
	close(CONTIGS);
    }

    return $lens;
}
