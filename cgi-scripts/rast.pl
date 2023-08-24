use strict;
use warnings;

use DBMaster;
use WebApplication;
use WebMenu;
use WebLayout;
use WebConfig;

use CGI qw(-debug);
#use CGI::Debug;
use CGI::Carp 'fatalsToBrowser';

#use IO::Handle;
#open(TICKLOG, ">/dev/pts/9") or open(TICKLOG, ">&STDERR");
#TICKLOG->autoflush(1);

use Time::HiRes 'gettimeofday';
my $start = gettimeofday;
my $time_last;
# sub tick {
#     my($w) = @_;
#     my $now = gettimeofday;
#     my $t = $now - $start;
#     my $tms = int(($now - $time_last) * 1000);
#     $time_last = $now;
#     my ($package, $filename, $line) = caller;
#
#     printf TICKLOG "$$ %-40s %5d %5d %.3f\n", $filename, $line, $tms, $t;
#     TICKLOG->flush();
# }

my $have_fcgi;
eval {
    require CGI::Fast;
    $have_fcgi = 1;
};


#
# If no CGI vars, assume we are invoked as a fastcgi service.
#
my $n_requests = 0;
if ($have_fcgi && $ENV{REQUEST_METHOD} eq '')
{
    #
    # Precompile modules. Find where we found one, and use that path
    # to walk for the rest.
    #
    
    my $mod_path = $INC{"WebComponent/Ajax.pm"};
    if ($mod_path && $mod_path =~ s,WebApplication/WebComponent/Ajax\.pm$,,)
    {
	local $SIG{__WARN__} = sub {};
	for my $what (qw(SeedViewer RAST WebApplication))
	{
	    for my $which (qw(WebPage WebComponent DataHandler))
	    {
		opendir(D, "$mod_path/$what/$which") or next;
		my @x = grep { /^[^.]/ } readdir(D);
		for my $mod (@x)
		{
		    $mod =~ s/\.pm$//;
		    my $fullmod = join("::", $what, $which, $mod);
		    eval " require $fullmod; ";
		}
		closedir(D);
	    }
	}
    }
    my $max_requests = 100;
    while ((my $cgi = new CGI::Fast()) &&
	   ($max_requests == 0 || $n_requests++ < $max_requests))
    {
	eval {
	    &main($cgi);
	};
	if ($@)
	{
	    if ($@ =~ /^cgi_exit/)
	    {
		# this is ok.
	    }
	    elsif (ref($@) ne 'ARRAY')
	    {
		warn "code died, cgi=$cgi returning error '$@'\n";
		print $cgi->header(-status => '500 error in body of cgi processing');
		print CGI::start_html();
		print '<pre>'.Dumper($@).'</pre>';
		print CGI::end_html();
	    }
	}
    endloop:
    }

}
else
{
    my $cgi = new CGI();
    eval { &main($cgi); };

    if ($@ && $@ !~ /^cgi_exit/)
    {
	my $error = $@;
	warn "ERROR rast.cgi: '$error'";
##	Warn("Script error: $error") if T(SeedViewer => 0);
	
	print CGI::header();
	print CGI::start_html();
	
# print out the error
	print '<pre>'.$error.'</pre>';
	
	print CGI::end_html();
    }
}

