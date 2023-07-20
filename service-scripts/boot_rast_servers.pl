#
# The independent-cluster RAST needs some extra servers to be running to work properly.
#
# 1. A mysql server that hosts the SEED database underlying the RAST. It also hosts
# the sims data.
#
# Hm, that's really it at this point.
# What is required is to ensure that the configuration files for the SEED
# database connectivity correctly reflect the setup that is in place.
#
# We do this by creating a new database directory in /scratch/username/seed.
# The boot script will write a customized my.cnf into that directory, and
# create files hostname.config in the FIG_Config directory that set up the
# database parameters accordingly (it uses the Cobalt nodelist to do this).
# The FIG_Config logic will look for the per-host config files.
#

use strict;
use FIG_Config;
use File::Basename;
use File::Path;
use DBI;
use Getopt::Long;

my $no_figfams;
my $rc = GetOptions("no-figfams" => \$no_figfams);
if (!$rc)
{
    die "invalid options\n";
}
    
my $db_source_path = "/intrepid-fs0/users/olson/persistent/RAST/db_tables";

my $db_name = "fig_rast_packed";
my $simserver_db_name = "sim_server";
my $simserver_db_table = "sim_seeks_028";

my $db_user = "seed";


my $db_dir = "/scratch/$ENV{USER}/mysql";
mkpath $db_dir;

my $db_data = "$db_dir/data";
mkpath $db_data;

my $db_temp = "$db_dir/tmp";
mkpath $db_temp;

my $db_socket = "$db_dir/mysql.sock";
my $db_port = 3306;


my %subst = (PORT => $db_port,
	     SOCKET => $db_socket,
	     TEMP => $db_temp,
	     DATADIR => $db_data);

my $db_conf = "$db_dir/my.cnf";
open(M, ">", $db_conf) or die "cannot open $db_dir/my.cnf: $!";
while (<DATA>)
{
    s/%([^%]+)%/$subst{$1}/ge;
    print M $_;
}
close(M);
	     
#
# Write the FIG_Config for this host, with the sql bootup information.
#

my $sims_dsn = "dbi:mysql:mysql_socket=$db_socket;database=$simserver_db_name";

my $myhost = `hostname`;
chomp $myhost;
open(CONF, ">", "$FIG_Config::fig_disk/config/config.$myhost");
print CONF <<END;
\$dbms = "mysql";
\$db = "$db_name";
\$dbuser = "$db_user";
\$dbpass = "";
\$dbsock = "$db_socket";

\$rast_sims_database = ['$sims_dsn', \$dbuser, \$dbpass, "$simserver_db_table"];

\$db_datadir = "$db_data";
\$preIndex = 1;
\@FIG_Config::db_server_startup_options = ("--defaults-extra-file=$db_conf",
                '--log-slow-queries', '--skip-slave-start', "--pid-file=$db_dir/mysql.pid");
1;
END
close(CONF);

#
# Now that we have a config, we can init the database.
#

my $rc = system("$FIG_Config::bin/init_dbserver");
if ($rc != 0)
{
    die "Error  rc=$rc initializing dbserver";
}

#
# Link in our tables.
#

for my $db ($db_name, $simserver_db_name)
{
    my $path = "$db_source_path/$db";
    if (! -d $path)
    {
	die "DB source for $db not found in $path";
    }
    my $target = "$db_data/$db";
    if (-l $target)
    {
	unlink($target);
    }
    if (-e $target)
    {
	die "Target $target already exists";
    }
    if (!symlink($path, $target))
    {
	die "symlink $path $target failed: $!";
    }
}


#
# And fire it up.
#

my $rc = system("$FIG_Config::bin/start_dbserver");
if ($rc != 0)
{
    die "Error  rc=$rc starting dbserver";
}

#
# Wait it for to start.
#
sleep 3;


#
# Grant required perms.
#

my $dbh = DBI->connect("dbi:mysql:mysql_socket=$db_socket;database=mysql", "root", '', { RaiseError => 1 });
$dbh or die "Could not connect to db: " . DBI->errstr;

for my $db ($db_name, $simserver_db_name)
{
    $dbh->do(qq(GRANT SELECT ON $db.* to $db_user\@localhost)); 
    $dbh->do(qq(GRANT SELECT ON $db.* to $db_user\@'%'));
}

#
# Set up the local copy of the figfams data.
#

if (!$no_figfams)
{
    my $ffdir = $FIG_Config::FigfamsData;
    if ($ffdir =~ m,/scratch, && 0)
    {
	mkpath($ffdir);
	for my $f (<$FIG_Config::FigfamsBaseData/*.db>)
	{
	    my $b = basename($f);
	    my $targ = "$ffdir/$b";
	    if (-s $targ != -s $f)
	    {
		print "Copy $f to $targ\n";
		system("cp", $f, $targ);
	    }
	}
	system("ln -s $FIG_Config::FigfamsBaseData/* $ffdir/.");
    }
}

#
# The prototype my.cnf is in the DATA section.
#

__DATA__
[client]
#password       = your_password
port            = %PORT%
socket          = %SOCKET%

[mysqld]
datadir = %DATADIR%
port            = %PORT%
socket          = %SOCKET%
skip-locking
#key_buffer = 600M
key_buffer = 1500M
max_allowed_packet = 10M
table_cache = 256
sort_buffer_size = 1M
read_buffer_size = 1M
read_rnd_buffer_size = 4M
myisam_sort_buffer_size = 64M
thread_cache_size = 8
query_cache_size= 100M
thread_concurrency = 4

#log-bin=mysql-bin
#log-slave-updates = true
#relay-log=seedu-relay-bin

#server-id       = 12

# Point the following paths to different dedicated disks
tmpdir         = %TEMP%
#log-update     = /path-to-dedicated-directory/hostname

# Uncomment the following if you are using InnoDB tables
#innodb_data_home_dir = /opt/bcr/2005-1205/linux-gentoo/var/
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = /opt/bcr/2005-1205/linux-gentoo/var/
#innodb_log_arch_dir = /opt/bcr/2005-1205/linux-gentoo/var/
# You can set .._buffer_pool_size up to 50 - 80 %
# of RAM but beware of setting memory usage too high
#innodb_buffer_pool_size = 256M
#innodb_additional_mem_pool_size = 20M
# Set .._log_file_size to 25 % of buffer pool size
#innodb_log_file_size = 64M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash
# Remove the next comment character if you are not familiar with SQL
#safe-updates

[isamchk]
key_buffer = 128M
sort_buffer_size = 128M
read_buffer = 2M
write_buffer = 2M

[myisamchk]
key_buffer = 128M
sort_buffer_size = 128M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout
