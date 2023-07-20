#
# Salvage annotations for the organisms that are replacements of SEED genomes.
#
# This is true if the file REPLACES exists and containst the genome ID of an
# existing SEED genome.
#
# Note that for this to work the SEED that this script is invoked from has to
# have a current copy of the canonical SEED organism data.
# 
# Salvage does the following:
#
# Determine the old->new mapping using make_peg_maps_from_fasta.
#
# Determine the set of pegs for which we will salvage assignments by finding
# the set of mapped pegs from the old organism that are in subsystems. We will
# carry across only those assignments; the others will be taken from the RAST
# pipeline. We will construct annotation file entries for the other mapped PEGs
# that have the old annotation data to keep the history, but they will be capped
# with the annotation for the RAST assignment.
#


use strict;
use FIG;
use Data::Dumper;
use FIG_Config;
use File::Copy;
use File::Basename;
use ImportJob;
use GenomeMeta;
use JobStage;
use POSIX;

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $fig = new FIG();

my $max_hits = 300;

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $stage = new JobStage('ImportJob', 'salvage', $jobdir);

$stage or die "$0: Could not create job object";

my $job = $stage->job;
my $job_id = $job->id;

$stage->log("Running on " . $stage->hostname);

$stage->set_status("running");
$stage->set_running("yes");

$stage->set_qualified_metadata("host", $stage->hostname);

#
#
# Begin
#
#

open(JOBS, "<$jobdir/rast.jobs") or $stage->fatal("Cannot open $jobdir/rast.jobs: $!");

while (my $rjdir = <JOBS>)
{
    chomp $rjdir;

    my $rj = new Job48($rjdir);
    my $rj_id = $rj->id;
    my $orgdir = $rj->orgdir();

    my $repl = $rj->meta->get_metadata("replace.seedID");

    my $salvage_msg;

    if ($repl ne "")
    {
	my $repfile = "$orgdir/REPLACES";
	my $fh = $stage->open_file(">$repfile");
	print $fh "$repl\n";
	close($fh);
    
	my $n = do_salvage($rj, $repl);

	$salvage_msg = "$n function assignments salvaged from $repl " . $fig->genus_species($repl);
    }
    else
    {
	#
	# We are not salvaging, but we need to do a little cleanup to make the two cases the same.
	#
	# Create imp_assigned_functions from the set of *_functions files we have, and copy
	# the annotations over to imp_annotations.
	#

	my $imp_af = $stage->open_file(">$orgdir/imp_assigned_functions");
	for my $f (qw(assigned_functions proposed_non_ff_functions proposed_functions))
	{
	    my $path = "$orgdir/$f";
	    
	    if (open(AF, "<$path"))
	    {
		while (<AF>)
		{
		    print $imp_af $_;
		}
		close(AF);
	    }
	}
	close($imp_af);

	if (-f "$orgdir/annotations")
	{
	    copy("$orgdir/annotations", "$orgdir/imp_annotations") or
		$stage->fatal("Cannot copy $orgdir/annotations to $orgdir/imp_annotations: $!");
	}
    }

    #
    # See if this is a NMPDR organism.
    #

    my $group;
    if ($rj->meta->get_metadata("submit.nmpdr"))
    {
	#
	# Determine the group.
	#

	my $genome = $rj->genome_name();
	$group = `$FIG_Config::bin/get_nmpdr_group $genome`;
	if ($? == 0)
	{
	    print "Marking $genome as being in NMPDR group $group\n";
	    my $nfh = $stage->open_file(">$orgdir/NMPDR");
	    print $nfh $group;
	    close($nfh);
	}
    }
    
    
    #
    # While we're here, we're going to also mark this genome directory as a RAST job.
    #
    
    my $fh = $stage->open_file(">$orgdir/RAST");
    my $submit_time = ctime($rj->meta->get_metadata("upload.timestamp"));
    my $dtime = (stat("$rjdir/DONE"))[9];
    my $finish_time = ctime($dtime);
    my $import_time = ctime(time);
    print $fh "Genome processed by RAST at $FIG_Config::fig\n";
    print $fh "$salvage_msg\n" if $salvage_msg;
    print $fh "NMPDR Group: $group\n" if $group;
    print $fh "RAST job number $rj_id from $rjdir\n";
    print $fh "Upload at: $submit_time";
    print $fh "Completion at: $finish_time";
    print $fh "Import processing at: $import_time";
    close($fh);

}

close(JOBS);


