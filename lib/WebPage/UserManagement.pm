package WebPage::UserManagement;
use WebApp::WebPage;

1;

our @ISA = qw ( WebApp::WebPage );

use CGI;
use Mail::Mailer;
use FIG_Config;

=pod

=head1 NAME

UserManagement - an instance of WebPage which allows an administrator to manage user accounts.

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the UserManagement page.

=cut

sub output {
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  my $session = $self->application->session;
  my $content = 'unknown action';
  $self->title('Annotation Server - User Management');

  my $action = 'default';
  if (defined($cgi->param('action'))) {
    $action = $cgi->param('action');
  }

  unless ($session->user) {
    return "You are not logged in.<br/>Please return to the <a href='index48.cgi?page=Login'>login page.</a>";
  }

  if ($action eq 'default') {
    $content = overview($self, $session, $cgi);
  } elsif ($action eq 'change_userinfo') {
    $content = change_userinfo($self, $session, $cgi);
  } elsif ($action eq 'perform_change') {
    $content = perform_change($self, $session, $cgi);
  }

  return $content;
}

=pod

=item * B<overview> ()

Returns the html for the overview page.

=cut

sub overview {
  my ($self, $session, $cgi) = @_;

  my $content = "";

  if ($self->application->authorized(2)) {
    $content .= $self->change_userinfo($session, $cgi);
    $content .= "<hr/>";
    $content .= $self->manage_requests($session, $cgi);
    $content .= "<hr/>";
    $content .= $self->manage_users($session, $cgi);
    $content .= "<hr/>";
    $content .= $self->manage_organisations($session, $cgi);
  } elsif ($self->application->authorized(1)) {
    $content .= $self->change_userinfo($session, $cgi);
  } else {
    $content .= "You are not a registered user. <br/>You can register for an account <a href='" . 
      $self->application->url . "?page=Login&action=register'>here</a>.";
  }

  return $content;
}

=pod

=item * B<change_userinfo> ()

Returns the html for changing of user information, i.e. password or email.

=cut

sub change_userinfo {
  my ($self, $session, $cgi) = @_;

  my $content = "";

  if ($self->application->authorized(1)) {
    
    $content = $self->start_form;
    $content .= "<h1>Account Management</h1><p>Here you can change your user information.</p>";
    
    $content .= "<input type=hidden name=action value='perform_change'>";

    $content .= "<table>";
    $content .= "<tr><td>First Name</td><td><input type=text name=firstname value='" . $session->user->firstName . "'></td></tr>";
    $content .= "<tr><td>Last Name</td><td><input type=text name=lastname value='" . $session->user->lastName . "'></td></tr>";
    $content .= "<tr><td>eMail</td><td><input type=text name=email value='" . $session->user->eMail . "'></td></tr>";
    $content .= "<tr><td>Old password</td><td><input type=password name=old_pwd></td></tr>";
    $content .= "<tr><td>New password</td><td><input type=password name=new_pwd></td></tr>";
    $content .= "<tr><td>Confirm new password</td><td><input type=password name=new_pwd_confirm></td></tr>";
    $content .= "<td><input type=submit value='Change'></td></tr>";
    $content .= "</table>";
    $content .= "</form>";
  } else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>You are currently not logged in. Please return to the <a href='" . 
      $self->application->url . "'>login page</a>.";
  }

  return $content;
}

=pod

=item * B<perform_change> ()

Changes the user information as requested. Also displays a confirmation message.

=cut

sub perform_change {
  my ($self, $session, $cgi) = @_;

  my $content = "";

  if ($self->application->authorized(1)) {

    # check for password change
    if ($cgi->param('old_pwd')) {
      if (crypt($cgi->param('old_pwd'), $session->user->password) eq $session->user->password) {
	if ($cgi->param('new_pwd') && $cgi->param('new_pwd_confirm')) {
	  if ($cgi->param('new_pwd') eq $cgi->param('new_pwd_confirm')) {
	    my $seed = join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64];
	    $new_password = crypt($cgi->param('new_pwd'), $seed);
	    $session->user->password($new_password);
	    $content .= "Your password has been changed.";
	  } else {
	    $content .= "New password does not match new password confirmation.<br/>Your password has not been changed.";
	  }
	} else {
	  $content .= "You must supply both 'new password' and 'confirm new password' fields.<br/>Your password has not been changed.";
	}
      } else {
	$content .= "Old password incorrect.<br/>Your password has not been changed.";
      }
    }

    # change non-password information
    $session->user->firstName($cgi->param('firstname'));
    $session->user->lastName($cgi->param('lastname'));
    $session->user->eMail($cgi->param('email'));

    $cgi->delete('action');
    $content .= "<br/>Your non-password information has been changed.<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  } else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }
  
  return $content;
}

