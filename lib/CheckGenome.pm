package CheckGenome;



use strict;
use warnings;
use DBI;
use FIG;
use GenomeMeta;
use ContigMD5;
use LWP::Simple;



use constant META_FILE => "meta.xml";


# my ($dir,$verbose,$update_meta, $overwrite_submit_candidate) = check_opts();

# unless (-d $dir) {
#   print STDERR "No directory \n";
#   &help;
#   exit;
# }

# $data->{job_directory}
# $data->{sequences}
# $data->{name} 
# $data->{message} 
# $data->{error} 
# $data->{taxonomy_id}
# $data->{ fig_id_for_name } 
# $data->{ fig_ids_for_tax_id }
# $data->{ seed_contigs_for_name }
# $data->{ seed_contigs_for_taxonomy }
# $data->{contig_in_seed}->{ $contig } = { checksum => $cksum,
# 					 fig_id   => $gen,
# 				       };


sub new {
  my ( $class , $job_id , $verbose) = @_;
  
  
  my $data = {};
  my $fig = new FIG;
  $data->{fig} = $fig;
  
  my $dir;
  if ($job_id =~ /^\d+$/)
    {
      $dir = "$FIG_Config::fortyeight_jobs/$job_id";
    }
  else
    {
      $dir = $job_id;
      $job_id = basename($dir);
    }
       

$data->{job_directory} = $dir;

my $error                                  = check_organism_dir($dir);
$data->{sequences}                         = get_sequences_from_organism_dir($dir) if ($dir);
my ($genomes , $ids)                       = get_seed_genomes($fig);

($data->{ name }, 
 $data->{ taxonomy_id }, 
 $data->{ fig_id } )                       = get_organism_and_tax_id_from_organism_dir($dir);

$data->{neighbors}                         = get_neighbors($fig , $dir);

$data->{ fig_id_for_name }                 = check_organism_name( $data->{name} , $genomes); 
$data->{ fig_ids_for_tax_id }              = check_tax_id( $data->{ taxonomy_id } , $ids );
$data->{ nr_matched_contigs }              = check_checksums($data);

check_nr_contigs_at_ncbi( $data );
get_contig_info_from_seed( $data );
make_decision( $data );

bless $data;


my $overwrite_submit_candidate = 1;
my $update_meta = 1;
update_meta_file( $dir, $data , $overwrite_submit_candidate) if ( $update_meta);


return $data;

}

sub check_nr_contigs_at_ncbi{
  my ($data) = @_;

  my $url = "http://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=";
  my $search_result = get($url.$data->{ taxonomy_id });


  my @lines = split ( "\n" , $search_result);
  
  my $nr_seq = 0;
  my $nr_proj = 0;
  my $url_seq = "";
  my $url_proj = "";
  my $genome_name = "";
  
  my $next = "";
  foreach my $line ( @lines ){
    if ( $next eq "Sequences"){
      ($url_seq)   = $line =~ m/href="([^"]*)"/;
      ($nr_seq) = $line =~ m/>(\d*)<\/font/;
      
      #print "Genome Sequences: $nr_seq\n";
      
      
      $next = "";
    }
    elsif ( $next eq "Projects"){
      ($url_proj) = $line =~ m/href="([^"]*)"/;
      ($nr_proj) = $line =~ m/>(\d*)<\/font/;
      
      #print "Genome Projects: $nr_proj \n";
      
      
      $next = "";
    }
    
 
    if ( $line =~ /<title>Taxonomy browser\s*\(([^()]+)\)\<\/title\>/ ) {
      $genome_name = $1;
    }
    
    if ($line =~ m/(Genome[\w;&]+Sequence)/){
      $next = "Sequences";
  } 
    elsif ($line =~ m/(Genome[\w;&]+Projects)/){
      $next = "Projects";
    }
    
}

  
 

  $data->{ ncbi_genome } = $genome_name;
  $data->{ ncbi_nr_projects } = $nr_proj;
  $data->{ ncbi_nr_seq } = $nr_seq;
}


