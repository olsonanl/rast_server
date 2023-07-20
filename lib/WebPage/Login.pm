package WebPage::Login;

use base qw( WebApp::WebPage );

1;

use CGI;
use Mail::Mailer;
use Carp qw( confess );

=pod

=head1 NAME

Login - an instance of WebPage which handles login, password retrieval and registration of new accounts.

=head1 DESCRIPTION

TODO

=head1 METHODS

=over 4

=item * B<output> ()

Returns the html output of the Login page.

=cut

sub output {
  my ($self) = @_;

  my $cgi = $self->application->cgi;
  my $session = $self->application->session;
  my $content = 'unknown action';

  my $action = 'default';
  if (defined($cgi->param('action'))) {
    $action = $cgi->param('action');
  }

  if ($action eq 'logout') {
    $self->title('Annotation Server - Login');
    $content = "<div style='padding-left: 50px; padding-top: 50px;'>" . perform_logout($self, $session, $cgi);
    $content .= login($self, $session, $cgi) . "</div>";
  }
  else {

    # none of these pages should be shown when a user is logged in
    my $webpage = $self->load_page_after_login;
    if ($webpage) {
      return $webpage->output();
    }

    if ($action eq 'default') {
      $self->title('Annotation Server - Login');
      $content = "<div style='padding-left: 50px; padding-top: 50px;'>" . login($self, $session, $cgi) . "</div>";
    } elsif ($action eq 'check_login') {
      $content = check_login($self, $session, $cgi);
    } elsif ($action eq 'forgot_password') {
      $self->title('Annotation Server - Reset Password');
      $content = forgot_password($self, $session, $cgi);
    } elsif ($action eq 'reset_password') {
      $self->title('Annotation Server - Reset Password');
      $content = reset_password($self, $session, $cgi);
    } elsif ($action eq 'register') {
      $self->title('Annotation Server - Register a new Account');
      $content = register($self, $session, $cgi);
    } elsif ($action eq 'perform_registration') {
      $self->title('Annotation Server - Register a new Account');
      $content = perform_registration($self, $session, $cgi);
    } 

  }

  return $content;
}

=pod

=item * B<login> ()

Returns the html for a login screen.

=cut

sub login {
  my ($self, $session, $cgi, $failed) = @_;

  my $content = $self->start_form;

  $content .= "<input type=hidden name=action value=check_login >";

  if ($failed) {
    $content .= "<span class='warning'>Login or password incorrect, please retry.</span>";
  }

  $content .= "<p style='width: 95%;border: 1px solid black; padding-left: 5px; padding-top: 3px; padding-bottom: 5px; padding-right: 5px;'><table><tr><td><b>Note:</b></td><td>We have updated the RAST server to version 1.2 to provide you with our current improvements. All your jobs have been rerun at this server. Your old results have been preserved at <a href='http://www.nmpdr.org/anno-server-1-0/'>RAST v1.0</a>. For more information, visit our update information page <a href='http://www.theseed.org/wiki/RAST_update'>here</a>.</td></tr></table></p>";

  $content .= "<p style='width: 95%;'>While originally designed in the <a target=_blank href='http://www.nmpdr.org'>NMPDR project</a> only for the annotation of  certain re-emerging <a target=_blank href='http://www.nmpdr.org/content/organisms.php'>pathogens</a>, the RAST (Rapid Annotation using Subsystem Technology) server now provides high-quality genome annotations for bacterial and archaeal genomes across the entire phylogenetic spectrum. A similar RAST-based approach has been used to create a <a target=_blank href='http://metagenomics.nmpdr.org'>metagenomics RAST server</a>.";

  $content .= "<p style='width: 95%;'>As the number of sequenced, more or less complete, bacterial and archaeal genomes is constantly rising, the need for high-quality automated initial annotations is rising with it. In response to numerous requests for a SEED-quality automated annotation service, we provide RAST as a free service to the community. It leverages the data and procedures established within the <a target=_blank href='http://www.theseed.org'>SEED framework</a> to provide automated high-quality gene calling and functional annotation. RAST supports both the automated annotation of high-quality genome sequences AND the analysis of draft genomes. The server also supports the analysis of contigs of at least 40 kb. While the computation time is typically reasonably low, the \"guaranteed\" turn-around time for this service is 48 hours.</p>\n";

$content .= "<p style='width: 95%;'>SEED code and SEED data structures (most prominently <a target=_blank href='http://www.theseed.org/wiki/index.php/Glossary#Subsystem'>subsytems</a> and <a target=_blank href='http://www.theseed.org/wiki/index.php/Glossary#FIGfam'>FIGfams</a>) are used to compute the automatic annotations. Completed genome annotations can be viewed online with a password-protected version of the <a target=_blank href='http://www.theseed.org/wiki/index.php/Glossary#SEED-Viewer'>SEED Viewer</a>. Genomes are NOT added to the SEED automatically; submitting users can, however, request inclusion of a their genome in the SEED via the web interface. Genomes can be downloaded in a variety of formats, including GenBank and GFF3. The genome annotation includes a mapping of genes to <a target=_blank href='http://www.theseed.org/wiki/index.php/Glossary#Subsystem'>subsystems</a> and a metabolic reconstruction.</p>";
$content .= "<p style='width: 95%;'>So that we may contact you once the computation is finished, or in case user intervention is required, we request that you register for an account with a valid email address.</\p>\n";

  $content .= "<table>";
  $content .= "<tr><td>Login</td><td><input type=text name=login></td></tr>";
  $content .= "<tr><td>Password</td><td><input type=password name=password></td>";
  $content .= "<td><input type=submit value='Login'></td></tr>";
  $content .= "</table>";

  $content .= "<br/><br/><a href='" . $self->url . "action=forgot_password'>Forgot your password?</a><br/>";
  $content .= "<a href='" . $self->url . "action=register'>Register a new account</a>";

  $content .= "</form>";

  return $content;
}