=pod

=item * B<manage_requests> ()

Manages the requests for user accounts.

=cut

sub manage_requests {
  my ($self, $session, $cgi) = @_;

  my $content = "";

  if ($self->application->authorized(2)) {
    
    # check if a request is being handled
    if ($cgi->param('email')) {
      my $request = $self->application->dbmaster->Request->get_objects( { eMail => $cgi->param('email') } )->[0];
      if ($cgi->param('allow') eq '1') {
	
	# create the user in the database
	my $password = join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64, rand 64, rand 64, rand 64, rand 64, rand 64, rand 64];
	my $seed = join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64];
	my $encrypted_password = crypt($password, $seed);
	my $login = $cgi->param('login');
	
	my $new_user = $self->application->dbmaster->User->create( { login     => $login,
								     firstName => $cgi->param('firstname'),
								     lastName  => $cgi->param('lastname'),
								     eMail     => $cgi->param('email'),
								     status    => 1,
								     entryDate => time,
								     note      => '',
								     password  => $encrypted_password } );
	
	# send an email to the user
	my $body = qq~RAST annotation server WELCOME message

Dear User of the RAST Rapid Annotation using Subsystem Technology service,

You have requested an account for our service with the following data:

Name: ~ . $new_user->firstName . " " . $new_user->lastName . qq~
login: $login
email: ~ . $new_user->eMail . qq~
password: $password

This mail is to inform you that we have created an account for you for our annotation service.

Note that we provide two distinct services:

For complete genome annotation, including the annotation of fragments (which should be at least 40kb in size) please visit:

http://www.nmpdr.org/anno-server/

For annotation of metagenomic samples please visit:

http://metagenomics.theseed.org/

You will be able to log into both sites using the username and password provided above. After you log in, please use the 'Manage Account' link in the top menu to change your password.


Contacting us
-----------------
We can be contacted at ~ . &admin_email() . qq~

Citing our service
---------------------
If you find the annotation provided by our service useful, please cite the reference listed on the start page.

Data export
--------------
Once the automatic annotation process has completed, you will be notified via email. You can then either browse the annotation online or download the genome in a number of formats. If unsure, pick the GenBank format, as it is also required for submission to NCBI Genbank.

Privacy statement
----------------------
We do not include any of the genomes submitted via the RAST server into the regular SEED environment, however we would usually be willing to include it on your request. Please make sure that you are entitled to request a publication of the genome.

Disclaimer
--------------
Argonne National Labs, the University of Chicago and FIG make this service available on a best effort basis and accept no liability to any party for loss or damage caused by errors or omissions in this service, whether such errors result from accident, negligence or any other cause. We assume no liability for incidental or consequential damages arising from the use of information in this service. We provide no warranties regarding the information generated, whether expressed, implied, or statutory, including implied warranties of merchantability or fitness for a particular purpose.
~;

	my $mailer = Mail::Mailer->new();
	$mailer->open({ From    => &admin_email,
			To      => $cgi->param('email'),
			Subject => "48-hour server: account request",
		      })
	  or die "Can't open: $!\n";
	print $mailer $body;
	$mailer->close();
	
	# update the content
	$content .= "The account of " .$cgi->param('firstname') . " " . $cgi->param('lastname') . " has been approved. The user has been notified via eMail.<hr/>";
	
	$request->delete;
      } elsif ($cgi->param('allow') eq '0') {
	# notify the user that their request has been denied
	my $mailer = Mail::Mailer->new();
	$mailer->open({ From    => &admin_email,
			To      => $cgi->param('email'),
			Subject => "48-hour server: account request",
		      })
	  or die "Can't open: $!\n";
	print $mailer "Your account request has been denied.";
	$mailer->close();
	
	$content .= "The account of " .$cgi->param('firstname') . " " . $cgi->param('lastname') . " has been denied. The user has been notified via eMail.<hr/>";
	
	$request->delete;
      }
    }
    
    # get currently open requests
    my $requests = $self->application->dbmaster->Request->get_objects;
    
    unless (@$requests) {
      $content .= "There are currently no open requests.";
    } else {
      my $count = 1;
      my $organisation_select = "";
      foreach my $request (@$requests) {
	my $login = $self->create_login_name($request->firstName, $request->lastName);
	
	$content .= $self->start_form("request_form_" . $count);
	$content .= "<table>";
	$content .= "<tr><td>First Name</td><td><input type='hidden' name='firstname' value='" . $request->firstName . "'>" . $request->firstName . "</td></tr>";
	$content .= "<tr><td>Last Name</td><td><input type='hidden' name='lastname' value='" . $request->lastName . "'>" . $request->lastName . "</td></tr>";	  
	$content .= "<tr><td>Note</td><td><textarea name='note'>" . $request->note . "</textarea></td></tr>";
	$content .= "<tr><td>eMail</td><td><input type='hidden' name='email' value='" . $request->eMail . "'>" . $request->eMail . "</td>";
	$content .= "<tr><td>Organization</td><td>Requested:" . $request->organisation . "</td><td>" . $organisation_select . "</td></tr>";
	$content .= "<tr><td>Login</td><td><input type='hidden' name='login' value='" . $login . "'>" . $login . "</td></tr>";
	
	$content .= "<td><input type='button' value='Allow' onclick='document.getElementById(\"request_form_$count\").submit();'><input type='button' value='Deny' onclick='document.getElementById(\"allow_$count\").value=\"0\";document.getElementById(\"request_form_$count\").submit();'></td></tr>";
	$content .= "</table>";
	$content .= "<input type='hidden' name='allow' id='allow_$count' value='1'>";
	$content .= "</form>";
	$content .= "<hr/>";
	$count++;
      }
    }
    
  } else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }
  
  return $content;
}

