

package Mantis;

use Data::Dumper;
use FIG_Config;
use POSIX;
use LWP::UserAgent;
use File::Basename;

use base 'Class::Accessor';
use DBI;
use strict;

__PACKAGE__->mk_accessors(qw(info dbh ua base_url web_user web_pass logged_in));

sub new
{
    my($class, $info) = @_;

    my $db_conn = $info->{db_connect};
    my $db_user = $info->{db_user};
    my $db_pass = $info->{db_pass};
    my $base_url = $info->{base_url};

    my $dbh = DBI->connect($db_conn, $db_user, $db_pass);

    $dbh or die "cannot connect to db: conn=$db_conn user=$db_user\n";

    my $ua = LWP::UserAgent->new();
    my $cookies = {};
    $ua->cookie_jar($cookies);

    my $self = {
	dbh => $dbh,
	info => $info,
	ua => $ua,
	base_url => $base_url,
	web_user => $info->{web_user},
	web_pass => $info->{web_pass},
    };
    return bless $self, $class;
}

#
# Invoked like:
#
# 	    Mantis::report_bug(info => $FIG_Config::mantis_info,
# 			       stage => $stage,
# 			       genome => $genome,
# 			       genome_name => $genome_name,
# 			       job_id =>$ job_id,
#			       job_dir => $job_dir,
#		               meta => $meta,
# 			       user_email => $email,
# 			       user_name => $name,
# 			       msg => $msg);

sub report_bug
{
    my($self, %opts) = @_;

    my $reporter = $self->check_for_reporter($opts{user_email});

    my $project = $self->info->{project_id} or 0;

    #
    # Bug description.
    #

    my $sys = $self->info->{system};
    my $summary = "$sys error detected in job $opts{job_id} stage $opts{stage}";
    
    my $descr = "Error reported in job $opts{job_id} in $opts{job_dir}\n";
    $descr .= $opts{msg};

    #
    # Extra info. Include dump of metadata here plus the metadata log.
    #
    my $extra = "";
    my $meta = $opts{meta};

    my $dbh = $self->dbh;
    $dbh->do(qq(INSERT INTO mantis_bug_text_table (description, steps_to_reproduce, additional_information)
		VALUES (?, ?, ?)), undef,
	     $descr, '', $extra);
                      
    my $text_id = $dbh->{mysql_insertid};
    print "inserted: '$text_id'\n";

    #
    # Determine if there is an auto-assigned handler for this project & category.
    #

    my $res = $dbh->selectall_arrayref(qq(SELECT user_id
					  FROM mantis_project_category_table
					  WHERE project_id = ? AND category = ?), undef,
				       $project, $self->info->{bug_category});
    # print Dumper($res);
    my $handler = 0;
    if (@$res)
    {
	$handler = $res->[0]->[0];
    }

    $dbh->do(qq(INSERT INTO mantis_bug_table (project_id, reporter_id, handler_id, date_submitted, last_updated,
					      bug_text_id, summary, category)
		VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?, ?)), undef,
	     $project, $reporter, $handler, $text_id, $summary, $self->info->{bug_category});
    my $bug_id = $dbh->{mysql_insertid};

    {
	my $b = $meta->get_metadata('mantis.bug');
	if (ref($b))
	{
	    push(@$b, $bug_id);
	}
	else
	{
	    $b = [$bug_id];
	}
	$meta->set_metadata('mantis.bug', $b);
    }

    #
    # custom field.
    #
    $dbh->do(qq(INSERT INTO mantis_custom_field_string_table (field_id, bug_id, value)
		VALUES (?, ?, ?)), undef,
	     $self->info->{field_job_number}, $bug_id, $opts{job_id});
    $dbh->do(qq(INSERT INTO mantis_custom_field_string_table (field_id, bug_id, value)
		VALUES (?, ?, ?)), undef,
	     $self->info->{field_server}, $bug_id, $self->info->{server_value});
    
    if ($meta)
    {
	my $tmp = "/tmp/mantis.$$";
	mkdir $tmp;
	open(T, ">$tmp/metadata_dump");
	
	for my $key (sort $meta->get_metadata_keys())
	{
	    my $val = $meta->get_metadata($key);
	    if (ref($val))
	    {
		$val = Dumper($val);
	    }
	    print T "$key: $val\n";
	}
	close(T);

	$self->upload_file($bug_id, "$tmp/metadata_dump");
	unlink("$tmp/metadata_dump");

	open(T, ">$tmp/log_dump");
	
	my $log = $meta->get_log();
	for my $l (@$log)
	{
	    my($type, $what, $date, $data) = @$l;
	    my $dstr = strftime("%Y-%m-%d %H:%M:%S", localtime $date);
	    if (ref($data))
	    {
		$data = Dumper($data);
	    }
	    print T "$type\t$what\t$dstr\t$data\n";
	}
	close(T);
	$self->upload_file($bug_id, "$tmp/log_dump");
	unlink("$tmp/log_dump");
	rmdir($tmp);
    }

    #
    # Insert a note for each error file.
    #

    my @err_files = <$opts{job_dir}/rp.errors/*>;
    @err_files = grep { -f $_->[0] } map { my @s = stat($_); [$_, @s] } @err_files;

    my @empty;
    for my $err_file (sort { $b->[10] <=> $a->[10] } @err_files)
    {
	my $path = $err_file->[0];

	if ($err_file->[8] == 0)
	{
	    push(@empty, $path);
	    next;
	}
	    
	eval {
	    my $url_base = $FIG_Config::fortyeight_home;
	    $url_base =~ s,/[^/]+\.cgi,,;

	    my $size = -s $path;

	    my $txt;
	    my $base = basename($path);
	    my $url = "$url_base/rast.cgi?page=ShowErrorFile&job=$opts{job_id}&file=$base";

	    $txt .= "Error file $base exists ($size bytes)\n";
	    $txt .= "$url\n";
	    $txt .= "Last ten lines of file:\n\n";
	    $txt .= `tail -10 $path`;

	    insert_note($dbh, $bug_id, $reporter, $txt);
	};
	if ($@)
	{
	    warn "Error inserting bug note about $path: $@\n";
	}
    }

    if (@empty)
    {
	my $txt = "Empty error files:\n" . join("\n", @empty), "\n";
	insert_note($dbh, $bug_id, $reporter, $txt);
    }
    
    my $bug_url = $self->info->{public_url} . "/view.php?id=$bug_id";
    return($bug_id, $bug_url);
}


sub insert_note
{
    my($dbh, $bug_id, $reporter, $txt) = @_;

    $dbh->do(qq(INSERT INTO mantis_bugnote_text_table(note) VALUES (?)),
	     undef, $txt);
    my $tid = $dbh->{mysql_insertid};
    $dbh->do(qq(INSERT INTO mantis_bugnote_table (bug_id, reporter_id, bugnote_text_id, view_state,  date_submitted, last_modified)
		VALUES (?, ?, ?, 10, NOW(), NOW())), undef, $bug_id, $reporter, $tid);
}

sub check_for_reporter
{
    my($self, $email) = @_;

    my $res = $self->dbh->selectall_arrayref(qq(SELECT id
						FROM mantis_user_table
						WHERE email = ? AND enabled = 1
						ORDER BY access_level), undef, $email);
    if (! $res)
    {
	die "check_for_reporter: lookup error: " . DBI->errstr;
    }
    if (@$res)
    {
	return $res->[0]->[0];
    }
    else
    {
	#
	# Look up the rast user.
	#

	my $rast_user = $self->info->{default_reporter};
	my $res = $self->dbh->selectall_arrayref(qq(SELECT id
						    FROM mantis_user_table
						    WHERE username = ? AND enabled = 1
						    ORDER BY access_level), undef, $rast_user);
	if (@$res)
	{
	    return $res->[0]->[0];
	}
	else
	{
	    die "Default mantis reporter not found (rast_user='$rast_user')";
	}
    }
}

sub login
{
    my($self) = @_;

    my $resp = $self->ua->post($self->base_url . '/login.php',
		     [ username => $self->web_user,
		      password =>  $self->web_pass,
		      perm_login => '',
		      ],
			       Content_Type => 'form-data',
		      );
    $self->logged_in(1);
}

sub upload_file
{
    my($self, $bug_id, $file) = @_;

    if (!$self->logged_in)
    {
	$self->login();
    }

    my $l = -s $file;

    my $resp = $self->ua->post($self->base_url . "/bug_file_add.php",
		     [
		      bug_id => $bug_id,
		     max_file_size => 2000000,
		     file => [$file],
		      ],
		      Content_Length => $l,
		     Content_Type => 'form-data'
		    );

}


1;