sub get_contig_info_from_seed{
  my ( $data  ) = @_;

  my $fig = $data->{fig};

  # get contigs for orgaism name
  if ( $data->{ fig_id_for_name } ) {
    my @contig_ids = $fig->all_contigs($data->{fig_id_for_name} );
    $data->{ seed_contigs_for_name } = \@contig_ids;
  }

  # get contigs for taxonomy
  if ( $data->{ fig_ids_for_tax_id } ) {
    
    foreach my $id   (@{$data->{ fig_ids_for_tax_id } } ) {
      my @contig_ids = $fig->all_contigs($id);
      $data->{ seed_contigs_for_taxonomy }->{ $id } =  \@contig_ids;
    }
  }
  return $data;
}


sub check_checksums{
  my ($data) = @_;
  my $matched_contigs = 0;

  my $fig = $data->{fig};

  foreach my $sq (@{$data->{sequences}}){
    
    my $c = new ContigMD5;
    $c->add( $sq );
    my $cksum = $c->checksum();
    #print $cksum,"\n";
    my ($contig, $gen , $error) = $fig->md5sum_to_contig_genome( $cksum );
    
    if ($contig){
      #print "Contig is in the SEED\n";
      $data->{contig_in_seed}->{ $contig } = { checksum => $cksum,
					       fig_id   => $gen,
					     };
      $matched_contigs++;
      #print $cksum,"\t",$contig,"\t",$gen,"\n";
    }
    if ( $error ){
      $data->{ error } = $error;
      $data->{ message } .= $error;
    }
  }
  return $matched_contigs;
}
 

sub get_seed_genomes{
  my ($fig) = @_;
  my $genomes = {};
  my $ids = {};

  my @gs = $fig->genomes();
  foreach my $g ( @gs ) {
    my $name = $fig->genus_species( $g );
    $genomes->{ $name } = $g;
    my ($id) = $g =~/(\d+)\.\d+/;
    
    if ( $ids->{ $id } ){
      push @{$ids->{ $id }} , $g ;
    }
    else{
      $ids->{ $id } = [$g];  
    }
  }

  return ($genomes, $ids);
}

sub help{
  print "check_rast_genome.pl -d organism_directory \n";
  exit;
}

# sub check_opts{
#   # initialise
#   my ( $dir , $verbose , $update_meta) = ("","0","0");
#   getopts('d:uvoh');
  
#   help if ($opt_h);
 
#   if (($opt_d) && (-d $opt_d)){
#     $dir = $opt_d;;
#   }
#   else{
#     print STDERR "No directory!\n";
#     help;
#   }

#   $verbose = 1 if ($opt_v);
#   $update_meta = 1 if ( $opt_u );
#   my $overwrite_submit_candidate = 0;
#   $overwrite_submit_candidate = 1 if ( $opt_o);

#   return ( $dir, $verbose, $update_meta, $overwrite_submit_candidate);
# }

sub check_organism_dir{
  my ( $dir ) = @_;
  my $error = 0;
  unless ( -f $dir."/DONE" ) {
  }
  if ( -f $dir."/ERROR" ) {
    $error = "\nCheck job directory, there has been an error!\nDon't process $dir.\n\n";
    print STDERR $error;
    exit;
  }

  return $error;
}

sub get_organism_and_tax_id_from_organism_dir{
  my ($dir) = @_;

  my $id;
  my $name;

  my @id_files = `find $dir -follow -name GENOME_ID`;
  my @genome_files = `find $dir -follow -name GENOME`;

  if ( scalar @id_files ){
    open (FILE, $id_files[0] ) or die "Can't open $id_files[0]\n";
    $id = <FILE>;
    close(FILE);
  }
  else{
    print STDERR "No GENOME_ID file in $dir!\n";
    print STDERR "Files = " . join " ",@id_files ,"\n";
    exit;
  }

  if ( scalar @genome_files ){
    open (FILE, $genome_files[0] ) or die "Can't open $genome_files[0]\n";
    $name = <FILE>;
    close(FILE);
  }
  else{
    print STDERR "No GENOME file in $dir!\n";
    exit;
  }
  
  my ($seed_tax) = $id =~ /(\d+)\.\d+/;
  chomp $name;
  chomp $id;
  return ( $name ,  $seed_tax,  $id);

}



