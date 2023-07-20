package WebPage::ClusterLoad;

use warnings;
use strict;

use Carp qw( confess );
use base qw( WebApp::WebPage );

use FIG;
use FIG_Config;
use XML::LibXML;
use strict;
use GD;
use Data::Dumper;
use CGI;

=pod

=head1 NAME

ClusterLoad - an instance of WebPage which displays the cluster load

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the page.

=cut

sub output {
  my ($self) = @_;

  $self->title('Annotation Server - View Cluster Load');
  my $content = "<h1>Cluster Load Overview</h1>";
  $content .= $self->draw_cluster();

  return $content;
}


sub draw_cluster {
  my ($self) = @_;

  my $parser = XML::LibXML->new();
  
  my $tmp = "$FIG_Config::temp/tmp.qstat.$$";
  
  my $rc = system(". /vol/sge/default/common/settings.sh; qstat -xml > $tmp");
  $rc == 0 or die "qstat failed with rc=$rc\n";
  
  my $doc = $parser->parse_file($tmp);
  unlink($tmp);
  
  my %nodes;
  
  for my $q ($doc->findnodes('//queue_info/job_list')) {
    my %i;
    
    for my $c ($q->childNodes()) {
      next if $c->nodeType != XML_ELEMENT_NODE;
      my $n = $c->nodeName;
      my $v = $c->textContent();
      $i{$n} = $v;
    }
      
    if ($i{queue_name} =~ /\@(bio-ppc-(\d+)\S+)/) {
      my $node = $1;
      my $nodenum = $2;
      
      my $jobname = $i{JB_name};
      my $jobnum = $i{JB_job_number};
      my $task = $i{tasks};
      
      my $app_job;
      if ($jobname =~ s/_(\d+)$//) {
	$app_job = $1;
      }
      push(@{$nodes{$nodenum}}, [$node, $nodenum, $jobnum, $jobname, $task, $app_job]);
    }
    
  }
  
  my $boxes_vert = 23;
  my $box_height = 25;
  my $box_space = 2;
  
  my $boxes_horiz = 2;
  my $box_width = 120;
  my $box_center_space = 10;
  
  my $height = $boxes_vert * $box_height + ($boxes_vert - 1) * $box_space;
  my $width = $boxes_horiz * $box_width + ($boxes_horiz - 1) * $box_space + $box_center_space;
  
  my $image = new GD::Image($width, $height);
  
  # allocate some colors
  my $white = $image->colorResolve(255,255,255);
  my $black = $image->colorResolve(0,0,0);   
  
  my $sim = $image->colorResolve(30,120,220);
  my $rp = $image->colorResolve(255,190,30);
  my $qc = $image->colorResolve(255,30,30);
  my $post = $image->colorResolve(30,255,30);
  my $bbh = $image->colorResolve(160, 32, 240);
  my $other = $image->colorResolve(128,128,128);
    
  # make the background transparent and interlaced
  $image->transparent($white);
  $image->interlaced('true');
  
  my %colors = (rp_compute_sims => $sim,
		rp_postproc_sims => $post,
		rapid_propagation => $rp,
		rp_sims => $sim,
		rp_cor => $image->colorResolve(30, 255, 255),
		rp => $rp,
		rp_postsim => $post,
		rp_bbh => $bbh,
		rp_aa => $image->colorResolve(30, 30, 255),
		rp_qc => $image->colorResolve(30, 90, 255),
	       );
  
  my $font = gdLargeFont;
  my $y = 0;
  for my $n (1..$boxes_vert) {
    my $left = $nodes{$n};
    my $right = $nodes{$n + 22};
    
    my $nj = $left ? @$left : 0;
    
    if ($n != 23) {		# node 45 is on the right
      if ($nj) {
	my $bw = int(($box_width - $nj + 1)/ $nj);
	my $x = 0;
	      
	for my $j (@$left) {
	  my $color = $colors{$j->[3]};
	  $color = $other unless $color;
	  
	  my $num = $j->[5];
	  my $task = $j->[4];
	  $num .= ".$task" if $task ne '';
	  
	  my $l = length($num);
	  my $nw = $font->width * $l;
	  my $nh = $font->height;
	  
	  $image->filledRectangle($x, $y, $x + $bw - 1, $y + $box_height - 1, $color);
	  $image->string($font, $x + $bw / 2 - $nw / 2, $y + $box_height / 2 - $nh / 2, $num, $black);
	  
	  $x += $bw + 1;
	}
	
      }
      my $x = 0;
      $image->rectangle($x, $y, $x + $box_width - 1, $y + $box_height - 1, $black);
    }
    
    my $nj = $right ? @$right : 0;
    if ($nj) {
      my $bw = int(($box_width - $nj + 1)/ $nj);
      my $x = $width / 2.0;
      
      for my $j (@$right) {
	my $color = $colors{$j->[3]};
	$color = $other unless $color;
	
	my $num = $j->[5];
	my $task = $j->[4];
	$num .= ".$task" if $task ne '';
	my $l = length($num);
	my $nw = $font->width * $l;
	my $nh = $font->height;
	
	$image->filledRectangle($x, $y, $x + $bw - 1, $y + $box_height - 1, $color);
	$image->string($font, $x + $bw / 2 - $nw / 2, $y + $box_height / 2 - $nh / 2, $num, $black);
	$x += $bw + 1;
      }
    }
    my $x = $width / 2.0;
    $image->rectangle($x, $y, $x + $box_width - 1, $y + $box_height - 1, $black);
    
    $y += $box_height + $box_space;
  }
  
  my $encoded = MIME::Base64::encode($image->png());
  return qq~<img style="border: none;" src="data:image/gif;base64,$encoded"/>~;

}

1;