=pod

=item * B<create_login_name> ()

Creates a login name unique to the database.

=cut

sub create_login_name {
  my ($self, $firstname, $lastname) = @_;

  # first try: first letter of first name, first seven of last name
  my $login = substr($firstname, 0, 1) . $lastname;
  $login =~ s/\s//g;

  if (@{$self->application->dbmaster->User->get_objects( { login => $login } )}) {
    # keep trying by adding increasing number to #1 until it works
    my $count = 1;
    while (@{$self->application->dbmaster->User->get_objects( { login => $login . $count } )}) {
      $count ++;
    }
    $login .= $count;
  }
  $login = lc($login);

  # return the result
  return $login;
}

=pod

=item * B<manage_users> ()

Manages the user accounts.

=cut

sub manage_users {
  my ($self, $session, $cgi) = @_;

  my $content = "";
  
  if ($self->application->authorized(2)) {
    # check for promotion requests
    if ($cgi->param('make_disabled')) {
      my @values = $cgi->param('make_disabled');
      foreach my $login (@values) {
	my $user = $self->application->dbmaster->User->get_objects( { login => $login } )->[0];
	$user->status('0');
      }
    }
    
    if ($cgi->param('make_user')) {
      my @values = $cgi->param('make_user');
      foreach my $login (@values) {
	my $user = $self->application->dbmaster->User->get_objects( { login => $login } )->[0];
	$user->status('1');
      }
    }
    
    if ($cgi->param('make_admin')) {
      my @values = $cgi->param('make_admin');
      foreach my $login (@values) {
	my $user = $self->application->dbmaster->User->get_objects( { login => $login } )->[0];
	$user->status('2');
      }
    }
    
    # check for deletion requests
    if ($cgi->param('delete')) {
      my @values = $cgi->param('delete');
      foreach my $login (@values) {
	my $user = $self->application->dbmaster->User->get_objects( { login => $login } )->[0];
	$user->delete;
      }
    }
    
    # check for change of organisation
    if ($cgi->param('new_org')) {
      my @values = $cgi->param('new_org');
      foreach my $login_org_name (@values) {
	my ($login, $new_org) = split('~', $login_org_name);
	unless ($new_org eq "unchanged") {
	  my $user = $self->application->dbmaster->User->get_objects( { login => $login } )->[0];
	  my $organisation = $self->application->dbmaster->Organisation->get_objects( { name => $new_org } )->[0];
	  $user->organisation($organisation);
	}
      }
    }
    
    # print out the user list
    $content .= $self->start_form;
    $content .= "<span class='info'>This user list lets you delete users and update their status.</span>";
    $content .= "<table border=1>";
    $content .= "<tr><td>User</td><td>Login</td><td>eMail</td><td>Status</td><td>Entry Date</td><td>Organization</td><td>Delete</td><td>Promote</td><td>Demote</td></tr>";

    my $users = $self->application->dbmaster->User->get_objects();
    my $organisations = $self->application->dbmaster->Organisation->get_objects();
    foreach my $user (@$users) {
      my $status = "";
      my $promote = "";
      my $demote = "";
      if ($user->status == 0) {
	$status = 'Disabled';
	$promote = "<input type='checkbox' name='make_user' value='" . $user->login . "'>";
      } elsif ($user->status == 1) {
	$status = 'User';
	$demote = "<input type='checkbox' name='make_disabled' value='" . $user->login . "'>";
	$promote = "<input type='checkbox' name='make_admin' value='" . $user->login . "'>";
      } elsif ($user->status == 2) {
	$demote = "<input type='checkbox' name='make_user' value='" . $user->login . "'>";
	$status = 'Admin';
      }
      my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($user->entryDate);
      $mon += 1;
      $year += 1900;
      my $entry_date = "$mon / $mday / $year";
      my $organisation_select = "<select name='new_org'>";
      if ($organisations) {
	foreach my $organisation (@$organisations) {
	  if ($user->organisation) {
	    if ($organisation->name eq $user->organisation->name) {
	      $organisation_select .= "<option value='" . $user->login . "~unchanged' selected=selected>" . $organisation->name . "</option>";
	      next;
	    }
	  }
	  
	  $organisation_select .= "<option value='" . $user->login . "~" . $organisation->name . "'>" . $organisation->name . "</option>";
	}
      }
      $organisation_select .= "</select>";
      $content .= "<tr><td>" . $user->firstName . " " . $user->lastName . "</td><td>" . $user->login . "</td><td>" . $user->eMail . "</td><td>" . $status . "</td><td>" . $entry_date . "</td><td>" . $organisation_select . "</td><td><input type='checkbox' name='delete' value='" . $user->login ."'></td><td>" . $promote . "</td><td>" . $demote . "</td></tr>";
    }
    $content .= "</table>";
    $content .= "<input type='submit' value='Submit'>";
    $content .= "</form>";
  } else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }
  return $content;
}