sub main {
    my($cgi) = @_;

# read local WebConfig because we need it here
    &WebConfig::import_local_config('RAST');

# choose a layout
    my $layout = WebLayout->new("$FIG_Config::fig/CGI/Html/RAST.tmpl");
    $layout->add_css(TMPL_URL_PATH.'/web_app_default.css');
    $layout->add_css(TMPL_URL_PATH.'/rast.css');
    
# add site meter
    my $site_meter = $FIG_Config::site_meter;
    if ($site_meter) {
        $layout->add_javascript("http://s20.sitemeter.com/js/counter.js?site=s20nmpdr");
    }


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++    
# create the menu
#-----------------------------------------------------------------------
    my $menu = WebMenu->new();

    $menu->add_category('&raquo;Home', 'rast.cgi', undef, [ 'login' ]);
    $menu->add_entry('&raquo;Home', 'SeedViewer', 'seedviewer.cgi');


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Help Menu...
#-----------------------------------------------------------------------
    $menu->add_category('&raquo;Your Jobs', 'rast.cgi?page=Jobs', undef, [ 'login' ]);
    $menu->add_entry('&raquo;Your Jobs', 'Jobs Overview', 'rast.cgi?page=Jobs');
    $menu->add_entry('&raquo;Your Jobs', 'Upload New Job', 'rast.cgi?page=Upload');
    $menu->add_entry('&raquo;Your Jobs', 'Private Organism Preferences', '?page=PrivateOrganismPreferences');
    

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...(We have stopped accepting genomes for import into the SEED)...
#-----------------------------------------------------------------------
#   $menu->add_category('&raquo;Import Control', 'rast.cgi?page=ControlCenter', undef, [ 'import' ]);
#=======================================================================


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Tutorials Menu...
#-----------------------------------------------------------------------
    $menu->add_category('&raquo;Tutorials',  undef, undef, undef, 98);
    $menu->add_entry('&raquo;Tutorials', 'Registering for RAST',
		     'http://blog.theseed.org/servers/presentations/t1/rast.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Automated Assembly and RASTtk Workshop presentations',
		     'http://tutorial.theseed.org/', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'SEED and "Classic RAST" Workshop presentations',
		     'http://blog.theseed.org/servers/rast-workshop-presentations.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Downloading and installing the myRAST Toolkit',
		     'http://blog.theseed.org/servers/installation/distribution-of-the-seed-server-packages.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Scripting job submissions using the myRAST command-line interface',
		     'http://blog.theseed.org/servers/usage/the-rast-batch-interface.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Downloading and installing the RASTtk Toolkit (Mac and Ubuntu)',
		     'https://github.com/TheSEED/RASTtk-Distribution/releases/', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'General tutorial on using the myRAST command-line interface',
		     'http://blog.theseed.org/servers/usage/command-line-services.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Getting Started using IRIS',
		     'http://tutorial.theseed.org/IRIS.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Getting Started using RASTtk',
		     'http://tutorial.theseed.org/RASTtk/RASTtk_Getting_Started.html', '_blank');
    $menu->add_entry('&raquo;Tutorials', 'Other Tutorials',
		     'http://www.theseed.org/tutorials/', '_blank');


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#...Help Menu...
#-----------------------------------------------------------------------
    $menu->add_category('&raquo;Help', undef, undef, undef, 99);
    $menu->add_entry('&raquo;Help', 'What is RAST', 'http://www.nmpdr.org/FIG/wiki/view.cgi/Main/RAST', '_blank');
    $menu->add_entry('&raquo;Help', 'RAST FAQ',     'http://www.nmpdr.org/FIG/wiki/view.cgi/Main/RASTFAQ', '_blank');
    $menu->add_entry('&raquo;Help', 'What is the SEED', 'http://www.theseed.org/wiki/index.php/Home_of_the_SEED', '_blank');
    $menu->add_entry('&raquo;Help', 'HowTo use the SEED Viewer', 'http://www.theseed.org/wiki/index.php/SEED_Viewer_Tutorial', '_blank');
    $menu->add_entry('&raquo;Help', 'Contact', 'mailto:rast@mcs.anl.gov');
    $menu->add_entry('&raquo;Help', 'Register', '?page=Register');
    $menu->add_entry('&raquo;Help', 'I forgot my Password', '?page=RequestNewPassword');


#   $menu->add_category('<center>Test of <font color=red>centering</font> in categories</center>', undef, undef, undef, 100);


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++    
# init the WebApplication
#-----------------------------------------------------------------------
    my $WebApp = WebApplication->new( { id       => 'RAST',
					menu     => $menu,
					layout   => $layout,
					cgi      => $cgi,
					default  => 'Home',
				      } );
    
    $WebApp->page_title_prefix('RAST Server - ');
#   $WebApp->fancy_login(1);
    $WebApp->show_login_user_info(1);
    $WebApp->run();
}
