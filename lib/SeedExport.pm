package SeedExport;

1;

use Data::Dumper;
use strict;
use FIG;
use FIG_Config;
use FIGV;
use URI::Escape;
use Bio::FeatureIO;
use Bio::SeqIO;
use Bio::Seq;
use Bio::Seq::RichSeq;
use Bio::Location::Split;
use Bio::Location::Simple;
use Bio::SeqFeature::Generic;
use Bio::SeqFeature::Annotated;
use Bio::Species;
use File::Basename;

sub export {
    my ($parameters) = @_;
    
    # get parameters
    my $virt_genome_dir = $parameters->{'virtual_genome_directory'};
    my $genome          = $parameters->{'genome'};
    my $directory       = $parameters->{'directory'};
    my $format          = $parameters->{'export_format'};
    my $strip_ec        = $parameters->{'strip_ec'};
    my $filename   	= $parameters->{'filename'};
    
    # set some variables
    my $user = "master:master";
    my $format_ending;
    
    # check format
    if ($format eq "genbank") {
	$format_ending = "gbk";
    } elsif ($format eq "GTF") {
	$format_ending = "gtf";
    } elsif ($format eq "gff") {
	$format = "GTF";
	$format_ending = "gff";
    } elsif ($format eq "embl") {
	$format_ending = "embl";
    } else {
	die "unknown export format: $format\n";
    }
    
    # initialize fig object
    my $fig;
    my $virt_genome;
    if ($virt_genome_dir) {
	$fig = new FIGV($virt_genome_dir);
	$virt_genome = basename($virt_genome_dir);
    } else {
	$fig = new FIG;
    }
    
    # check for genus species
    my $gs = $fig->genus_species($genome);
    unless ($gs) {
	warn "No genome name set for $genome\n";
	$gs = "Unknown sp.";
    }
    
    # get taxonomy id and taxonomy
    my $taxid = $genome;
    $taxid =~ s/\.\d+$//;
    my $taxonomy = $fig->taxonomy_of($genome);
    
    # get project
    if ($virt_genome_dir and $genome eq $virt_genome) {
	open(PROJECT, "<$virt_genome_dir/PROJECT") or die "Error opening $virt_genome_dir/PROJECT: $!\n";
    } else {
	open( PROJECT, "<$FIG_Config::organisms/$genome/PROJECT" ) or die "Error opening $FIG_Config::organisms/$genome/PROJECT: $!\n";
    }
    my @project = <PROJECT>;
    chomp(@project);
    close PROJECT;
    map {s/^\<a href\=\".*?\"\>(.*)\<\/a\>/$1/i} @project;
    
    # get md5 checksum
    my $md5 = $fig->genome_md5sum($genome);
    
    # create the variable for the bio object
    my $bio;
    my $bio2;
    my $gff_export;

    my @tax = split(/;\s+/, $taxonomy);

    #
    # To avoid issues with EMBL exports on long taxonomies, truncate
    # any field in the taxonomy to 74 chars.
    #
    if (lc($format) eq 'embl')
    {
	for my $t (@tax)
	{
	    if ((my $l = length($t)) > 73)
	    {
		
		$t = substr($t, 0, 73);
		print STDERR "EMBL export: truncating long taxonomy string (length=$l) to $t\n";
	    }
	}
    }

    my $species = Bio::Species->new(-classification => [reverse @tax]);
    
    my $gc = 11;
    if (open(my $gcfh, "<", $fig->organism_directory($genome) . "/GENETIC_CODE"))
    {
	$gc = <$gcfh>;
	chomp $gc;
    }


    # get the contigs
    foreach my $contig ($fig->contigs_of($genome)) {
	my $cloc = $contig.'_1_'.$fig->contig_ln($genome, $contig);
	my $seq = $fig->dna_seq($genome, $cloc);
	$seq =~ s/>//;  
	$bio->{$contig} = Bio::Seq::RichSeq->new( -id => $contig, 
						 -accession_number => $contig,
						 -display_name => $gs,
						 -seq => $seq,
						 -species => $species,
				       );
	$bio->{$contig}->desc($gs);

	my $feature = Bio::SeqFeature::Generic->new(
						    -start	=> 1,
						    -end	=> $fig->contig_ln($genome, $contig),
						    -tag        => { db_xref     => "taxon:$taxid", 
									 organism   => $gs, 
									 mol_type   => "genomic DNA", 
									 genome_id  => $genome,
									 project    => join(" ", @project),
									 genome_md5 => $md5 },
						    -primary    => "source" );
	$bio->{$contig}->add_SeqFeature($feature);
    }

    # get the functional role name -> GO file
    open(FH, $FIG_Config::data . "/Ontologies/GO/fr2go") or die "could not open fr2go";
    my $fr2go = {};
    while (<FH>) {
	chomp;
	my ($fr, $go) = split /\t/;
	$fr2go->{$fr} = [] unless (exists $fr2go->{$fr});
	push @{$fr2go->{$fr}}, $go;
    }
    close FH;
    
    my @all_features = sort { &FIG::by_fig_id($a,$b) } $fig->pegs_of($genome), $fig->rnas_of($genome);
    my $feature_fns = $fig->function_of_bulk(\@all_features);
    my @all_locations = $fig->feature_location_bulk(\@all_features);
    my %all_locations;
    $all_locations{$_->[0]} = $_->[1] foreach @all_locations;
    my $all_aliases = $fig->feature_aliases_bulk(\@all_features);

    # get the pegs
    foreach my $peg (@all_features) {
	my $note;
	# my $func = $fig->function_of($peg, $user);
	my $func = $feature_fns->{$peg};
	
	my %ecs;
	my @gos;
	
	# get EC / GO from role
	if (defined $func) {
	    foreach my $role ($fig->roles_of_function($func)) {
		my ($ec) = ($role =~ /\(EC (\d+\.\d+\.\d+\.\d+)\)/);
		$ecs{$ec} = 1 if ($ec);
		push @gos, @{$fr2go->{$role}} if ($fr2go->{$role});
	    }
	}

	push @{$note->{db_xref}}, "SEED:$peg";
	push @{$note->{transl_table}}, $gc;
	
	# remove duplicate gos
	my %gos = map { $_ => 1 } @gos if (scalar(@gos));
	
	# add GOs
	push @{$note->{"db_xref"}}, @gos;
	
	# add ECs
	push @{$note->{"EC_number"}}, keys(%ecs);
	
	# get the aliases from principal id
	my $pid = $fig->maps_to_id($peg);
	my @rw_aliases = map { $fig->rewrite_db_xrefs($_->[0]) } $fig->mapped_prot_ids($pid);
	my @aliases;
	foreach my $a (@rw_aliases) {
	    push @{$note->{"db_xref"}}, $a if ( $a );
	}
	
	# get the links
	foreach my $ln ($fig->fid_links($peg, $all_aliases->{$peg})) {
	    my ($db, $id);
	    if ($ln =~ /field0=CATID/ && $ln =~ /query0=(\d+)/ && ($id=$1) && $ln =~ /pcenter=harvard/) {
		$db = "HarvardClone";
	    } elsif ($ln =~ /(PIRSF)(\d+)/) {
		($db, $id) = ($1, $2);
	    } elsif ($ln =~ />(\S+)\s+(\S+.*?)</) {
		($db, $id) = ($1, $2);
	    }
	    
	    $db =~ s/\://;
	    if (!$db && !$id) {
		print STDERR "Ignored link: $ln\n";
		next;
	    }
	    push @{$note->{"db_xref"}}, "$db:$id";
	}
	
	# add FIG id as a note
	# push @{$note->{"db_xref"}}, "FIG_ID:$peg";
	
	# get the features
	
	my $loc_obj;
#	my @location = $fig->feature_location($peg);
	my @location = split(/,/, $all_locations{$peg});
	my @loc_info;
	my $contig;
	foreach my $loc (@location) {
	    my($start, $stop);
	    $loc =~ /^(.*)\_(\d+)\_(\d+)$/;
	    ($contig, $start, $stop) = ($1, $2, $3);
	    my $original_contig = $contig;
	    my $strand = '+';
	    my $frame = $start % 3;
	    if ($start > $stop) {
		$frame = $stop % 3;
		($start, $stop, $strand) = ($stop, $start, '-');
	    } elsif ($start == $stop) {
		$strand = ".";
		$frame = ".";
	    }

	    push(@loc_info, [$contig, $start, $stop, $strand, $frame]);
	    
	    my $sloc = new Bio::Location::Simple(-start => $start,
						 -end => $stop,
						 -strand => $strand);
	    if (@location == 1)
	    {
		$loc_obj = $sloc;
	    }
	    else
	    {
		$loc_obj = new Bio::Location::Split() if !$loc_obj;
		$loc_obj->add_sub_Location($sloc);
	    }
	}
	
	my $source = "FIG";
	my $type = $fig->ftype($peg);
	my $feature;
	
	# strip EC from function
	my $func_ok = $func;
	if ($strip_ec) {
	    $func_ok =~ s/\s+\(EC \d+\.(\d+|-)\.(\d+|-)\.(\d+|-)\)//g;
	    $func_ok =~ s/\s+\(TC \d+\.(\d+|-)\.(\d+|-)\.(\d+|-)\)//g;
	}
	
	if ($type eq "peg") {
	    $feature = Bio::SeqFeature::Generic->new(-location => $loc_obj,
						     -primary  => 'CDS',
						     -tag      => {
							 product     => $func_ok,
							 translation => $fig->get_translation($peg),
						     },
						    );
	    
	    foreach my $tagtype (keys %$note) {
		$feature->add_tag_value($tagtype, @{$note->{$tagtype}});
	    }
	  
	    # work around to get annotations into gff
	    # this is probably still wrong for split locations.
	    $func_ok =~ s/ #.+//;
	    $func_ok =~ s/;/%3B/g;
	    $func_ok =~ s/,/%2C/g;
	    $func_ok =~ s/=//g;
	    for my $l (@loc_info)
	    {
	      my $ec = "";
	      my @ecs = ($func =~ /[\(\[]*EC[\s:]?(\d+\.[\d-]+\.[\d-]+\.[\d-]+)[\)\]]*/ig);
	      if (scalar(@ecs)) {
		$ec = ";Ontology_term=".join(',', map { "KEGG_ENZYME:" . $_ } @ecs);
	      }
	      my($contig, $start, $stop, $strand, $frame) = @$l;
	      push @$gff_export, "$contig\t$source\tCDS\t$start\t$stop\t.\t$strand\t$frame\tID=".$peg.";Name=".$func_ok.$ec."\n";
	    }
		
		
	} elsif ($type eq "rna") {
	    my $primary;
	    if ( $func =~ /tRNA/ ) {
		$primary = 'tRNA';
	    } elsif ( $func =~ /(Ribosomal RNA|5S RNA)/ ) {
		$primary = 'rRNA';
	    } else {
		$primary = 'RNA';
	    }
	    
	    $feature = Bio::SeqFeature::Generic->new(-location => $loc_obj,
						     -primary  => $primary,
						     -tag      => {
							 product => $func,
						     },
						     
						    );
	    $func_ok =~ s/ #.+//;
	    $func_ok =~ s/;/%3B/g;
	    $func_ok =~ s/,/2C/g;
	    $func_ok =~ s/=//g;
	    foreach my $tagtype (keys %$note) {
		$feature->add_tag_value($tagtype, @{$note->{$tagtype}});
		
		# work around to get annotations into gff
		for my $l (@loc_info)
		{
		    my($contig, $start, $stop, $strand, $frame) = @$l;
		    push @$gff_export, "$contig\t$source\t$primary\t$start\t$stop\t.\t$strand\t.\tID=$peg;Name=$func_ok\n";
		}
	    }
	    
	} else {
	    print STDERR "unhandled feature type: $type\n";
	}

	my $bc = $bio->{$contig};
	if (ref($bc))
	{
	    $bc->add_SeqFeature($feature);
	}
	else
	{
	    print STDERR "No contig found for $contig on $feature\n";
	}
    } 


    # generate filename
    if (!$filename)
    {
	$filename = $directory . $genome . "." . $format_ending;
    }
    
    # check for FeatureIO or SeqIO
    if ($format eq "GTF") {
	#my $fio = Bio::FeatureIO->new(-file => ">$filename", -format => "GTF");
	#foreach my $feature (@$bio2) {
	#$fio->write_feature($feature);
	#}
	open (GTF, ">$filename") or die "Cannot open file $filename.";
	print GTF "##gff-version 3\n";
	foreach (@$gff_export) {
	    print GTF $_;
	}
	close(GTF);
	
    } else {
#	my $sio = Bio::SeqIO->new(-file => ">$filename", -format => $format);
	#
	# bioperl writes lowercase dna. We want uppercase for biophython happiness.
	#
	my $sio = Bio::SeqIO->new(-file => "| sed '/^LOCUS/s/dna/DNA/' >$filename", -format => $format);
	foreach my $seq (keys %$bio) {
	    $sio->write_seq($bio->{$seq});
	}
    }
    
    return ($filename, "Output file successfully written.");
}

sub export_fids_as_GB
{
    my($fig, $fids, $file, $strip_ec) = @_;

    my @locs = $fig->feature_location_bulk($fids);
    my $all_aliases = $fig->feature_aliases_bulk($fids);

    my %contigs;
    my %all_locations;
    for my $loct (@locs)
    {
	my($fid, $loc) = @$loct;
	my $genome = FIG::genome_of($fid);
	my ($contig,$beg,$end) = $fig->boundaries_of($loc);
	$contigs{$genome, $contig}++;
	$all_locations{$fid} = $loc;
    }

    my $bio;
    
    for my $ckey (keys %contigs)
    {
	my($genome, $contig) = split(/$;/, $ckey);
	my $gs = $fig->genus_species($genome);

	my $taxid = $genome;
	$taxid =~ s/\.\d+$//;
	
	my $cloc = $contig.'_1_'.$fig->contig_ln($genome, $contig);

#	my $seq = $fig->dna_seq($genome, $cloc);
	my $seq = '';
	$seq =~ s/>//;  
	$bio->{$contig} = Bio::Seq->new( -id => $contig, 
					-seq => $seq,
				       );
	$bio->{$contig}->desc("Contig $contig from $gs");
	
	my $feature = Bio::SeqFeature::Generic->new(
						    -start	=> 1,
						    -end	=> $fig->contig_ln($genome, $contig),
						    -tag        => { db_xref     => "taxon:$taxid", 
									 organism   => $gs, 
									 mol_type   => "genomic DNA", 
									 genome_id  => $genome,
								     },
						    -primary    => "source" );
	$bio->{$contig}->add_SeqFeature($feature);
    }

    my $feature_fns = $fig->function_of_bulk($fids);

    # get the pegs
    foreach my $peg (@$fids)
    {
	my $note;
	my $func = $feature_fns->{$peg};
	
	my %ecs;
	my @gos;
	
	push @{$note->{db_xref}}, "SEED:$peg";
	
	# remove duplicate gos
	my %gos = map { $_ => 1 } @gos if (scalar(@gos));
	
	# add GOs
	push @{$note->{"db_xref"}}, @gos;
	
	# add ECs
	push @{$note->{"EC_number"}}, keys(%ecs);
	
	# get the aliases from principal id
	my $pid = $fig->maps_to_id($peg);
	my @rw_aliases = map { $fig->rewrite_db_xrefs($_->[0]) } $fig->mapped_prot_ids($pid);
	my @aliases;
	foreach my $a (@rw_aliases) {
	    push @{$note->{"db_xref"}}, $a if ( $a );
	}
	
	# get the links
	foreach my $ln ($fig->fid_links($peg, $all_aliases->{$peg})) {
	    my ($db, $id);
	    if ($ln =~ /field0=CATID/ && $ln =~ /query0=(\d+)/ && ($id=$1) && $ln =~ /pcenter=harvard/) {
		$db = "HarvardClone";
	    } elsif ($ln =~ /(PIRSF)(\d+)/) {
		($db, $id) = ($1, $2);
	    } elsif ($ln =~ />(\S+)\s+(\S+.*?)</) {
		($db, $id) = ($1, $2);
	    }
	    
	    $db =~ s/\://;
	    if (!$db && !$id) {
		print STDERR "Ignored link: $ln\n";
		next;
	    }
	    push @{$note->{"db_xref"}}, "$db:$id";
	}
	
	# add FIG id as a note
	# push @{$note->{"db_xref"}}, "FIG_ID:$peg";
	
	# get the features
	
	my $loc_obj;
	my @location = split(/,/, $all_locations{$peg});
	my @loc_info;
	my $contig;
	foreach my $loc (@location) {
	    my($start, $stop);
	    $loc =~ /^(.*)\_(\d+)\_(\d+)$/;
	    ($contig, $start, $stop) = ($1, $2, $3);
	    my $original_contig = $contig;
	    my $strand = '+';
	    my $frame = $start % 3;
	    if ($start > $stop) {
		$frame = $stop % 3;
		($start, $stop, $strand) = ($stop, $start, '-');
	    } elsif ($start == $stop) {
		$strand = ".";
		$frame = ".";
	    }

	    push(@loc_info, [$contig, $start, $stop, $strand, $frame]);
	    
	    my $sloc = new Bio::Location::Simple(-start => $start,
						 -end => $stop,
						 -strand => $strand);
	    if (@location == 1)
	    {
		$loc_obj = $sloc;
	    }
	    else
	    {
		$loc_obj = new Bio::Location::Split() if !$loc_obj;
		$loc_obj->add_sub_Location($sloc);
	    }
	}
	
	my $source = "FIG";
	my $type = $fig->ftype($peg);
	my $feature;
	
	# strip EC from function
	my $func_ok = $func;
	if ($strip_ec) {
	    $func_ok =~ s/\s+\(EC \d+\.(\d+|-)\.(\d+|-)\.(\d+|-)\)//g;
	    $func_ok =~ s/\s+\(TC \d+\.(\d+|-)\.(\d+|-)\.(\d+|-)\)//g;
	}
	
	if ($type eq "peg") {
	    $feature = Bio::SeqFeature::Generic->new(-location => $loc_obj,
						     -primary  => 'CDS',
						     -tag      => {
							 product     => $func_ok,
							 translation => $fig->get_translation($peg),
						     },
						    );
	    
	    foreach my $tagtype (keys %$note) {
		$feature->add_tag_value($tagtype, @{$note->{$tagtype}});
	    }
	  
	    # work around to get annotations into gff
	    # this is probably still wrong for split locations.
	    $func_ok =~ s/ #.+//;
	    $func_ok =~ s/;/%3B/g;
	    $func_ok =~ s/,/2C/g;
	    $func_ok =~ s/=//g;
	    for my $l (@loc_info)
	    {
	      my $ec = "";
	      my @ecs = ($func =~ /[\(\[]*EC[\s:]?(\d+\.[\d-]+\.[\d-]+\.[\d-]+)[\)\]]*/ig);
	      if (scalar(@ecs)) {
		$ec = ";Ontology_term=".join(',', map { "KEGG_ENZYME:" . $_ } @ecs);
	      }
	      my($contig, $start, $stop, $strand, $frame) = @$l;
	    }
		
		
	} elsif ($type eq "rna") {
	    my $primary;
	    if ( $func =~ /tRNA/ ) {
		$primary = 'tRNA';
	    } elsif ( $func =~ /(Ribosomal RNA|5S RNA)/ ) {
		$primary = 'rRNA';
	    } else {
		$primary = 'RNA';
	    }
	    
	    $feature = Bio::SeqFeature::Generic->new(-location => $loc_obj,
						     -primary  => $primary,
						     -tag      => {
							 product => $func,
						     },
						     
						    );
	    $func_ok =~ s/ #.+//;
	    $func_ok =~ s/;/%3B/g;
	    $func_ok =~ s/,/2C/g;
	    $func_ok =~ s/=//g;
	    foreach my $tagtype (keys %$note) {
		$feature->add_tag_value($tagtype, @{$note->{$tagtype}});
		
		# work around to get annotations into gff
		for my $l (@loc_info)
		{
		    my($contig, $start, $stop, $strand, $frame) = @$l;
		}
	    }
	    
	} else {
	    print STDERR "unhandled feature type: $type\n";
	}

	my $bc = $bio->{$contig};
	if (ref($bc))
	{
	    $bc->add_SeqFeature($feature);
	}
	else
	{
	    print STDERR "No contig found for $contig on $feature\n";
	}
    } 

    my @file;
    if (ref($file))
    {
	@file = (-file => $file);
    }
    elsif ($file)
    {
	@file = (-file => ">$file");
    }
    else
    {
	@file = (-file => \*STDOUT);
    }
    print STDERR Dumper(\@file);
    my $sio = Bio::SeqIO->new(-file => ">$file", -format => 'genbank');
    foreach my $seq (keys %$bio) {
	$sio->write_seq($bio->{$seq});
    }
}


