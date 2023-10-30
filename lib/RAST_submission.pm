
package RAST_submission;


use strict;
use Job48;
use JobUpload;
use Data::Dumper;
use FIG;
use FIG_Config;
use gjoseqlib;
use XML::LibXML;
use HTML::TableContentParser;

use LWP::UserAgent;
use Bio::DB::RefSeq;
use Bio::SeqIO;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(rast_dbmaster user_dbmaster user_obj project_cache_dir
			     contig_cache_dir max_cache_age ua));

sub new
{
    my($class, $rast_dbmaster, $user_dbmaster, $user_obj) = @_;
    
    my $self = {
	rast_dbmaster => $rast_dbmaster,
	user_dbmaster => $user_dbmaster,
	user_obj => $user_obj,
	project_cache_dir => "$FIG_Config::var/ncbi_project_cache",
	contig_cache_dir => "$FIG_Config::var/ncbi_contig_cache",
	max_cache_age => 86400,
	ua => LWP::UserAgent->new(),
	url_retries => [1, 5, 20],
	codes_to_retry => { map { $_ => 1 } qw(408 500 502 503 504) }
    };

    &FIG::verify_dir($self->{project_cache_dir});
    &FIG::verify_dir($self->{contig_cache_dir});


    return bless $self, $class;
}

sub get_contig_ids_in_project_from_entrez
{
    my($self, $params) = @_;

    #
    # Determine the project ID to use. Which one we take depends on if
    # we were passed a project id, a tax id, or a contig id.
    #

    my $proj;
    if ($params->{-tax_id})
    {
    }
    elsif ($params->{-contig_id})
    {
	$proj = $self->determine_project_of_contig($params->{-contig_id});
    }
    elsif ($params->{-project_id})
    {
	$proj = $params->{-project_id};
    }

    print STDERR "project is $proj\n";
    my $project_data = $self->retrieve_project_data($proj);

    return $self->check_project_for_redundancy($project_data);
}