=pod

=item * B<manage_organisations> ()

Manages the organisations.

=cut

sub manage_organisations {
  my ($self, $session, $cgi) = @_;
  
  my $content = "";
  
  if ($self->application->authorized(1)) {
    $content = $self->start_form;
    
    # check for a new organisation
    my $org_content = "";
    if ($cgi->param('organisation_name')) {
      $org_content = "<br/>" . $self->create_organisation($session, $cgi) . "<br/>";
    }
    
    # get all organisations
    my $organisations = $self->application->dbmaster->Organisation->get_objects();
    $content .= "<span class='info'>Here you can manage organizations</span>";
    
    $content .= $org_content;
    
    $content .= "<table border=1>";
    $content .= "<tr><td>Abbrev.</td><td>Name</td><td>URL</td></tr>";
    
    # display all organisations
    if (@$organisations) {	
      foreach my $organisation (@$organisations) {
	$content .= "<tr><td>" . $organisation->abbreviation . "</td><td>" . $organisation->name . "</td><td>" . $organisation->url . "</td></tr>";
      }
    }
    $content .= "<tr><td><input type='text' name='abbreviation'></td><td><input type='text' name='organisation_name'></td><td><input type='text' name='url'></td></tr>";
    $content .= "</table>";
    $content .= "<input type='submit' value='create'>";
    
    # create form for new organisation
    $content .= "";
    
    $content .= "</form>";
  } else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }
  
  return $content;
}

=pod

=item * B<create_organisation> ()

Creates an organisation.

=cut

sub create_organisation {
  my ($self, $session, $cgi) = @_;
  
  my $content = "";
  
  if ($self->application->authorized(1)) {
    $content = $self->start_form;
    
    # get all organisations
    my $organisations = $self->application->dbmaster->Organisation->get_objects( { name => $cgi->param('organisation_name') } );
    
    # no duplicate names allowed for organisations
    if (@$organisations) {
      $content = "<span class='info'>An organisation with this name already exists.</span>";
    } else {
      my $organisation = $self->application->dbmaster->Organisation->create( { name => $cgi->param('organisation_name'),
									       abbreviation => $cgi->param('abbreviation'),
									       url => $cgi->param('url')} );
      $content = "<span class='info'>The organisation " . $cgi->param('organisation_name') . " has been created.</span>";
    }
  } else {
    $cgi->delete('action');
    $content .= $self->application->error . "<br/>Please return to the <a href='" . $self->application->url . "'>login page</a>.";
  }
  
  return $content;
}

sub admin_email {
  return $FIG_Config::rast_admin_mail;
}
