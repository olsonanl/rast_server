package RAST::WebPage::ComputeCloseStrains;

use strict;
use warnings;

use POSIX;

use base qw( WebPage );
use WebConfig;
use Template;
use File::Basename;
use FIG_Config;
use File::Path 'make_path';
use Data::Dumper;
use CloseStrains;

1;


=pod

=head1 NAME

ComputeCloseStrains - query user for information to compute close strains for his job(s).

=head1 DESCRIPTION

Compute Close Strains.

=head1 METHODS

=over 4

=item * B<init> ()

Called when the web page is instantiated.

=cut

sub init {
  my $self = shift;

  $self->title("Close Strains");

  # sanity check on job
  my $id = $self->application->cgi->param('job') || '';
  my $job;
  eval { $job = $self->app->data_handle('RAST')->Job->init({ id => $id }); };
  if (!$job) {
    $self->app->error("Unable to retrieve the job '$id'.");
  }
  
  $self->data('job', $job);

}

sub output
{
    my($self) = @_;

    my $job = $self->data('job');

    my $templ = Template->new(INCLUDE_PATH => ".");

    my $dir = $job->dir;

    my $content = '';

    my $cgi = $self->app->cgi;

    $cgi->param('organism', $job->genome_id);

    my $cs_dir = "$dir/CloseStrains";
    if ($cgi->param('create_set'))
    {
	make_path($cs_dir);
	$self->create_set($cs_dir, \$content, $cgi);
    }

    my @set_dirs = <$cs_dir/*>;

    my $sets = [];

    for my $dir (@set_dirs)
    {
	my $set = {};

	next if -f "$dir/HIDE";

	my $status = 'unknown';
	my $last_update = '';
	if (open(S, "<", "$dir/STATUS"))
	{
	    my @s = stat(S);
	    $last_update = asctime(localtime($s[9]));
	    print STDERR "read from $dir/STATUS\n";
	    $status = <S>;
	    chomp $status;
	}
	else
	{
	    print STDERR "error reading $dir/STATUS: $!\n";
	}
	$set->{status} = $status;
	$set->{last_update} = $last_update;
	
	#
	# For now, name == job id == setting for wc.cgi
	#
	$set->{name} = basename($dir);
	my $link = "$FIG_Config::cgi_url/wc.cgi?request=show_options_for_otu&dataD=$set->{name}";
	$set->{url} = $link;

	my %g_name;
	open(D, "<", "$dir/genome.names");
	while (<D>)
	{
	    chomp;
	    my($g, $n) = split(/\t/);
	    $g_name{$g} = $n;
	}
	close(D);

	my @rast;
	my @seed;
	open(R, "<", "$dir/rep.genomes");
	while (<R>)
	{
	    if (/^rast\|(\d+)/)
	    {
		open(N, "<", "$FIG_Config::rast_jobs/$1/GENOME_ID");
		my $g = <N>;
		close(N);
		chomp $g;
		push(@rast, { job_id => $1, genome_id => $g, name => $g_name{$g} });
	    }
	    elsif (/^(\d+\.\d+)/)
	    {
		push(@seed, { genome_id => $1, name => $g_name{$1} });
	    }
	}
	$set->{rast} = \@rast;
	$set->{ref} = \@seed;

	push(@$sets, $set);
    }

    #
    # Compute available references.
    # Available rast job for now is just this job. We may expand this later.
    #

    my @avail_jobs = ({ job_id => $job->id, name => $job->genome_name });

    my @avail_refs = CloseStrains::get_outgroups_list();
    open(CLOSE, "<", $job->dir . "/rp/" . $job->genome_id . "/closest.genomes");
    while (<CLOSE>)
    {
	chomp;
	my($gid, $count, $name) = split(/\t/);
	push(@avail_refs, [$gid, $name]);
    }
    my @set = CloseStrains::get_closest_genome_set(\@avail_refs, 10);
    my %in_default = map { $_->[0] => 1 } @set;

    my @avail_refs_marked = map { 
    	{ genome_id => $_->[0], name => $_->[1], default => ($in_default{$_->[0]} ? 1 : 0) }
    } @avail_refs;

    my %data = (
		this_page => 'ComputeCloseStrains',
		this_job => { job_id => $job->id, name => $job->genome_name },
		strain_sets => $sets,
		avail_jobs => \@avail_jobs,
		avail_refs => \@avail_refs_marked,
	       );

    if (!$templ->process("Html/CloseStrains.tt2", \%data, \$content))
    {
	$content = "<pre>Template error: " . $templ->error() . "\n</pre>\n";
    }
    return $content;
    
}

sub create_set
{
    my($self, $cs_dir, $contentP, $cgi) = @_;

    my $job = $self->data('job');
    my $id = $job->id;

    my $path = "$cs_dir/$id";
    if (-d $path)
    {
	# $$contentP .= "<p>Moving old directory out of the way\n";
	my $bak = $path . ".bak." . time;
	rename($path, $bak);
	open(X, ">", "$bak/HIDE");
	print X "Hidden due to creation of new set\n";
	close(X);
    }
    make_path($path);
    
    my @refs;
    for my $p ($cgi->param)
    {
	if ($p =~ /^ref_(\d+\.\d+)/)
	{
	    push(@refs, $1);
	}
    }
    # $$contentP .= "@refs<br>\n";

    
    my $fig = $self->application->data_handle("FIG");
    my $gobj = $fig->genome_id_to_genome_object($job->genome_id);

    my @rast_genomes;
    push(@rast_genomes, [$id, $gobj]);

    my $extra = $cgi->param('extra_genomes');
    my @extra = split(/[\s,]+/, $extra);

    for my $e (@extra)
    {
	if ($e =~ /^\d+$/)
	{
	    my $ejob = $self->app->data_handle('RAST')->Job->init({ id => $e });
	    if ($ejob)
	    {
		my $gobj = $self->job_to_genome_object($ejob);
		if ($gobj)
		{
		    push(@rast_genomes, [$ejob->id, $gobj]);
		}
		else
		{
		    warn "Failed to create gobj for job $e\n";
		}
	    }
	    else
	    {
		warn "Cannot find RAST job for job id $e\n";
	    }
	}
	elsif ($e =~ /^(core|p3)\|\d+\.\d+$/)
	{
	    #
	    # This is a PATRIC or coreseed genome. Save it in the refs list for later expansion.
	    #
	    push(@refs, $e);
	}
	elsif ($e =~ /^\d+\.\d+$/)
	{
	    #
	    # We check first to see if this is a valid genome in pubseed
	    # (since all PubSEED genomes went thru rast, we prefer the pubseed
	    # version to the RAST version).
	    #
	    my $gdir = "/vol/public-pseed/FIGdisk/FIG/Data/Organisms/$e";
	    if (-d $gdir && ! -f "$gdir/DELETED")
	    {
		push(@refs, $e);
	    }
	    else
	    {
		my $ejob = $self->app->data_handle('RAST')->Job->init({ genome_id => $e });
		if ($ejob)
		{
		    my $gobj = $self->job_to_genome_object($ejob);
		    if ($gobj)
		    {
			push(@rast_genomes, [$ejob->id, $gobj]);
		    }
		    else
		    {
			warn "Failed to create gobj for RAST genome $e\n";
		    }
		}
		else
		{
		    push(@refs, $e);
		}
	    }
	}
	else
	{
	    warn "Unparsable job specfifier '$e'\n";
	}
	    
    }

    if (0)
    {
	open(L, ">", "/tmp/compute.$$");
	my @rg = map { $_->[0] } @rast_genomes;
	print L Dumper(\@refs, \@rg, \@rast_genomes);
	close(L);
    }

    CloseStrains::create_set_from_rast($path, \@refs, \@rast_genomes);
    CloseStrains::get_genome_name($path);

    #
    # We may now submit.
    #

    my $tmpdir = "$path/tmp";
    make_path($tmpdir);
    my $cs_compute = "$FIG_Config::bin/svr_CS";
    if ($FIG_Config::fig_disk eq '/vol/rast-prod/FIGdisk' ||
	$FIG_Config::fig_disk eq '/vol/rast-test/FIGdisk')
    {
	#
	# prod rast for now uses pubseed to compute. Wrapper script used
	# sources the environment so it can find the subsidiary scripts.
	#
	$cs_compute = "/vol/public-pseed/FIGdisk/bin/submit_svr_CS";
    }
    
    my @cmd = ("qsub",
	       "-b", "yes",
	       "-q", "maple",
	       "-e", "$path/SGE_STDERR",
	       "-o", "$path/SGE_STDOUT",
	       "-v", "TMPDIR=$tmpdir",
	       "-N", "CS$id",
	       $cs_compute, "-d", $path, "--fill-in-refs");
    print STDERR "@cmd\n";
    open(X, ">", "$path/SUBMIT");
    print X "@cmd\n";
    open(P, ". /vol/sge/default/common/settings.sh ; @cmd |") or die "Error submitting @cmd: $!";
    my $sge;
    while (<P>)
    {
	print X $_;
	# Your job 7152711 ("svr_CS") has been submitted
	
	if (/job\s+(\d+)/)
	{
	    $sge = $1;
	}
    }
    close(P);
    close(X);
    CloseStrains::set_status($path, "Queued job $sge");
}


sub job_to_genome_object
{
    my($self, $job) = @_;

    my $fig = $self->application->data_handle("FIG");
    my $jid = $job->id;
    my $gid = $job->genome_id;
    
    if ($self->app->session->user->has_right(undef, 'view', 'genome', $gid))
    {
	my $gobj;
	eval {
	    my $gdir = $job->org_dir;
	    my $figv = FIGV->new($gdir, undef, $fig);
	    $gobj = FIG::genome_id_to_genome_object($figv, $gid);
	};
	if ($@)
	{
	    warn "Error creating genome obj for $gid: $@\n";
	}
	
	return $gobj;
    }
    else
    {
	warn "User does not have rights for job $jid genome $gid\n";
	return undef;
    }
}

=pod

=item * B<required_rights>()

Returns a reference to the array of required rights

=cut

sub required_rights {
  my $rights = [ [ 'login' ], ];
  push @$rights, [ 'view', 'genome', $_[0]->data('job')->genome_id ]
    if ($_[0]->data('job'));
      
  return $rights;
}