# exctract sequences from contigs file
sub get_sequences_from_organism_dir{
  my ($dir , $verbose) = @_;
  my @sequences;

  $dir = $dir."/raw" if (-d $dir."/raw");
  my @files = `find $dir -follow -name contigs`;

  foreach my $file (@files) {
    print STDERR "Use contig file: $file\n" if $verbose;
    open (FILE , $file) or die "Can't open file $file\n";

    my $seq = "";
    while (my $line = <FILE>) {
      if ($line =~ /^>/){
	push @sequences, $seq if ($seq);
	$seq = "";
      }
      else{
	chomp $line;
	$seq .= $line;
      }

    }
    push @sequences, $seq if ($seq); # get the last entry too
    close(FILE);

  }
  return \@sequences;
}


sub check_organism_name{
  my ( $org , $list ) = @_;

  # simple check
  
  my $fig_id = $list->{ $org };

  return $fig_id;
}

sub check_tax_id{
  my ( $id , $list ) = @_;

  #simple check

  my $fig_versions = $list->{ $id };

  return $fig_versions;

}


sub get_neighbors{
  my ($fig , $dir , $verbose) = @_;
  my @sequences;

  $dir = $dir."/rp" if (-d $dir."/rp");
  my @files = `find $dir -follow -name neighbors`;
  
  my %neighbors;
  foreach my $file (@files) {
    
    open (FILE , $file) or die "Can't open file $file\n";
    
    
    while (my $line = <FILE>) {
      my @fields = split "\t" , $line;
      my $name = $fig->genus_species( $fields[0] );
      $neighbors{$fields[0]} = { 
				rank => $fields[1],
				score => $fields[2],
				name => $name,
			       };
     
    }
    close(FILE);

  }
  return \%neighbors;

}

sub create_html_output{
  my ($data) = @_;

  my $content = '';
  
  $content .= "<table>";
  $content .= "<tr>";

  # for organism name
  if ( $data->{ fig_id_for_name } ) {
    $content .=  "<td>SEED id found for organism  ".$data->{ name }."</td><td>".$data->{ fig_id_for_name }."</td></tr>\n";
  
   my $contig_ids = $data->{ seed_contigs_for_name };
   $content .=  "<tr><td>Contigs in the seed for ". $data->{ name } ."</td><td>".scalar @$contig_ids."</td><tr>\n";
 }
  
  # for taxonomy
  my %matched_ids;
  foreach my $id ( @{ $data->{ fig_ids_for_tax_id } }){
    $matched_ids{$id} = $id;
  }
  if ( $data->{ fig_ids_for_tax_id } ) {
    $content .=  "<tr><td>Found following SEED ids for given taxonomy</td><td> ";
    $content .=  join ( " ",@{ $data->{ fig_ids_for_tax_id } } ) . "</td></tr>\n";
  }
  foreach my $id   (@{$data->{ fig_ids_for_tax_id } } ) {
    $content .=  "<tr><td>Contigs in the seed for $id</td><td>".scalar @{ $data->{ seed_contigs_for_taxonomy }->{ $id } }." </td></tr>\n";
  }

  # from organism dir
  $content .=  "<tr><td>Contigs in organism dir</td><td>". scalar @{$data->{sequences}} . "</td></tr>\n";

  # for compared contigs
  if (keys %{ $data->{ contig_in_seed } } ){

    
    $content .=  "<tr><td>Contig is in the SEED</td><td>";
    foreach my $contig ( keys %{ $data->{ contig_in_seed } } ) {
      
      $content .=  "<table><tr><th>Checksum<td>".$data->{contig_in_seed}->{ $contig }->{ checksum }."</tr><tr><th>SEED Name<td> ".
	$contig."</tr><tr><th>SEED ID<td>".$data->{contig_in_seed}->{ $contig }->{ fig_id }."</tr></table>\n";
    }
    $content .= "</td></tr>"
  }
  $content .= " </table> ";
  
  $content .= "<hr>";
  $content .= "<h4>Neighbors</h4>\n";
  $content .= "<table>";

  my @list;
  foreach my $neighbor ( keys %{ $data->{ neighbors }}){
    push @list , [ 
		  $neighbor , 
		  $data->{ neighbors }->{ $neighbor }->{ name } ,
		  $data->{ neighbors }->{ $neighbor }->{ rank },
		  $data->{ neighbors }->{ $neighbor }->{ score }
		 ];
  }

  my @show = sort { $a->[3] <=> $b->[3] } @list;
  foreach my $line (reverse @show){
    $content .= "<tr><th> ".$line->[0];
    if ($matched_ids{ $line->[1] } or ( $data->{name} eq $line->[1])){
      $content .= "<td><b>".$line->[1]."</b></td>";
    }
    else{
      $content .= "<td>".$line->[1]."</td>";
    }
    $content .= "<td>".$line->[2]."</td>";
    $content .= "<td>".$line->[3]."</td></tr>";
  }
  $content .= "</table><hr>\n";

  if ( $data->{ message }  ){
    $content .=  "<p>".$data->{ message }."<br>\n";
  }
  if  ( $data->{ error }  ){
    $content .=  "<p>There has been an error:\n".$data->{ error }."<br>\n";
  }

  return $content;
 
}