=pod

=item * B<check_login> ()

Tries to initialize a user using the login and password in the current cgi object.
On success calls the redirect method of the WebApplication object, on failure
calls the login method with the 'failed' parameter.

=cut

sub check_login {
  my ($self, $session, $cgi) = @_;

  # get login and password from cgi
  my $login = $cgi->param('login');
  my $password = $cgi->param('password');

  # try to initialize user
  my $user = undef;
  my $possible_users = $self->application->dbmaster->User->get_objects( { login => $login } );
  if (@$possible_users) {
    $user = $possible_users->[0];
    if (crypt($password, $user->password) eq $user->password) {
      $session->user($user);
    } else {
      $user = undef;
    }
  }

  # if user initialization is successful, call first page
  # otherwise recall login page with login failed
  my $webpage = $self->load_page_after_login;
  if ($webpage) {

    # update menu 
    $self->application->menu->add_category( "Logout", "rast.cgi?page=Login&action=logout" );
    $self->application->menu->add_category( "Manage Account",  "rast.cgi?page=UserManagement");
    $self->application->menu->add_category( "Your Jobs",  "rast.cgi?page=Jobs");	
    $self->application->menu->add_entry( "Your Jobs", "Jobs Overview", "rast.cgi?page=Jobs" );
    $self->application->menu->add_entry( "Your Jobs", "Upload New Job", "rast.cgi?page=Upload" );

    return $webpage->output();
  } else {
    return "<div style='padding-left: 50px; padding-top: 50px;'>" . $self->login($session, $cgi, 1) . "</div>";
  }
}

=pod

=item * B<load_page_after_login> ()

Expires the session cookie.

=cut

sub load_page_after_login {
  my ($self) = @_;

  $self->title('Annotation Server - Jobs Overview');

  # if the session has a user, call the first page
  if (defined($self->application->session->user)) {

    use WebPage::Jobs;
    my $webpage = WebPage::Jobs->new($self->application); 
    unless (ref $webpage) {
      confess "Unable to initialize Jobs Page.\n";
    }
    $self->application->cgi->delete('action');

    return $webpage;
  }

  return undef;
}


=pod

=item * B<perform_logout> ()

Expires the session cookie.

=cut

sub perform_logout {
  my ($self, $session, $cgi) = @_;

  $session->expire_cookie();
  $session->user(undef);
  $self->application->menu->flush();

  my $content = "<span class='info'>You have been logged out.</span><br/><br/>";

  return $content;
}

=pod

=item * B<register> ()

Returns the html for the registration of a new user.

=cut

sub register {
  my ($self, $session, $cgi) = @_;

  my $content = $self->start_form;

  $content .= "<div style='padding-left: 50px; padding-top: 50px;'><input type=hidden name=action value=perform_registration >";

  $content .= "<table>";
  $content .= "<tr><td>First Name</td><td><input type=text name=firstname></td></tr>";
  $content .= "<tr><td>Last Name</td><td><input type=text name=lastname></td></tr>";
  $content .= "<tr><td>eMail</td><td><input type=text name=email></td></tr>";
  $content .= "<tr><td>Organization</td><td><input type=text name=organisation></td></tr>";
  $content .= "<tr><td colspan=2>Please note that you may not include html in the note field.</td>";
  $content .= "<tr><td>Note</td><td><textarea cols=50 rows=5 name=note></textarea></td>";
  $content .= "<td><input type=submit value='Request'></td></tr>";
  $content .= "</table>";

  $content .= "</form><br/><a href='".$self->application->url."?page=Login'>return to login</a></div>";

  return $content;
}

=pod

=item * B<perform_registration> ()

Sends a mail to the administrator mailing list of the site. The mail will contain
the registration information entered by the user and a link to the webpage.

=cut

