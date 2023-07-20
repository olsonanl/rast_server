use strict;
use FIG_Config;
use GenomeMeta;
use Data::Dumper;
use DBI;
use FIG;
use POSIX;
use Storable;
use XML::LibXML;
use Cache::Memcached::Fast;

my $user;
my $job;
my $stages;
my $sge_status;
my $running_only;

my $njobs = 1000;

my $user_dbh = DBI->connect("dbi:mysql:$FIG_Config::webapplication_db;host=$FIG_Config::webapplication_host",
			    $FIG_Config::webapplication_user, $FIG_Config::webapplication_password);

my $job_dbh = DBI->connect("dbi:mysql:RastProdJobCache;host=rast.mcs.anl.gov", "rast");

my $users = $user_dbh->selectall_hashref(qq(SELECT _id, login, email, firstname, lastname
					    FROM User), '_id');

my $jobs = $job_dbh->selectall_arrayref(qq(SELECT _id, id, genome_id, genome_name, project_name, created_on, owner
					   FROM Job
					   ORDER BY id DESC));

my $job_final_status = $job_dbh->selectall_hashref(qq(SELECT j.id, s.status
						      FROM Job j JOIN Status s ON j._id = s.job
						      WHERE s.stage = "status.final"), 'id');
my $job_upload_status = $job_dbh->selectall_hashref(qq(SELECT j.id, s.status
						      FROM Job j JOIN Status s ON j._id = s.job
						      WHERE s.stage = "status.uploaded"), 'id');
my $parser = XML::LibXML->new;
open(JFH, "-|", "qstat", "-u", "*", "-xml") or die "cannot qstat: $!";
my $jdoc = $parser->parse_fh(\*JFH);

my @jnodes = $jdoc->findnodes('//job_list/JB_job_number');
my %active_sge;
for my $jn (@jnodes)
{
    $active_sge{$jn->textContent()} = 1;
}

#die Dumper($jobs, $job_final_status);
my $last_job = $jobs->[0]->[1] - $njobs;

for my $job (@$jobs)
{
    my($xid, $id, $gid, $gname, $project, $created, $oid) = @$job;
    last if $id < $last_job;

    my $owner = $users->{$oid}->{login};
    my $owner_email = $users->{$oid}->{email};
    my $status = $job_final_status->{$id}->{status} || "incomplete";
    my $upstatus = $job_upload_status->{$id}->{status} || "incomplete";

    next if $status eq 'complete';
    next if $upstatus ne 'complete';

    my $dir = "/vol/rast-prod/jobs/$id";

    if (-f "$dir/DONE")
    {
	# print "$id done\n";
	next;
    }
    elsif (-f "$dir/ACTIVE")
    {
	# print "$id active $upstatus\n";
	# next;
    }
    elsif (-f "$dir/ERROR")
    {
	# print "$id error\n";
	next;
    }
    elsif (-f "$dir/CANCEL")
    {
	# print "$id cancel\n";
	next;
    }
    elsif (-f "$dir/DELETE")
    {
	# print "$id deleted\n";
	next;
    }

    my $ok;
    my $meta = GenomeMeta->new(undef, "$dir/meta.xml");

    #
    # Recheck final status against the meta file
    #
    if ($meta->get_metadata('status.final') eq 'complete')
    {
	next;
    }
    
    if ($meta->get_metadata('status.correction') eq 'requires_intervention')
    {
	print "$id waiting for approval\n";
	next;
    }

    my @why;

    my @mdkeys = $meta->get_metadata_keys;
    my @maybefix;
    for my $statusk (@mdkeys)
    {
	next unless $statusk =~ /^status\.(\S+)/;
	my $stage = $1;
	my $v = $meta->get_metadata($statusk);
	my $v2 = $meta->get_metadata("$stage.running");
#	print "$stage: $v $v2\n";
	if ($v eq 'queued' && $v2 eq 'yes')
	{
	    push @maybefix, "meta $dir/meta.xml set $statusk not_started";
	    push @maybefix, "meta $dir/meta.xml set $stage.running no";
	}
    }

    for my $attr (grep { /sge_(job_?)id$/ } @mdkeys)
    {
	my $val = $meta->get_metadata($attr);
	if ($active_sge{$val})
	{
	    push(@why, "$id\tOK: $attr $val");
	    $ok++;
	}
	else
	{
	    push(@why, "$id\tmissing $attr $val");
	}
    }
    if ($ok)
    {
	next;
    }

    #
    # See if the sge output dir was recently written to; if so we may be in a
    # hole between submissions.
    #
    my @s = stat("$dir/sge_output");
    my $sge_delay = time - $s[9];
    if ($sge_delay < 15 * 60)
    {
	printf "$id recent sge output (%d:%02d)\n", int($sge_delay / 60), $sge_delay % 60;
	next;
    }
	
    
    print "$id probably orphaned\n";
    print "$_\n" for @why;
    print "$_\n" for @maybefix;
    
	    
   
}
						      
					
			