sub update_meta_file{
  my ($job_dir,$data,$overwrite_submit_candidate) = @_;
 
  my $var = '';
 
  unless ( -f $job_dir."/".META_FILE ){
    print STDERR  "No ".$job_dir."/".META_FILE,"\n";
    exit;
  }


  #print STDERR "Overwriting: $overwrite_submit_candidate\n";

  my $meta = new GenomeMeta($data->{ fig_id }, $job_dir."/".META_FILE);

  
  
  if ( $data->{ fig_id_for_name } and 
       ($meta->get_metadata("v2c2.fig_id_for_name") ne $data->{ fig_id_for_name }) 
     ){
    $meta->set_metadata("v2c2.fig_id_for_name",$data->{ fig_id_for_name });
  }


  if ( $data->{ seed_contigs_for_name } ){
    $var = scalar @{ $data->{ seed_contigs_for_name } };  
  }
  else{    
    $var = 0;
  }
  if ($meta->get_metadata("v2c2.nr_contigs_for_name") ne $var) {
    $meta->set_metadata("v2c2.nr_contigs_for_name", $var) ;
  }
  $var = '';


  if ( $data->{ fig_ids_for_tax_id } ) {
   $var =  join ";" , @{ $data->{ fig_ids_for_tax_id } } ;
  }
  if  ($meta->get_metadata("v2c2.fig_ids_for_tax_id") ne $var ) {
    $meta->set_metadata("v2c2.fig_ids_for_tax_id", $var);
  }
  $var = '';
  

  if  ( $data->{ seed_contigs_for_taxonomy } ) {

    my $nr_contig = 0;
    foreach my $id ( keys %{ $data->{ seed_contigs_for_taxonomy } } ) {
      
      ( $nr_contig ) ?  $nr_contig .= ":".scalar @{ $data->{ seed_contigs_for_taxonomy }->{ $id } } : $nr_contig = scalar @{ $data->{ seed_contigs_for_taxonomy }->{ $id } } ;
    }

    $meta->set_metadata("v2c2.nr_contigs_for_tax_id", $nr_contig) if ($meta->get_metadata("v2c2.nr_contigs_for_tax_id") ne $nr_contig);
  }
  
  $meta->set_metadata("v2c2.nr_contigs_in_org_dir", scalar @{ $data->{ sequences } } )if ( $meta->get_metadata("v2c2.nr_contigs_in_org_dir") ne (scalar @{ $data->{ sequences } } ) );


  # count matched contigs
  my $matched_contigs = "";
  my $nr_matched_contigs = 0;
  if (keys %{ $data->{ contig_in_seed } } ){
 
    foreach my $contig ( keys %{ $data->{ contig_in_seed } } ) {
      $nr_matched_contigs++;
      $matched_contigs .=  $contig."\t".$data->{contig_in_seed}->{ $contig }->{ fig_id }."\n";
    }
  }

  if ($meta->get_metadata("v2c2.matched_contigs") ne $matched_contigs){
    $meta->set_metadata("v2c2.matched_contigs", $matched_contigs );
  }
  if ($meta->get_metadata("v2c2.nr_matched_contigs") ne $nr_matched_contigs){
    $meta->set_metadata("v2c2.nr_matched_contigs", $nr_matched_contigs );
  }



  # set submit candidate
  my $info_submit_candidate = $meta->get_metadata("submit.candidate");

  if ( $data->{ remove_candidate} and $overwrite_submit_candidate ){
    print STDERR "Set submit.candidate\n";
    $meta->set_metadata("submit.candidate", 0 ) if ($meta->get_metadata("submit.candidate") ne  "0" );
  }

  if ( (defined $data->{ replace_seedID}) and ( $meta->get_metadata("replace.seedID") ne $data->{ replace_seedID }) ) {
    $meta->set_metadata("replace.seedID", $data->{ replace_seedID }) if ( (defined $data->{ replace_seedID}) and $overwrite_submit_candidate );
  }
  if  ( $meta->get_metadata("v2c2.message") ne $data->{ message }) {
    $meta->set_metadata("v2c2.message", $data->{ message });
  }
  

  return 1;
}