sub perform_registration {
  my ($self, $session, $cgi) = @_;

  # test for bots
  if ($cgi->param('note') =~ /\<(.*)\>/) {
    return "<h2>You may not use html in the note field, please retry.</h2>" . $self->register($session, $cgi);
  }

  my $content = "<div style='padding-left: 50px; padding-top: 50px;'>";

  unless ($cgi->param('email')) {
    return "You must enter a valid eMail address.<br/>" . $self->register($session, $cgi);
  }

  # check if this email already has an account
  my $potential = $self->application->dbmaster->User->get_objects( { eMail => $cgi->param('email') } );
  if (@$potential) {
    $content .= "This eMail address is already registered for " . $potential->[0]->firstName . " " . $potential->[0]->lastName . ".";
  } else {

    my $request = $self->application->dbmaster->Request->create( { eMail        => $cgi->param('email'),
								   firstName    => $cgi->param('firstname'),
								   lastName     => $cgi->param('lastname'),
								   organisation => $cgi->param('organisation'),
								   note         => $cgi->param('note') } );
    
    my $body = qq~A request for a new account has been submitted at the RAST annotation server website.
You are receiving this mail, because you are on the administrators mailing list for this service. The user has sent the following data:

First Name\t:\t ~  . $cgi->param('firstname') . qq~
Last Name\t:\t ~  . $cgi->param('lastname') . qq~
eMail\t\t:\t ~  . $cgi->param('email') . qq~
Organization\t:\t ~  . $cgi->param('organisation') . qq~
Note\t\t\t:\t ~  . $cgi->param('note') . qq~

To process this request, click the following link:
http://www.nmpdr.org/anno-server/~;
    
    my $mailer = Mail::Mailer->new();
    $mailer->open({ From    => &admin_email,
		    To      => &admin_email,
		    Subject => "RAST server: registration request",
		  })
      or die "Can't open: $!\n";
    print $mailer $body;
    $mailer->close();
    
    $content .= "Your registration request has been sent.<br/>You will be notified as soon as your request has been processed.";
  }

  $content .= "<br/><br/><a href='".$self->application->url."?page=Login'>return to login</a></div>";

  return $content;
}

=pod

=item * B<forgot_password> ()

Returns the html for a form for the user to enable them to resend their password.

=cut

sub forgot_password {
  my ($self, $session, $cgi) = @_;

  my $content = $self->start_form;

  $content .= "<div style='padding-left: 50px; padding-top: 50px;'><input type=hidden name=action value=reset_password>";

  $content .= "<span class=info>Enter your information to have your password reset.<br/>You will then shortly receive an email with your new password.<br/>Please change your password as soon as you receive this mail.</span>";

  $content .= "<br/><br/><table>";
  $content .= "<tr><td>Login</td><td><input type=text name=login></td></tr>";
  $content .= "<tr><td>eMail</td><td><input type=text name=email></td>";
  $content .= "<td><input type=submit value='Reset'></td></tr>";
  $content .= "</table>";

  $content .= "</form><br/><a href='".$self->application->url."?page=Login'>return to login</a></div>";

  return $content;
}

=pod

=item * B<reset_password> ()

Tries to initialize a user, given the email and login parameters in the current cgi object.
On success, informs the user that their password has been reset, on failure informs
the user that login and email do not match.

=cut

sub reset_password {
  my ($self, $session, $cgi) = @_;

  # get all parameters
  my $login = $cgi->param('login') || "";
  my $email = $cgi->param('email') || "";

  # initialize content
  my $content = "";

  # try to initialize user
  my $user = undef;
  my $possible_users = $self->application->dbmaster->User->get_objects( { login => $login } );
  if (@$possible_users) {
    $user = $possible_users->[0];
    unless ($user->eMail eq $email) {
      $user = undef;
    }
  }

  # check whether login and email match
  if (defined($user)) {
    my $new_password = join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64, rand 64, rand 64, rand 64, rand 64, rand 64, rand 64];
    
    my $body = qq~This email was automatically generated by the RAST annotation server.
You have requested your password to be resent. Your password is:

$new_password

Please go to 

http://www.nmpdr.org/anno-server/

and change your password.~;
    
    my $mailer = Mail::Mailer->new();
    $mailer->open({ From    => &admin_email,
		    To      => $email,
		    Subject => "RAST server: password request",
		  })
      or die "Can't open: $!\n";
    print $mailer $body;
    $mailer->close();

    # reset the user's password
    my $seed = join '', ('.', '/', 0..9, 'A'..'Z', 'a'..'z')[rand 64, rand 64];
    $new_password = crypt($new_password, $seed);
    $user->password($new_password);
    
    $content = "Your password has been resent to your email address.<br/><a href='" . $self->url . "'>return to login</a>";
  } else {
    $content = "Login and user do not match.";
  }

  return $content;
}

################

sub admin_email {
  ### stub until user management exists
  return $FIG_Config::rast_admin_email;
}
