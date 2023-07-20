package TeragridCompute;

#
# Class to encapsulate SSH2 communications with a teragrid host.
#

use strict;

use lib '/home/olson/netssh/lib';
use Net::SSH2;

sub new
{
    my($class, $host, $user, $pubkey, $privkey) = @_;

    my $ssh = Net::SSH2->new();

    $ssh->connect($host) or die "ssh connect failed: $!";

    if ($ssh->auth_publickey($user, $pubkey, $privkey))
    {
	warn "Authenticated to $host\n";
    }
    else
    {
	die "Authentication failure to $host\n";
    }
    my $self = {
	host => $host,
	user => $user,
	pubkey => $pubkey,
	privkeyh => $privkey,
	ssh => $ssh,
    };
    return bless $self, $class;
}

1;