sub make_decision {
  my ( $data ) = @_;
  my $meta;
  
  my $msg = "";
  # 1. name , tax , contigs match -> same genome
  # 2. name , tax  match same number of contigs but checksum does not match -> different/new version 
  # 3. name , tax  match different number of contigs -> different/new version
  # 4. name matches , tax differs
  # 5. name differs, tax matches
  # 6, name , tax differs contigs matches -> problem
  # 7. name , tax , contigs differ -> new genome
  

  if ( $data->{ replace_seedID } ) {
    print STDERR "Replace ID submitted : ".$data->{ replace_seedID },"\n";
    exit;
  }

  # get matched contigs
  my $matched_contigs = "";
  my $nr_matched_contigs = 0;

  if (keys %{ $data->{ contig_in_seed } } ){  
    foreach my $contig ( keys %{ $data->{ contig_in_seed } } ) {
      $nr_matched_contigs++;
      $matched_contigs .=  $contig."\t".$data->{contig_in_seed}->{ $contig }->{ fig_id }."\n";
    }
  }
  $data->{ matched_contigs } = $matched_contigs;
  $data->{ nr_matched_contigs } = $nr_matched_contigs;

  # name is matching
  if  ( $data->{ fig_id_for_name } ) {

    # check for taxonomy 
    if (scalar @{$data->{ fig_ids_for_tax_id }} == 1){
      my $fig_id = $data->{ fig_ids_for_tax_id }->[0];
      
      # name and taxonomy matches
      if ( $fig_id eq $data->{ fig_id_for_name } ){
	# set ID for replacement
	$data->{ replace_seedID } = $fig_id;
	
	if (  @{ $data->{ sequences } } < @{ $data->{ seed_contigs_for_name } } ) {
	  $msg .= "less contigs than seed contigs, probably new version\n";
	}
	elsif (  @{ $data->{ sequences } } > @{ $data->{ seed_contigs_for_name } } ) {
	  $msg .= "more contigs than seed contigs, either older version or new genome project\n";
	}
	else{
	 
	  if  (scalar @{ $data->{ seed_contigs_for_name } } == $data->{ nr_matched_contigs } ){
	    $msg .= "same version, don't import\n";
	    
	    $data->{ remove_candidate } = 1;
	  }
	  else{
	    
	    $msg .= "same number of contigs but not same contigs\n";
	  }
	}
	
      }
      # different id for taxonomy and org name
      else{
	$msg .= "ID for taxonomy doesn't match id for organism name: $fig_id and ". $data->{ fig_id_for_name }."\n";
      }
      
    }
    elsif (scalar @{$data->{ fig_ids_for_tax_id }} > 1){ 
      $msg .= "Geome exists in different versions: ". join (" ", @{$data->{ fig_ids_for_tax_id }} )."\n";
    }
    else{
      # no match for name and taxonomy
      # check for contigs
      
      if ( $data->{ nr_matched_contigs} ){
	$msg .= "Contigs found in the SEED, but no match for name and taxonomy\n";
	$msg .= $data->{ matched_contigs };
      }
      else{
	$msg .= "probably new genome\n";
      }

    }
    
  } 
  # name is not matching
  else{

    # check taxonomy
    if ( ref $data->{ fig_ids_for_tax_id } and scalar ( @{$data->{ fig_ids_for_tax_id }} ) == 1){
      
      my $fig_id_for_taxonomy = $data->{ fig_ids_for_tax_id }->[0];
      
      $msg .= "Seems to be an existing genome ( $fig_id_for_taxonomy ) but name is not correct. Please check organism name.\n";
      

      if (  @{ $data->{ sequences } } < @{ $data->{ seed_contigs_for_taxonomy }->{ $fig_id_for_taxonomy } } ) {
	$msg .= "less contigs than seed contigs, probably new version\n";
      }
      elsif (  @{ $data->{ sequences } } > @{ $data->{ seed_contigs_for_taxonomy }->{ $fig_id_for_taxonomy } } ) {
	$msg .= "more contigs than seed contigs, either older version or new genome project\n";
      }
      else{
	if  ( $data->{ seed_contigs_for_name } and scalar @{ $data->{ seed_contigs_for_name } } == $data->{ nr_matched_contigs } ){
	  $msg .= "same version, don't import\n";
	  $data->{ remove_candidate } = 1;
	}
      }
      
    }
    elsif (ref $data->{ fig_ids_for_tax_id } and scalar @{$data->{ fig_ids_for_tax_id }} > 1){ 
      $msg .= "Geome exists in different versions: ". join (" ", @{$data->{ fig_ids_for_tax_id }} )."\n";
    }
    else{
      # no match for name and taxonomy
      # check for contigs
      
      if ( $data->{ nr_matched_contigs} ){
	$msg .= "Contigs found in the SEED, but no match for name and taxonomy\n";
	$msg .= $data->{ matched_contigs };
      }
      else{
	$msg .= "probably new genome\n";
      }
    }
  }
  if ( $data->{ ncbi_nr_seq} ne  @{ $data->{ sequences } } ){
    $msg .= "NCBI has ".$data->{ ncbi_nr_seq}." sequences and " . $data->{ ncbi_nr_projects} . " projects for ".$data->{ ncbi_genome}." in the Taxonomy Browser!<hr>";
  
  my $user = get_user_from_job( $data );
    if ( $user eq "batch"){
       $data->{ remove_candidate } = 1;
    }

  }
  else{
    $msg .= "<br>NCBI has ".$data->{ ncbi_nr_seq}." sequences and " . $data->{ ncbi_nr_projects} . " projects for ".$data->{ ncbi_genome}." in the Taxonomy Browser!<hr>";
    
    my $user = get_user_from_job( $data );
    if ( $user eq "batch"){
      $data->{ remove_candidate } = 1;
    }
    
  }
  
  $msg .= "NCBI has ".$data->{ ncbi_nr_seq}." sequences and " . $data->{ ncbi_nr_projects} . " projects for ".$data->{ ncbi_genome}." in the Taxonomy Browser!<hr>";
  
  if ( $data->{ ncbi_genome } ne $data->{ name } ){
    $msg .= "Different genome name at the NCBI for this taxonomy id: <b> ".$data->{ ncbi_genome }."</b>\n"; 
    
    my $user = get_user_from_job( $data );
    if ( $user eq "batch"){
       $data->{ remove_candidate } = 1;
    }

  } 

  $data->{ message } = $msg;
  return $data;
}


sub get_user_from_job{
  my ( $data ) = @_;
  my $user = "";
  
  my $dir = $data->{job_dir};

  if ( -f $dir."/USER" ) {
    open (FILE , "$dir/USER") or die "Can't open $dir/USER\n";
    $user = <FILE>;
    close FILE;
    chomp $user;
  }

  return $user;
}


sub _unspace{
  my ($line) =@_;
  my @words = split (/\s+/ , $line );
  $line = join( " ", @words);
  return $line;
}


1;
