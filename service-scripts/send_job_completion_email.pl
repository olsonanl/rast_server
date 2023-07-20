
use strict;
use Mail::Mailer;
use Data::Dumper;
use Job48;

my $usage = "Usage: send_job_completion_email jobdir\n";

@ARGV == 1 or die $usage;

my($job_dir) = @ARGV;

my $job = new Job48($job_dir);

if (!$job)
{
    die "Job $job_dir is not a valid job\n";
}

my $job_id = $job->id;

my $userobj = $job->getUserObject();

if ($userobj)
{
    my($email, $name);
    if ($FIG_Config::rast_jobs eq '')
    {
	$email = $userobj->eMail();
	$name = join(" " , $userobj->firstName(), $userobj->lastName());
    }
    else
    {
	$email = $userobj->email();
	$name = join(" " , $userobj->firstname(), $userobj->lastname());
    }
    
    my $full = $name ? "$name <$email>" : $email;
    print "send email to $full\n";
    
    my $mail = Mail::Mailer->new();
    $mail->open({
	To => $full,
	From => 'Annotation Server <rast@mcs.anl.gov>',
	Subject => "RAST annotation server job completed"
	});
    
    my $gname = $job->genome_name;
    my $entry = $FIG_Config::fortyeight_home;
    $entry = "http://www.nmpdr.org/anno-server/" if $entry eq '';
    print $mail "The annotation job that you submitted for $gname has completed.\n";
    print $mail "It is available for browsing at $entry as job number $job_id.\n";
    $mail->close();
}