sub get_contigs_from_entrez
{
    my($self, $params) = @_;
    
#     my $fh_log;
#     open($fh_log, q(>>/home/rastcode/Tmp/server.log))
# 	|| warn qq(Could not open logfile);
#     print $fh_log (qq(----------------------------------------\n), Dumper($params));
    
    my $id_list = $params->{-id};
    if (!ref($id_list))
    {
	$id_list = [$id_list];
    }
    
    my @ret;
    for my $id (@$id_list)
    {
	my $ent = { id => $id };
	
	my $file = $self->retrieve_contig_data($id);
#	print $fh_log qq(id=$id,\tfile=$file\n);
	
	open(F, "<", $file);
	
	my $txt = <F>;
	my $cur_section    = q();
	my $cur_subsection = q();
	if ($txt =~ /^LOCUS.*?(\d+)\s+bp/)
	{
	    $ent->{length} = $1;
	    $cur_section= "LOCUS";
	}
	
	my @sources;
	$_ = <F>;
	$txt .= $_;
	my @wgs = ();
#	my @wgs_scafld = ();   #...For now, we will not handle scaffolds....
	while (defined($_))
	{
#	    print $fh_log ($., qq(:\t), $_);
	    
	    if (m{//\n}) {
#		print $fh_log qq(Found end of file\n);
		
		if (@wgs) {
		    $txt = q();
		    push @$id_list, @wgs;
		}
		
		last;
	    }
	    
	    if (/^(\S+)/)
	    {
		$cur_section  = $1;
		undef $cur_subsection;
#		print $fh_log qq(cur_section=$cur_section\n);
	    }
	    
	    if ($cur_section =~ m/^(WGS\S*)/) {
#		print $fh_log qq(Found $1\n);
		my $trouble = 0;
		
		#++++++++++++++++++++++++++++++++++++++++++++++++++
		#... Assume a simple range of accession-IDs
		# (NOTE: this may not be a valid assumption!)
		#--------------------------------------------------
		my ($prefix, $first_num, $last_num);
		if ($_ =~ m/^WGS\s+([^-]+)\-(\S+)/) {
		    my ($first_acc, $last_acc) = ($1, $2);
#		    print $fh_log qq(first_acc=$first_acc,\tlast_acc=$last_acc\n);
		    
		    if ($first_acc =~ m/^(\D+)(\d+)$/) {
			($prefix, $first_num) = ($1, $2);
		    }
		    else {
			$trouble = 1;
			warn qq(In WGS accession $id, could not parse first accession $first_acc\n);
		    }
		    
		    if ($last_acc =~ m/^(\D+)(\d+)$/) {
			if ($1 ne $prefix) {
			    $trouble = 1;
			    warn qq(In WGS accession $id, first accession $first_acc and last accession $last_acc have differing prefixes\n);
			}
			else {
			    $last_num = $2;
			}
		    }
		    else {
			$trouble = 1;
			warn qq(In WGS accession $id, could not parse first accession $last_acc\n);
		    }
		    
		    if ($trouble) {
			warn qq(Could not handle WGS accession $id --- skipping\n);
		    }
		    else {
			if ($cur_section eq q(WGS)) {
			    push @wgs, map { $prefix.$_ } ($first_num..$last_num);
			}
# 			elsif ($cur_section eq q(WGS_SCAFLD)) {
# 			    @wgs = (); 
# 			    push @wgs_scafld, map { $prefix.$_ } ($first_num..$last_num);
# 			}
# 			else {
# 			    print $fh_log qq(Something is wrong, in WGS section --- skipping\n);
# 			    next;
# 			}
		    }
		}
	    }
	    
	    if ($cur_section eq 'SOURCE' && /^\s+ORGANISM\s+(.*)/)
	    {
		$ent->{name} = $1;
	    }
	    elsif (/^DBLINK\s+Project:(\d+)/)
	    {
		$ent->{project} = $1;
	    }
	    
	    if ($cur_section eq 'FEATURES')
	    {
		#
		# If we encounter a source, read all the lines
		# of the source and process the continuations.
		#
		
		if (/^ {5}source/)
		{
		    my $slines = [];
		    push(@sources, $slines);
		    my $cur_line = $_;
		    $_ = <F>;
		    $txt .= $_;
		    chomp;
		    while (defined($_) && m/^\s/)
		    {
			if (m,^ {5}\S,)
			{
			    push(@$slines, $cur_line);
			    last;
			}
			if (m,^ {21}/,)
			{
			    push(@$slines, $cur_line);
			    $cur_line = $_;
			}
			else
			{
			    s/^\s+/ /;
			    $cur_line .= $_;
			}
			$_ = <F>;
			$txt .= $_;
			chomp;
		    }
		    next;
		}
	    }
	    $_ = <F>;
	    $txt .= $_;
	}

	if ($txt) {
	    $ent->{contents} = $txt;
	}
	else {
	    #... $txt was cleared because entry is a WGS wrapper
	    next;
	}
	
	#
	# Determine the taxonomy id. If one of the sources in the source list
	# has the same /organism name as the overall SOURCE, use that source's
	# taxon ID. Otherwise use the first one in the list.
	#
	
	my $tax_id;
	my $first_tax_id;
	
	for my $src_lines (@sources)
	{
	    my($org, $tax);
	    for my $l (@$src_lines)
	    {
		if ($l =~ m,/organism="(.*)",)
		{
		    $org = $1;
		}
		elsif ($l =~ m,/db_xref="taxon:(\d+)",)
		{
		    $tax = $1;
		    if (!defined($first_tax_id))
		    {
			$first_tax_id = $tax;
		    }
		}
	    }
	    if ($org eq $ent->{name})
	    {
		$tax_id = $tax;
	    }
	}
	
	if ($tax_id eq '' && $first_tax_id ne '')
	{
	    $tax_id = $first_tax_id;
	}
	$ent->{taxonomy_id} = $tax_id;
	
	close(F);
	
	if ($ent->{taxonomy_id})
	{
	    #
	    # Pull the taxonomy database entry from NCBI.
	    #
	    
	    my $tdata = $self->get_taxonomy_data($ent->{taxonomy_id});
	    if ($tdata)
	    {
		$ent->{domain} = $tdata->{domain};
		$ent->{taxonomy} = $tdata->{taxonomy};
		$ent->{genetic_code} = $tdata->{genetic_code};
	    }
	}
	push(@ret, $ent);
    }
    return \@ret;
}
	

sub get_taxonomy_data
{
    my($self, $tax_id) = @_;

    my $res = $self->url_get("http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=taxonomy&id=$tax_id&report=sgml&mode=text");
    if ($res->is_success)
    {
	my $ent = {};
	my $doc = XML::LibXML->new->parse_string($res->content);
	
	my $lin = $doc->findvalue('//Taxon/Lineage');
	$lin =~ s/^cellular organisms;\s+//;
	my $domain = $lin;
	$domain =~ s/;.*$//;
	my $code = $doc->findvalue('//Taxon/GeneticCode/GCId');
	
	$ent->{domain} = $domain;
	$ent->{taxonomy} = $lin;
	$ent->{genetic_code} = $code;
	return $ent;
    }
    return undef;
}

sub determine_project_of_contig
{
    my($self, $contig_id) = @_;

    my $file = $self->retrieve_contig_data($contig_id);
    open(F, "<", $file) or die "cannot open contig data $file: $!";

    my $proj;
    while (<F>)
    {
	if (/DBLINK\s+Project:\s*(\d+)/)
	{
	    $proj = $1;
	    last;
	}
    }
    close(F);
    return $proj;
    
}

sub check_project_for_redundancy
{
    my($self, $file) = @_;

    my $seqio_object = Bio::SeqIO->new(
				       -file => $file ,
				       -format => "genbank",
				      );

    my @seqs;
    my @ids;
    while ( my $seq = $seqio_object->next_seq ) {
	push(@seqs, [$seq->accession_number, $seq->seq]);
	push(@ids, $seq->accession_number);
    }

    my @redundancy = $self->test_for_redundancy(\@seqs);
    return { ids => \@ids, redundancy_report => \@redundancy };
}

sub test_for_redundancy {
    my($self, $seqs) = @_;

    if (@$seqs < 2)
    {
	return ();
    }
    
    my %lens = map { $_->[0] => length($_->[1]) } @$seqs;
    my $tmp = "$FIG_Config::temp/tmp.$$.fasta";
    &gjoseqlib::print_alignment_as_fasta($tmp,$seqs);
    system "formatdb -i $tmp -pF";
    my @blastout = `blastall -m8 -i $tmp -d $tmp -p blastn -FF -e 1.0e-100`;
    system "rm $tmp $tmp\.*";
    my @tuples = ();
    my %seen;
    foreach my $hit (map { chomp; [split(/\t/,$_)] } @blastout)
    {
	my($id1,$id2,$iden,undef,undef,undef,$b1,$e1,$b2,$e2) = @$hit;
	if ((! $seen{"$id1/$id2"}) && ($id1 ne $id2))
	{
	    $seen{"$id1/$id2"} = 1;
	    if (($iden >= 98) &&
		(abs($e1 - $b1) > (0.9 * $lens{$id1})))
	    {
		push(@tuples,[$id1,$lens{$id1},$id2,$lens{$id2}]);
	    }
	}
    }
    
    return @tuples;
}

sub retrieve_project_data
{
    my($self, $project) = @_;
    
    my $cached_file = $self->project_cache_dir() . "/$project.gbff";
    if (my(@stat) = stat($cached_file))
    {
	my $last_mod = $stat[9];
	if (time - $last_mod < $self->max_cache_age)
	{
	    #
	    # Check for bad cached file.
	    #
	    if (open(F, "<", $cached_file))
	    {
		my $l = <F>;
		close(F);
		if ($l !~ /^LOCUS/)
		{
		    unlink($cached_file);
		    print STDERR "Cached file $cached_file contained NCBI error\n";
		}
		else
		{
		    return $cached_file;
		}
	    }
	}
    }
    my $url = "http://www.ncbi.nlm.nih.gov/sites/entrez?Db=genomeprj&Cmd=Retrieve&list_uids=";
    my $res = $self->url_get($url.$project);
    if (!$res->is_success)
    {
	die "error retrieving project data: " . $res->status_line;
    }
    my $search_result = $res->content;

    #
    # use TableContentParser to find the Replicons table from the page, and pull the RefSeq column.
    #

    my $tp = HTML::TableContentParser->new;
    my $tbls = $tp->parse($search_result);

    my @ids;
    my @tbl = grep { $_->{caption}->{data} eq 'Replicons' } @$tbls;
    if (@tbl)
    {
	my $tbl = $tbl[0];
	my $col;
	my $hlist = $tbl->{headers};
	for my $i (0..@$hlist-1)
	{
	    if ($hlist->[$i]->{data} eq 'RefSeq')
	    {
		$col = $i;
		last;
	    }
	}

#	print "Using col $col\n";

	for my $row (@{$tbl->{rows}})
	{
	    my $name = $row->{cells}->[0]->{data};
	    my $link = $row->{cells}->[$col]->{data};
#	    print "name => $link\n";
	    if ($link =~ m,>(\S+?)(\.\d+)?</a>,)
	    {
		push(@ids, $1);
	    }
	}
    }
   

    my $id_list = join(",", @ids);
    my $query = "http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nucleotide&id=" . $id_list . "&rettype=gb" ;
    my $resp = $self->url_get($query);
    if ($resp->is_success())
    {
	if ($resp->content !~ /^LOCUS/i)
	{
	    #
	    # NCBI is timing out; fail.
	    #
	    die "Error retrieving project with query $query: " . $resp->content;
	}
	open(F, ">", $cached_file) or die "Cannot open $cached_file for writing: $!";
	print F $resp->content;
	close(F);
	return $cached_file;
    }
    else
    {
	die "Error retrieving data: " . $resp->status_line;
    }
}

sub retrieve_contig_data
{
    my($self, $contig) = @_;
    
    my $cached_file = $self->contig_cache_dir() . "/$contig.gbff";
    if (my(@stat) = stat($cached_file))
    {
	my $last_mod = $stat[9];
	if (time - $last_mod < $self->max_cache_age)
	{

	    #
	    # Check for bad cached file.
	    #
	    if (open(F, "<", $cached_file))
	    {
		my $l = <F>;
		close(F);
		if ($l !~ /^LOCUS/)
		{
		    unlink($cached_file);
		    print STDERR "Cached file $cached_file contained NCBI error\n";
		}
		else
		{
		    return $cached_file;
		}
	    }
	}
    }

    my $query = "http://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nucleotide&id=" . $contig . "&rettype=gb" ;
    my $resp = $self->url_get($query);
    if ($resp->is_success())
    {
	if ($resp->content !~ /^LOCUS/)
	{
	    #
	    # NCBI is timing out; fail.
	    #
	    die "Error retrieving contig: " . $resp->content;
	}
	    
	open(F, ">", $cached_file) or die "Cannot open $cached_file for writing: $!";
	print F $resp->content;
	close(F);
	return $cached_file;
    }
    else
    {
	die "Error retrieving data: " . $resp->status_line;
    }
}

=head3 submit_RAST_job

Handle the actual job submission.

Use JobUpload.pm to create a clean input file (fixing line endings,
etc) and to pull stats for the job. 

Use Job48::create_new_job to then create the job from the 
data we brought in.

=cut

sub submit_RAST_job
{
    my($self, $params) = @_;

    my $filetype = lc($params->{-filetype});
    my $tax_id = $params->{-taxonomyID};
    my $domain = $params->{-domain};
    my $organism = $params->{-organismName};
    my $file = $params->{-file};
    my $keep = $params->{-keepGeneCalls};
    my $genetic_code = $params->{-geneticCode};
    my $gene_caller = lc($params->{-geneCaller});
    my $non_active = $params->{-nonActive};
    my $determine_family = $params->{-determineFamily};
    my $dataset  = $params->{-kmerDataset};
    my $fix_frameshifts = $params->{-fixFrameshifts};
    my $backfill_gaps = $params->{-backfillGaps};
    my $annotation_scheme = $params->{-annotationScheme};

    $annotation_scheme = "RASTtk" unless $annotation_scheme;

    $backfill_gaps = 1 unless defined($backfill_gaps);
    $fix_frameshifts = 0 unless defined($fix_frameshifts);

    my $work_dir = "$FIG_Config::temp/rast_submit_tmp.$$";
    &FIG::verify_dir($work_dir);

    my $upload_job = new JobUpload($work_dir);
    my $errs = [];

    my $fh;
    if (!open($fh, "<", \$file))
    {
	my $er = $!;
	my $len = length($file);
	system("rm", "-r", $work_dir);
	return { status => 'error', error_msg => "error creating filehandle from file data of length $len: $er" };
    }

    if (!$upload_job->create_from_filehandle($fh, "rast_submission_file", $errs))
    {
	system("rm", "-r", $work_dir);
	return { status => 'error', error_msg => join("\n", @$errs) };
    }

    my $meta_obj = $upload_job->meta();

    #
    # Pull the metadata into a hash, where it's easier to use
    # and so that we can just return it to our caller if everything
    # is good to go.
    #

    my %meta = map { $_ => $meta_obj->get_metadata($_) } $meta_obj->get_metadata_keys();

    my $res = { upload_metadata => \%meta };

    #
    # We have parsed the file. Let's do some error checking.
    #
    
    if ($meta{upload_type} ne $filetype)
    {
	$res->{status} = 'error';
	$res->{error_msg} = "Parsed filetype $meta{upload_type} not the expected $filetype";
	system("rm", "-r", $work_dir);
	return $res;
    }

    #
    # Do an NCBI lookup to pull the taxonomy string for the given tax id (if provided)
    #

    my $taxonomy;
    if ($tax_id && $tax_id ne '666666' && $tax_id ne '6666666')
    {
	my $tdata = $self->get_taxonomy_data($tax_id);
	if ($tdata)
	{
	    $domain = $tdata->{domain} unless defined($domain);
	    $genetic_code = $tdata->{genetic_code} unless defined($genetic_code);
	    $taxonomy = $tdata->{taxonomy};
	}
    }
    else
    {
	$tax_id = '6666666';
	$domain = ucfirst($domain);
	$taxonomy = $domain;
    }

    #
    # That's all for now; we might add  more later.
    # Use Job48 to create the job. We create another slightly
    # different parameter hash for this.
    #

    #
    # Find the file we're using.
    #
    my($clean_file, $clean_fh);
    if ($meta{upload_type} eq 'genbank')
    {
	$clean_file = $meta{clean_genbank};
    }
    elsif ($meta{upload_type} eq 'fasta')
    {
	$clean_file = $meta{clean_fasta};
    }
    $clean_fh = new FileHandle($clean_file, "<");

    my $j48_data = {
	genome       => $organism,
	project      => $self->user_obj->login."_".$tax_id,
	user         => $self->user_obj->login,
	taxonomy     => $taxonomy ."; $organism",
	taxonomy_id  => $tax_id,
	genetic_code => $genetic_code,
	sequence_file => $clean_fh,
	meta => {
	    source_file    => $clean_file,
	    'genome.genetic_code' => $genetic_code,
	    'genome.sequencing_method' => 'unknown',
	    'genome.coverage' => 'unknown',
	    'genome.contigs' => 'unknown',
	    'genome.average_read_length' => 'unknown',
	    'genome.gc_content' => $meta{stats_contigs}->{gc},
	    'genome.bp_count' => $meta{stats_contigs}->{chars},
	    'genome.contig_count' => $meta{stats_contigs}->{seqs},
	    'genome.ambig_count' => 0,
	    'import.candidate' => 0,
	    'keep_genecalls' => $keep ? 1 : 0,
	    ('use_glimmer' => $gene_caller eq 'glimmer3' ? 1 : 0),
	    'correction.automatic' => 1,
	    'correction.frameshifts' => $fix_frameshifts,
	    'correction.backfill_gaps' => $backfill_gaps,
	    'env.debug' => 0,
	    'env.verbose' => 0,
	    ('options.determine_family' => $determine_family ? 1 : 0),
	    upload_metadata => \%meta,
	    ($dataset ne '' ? ('options.figfam_version' => $dataset) : ()),
	    ($annotation_scheme ne '' ? (annotation_scheme => $annotation_scheme) : ()),
	},
	non_active => ($non_active ? 1 : 0),
    };

    my($job_id, $job_msg) = Job48->create_new_job($j48_data);
    if ($job_id)
    {
	$res->{status} = 'ok';
	$res->{job_id} = $job_id;


	# sync job so it'll appear in the job listings on the website
	my $sync;
	eval { $sync = $self->rast_dbmaster->Job->init({ id => $job_id }); };
    }
    else
    {
	$res->{status} = 'error';
	$res->{error_msg} = $job_msg;
    }
    close($clean_fh);
    system("rm", "-r", $work_dir); 
    return $res;
}

sub status_of_RAST_job
{
    my($self, $params) = @_;

    my @job_nums;
    my $job_num_param = $params->{-job};
    if (ref($job_num_param) eq 'ARRAY')
    {
	@job_nums = @$job_num_param;
    }
    else
    {
	@job_nums = ($job_num_param);
    }

    my $res = {};
    for my $job_num (@job_nums)
    {
	my $job = $self->rast_dbmaster->Job->init({ id => $job_num });
	if (!ref($job))
	{
	    $res->{$job_num} = { status => 'error', error_msg => 'Job not found'};
	    next;
	}
	
	if (!$self->user_may_access_job($job))
	{
	    $res->{$job_num} = { status => 'error', error_msg => 'Access denied' };
	    next;
	}

	my $dir = $job->dir;
	if (open(E, "<$dir/ERROR"))
	{
	    local $/;
	    undef $/;
	    my $emsg = <E>;
	    close(E);
	    $res->{job_num} = { status => 'error', error_msg => $emsg };
	    next;
	}

	#
	# Retrieve status flags from the meta file (not the database,
	# so that we can get the very latest state).
	#

	#
	# For now we only check status.export because that is what the
	# bulk API cares about.
	#
	
	my $status_list = [];
	my $cur_stage;
	my $stages = $job->stages();
	my %status;
	for my $stage (@$stages)
	{
	    my $status = $job->metaxml->get_metadata($stage) || 'not_started';
	    $status{$stage} = $status;
	    push(@$status_list, [$stage => $status]);
	    if ($status ne 'complete')
	    {
		$cur_stage = $stage;
	    }
	}

	#
	# If any stage is not in not_started, then the job is running.
	#
	my $exp_status = $status{'status.export'};
	if ($exp_status ne 'complete')
	{
	    if (grep { $status{$_} ne 'not_started' } keys %status)
	    {
		$exp_status = 'running';
	    }
	}

	$res->{$job_num} = { status => $exp_status, verbose_status => $status_list };
    }
    return $res;
}

=head3 kill_RAST_job

Mark the job as inactive, and qdel any stages that might be running.

=cut
sub kill_RAST_job
{
    my($self, $params) = @_;

    my @job_nums;
    my $job_num_param = $params->{-job};
    if (ref($job_num_param) eq 'ARRAY')
    {
	@job_nums = @$job_num_param;
    }
    else
    {
	@job_nums = ($job_num_param);
    }

    my $res = {};
    for my $job_num (@job_nums)
    {
	my $job = $self->rast_dbmaster->Job->init({ id => $job_num });
	if (!ref($job))
	{
	    $res->{$job_num} = { status => 'error', error_msg => 'Job not found'};
	    next;
	}
	
	if (!($self->user_may_access_job($job) && $self->user_owns_job($job)))
	{
	    $res->{$job_num} = { status => 'error', error_msg => 'Access denied' };
	    next;
	}

	my $messages = $self->_perform_job_kill($job, $job_num);
	$res->{$job_num} = { status => 'ok', messages => $messages };
    }
    return $res;
}

sub _perform_job_kill
{
    my($self, $job, $job_num) = @_;
    my $messages = [];
    my @ids;
    for my $k ($job->metaxml->get_metadata_keys())
    {
	if ($k =~ /sge[^.]*id/)
	{
	    my $id = $job->metaxml->get_metadata($k);
	    if (ref($id))
	    {
		push(@ids, @$id);
	    }
	    else
	    {
		push(@ids, $id);
	    }
	}
    }

    #
    # sanity check.
    #
    @ids = grep { /^\d+$/ } @ids;
    
    if (@ids)
    {
	my $cmd = ". /vol/sge/default/common/settings.sh; qdel @ids";
	if (open(my $p, "$cmd 2>&1 |"))
	{
	    while (<$p>)
	    {
		chomp;
		push(@$messages, $_);
	    }
	    
	    my $rc = close($p);
	    if (!$rc)
	    {
		push(@$messages, "'$cmd' returns status=$! $?");
	    }
	    else
	    {
		push(@$messages, "'$cmd' returns status=0");
	    }
	}
	else
	{
	    push(@$messages, "Cannot open pipe to $cmd: $!");
	}
    }
    else
    {
	push(@$messages, "No sge tasks to kill");
    }
    
    my $active = $job->dir . "/ACTIVE";
    if (-f $active)
    {
	if (unlink($active))
	{
	    push(@$messages, "unlinked $active");
	}
	else
	{
	    push(@$messages, "error unlinking $active: $!");
	}
    }
    else
    {
	push(@$messages, "no active file $active");
    }
    return $messages;
}

=head3 delete_RAST_job

Delete the given RAST jobs.  This is a real delete, not a mark-the-flag delete.

=cut
sub delete_RAST_job
{
    my($self, $params) = @_;

    my @job_nums;
    my $job_num_param = $params->{-job};
    if (ref($job_num_param) eq 'ARRAY')
    {
	@job_nums = @$job_num_param;
    }
    else
    {
	@job_nums = ($job_num_param);
    }

    my $res = {};
    for my $job_num (@job_nums)
    {
	my $job = $self->rast_dbmaster->Job->init({ id => $job_num });
	if (!ref($job))
	{
	    $res->{$job_num} = { status => 'error', error_msg => 'Job not found'};
	    next;
	}
	
	if (!($self->user_may_access_job($job) && $self->user_owns_job($job)))
	{
	    $res->{$job_num} = { status => 'error', error_msg => 'Access denied' };
	    next;
	}

	my $dir = $job->dir;

	#
	# Just make sure the dir ends in the job number, so an error
	# doesn't wreak TOO much havoc.
	#
	if ($dir =~ /$job_num$/)
	{
	    my $msgs = $self->_perform_job_kill($job, $job_num);

	    my $rc = system("rm", "-r", $dir);
	    if ($rc == 0)
	    {
		$res->{$job_num} = { status => 'ok', messages => $msgs }
	    }
	    else
	    {
		$res->{$job_num} = { status => 'error', error_msg => "Remove of $dir died with status $rc" }
	    }
	}
	#
	# Delete from the database too.
	#
	$job->delete();
    }

    return $res;
}

sub retrieve_RAST_job
{
    my($self, $params) = @_;

    my $job_id = $params->{-job};
    my $format = $params->{-format};

    my $job = $self->rast_dbmaster->Job->init({ id => $job_id });

    #
    # Support passing a genome ID in here.
    #
    if (!ref($job))
    {
        my $list = $self->rast_dbmaster->Job->get_objects({ genome_id => $job_id });
	if (ref($list) && @$list)
	{
	    $job = $list->[0];
	}
    }

    if (!ref($job))
    {
	return { status => 'error', error_msg => 'Job not found'};
    }
    
    if (!$self->user_may_access_job($job))
    {
	return { status => 'error', error_msg => 'Access denied' };
    }

    #
    # Map the given output format to a file.
    #

    my %type_map = (genbank => "%s.gbk",
		    genbank_stripped => "%s.ec-stripped.gbk",
		    embl => "%s.embl",
		    embl_stripped => "%s.ec-stripped.embl",
		    gff3 => "%s.gff",
		    gff3_stripped => "%s.ec-stripped.gff",
		    gtf => "%s.gtf",
		    gtf_stripped => "%s.ec-stripped.gtf",
		    rast_tarball => "%s.tgz",
		    nucleic_acid => "%s.fna",
		    amino_acid   => "%s.faa",
		    table_txt    => "%s.txt",
		    table_xls    => "%s.xls",
		    );

    my $file_pattern = $type_map{lc($format)};
    if (!defined($file_pattern))
    {
	return { status => 'error', error_msg => "Format $format not found" };
    }

    #
    # Find the download file.
    #

    my $dir = $job->download_dir();
    my $file = sprintf($file_pattern, $job->genome_id);
    my $path = "$dir/$file";

    return { status => 'ok', file => $path };

#     if (!open(F, "<", $path))
#     {
# 	return { status => 'error', error_msg => "Cannot open download file $path"}; 
#     }

#     local $/;
#     undef $/;
#     my $txt = <F>;
#     return { status => 'ok', contents => $txt };
}

sub copy_to_RAST_dir
{
    my($self, $params) = @_;

    my $job_id = $params->{-job};
    my $to = $params->{-to};
    my $to_name = $params->{-toName};
    my $from = $params->{-from};
    my $type = $params->{-type};
    my $chunk_num = $params->{-chunkNum};
    my $total_size = $params->{-totalSize};

    if ($to_name eq ''  || $to_name =~ m,/,)
    {
	return { status => 'error', error_msg => 'Invalid -toName'};
    }
	

    my $job;
    eval {
	$job = $self->rast_dbmaster->Job->init({ id => $job_id });
    };

    if (!ref($job))
    {
	warn "no job found\n";
	return { status => 'error', error_msg => 'Job not found'};
    }
    
    if (!($self->user_may_access_job($job)))
    {
	return { status => 'error', error_msg => 'Access denied'};
    }

    my $dest;
    if ($to eq '')
    {
	$dest = $job->dir . "/UserSpace";
    }
    else
    {
	#
	# if path starts with / or any component is ..
	# fail the attempt.
	#

	my @comps = split(/\//, $to);
	if ($to =~ m,^/, || (grep { $_ eq '..' } @comps))
	{
	    return { status => 'error', error_msg => 'Invalid Path'};
	}
	$dest = $job->dir . "/UserSpace/$to";
    }
    &FIG::verify_dir($dest);

    my $spool_file;
    if ($type eq 'tar')
    {
	$spool_file = "$dest/$to_name.tar";
    }
    else
    {
	$spool_file = "$dest/$to_name";
    }

    if (defined($total_size))
    {
	my $spool_size = -s $spool_file;
	if ($spool_size != $total_size)
	{
	    return { status => 'error', error_msg => "Size mismatch at end, $spool_size != $total_size" };
	}

	if ($type eq 'tar')
	{
	    my $rc = system("tar", "-x", "-f", $spool_file, "-C", $dest);
	    if ($rc == 0)
	    {
		unlink($spool_file);
		return { status => 'ok' };
	    }
	    else
	    {
		return { status => 'error', error_msg => "Untar failed with rc=$rc" };
	    }
	}
	else
	{
	    return { status => 'ok' };
	}
    }

    if ($chunk_num == 0)
    {
	open(F, ">", $spool_file);
    }
    else
    {
	open(F, ">>", $spool_file);
    }

    warn "Copying chunk $chunk_num to $dest/$to_name\n";
    if (ref($from))
    {
	my $buf;
	my $nread = 0;
	while (my $size = read($from, $buf, 4096))
	{
	    print F $buf;
	    $nread += $size;
	}
	warn "Read $nread\n";
    }
    else
    {
	my $s = length($from);
	warn "Read2 $s\n";
	print F $from;
    }
       
    close(F);

    return { status => 'ok' };
}

sub get_job_metadata
{
    my($self, $params) = @_;

    my $job_id = $params->{-job};

    $job_id =~ /^\d+$/ or return { status => 'error', error_msg => 'invalid job id'};

    my $res = {};
    my $job = $self->get_job_for_reading($job_id, $res);
    return $res if !$job;
    
    my $keys = $params->{-key};
    $keys = [$keys] unless ref($keys);

    for my $key (@$keys)
    {
	$res->{metadata}->{$key} = $job->metaxml->get_metadata($key);
    }
    $res->{status} = 'ok';
    return $res;
}
    
sub get_job_for_reading
{
    my($self, $job_id, $res) = @_;
    
    my $job = $self->rast_dbmaster->Job->init({ id => $job_id });
    if (!ref($job))
    {
	$res->{status} = 'error';
	$res->{error_msg} = 'Job not found';
	return;
    }
    
    if (!$self->user_may_access_job($job))
    {
	$res->{status} = 'error';
	$res->{error_msg} = 'Access denied';
	return;
    }
    return $job;
}

sub get_job_for_modification
{
    my($self, $job_id, $res) = @_;
    
    my $job = $self->rast_dbmaster->Job->init({ id => $job_id });
    if (!ref($job))
    {
	$res->{status} = 'error';
	$res->{error_msg} = 'Job not found';
	return;
    }
    
    if (!($self->user_may_access_job($job) && $self->user_owns_job($job)))
    {
	$res->{status} = 'error';
	$res->{error_msg} = 'Access denied';
	return;
    }
    return $job;
}

sub user_may_access_job
{
    my($self, $job) = @_;

    return $self->user_obj->has_right(undef, 'view', 'genome', $job->genome_id);
}

sub user_owns_job
{
    my($self, $job) = @_;

    my $userid = $self->user_obj->login();

    return $job->owner->login() eq $userid;
}

sub get_jobs_for_user_fast
{
	my($self) = @_;
	if (!defined $self->user_obj->login()) {return ()}
	return [$self->rast_dbmaster->Job->get_jobs_for_user_fast($self->user_obj, 'view')];
}


=head3 url_get

Use the LWP::UserAgent in $self to make a GET request on the given URL. If the
request comes back with one of the transient error codes, retry.

=cut

sub url_get
{
    my($self, $url) = @_;
    my @retries = @{$self->{url_retries}};

    my $res;
    while (1)
    {
	my $now = time;
	if ($self->{last_url_request} > 0)
	{
	    my $delay = $now - $self->{last_url_request};
	    if ($delay < 3)
	    {
		my $sleep = 3 - $delay;
		print STDERR "Sleeping $sleep to pace requests\n";
		sleep($sleep);
	    }
	}
	$self->{last_url_request} = $now;
	$res = $self->ua->get($url);

	if ($res->is_success)
	{
	    return $res;
	}

	my $code = $res->code;
	if (!$self->{codes_to_retry}->{$code})
	{
	    return $res;
	}

	if (@retries == 0)
	{
	    return $res;
	}
	my $retry_time = shift(@retries);
	print STDERR "Request failed with code=$code, sleeping $retry_time and retrying $url\n";
	sleep($retry_time);
    }
    return $res;
}


1;
