#
# Shutdown the server that was started by the rast boot.
#

use strict;
use FIG_Config;
use File::Path;
use DBI;

system("mysqladmin", "-u", "root", "-S", $FIG_Config::dbsock, "shutdown");
