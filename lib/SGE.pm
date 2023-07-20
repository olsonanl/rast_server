
package SGE;

use XML::LibXML;
use strict;
use Data::Dumper;
use FIG_Config;

#
# Utilities for dealing with a SGE-enabled cluster.
#

sub new
{
    my($class) = @_;

    my $self = {
	jobs => {},
    };

    bless $self, $class;

    #
    # Initialize our environment with the SGE stuff we need.
    #
    my $sge_root = $FIG_Config::sge_root || "/vol/sge";
    my $sge_cell = $FIG_Config::sge_cell || "default";

    my %env = map { /^([^=]+)=(.*)/  } `. $sge_root/$sge_cell/common/settings.sh; set`;
    for my $k (grep { /SGE/ } keys %env)
    {
	$ENV{$k} = $env{$k};
    }
    my $arch = `$sge_root/util/arch`;
    chomp $arch;
    $ENV{PATH} = "$sge_root/bin/$arch:$ENV{PATH}" if $arch;

    $self->read_qstat();

    return $self;
}

sub read_qstat
{
    my($self) = @_;
    if (!open(Q, "-|", qw(qstat -u * -s prsz -xml)))
    {
	warn "Could not read queue status: $!\n";
	return;
    }

    my $parser = XML::LibXML->new();
    my $doc = $parser->parse_fh(\*Q);

    close(Q);
    if (!$doc)
    {
	die "Cannot parse qstat output\n";
    }

    #
    # Walk the joblists and populate $self->{jobs} with information about them.
    #

    %{$self->{jobs}} = ();
    %{$self->{tasks}} = ();
    for my $node ($doc->findnodes('//job_list'))
    {
	my $job = SGE::Job->new($node);
	$self->add_job($job);
    }
#    print Dumper($self->{jobs});
}

sub add_job
{
    my($self, $job) = @_;

    push @{$self->{jobs}->{$job->id}}, $job;

    #
    # Also push into job/task index. We need to expand tasks that show up as
    # a-b:n,a-b etc
    #

    my @tlist = split(/,/, $job->tasks);

    if (@tlist == 0)
    {
	$self->{tasks}->{$job->id,''} = $job;
    }
    else
    {
	for my $tent (@tlist)
	{
	    if ($tent =~ /^\d+$/)
	    {
		$self->{tasks}->{$job->id, $tent} = $job;
	    }
	    elsif ($tent =~ /^(\d+)-(\d+)$/)
	    {
		map { $self->{tasks}->{$job->id, $_} = $job } $1..$2;
	    }
	    elsif ($tent =~ /^(\d+)-(\d+):(\d+)$/)
	    {
		for (my $t = $1; $t <= $2; $t += $3)
		{
		    $self->{tasks}->{$job->id, $t} = $job;
		}
	    }
	    else
	    {
		die "unknown task specifier '$tent'\n";
	    }
	}
    }
    
}

#
# A job is running if there are any instances that are still running.
#
# We return the list of running jobs; in a scalar context this acts correctly.
#

sub job_running
{
    my($self, $id) = @_;

    my $jobs = $self->{jobs}->{$id};
    my @running = grep { $_->state eq 'running' } @$jobs;
    return @running;
}

sub job_queued
{
    my($self, $id) = @_;

    my $jobs = $self->{jobs}->{$id};
    my @running = grep { $_->state eq 'pending' } @$jobs;
    return @running;
}

sub find_task
{
    my($self, $job, $task) = @_;

    return $self->{tasks}->{$job, $task};
}

sub submit_job
{
    my($self, $meta, $sge_args, $cmd) = @_;
    
    my $sge_cmd = "qsub $sge_args $cmd";
    
    $meta->add_log_entry($0, $sge_cmd) if $meta;

    if (!open(Q, "$sge_cmd 2>&1 |"))
    {
	die "Qsub failed: $!";
    }
    my $sge_job_id;
    my $submit_output;
    while (<Q>)
    {
	$submit_output .= $_;
	print "Qsub: $_";
	if (/Your\s+job\s+(\d+)/)
	{
	    $sge_job_id = $1;
	}
	elsif (/Your\s+job-array\s+(\d+)/)
	{
	    $sge_job_id = $1;
	}
    }
    $meta->add_log_entry($0, ["qsub_output", $submit_output]) if $meta;
    if (!close(Q))
    {
	die "Qsub close failed: $!";
    }

    if (!$sge_job_id)
    {
	die "did not get job id from qsub";
    }

    return $sge_job_id;
}

package SGE::Job;

use Data::Dumper;
use strict;
use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(id prio name owner start_time slots tasks state));

sub new
{
    my($class, $node) = @_;


    my $self = {
	node => $node,
    };

    bless($self, $class);

    for my $pair ((['id', 'JB_job_number'],
		   [prio => 'JAT_prio'],
		   [name => 'JB_name'],
		   [owner => 'JB_owner'],
		   [start_time => 'JAT_start_time'],
		   [slots => 'slots'],
		   [tasks => 'tasks']))
    {
	my($name, $key) = @$pair;
	$self->{$name} = $self->getAttr($key);
    }
    $self->state($node->getAttribute('state'));

    return $self;
}

sub getAttr
{
    my($self, $name) = @_;

    my $l = $self->{node}->getChildrenByTagName($name);

    if ($l)
    {
	return $l->item(0)->firstChild->nodeValue();
    }
    else
    {
	return undef;
    }
}
1;