sub do_salvage
{
    my($job, $old_genome) = @_;

    print "Do replacement on " . $job->genome_name()  . " from $old_genome\n";

    my $orgdir = $job->orgdir();

    #
    # Compute mappings.
    #

    my $n_salvaged = 0;

    my $old_orgdir = "$FIG_Config::organisms/$old_genome";

    -d $old_orgdir or $stage->fatal("Old organism dir $old_orgdir does not exist");

    my $maps = "$orgdir/peg_maps";
    #
    # XXX - should rerun this every time, later.
    if (! -f $maps)
    {
	$stage->run_process("make_peg_maps_from_fasta",
			    "$FIG_Config::bin/make_peg_maps_from_fasta",
			    $old_orgdir,
			    $orgdir,
			    $maps);
    }
    
    #
    # Ingest the map and mark each peg with its subsystem status.
    #

    open(M, "<$maps") or $stage->fatal("Cannot open peg maps $maps: $!");
    my @map;
    my(%old_to_new, %new_to_old);
    while (<M>)
    {
	chomp;
	my($peg_old, $peg_new) = split(/\t/);
	my $ss = [$fig->peg_to_subsystems($peg_old)];
	my $ent = {
	    old => $peg_old,
	    new => $peg_new,
	    ss => $ss,
	};
	
	push(@map, $ent);
	$old_to_new{$peg_old} = $ent;
	$new_to_old{$peg_new} = $ent;
    }
    close(M);

    #
    # Given this map, we construct the new assigned_functions and annotations files.
    #
    # We start by copying annotations to imp_annotations, to get the initial history.
    #
    # Then we scan the old organism's annotations and assigned function files,
    # remembering any of the pegs that show up in the map. Any that do not,
    # we write to files unmapped.annotations and unmapped.assigned_functions, again
    # to retain history.
    #
    # Once this scan is complete, we scan the new organism's assigned functions file.
    # If a peg in there is mapped, we copy the set of annotations for the old
    # peg across into the new annotations file, mapping pegs as we go.
    #
    # If the peg was in a subsystem, we then write
    # an annotation declaring the set of subsystems the peg was in, and a final
    # annotation with the function assignment from the old org. The old
    # assignment is written to imp_assigned_functions.
    #
    # If the peg is not in a subsystmem, we write a final annotation with the
    # rast annotation, and write the rast assignment to imp_assigned_functions.
    #
    # If the peg was not mapped, we just write the rast function to imp_assigned_functions.
    #
    # Note that we don't actually have to scan anything - all we need to do is
    # walk over the entries in the old/new map, and write out the appropriate data.
    # Anything that isn't in there was already copied from the rast version of the data.
    #

    my $new_af = $stage->open_file(">$orgdir/imp_assigned_functions");

    #
    # Read the RAST assigned functions files, write a single large file with
    # all the data in it, and pull the assignments into the %rast hash as well.
    #

    my %rast;

    for my $f (qw(assigned_functions proposed_non_ff_functions proposed_functions))
    {
	my $path = "$orgdir/$f";

	if (open(AF, "<$path"))
	{
	    while (<AF>)
	    {
		print $new_af $_;
		chomp;
		my($peg, $fn) = split(/\t/);
		$rast{$peg} = $fn;
	    }
	    close(AF);
	}
    }

    #
    # Copy annotations to imp_annotations to initialize it; leave the
    # filehandle open to add more later on.
    #
    my $new_anno = $stage->open_file(">$orgdir/imp_annotations");
    my $orig_anno = $stage->open_file("<$orgdir/annotations");
    my $buf;
    while (read($orig_anno, $buf, 4096))
    {
	print $new_anno $buf;
    }
    close($orig_anno);

    my $unmapped_af = $stage->open_file(">$orgdir/unmapped.assigned_functions");
    my $unmapped_anno = $stage->open_file(">$orgdir/unmapped.annotations");

    my $old_af = $stage->open_file("<$old_orgdir/assigned_functions");
    my $old_anno = $stage->open_file("<$old_orgdir/annotations");

    my(%old_anno, %old_af);

    #
    # Scan the SEED annotations and assigned functions files and ingest.
    #

    while (<$old_af>)
    {
	chomp;
	my($peg, $fun) = split(/\t/);
	if (my $ent = $old_to_new{$peg})
	{
	    $ent->{old_func} = $fun;
	}
	else
	{
	    print $unmapped_af "$_\n";
	}
    }
    close($old_af);

    {
	local $/;
	$/ = "//\n";
	
	while (<$old_anno>)
	{
	    chomp;
	    my($peg, $time, $who, $what, $val) = split(/\n/, $_, 5);

	    if (my $ent = $old_to_new{$peg})
	    {
		$val =~ s/\n*$//;
		push @{$ent->{old_anno}}, [$peg, $time, $who, $what, $val];
	    }
	    else
	    {
		print $unmapped_anno $ent . $/;
	    }
	}
    }
    close($old_anno);

    for my $new_peg (sort { &FIG::by_fig_id($a, $b) }  keys %new_to_old)
    {
	my $ent = $new_to_old{$new_peg};

	#
	# Copy old annotations
	#
	for my $anno (@{$ent->{old_anno}})
	{
	    $anno->[0] = $new_peg;
	    print $new_anno join("\n", @$anno), "\n//\n";
	}

	my $old_func = $ent->{old_func};
	my $new_func = $rast{$new_peg};

	#
	# Determine if we need to update.
	#
	my @ss_list = @{$ent->{ss}};

	if ($old_func eq '')
	{
	    # print "$ent->{old} => $new_peg No existing function\n";
	    print $new_anno join("\n", $new_peg, time, "salvage",
				 "No function found in original organism $ent->{old}"), "\n//\n";

	}
	elsif ($old_func eq $new_func)
	{
	    # print "$ent->{old} => $new_peg functions are the same\n";
	    print $new_anno join("\n", $new_peg, time, "salvage",
				 "Old and new assignments are the same", $old_func), "\n//\n";

	}
	else
	{
	    if (@ss_list > 0)
	    {
		# print "$ent->{old} => $new_peg is in a ss\n";
		
		print $new_anno join("\n", $new_peg, time, "salvage",
				     "Retaining old assignment due to membership in subsystems", "@ss_list", $old_func), "\n//\n";
		print $new_anno join("\n", $new_peg, time, "salvage", "Set master function to", $old_func), "\n//\n";
		print $new_af "$new_peg\t$old_func\n";

		$n_salvaged++;
	    }
	    else
	    {
		# print "$ent->{old} => $new_peg is not in a ss\n";
		
		print $new_anno join("\n", $new_peg, time, "salvage",
				     "Using RAST assignment due to no subsystem membership", $new_func), "\n//\n";
		print $new_anno join("\n", $new_peg, time, "salvage", "Set master function to", $new_func), "\n//\n";
	    }
	}
    }
    close($new_af);
    close($new_anno);

    return $n_salvaged;
}

    
    
    
