package JobError;

use strict;
use FIG_Config;
use FIG;
use Mantis;
use Mail::Mailer;
use Job48;

use base 'Exporter';

use vars qw(@EXPORT_OK);

@EXPORT_OK = qw(find_and_flag_error flag_error);

sub find_and_flag_error
{
    my($genome, $job_id, $job_dir, $meta) = @_;

    for my $mkey ($meta->get_metadata_keys())
    {
	if ($mkey =~ /^status\.(.*)$/)
	{
	    my $stage = $1;
	    my $mval = $meta->get_metadata($mkey);

	    if ($mval eq "error")
	    {
		flag_error($genome, $job_id, $job_dir, $meta, $stage);
	    }
	}
    }
       
}

#
# flag an error.
#
# this will send an email to the user notifying them that their job had
# an error; it copies the rast list in order to alert them that
# such an error occurred.
#
sub flag_error
{
    my($genome, $job_id, $job_dir, $meta, $stage, $msg) = @_;

    if (!$msg)
    {
	$msg = find_job_error($genome, $job_id, $job_dir, $meta, $stage);
    }

    if (!$msg)
    {
	$msg = "An error occurred during the analysis of your genome.";
    }

    #
    # Use the mantis info if there to figure out what server this is.
    #

    my $server_info;
    if (my $mi = $FIG_Config::mantis_info)
    {
	my $system = $mi->{system};
	my $server = $mi->{server_value};
	$server_info = " in the $system $server server"
    }
    else
    {
	$server_info = "";
    }
    
    my $genome_name = &FIG::file_head("$job_dir/GENOME", 1);
    chomp $genome_name;
    my $body = <<END;
This message is regarding RAST processing of your genome $genome_name,
job number $job_id$server_info.

$msg

RAST developers will be investigating the cause of the error,
and will contact you regarding the problem and its resolution.
END

    if (open(E, ">$job_dir/ERROR"))
    {
	print E "$msg\n";
	close(E);
    }
    $meta->set_metadata("genome.error", $msg);

    unlink("$job_dir/ACTIVE");

    my $job = new Job48($job_id);
    my $userobj = $job->getUserObject();
    my($email, $name);
    
    if ($userobj)
    {
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
    }

    #
    # if we are configured for Mantis integration, notify Mantis.
    # But only if we are not the batch user.
    #

    my($bug_id, $bug_url);
    if ($FIG_Config::mantis_info and $job->user() ne 'batch')
    {
	eval {
	    my $mantis = Mantis->new($FIG_Config::mantis_info);
	    
	    ($bug_id, $bug_url) = $mantis->report_bug(stage => $stage,
						     genome => $genome,
						     genome_name => $genome_name,
						     job_id => $job_id,
						     job_dir => $job_dir,
						     user_email => $email,
						     user_name => $name,
						     meta => $meta,
						     msg => $msg);

	    $body .= "\nBug report number $bug_id has been filed in the RAST bugtracking system for this error.\n";
	    $body .= "It may be viewed at the url $bug_url\n";
	};
	if ($@)
	{
	    warn "Exception while reporting Mantis bug:\n$@\n";
	}
    }

    if ($meta->get_metadata("genome.error_notification_sent") ne "yes")
    {
	if ($email)
	{
            #
            # Names with HTML escapes do not work properly. Drop
            # them as they are just for decoration.
            #
            $name = '' if $name =~ /&#\d+;/;

	    my $full = $name ? "$name <$email>" : $email;
	    
	    my $mail = Mail::Mailer->new();
	    $mail->open({
		To => $full,
		Cc => 'Annotation Server <rast@mcs.anl.gov>',
		From => 'Annotation Server <rast@mcs.anl.gov>',
		Subject => "RAST annotation server error on job $job_id",
		});

	    print $mail $body;
	    $mail->close();
	    $meta->set_metadata("genome.error_notification_sent", "yes");
	    $meta->set_metadata("genome.error_notification_time", time);
	    $meta->set_metadata("genome.error_notification_sent_address", $email);
	}
    }
}

sub find_job_error
{
    my($genome, $job_id, $job_dir, $meta, $stage) = @_;

    my $msg;
    if ($stage eq 'rp')
    {
	#
	# hunt down some more details on the error.
	#

	$msg = find_rp_error($genome, $job_id, $job_dir, $meta);
    }
    elsif ($stage eq 'qc')
    {
	$msg = "An error occurred during the quality check phase of your genome's analysis.";
    }
    elsif ($stage eq 'sims')
    {
	$msg = "An error occurred during the similarity computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'bbhs')
    {
	$msg = "An error occurred during the BBH computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'auto_assign')
    {
	$msg = "An error occurred during the automated assignment phase of your genome's analysis.";
    }
    elsif ($stage eq 'glue_contings')
    {
	$msg = "An error occurred during the postprocessing phase of your genome's analysis.";
    }
    elsif ($stage eq 'pchs')
    {
	$msg = "An error occurred during the coupling computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'scenario')
    {
	$msg = "An error occurred during the scenario computation phase of your genome's analysis.";
    }
    elsif ($stage eq 'export')
    {
	#
	# An export error can occur if the verify_genome_directory for the job
	# fails.
	#

	if ($meta->get_metadata("genome.directory_verification_status") =~ /fail/)
	{
	    $msg = "An error occurred during the final verification of the genome directory for your genome.";
	}
	else
	{
	    $msg = "An error occurred during the final export of your analyzed genome.";
	}
    }
    return $msg;
}

sub find_rp_error
{
    my ($genome, $job_id, $job_dir, $meta) = @_;

    my $err = $meta->get_metadata("rp.error");
    
    if ($err =~ /raw genome directory.*does not exist/ or
	$err =~ /Unformatted contigs file.*does not exist/)
    {
	return "An error occurred during the upload of your data.";
    }

    if ($err =~ /reformat command failed/)
    {
	my $f = &FIG::file_read("$job_dir/rp.errors/reformat_contigs_split.stderr");
	if ($f =~ /File does not appear to be in FASTA/)
	{
	    return "An error occurred during the parsing of your input file.";
	}
	else
	{
	    return "An error occurred during the upload of your data.";
	}
    }

    if (-f "$job_dir/rp.errors/find_neighbors_using_figfams.stderr")
    {
	my $ff = &FIG::file_read("$job_dir/rp.errors/find_neighbors_using_figfams.stderr");
	if ($ff =~ /Could not find any features of sufficient length/)
	{
	    my $msg = "RAST processing could not determine the phylogenetic neighborhood of your genome.\n";
	    $msg .= "This may mean the genome was a fragment too small for RAST processing to be effective.";
	    return $msg;
	}
    }

    if ($err =~ /rapid_propagation command failed/ or
	   $err =~ /rapid_propagation did not create any features/)
    {
	return "An error occurred during the annotation of your data.";
    }
}
