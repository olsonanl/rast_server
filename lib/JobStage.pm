package JobStage;

#
# Class to wrap up the common code that shows up in all of the job stage processing
# scripts.
#


use strict;
use Carp qw(cluck croak carp);
use Job48;
use FileHandle;
use ImportJob;

use base 'Class::Accessor';
__PACKAGE__->mk_accessors(qw(job job_name job_dir meta status_name hostname error_dir sge_dir));

sub new
{
    my($class, $job_type, $job_name, $job_dir) = @_;

    my $job = $job_type->new($job_dir);
    $job or die "Could not create $job_type on $job_dir: $!\n";

    my $host = `hostname`;
    chomp $host;

    my $errdir = "$job_dir/errors";
    -d $errdir or mkdir $errdir;

    my $sgedir = "$job_dir/sge_output";
    -d $sgedir or mkdir $sgedir;


    my $self = {
	job => $job,
	job_type => $job_type,
	job_name => $job_name,
	job_dir => $job_dir,
	meta => $job->meta,
	status_name => "status.$job_name",
	hostname => $host,
	error_dir => $errdir,
	sge_dir => $sgedir,
    };

    return bless $self, $class;
}

sub open_error_file
{
    my($self, $tag, $dir) = @_;

    my $fh;
    my $file = $self->error_dir . "/$tag.stderr";
    if ($dir eq '>' or $dir eq 'w')
    {
	$fh = new FileHandle(">$file");
    }
    else
    {
	$fh = new FileHandle("<$file");
    }
    return $fh;
}

sub set_metadata
{
    my($self, $key, $value) = @_;
    $self->meta->set_metadata($key, $value);
}

sub get_metadata
{
    my($self, $key) = @_;
    return $self->meta->get_metadata($key);
}

sub set_qualified_metadata
{
    my($self, $key, $value) = @_;
    $self->meta->set_metadata($self->job_name . '.' . $key, $value);
}

sub get_qualified_metadata
{
    my($self, $key) = @_;
    return $self->meta->get_metadata($self->job_name . '.' . $key);
}

sub log
{
    my($self, $msg) = @_;

    $self->meta->add_log_entry($self->job_name, $msg);
}

sub set_status
{
    my($self, $status) = @_;
    $self->meta->set_metadata($self->status_name, $status);
}

sub set_running
{
    my($self, $status) = @_;
    $self->meta->set_metadata($self->job_name . ".running", $status);
}

=head3 run_process($tag, $cmd, @args)

Run the given command and argument list in a subshell. Stdout and stderr are collected
and written to jobdir/errors/$tag.stderr.

If the command fails, this code invokes $stage->fatal() so does not return.

=cut

sub run_process
{
    my($self, $tag, $cmd, @args) = @_;

    -x $cmd or $self->fatal("run_process: command $cmd is not executable");

    $self->log("running $cmd @args");

    my $pid = open(P, "-|");
    $self->log("created child $pid");

    if ($pid == 0)
    {
	open(STDERR, ">&STDOUT");
	exec($cmd, @args);
	die "Cmd failed: $!\n";
    }
    
    my $errfh = $self->open_error_file($tag, "w");
    $errfh->autoflush(1);

    while (<P>)
    {
	print $errfh $_;
	print "$tag: $_";
    }
    
    if (!close(P))
    {
	my $msg = "error closing $tag pipe: \$?=$? \$!=$!";
	print $errfh "$msg\n";
	close($errfh);
	print "$msg\n";
	$self->fatal($msg);
    }
    close($errfh);
    $self->log("process $cmd finishes successfully");
}

=head3 run_process_nofatal($tag, $cmd, @args)

Run the given command and argument list in a subshell. Stdout and stderr are collected
and written to jobdir/errors/$tag.stderr.

If the command fails, this code invokes die.

=cut

sub run_process_nofatal
{
    my($self, $tag, $cmd, @args) = @_;

    -x $cmd or die("run_process: command $cmd is not executable");

    $self->log("running $cmd @args");

    my $pid = open(P, "-|");
    $self->log("created child $pid");

    if ($pid == 0)
    {
	open(STDERR, ">&STDOUT");
	exec($cmd, @args);
	die "Cmd failed: $!\n";
    }
    
    my $errfh = $self->open_error_file($tag, "w");
    $errfh->autoflush(1);

    while (<P>)
    {
	print $errfh $_;
	print "$tag: $_";
    }
    
    if (!close(P))
    {
	my $msg = "error closing $tag pipe: \$?=$? \$!=$!";
	print $errfh "$msg\n";
	close($errfh);
	print "$msg\n";
	die($msg);
    }
    close($errfh);
    $self->log("process $cmd finishes successfully");
}

sub run_process_in_shell
{
    my($self, $tag, $cmd) = @_;

    $self->log("running $cmd");

    my $pid = open(P, "$cmd |");
    if (!defined($pid))
    {
	$self->fatal("run_process_in_shell(): error creating pipe from $cmd: $!");
    }
	
    $self->log("created child $pid");

    my $errfh = $self->open_error_file($tag, "w");
    $errfh->autoflush(1);

    while (<P>)
    {
	print $errfh $_;
	print "$tag: $_";
    }
    
    if (!close(P))
    {
	my $msg = "error closing $tag pipe: \$?=$? \$!=$!";
	print $errfh "$msg\n";
	close($errfh);
	print "$msg\n";
	$self->fatal($msg);
    }
    close($errfh);
    $self->log("process $cmd finishes successfully");
}

sub open_file
{
    my($self, @spec) = @_;

    my $fh = FileHandle->new(@spec);
    $fh or $self->fatal("Cannot open @spec: $!");
    return $fh;
}


sub fatal
{
    my($self, $msg) = @_;

    $self->meta->add_log_entry($self->job_name, ['fatal error', $msg]);
    $self->meta->set_metadata($self->status_name, "error");
    $self->set_running("no");

    croak "$0: $msg";
}
    
sub warning
{
    my($self, $msg) = @_;

    $self->meta->add_log_entry($self->job_name, ['warning', $msg]);

    carp "$0: $msg";
}
    
1;
