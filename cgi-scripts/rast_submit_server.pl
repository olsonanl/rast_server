use strict;
use FIG;
use POSIX;

my $have_fcgi;
eval {
    require CGI::Fast;
    $have_fcgi = 1;
};

use Data::Dumper;
use DBMaster;
use FIG_Config;
use RAST_submission;

use YAML;
use YAML::XS;
$YAML::CompressSeries = 0;

#
# This is the list of supported methods.
#

my @methods = qw(
		 get_contig_ids_in_project_from_entrez
		 get_contigs_from_entrez
		 submit_RAST_job
		 status_of_RAST_job
		 kill_RAST_job
		 delete_RAST_job
		 copy_to_RAST_dir
		 get_job_metadata
		 get_jobs_for_user_fast
		);

my %methods = map { $_ => 1 } @methods;


$| = 1;

my $header = "Content-type: text/plain\n\n";

my $max_requests = 5000;

#
# If no CGI vars, assume we are invoked as a fastcgi service.
#
my $n_requests = 0;
if ($have_fcgi && $ENV{REQUEST_METHOD} eq '')
{
    while ((my $cgi = new CGI::Fast()) &&
	   ($max_requests == 0 || $n_requests++ < $max_requests))
    {
	&log("fcgi request received");
	eval {
	    &process_request($cgi);
	};
	my $had_error = $@;
	&log("fcgi request completed $had_error");
	if ($had_error)
	{
	    if (ref($had_error) ne 'ARRAY')
	    {
		warn "code died, cgi=$cgi returning error\n";
		print $cgi->header(-status => '500 error in body of cgi processing');
		print $@;
	    }
	}
    endloop:
    }
}
else
{
    my $cgi = new CGI();
    &log("request received");
    &process_request($cgi);
    &log("request completed");
}

exit;

sub log
{
    my($msg) = @_;
    print STDERR strftime("%D %T: $msg\n", localtime);
}
    

sub process_request
{
    my($cgi) = @_;

    my $function = $cgi->param('function');
#    print STDERR "got function=$function\n";
    &log("handle $function");

    my $arg_str = $cgi->param('args');
    my @args;
    if ($arg_str)
    {
	eval {
	     if (length($arg_str) > 100_000)
	     {	     
		 @args = YAML::XS::Load($arg_str);
	     }
	     else
	     {
		 @args = YAML::Load($arg_str);
	     }
	};
	if ($@)
	{
	    myerror($cgi, "500 bad YAML parse", "YAML parse failed");
	    next;
	}
    }

    $function or myerror($cgi, "500 missing argument", "missing function argument");

    #
    # Pull username & password from the arguments and authenticate.
    #

    my $rast_user = $cgi->param('username');
    my $rast_password = $cgi->param('password');

    if ($rast_user eq '')
    {
	&myerror($cgi, '500 missing username', 'RAST username is missing');
    }

    #
    # Connect to the authentication database.
    #

    my $dbmaster;
    eval {
      $dbmaster = DBMaster->new(-database => $FIG_Config::webapplication_db || "WebAppBackend",
				-host     => $FIG_Config::webapplication_host || "localhost",
				-user     => $FIG_Config::webapplication_user || "root",
				-password => $FIG_Config::webapplication_password || "");
    };

    #
    # And evaluate username and password.
    #

    my $user_obj = $dbmaster->User->init( { login => $rast_user });
    if (!ref($user_obj) || !$user_obj->active)
    {
	&myerror($cgi, '500 invalid login', 'Invalid RAST login');
    }

    if (crypt($rast_password, $user_obj->password) ne $user_obj->password)
    {
	&myerror($cgi, '500 invalid login', 'Invalid RAST login');
    }
    warn "Authenticated $rast_user\n";

    # Connect to the RAST job cache
    my $rast_dbmaster = DBMaster->new(-backend => 'MySQL',
				      -database  => $FIG_Config::rast_jobcache_db,
				      -host     => $FIG_Config::rast_jobcache_host,
				      -user     => $FIG_Config::rast_jobcache_user,
				      -password => $FIG_Config::rast_jobcache_password );
    
    my $rast_obj = new RAST_submission($rast_dbmaster, $dbmaster, $user_obj);

    if ($function eq 'copy_to_RAST_dir')
    {
	#
	# For the copy, we pluck the file upload
	# from the CGI and give it to the handler as well.
	#
	my $file = $cgi->upload('file');
	if (!ref($file))
	{
	    $file = $cgi->param("file");
	}
	
	my $params = $args[0];
	$params->{-from} = $file if ref($params) eq 'HASH';
    }

    #
    # We handle retrieve in a different manner.
    #
    if ($function eq 'retrieve_RAST_job')
    {
	my $res;
	eval {
	    $res = $rast_obj->retrieve_RAST_job(@args);
	};

	if ($@)
	{
	    myerror($cgi, '500 error in method invocation', $@);
	}

	if ($res->{status} ne 'ok')
	{
	    myerror($cgi, "501 retrieve failed: $res->{error_msg}");
	}

	if (!open(F, "<", $res->{file}))
	{
	    myerror($cgi, "501 could not open output file");
	}

	print $cgi->header();

	my $buf;
	
	while (read(F, $buf, 4096))
	{
	    print $buf;
	}
	close(F);
    }
    elsif ($methods{$function})
    {

	my @results;
	eval {
	    @results = $rast_obj->$function(@args);
	};

	if ($@)
	{
	    warn $@;
	    myerror($cgi, '500 error in method invocation', $@);
	}

	print $cgi->header();
	my $res =  YAML::Dump(@results);
	#print STDERR $res;
	print $res;

    } else {
	myerror($cgi,  "500 invalid function", "invalid function $function\n");
    }
}

exit;

sub get_string_param
{
    my($cgi, $name) = @_;

    my $str = $cgi->param($name);
    if ($str =~ /^(\S+)/)
    {
	return $1;
    }
    else
    {
	return undef;
    }
    
}


sub myerror
{
    my($cgi, $stat, $msg) = @_;
    print $cgi->header(-status =>  $stat);
    print "$msg\n";
    goto endloop;
}




