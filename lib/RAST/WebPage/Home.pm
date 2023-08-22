package RAST::WebPage::Home;

use strict;
use warnings;

use base qw( WebPage );
use WebConfig;
use File::Slurp;

1;

sub init {
    my $self = shift;
    
    $self->title('RAST Annotation Server');
    $self->require_css(CSS_PATH.'rast_home.css');
    
    $self->application->register_component('Login', 'Login');
    $self->application->component('Login')->login_target_page('Jobs');
}

sub output {
    my ($self) = @_;

# home page text for normal RAST
    my $content = "<div id='home'>";

    $content .= "<table>\n";
    $content .= "<tr align=LEFT>\n";
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Login block...
#-----------------------------------------------------------------------
    $content .= "<td>\n";
# if logged in, add some links, else login box
    unless ($self->application->session->user) {
	$content .= "<h2>Welcome to RAST</h2>\n";
	$content .= "<br>&raquo; <a href='?page=Register'>Register for a new account, service, or user-group</a>";
	$content .= "<br>&raquo; <a href='?page=RequestNewPassword'>Forgot your password?</a>";
	$content .= $self->application->component('Login')->output();
    }
    else {
	$content .= "<p><strong>You are already logged in.</strong></p>";
	$content .= "<p> &raquo <a href='?page=Jobs'>Go to the Jobs Overview</a></p>";
	$content .= "<p> &raquo <a href='?page=Upload'>Upload a new job</a></p>";
	$content .= "<p> &raquo <a href='?page=Logout'>Logout</a></p>";
    }
    $content .= "</td>\n";
    
    
#...Add some horizontal space to pretty up the layout...
    $content .= "<td>\n";    
    $content .= "<span style='display:inline-block; width: 100px;'></span>\n";
    $content .= "</td>\n";


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Load graphs...
#----------------------------------------------------------------------- 
    $content .= "<td align=CENTER>\n";
    my $img = read_file("$FIG_Config::daily_statistics_dir/ganglia_daily", err_mode => 'quiet');
    if ($img) {
	$content .= "<h2>RAST Job Load, last 24 hours</h2>\n";
	$content .= "<img src='$img'>";
    } 
    else {
	$content .= "(RAST job-load unavailable)\n";
    }
    $content .= "</td>\n";
    $content .= "</tr>\n";
    $content .= "</table>\n";
    
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Description, Citations, Acknowledgements...
#-----------------------------------------------------------------------
    $content .= "<H2>What is RAST?</H2>\n";
    $content .= "<p>RAST (Rapid Annotation using Subsystem Technology) is a fully-automated service for annotating complete or nearly complete bacterial and archaeal genomes. It provides high quality genome annotations for these genomes across the whole phylogenetic tree.</p>\n";
    
    $content .= "<p>We have a number of presentations and tutorials available:<br>\n";
    $content .= "<ul>\n";
    $content .= "<li><a target=_blank href='http://blog.theseed.org/servers/presentations/t1/rast.html'>Registering for RAST</a></li>\n";
    $content .= "<li><a target=_blank href='http://tutorial.theseed.org/'>The IRIS/Automated-Assembly/RASTtk Workshop Presentations and Tutorials</a></li>\n";
    $content .= "<li><a target=_blank href='http://blog.theseed.org/servers/rast-workshop-presentations.html'>The SEED/\"Classic-RAST\" Workshop presentations and Tutorials</a></li>\n";
    $content .= "<li><a target=_blank href='https://github.com/TheSEED/RASTtk-Distribution/releases/'>Downloading and installing the RASTtk Toolkit</a></li>\n";
    $content .= "<li><a target=_blank href='http://blog.theseed.org/servers/installation/distribution-of-the-seed-server-packages.html'>Downloading and installing the myRAST Toolkit</a></li>\n";
    $content .= "<li><a target=_blank href='http://blog.theseed.org/servers/usage/the-rast-batch-interface.html'>The RAST batch submission interface</a> (a part of myRAST)</li>\n";
    $content .= "<li><a target=_blank href='http://www.theseed.org/tutorials/ManualImprovementsToRastGenome.pptx'>Making manual improvements to RAST-annotated genomes (first tutorial)</a>. This is a powerpoint presentation; bring it up in slide-show mode and click through to see the animations and movies.</li>\n";
    $content .= "<li><a target=_blank href='http://www.theseed.org/tutorials/ImprovingRASTAnnotations.pptx'>Making manual improvements to RAST-annotated genomes (second tutorial)</a>. This is a second tutorial on the topic of manually improving RAST annotations; it is also a powerpoint presentation with animations.</li>\n";
    $content .= "</ul>\n";
    $content .= "</p>\n";
    
    $content .= "<p>As the number of more or less complete bacterial and archaeal genome sequences is constantly rising, the need for high quality automated initial annotations is rising with it. In response to numerous requests for a SEED-quality automated annotation service, we provide RAST as a free service to the community. It leverages the data and procedures established within the <a target=_blank href='http://www.theseed.org'>SEED framework</a> to provide automated high quality gene calling and functional annotation. RAST supports both the automated annotation of high quality genome sequences AND the analysis of draft genomes. The service normally makes the annotated genome available within 12-24 hours of submission.</p>\n";

    $content .= "<p>Please note that while the SEED environment and SEED data structures (most prominently <a target=_blank href='http://www.theseed.org/wiki/Glossary#FIGfam'>FIGfams</a>) are used to compute the automatic annotations, the data is NOT added into the SEED automatically. Users can however request inclusion of a their genome in the SEED. Once annotation is completed, genomes can be downloaded in a variety of formats or viewed online. The genome annotation provided does include a mapping of genes to <a target=_blank href='http://www.theseed.org/wiki/Glossary#Subsystem'>subsystems</a> and a metabolic reconstruction.</p>\n";
    
    $content .= "<p>To be able to contact you once the computation is finished and in case user intervention is required, we request that users register with email address.</p>\n";
    
    $content .= q(
<p><strong>If you use the results of this annotation in your work, please cite:</strong><br/>
<ul>
<li>
<em>The RAST Server: Rapid Annotations using Subsystems Technology.</em><br/>
Aziz RK, Bartels D, Best AA, DeJongh M, Disz T, Edwards RA, Formsma K,
Gerdes S, Glass EM, Kubal M, Meyer F, Olsen GJ, Olson R, Osterman AL,
Overbeek RA, McNeil LK, Paarmann D, Paczian T, Parrello B, Pusch GD,
Reich C, Stevens R, Vassieva O, Vonstein V, Wilke A, Zagnitko O.<br/>
<em>BMC Genomics,</em> 2008,
[ <a href="http://www.ncbi.nlm.nih.gov/pubmed/18261238"
target="_blank">PubMed entry</a> ]</em>
</li>

<li><em>The SEED and the Rapid Annotation of microbial genomes using Subsystems Technology (RAST).</em><br/>
Overbeek R, Olson R, Pusch GD, Olsen GJ, Davis JJ, Disz T, Edwards RA,
Gerdes S, Parrello B, Shukla M, Vonstein V, Wattam AR, Xia F, Stevens R.
</br/>
<em>Nucleic Acids Res.</em> 2014 
[ <a
href="http://www.ncbi.nlm.nih.gov/pubmed/?term=24293654"
target="_blank">PubMed entry</a> ]
</li>

<li>
<em>RASTtk: A modular and extensible implementation of the RAST algorithm for 
building custom annotation pipelines and annotating batches of genomes.</em><br/>
Brettin T, Davis JJ, Disz T, Edwards RA, Gerdes S, Olsen GJ, Olson R, Overbeek R, 
Parrello B, Pusch GD, Shukla M, Thomason JA, Stevens R, Vonstein V, Wattam AR, Xia F.<br/>
<em>Sci Rep.,</em> 2015,
[ <a href="http://www.ncbi.nlm.nih.gov/pubmed/25666585"
target="_blank">PubMed entry</a> ]</em>
</li>

</ul>
);


    $content .= "<p>This project has been funded in whole or in part with Federal funds from the National Institute of Allergy and ";
    $content .= "Infectious Diseases, National Institutes of Health, Department of Health and Human Services, under Contract ";
    $content .= "No. HHSN272200900040C and the National Science Foundation under Grant No.  0850546.";

    $content .= '</div>';

    return $content;
}


sub supported_rights {
  return [ [ 'login', '*', '*' ] ];
}
