
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Write the export files for this completed job.
#-----------------------------------------------------------------------

use Data::Dumper;
use Carp;
use strict;
use FIGV;
use FIG;
use FIG_Config;
use FileHandle;
use File::Basename;
use GenomeMeta;
use GenomeTypeObject;
use SeedExport;
use Job48;
use JSON::XS;
our $has_kbinvoke;
eval {
    require KBInvoke;
    $has_kbinvoke = 1;
};
    

@ARGV == 1 or die "Usage: $0 job-dir\n";

my $jobdir = shift;

-d $jobdir or die "$0: job dir $jobdir does not exist\n";

my $job = new Job48($jobdir);
$job or die "cannot create job for $jobdir";

my $hostname = `hostname`;
chomp $hostname;

my $genome = &FIG::file_head("$jobdir/GENOME_ID");
chomp $genome;
$genome =~ /^\d+\.\d+/ or die "$0: Cannnot find genome ID for jobdir $jobdir\n";

my $meta = new GenomeMeta($genome, "$jobdir/meta.xml");

my $genome_dir = "$jobdir/rp/$genome";

my $export_dir = "$jobdir/download";
&FIG::verify_dir($export_dir);

$meta->set_metadata("export.hostname", $hostname);
$meta->set_metadata("export.running", "yes");
$meta->set_metadata("status.export", "in_progress");

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# We're done with genome processing here so submit the model build.
#-----------------------------------------------------------------------
if ($meta->get_metadata("model_build.enabled")) {

    if (!$has_kbinvoke)
    {
	warn "KBInvoke module not available; model build not requested";
	$meta->add_log_entry($0, "KBInvoke module not available; model build not requested");
    }
    else
    {
	my $username;
	if (open(U, "<", "$jobdir/USER"))
	{
	    $username = <U>;
	    chomp $username;
	    close(U);
	}
	else
	{
	    die "Cannot open $jobdir/USER: $!";
	}

	my $link = "http://modelseed.org/model/$username/modelseed/$genome";

	eval {
	    warn "request token for $username\n";
	    my $token = KBInvoke::rast_server_login($username,
						    $FIG_Config::nexus_override_login,
						    $FIG_Config::nexus_override_passwd);
	    warn "Got token $token\n";
	    
	    my $k = KBInvoke->new("https://p3.theseed.org/services/ProbModelSEED", "ProbModelSEED", $token);
	    
	    my $res = $k->call("ModelReconstruction", { genome => "RAST:$genome" });
	    
	    $meta->add_log_entry($0, ['model reconstruction requested', $res]);
	    
	    if (defined($link)) {
		$meta->set_metadata("model_build.viewing_link", $link) ;
	    }
	    
	    $meta->set_metadata("model_build.user_name", $username) ;
	    $meta->set_metadata("model_build.reconstruction_id", $res);
	};
	if ($@)
	{
	    warn "Error submitting reconstruction: $@";
	    $meta->add_log_entry($0, "Error submitting reconstruction: $@");
	}
	    
    }
}



#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Before writing the export, perform a final check on the genome directory.
# If this is not intended for SEED use, we pass the -no_fatal_stops
# option in order to have jobs not fail in the face of some of the
# genes with bad stops that are currently being generated.
#
# If keep_genecalls is enabled, skip the verify entirely.
#-----------------------------------------------------------------------

my $keep_genecalls = $meta->get_metadata("keep_genecalls");

my $genetic_code = $meta->get_metadata("genome.genetic_code");

unless ($keep_genecalls)
{
    my @verify_cmd = ("$FIG_Config::bin/verify_genome_directory");
    
    if (!($meta->get_metadata("import.candidate")))
    {
	push(@verify_cmd, "-no_fatal_stops");
    }
    if ($genetic_code ne '')
    {
	push(@verify_cmd, "-code=$genetic_code");
    }
    push(@verify_cmd, $genome_dir);
    
    my $verify_cmd = "@verify_cmd > $jobdir/rp.errors/verify_genome_directory.report 2>&1";
    
    $meta->add_log_entry($0, "Verifying with command: $verify_cmd");
    my $rc = system($verify_cmd);
    
    if ($rc != 0)
    {
	$meta->set_metadata("genome.directory_verification_status", "failed_$rc");
	&fatal("verify_genome_directory failed with rc=$rc");
    }
    
    $meta->set_metadata("genome.directory_verification_status", "success");
    $meta->add_log_entry($0, "Verification succeeded");
}
else
{
    $meta->set_metadata("genome.directory_verification_status", "skipped");
}

if (!$meta->get_metadata("correction.frameshifts"))
{
    #
    # correct_frameshifts appends to an existing file.
    #
    if (! -s "$genome_dir/possible.frameshifts")
    {
	$meta->add_log_entry($0, "Computing possible frameshifts");
	# unlink("$genome_dir/possible.frameshifts");
	system("$FIG_Config::bin/correct_frameshifts", "-justMark", $genome_dir);
    }
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Save job signature data for later identical-run replication.
#
# Don't do this if the signature file already exists; rp_write_exports
# may be run multiple times and we only want to do this once. It might
# be better placed somewhere else, but this is a convenient place
# for it.
#-----------------------------------------------------------------------
my $sig_file = "$jobdir/JOB_SIGNATURE";
if (! -f $sig_file || -s $sig_file == 0)
{
    my $rc = system("$FIG_Config::bin/save_job_signature $jobdir > $jobdir/rp.errors/save_job_signature.out 2>&1");
    if ($rc != 0)
    {
	$meta->add_log_entry($0, "Error saving job signature rc$rc");
    }
    else
    {
	my $sig = &FIG::file_head($sig_file, 1);
	chomp $sig;
	$meta->add_log_entry($0, "Job signature saved: $sig");
    }
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Write the go term mappings.
#-----------------------------------------------------------------------
my $rc = system("$FIG_Config::bin/write_go_mappings $genome_dir > $genome_dir/go.mappings"); 
if ($rc == 0)
{
    $meta->add_log_entry($0, "wrote go mappings");
}
else
{
    $meta->add_log_entry($0, "error $rc invoking $FIG_Config::bin/write_go_mappings $genome_dir > $genome_dir/go.mappings");
}


$meta->add_log_entry($0, "Writing exports to $export_dir");


my @export_types = qw(genbank GTF embl gff);
my @strip_ec_flag = (0, 1);
my %export_names = (genbank => "Genbank",
		    GTF => "GTF",
		    embl => "EMBL",
		    gff => "GFF3",
		    );
my %export_suffix = (genbank => "gbk",
		     GTF => "gtf",
		     embl => "embl",
		     gff => "gff",
		    );


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# If we have not yet indexed the contigs, do that here. Speeds a lot
# of stuff up.
#-----------------------------------------------------------------------
if (! -f "$genome_dir/contigs.btree")
{
    my $rc = system("$FIG_Config::bin/make_fasta_btree",
		    "$genome_dir/contigs",
		    "$genome_dir/contigs.btree",
		    "$genome_dir/contig_len.btree");
    if ($rc != 0)
    {
	warn "make_fasta_btree failed with rc $rc\n";
    }
}

open(I, ">$export_dir/index");

my $figv = FIGV->new($genome_dir);
my $rasttk_genome = &FIG::genome_id_to_genome_object($figv, $genome);
#$rasttk_genome->prepare_for_return();
my $rasttk_file = "$export_dir/$genome.gto";
my $json = JSON::XS->new->pretty(1);
open(J, ">", $rasttk_file);
print J $json->encode($rasttk_genome);
close(J);
print I "$genome.gto\tGenome Typed Object (GTO)\n";

for my $strip_ec (@strip_ec_flag)
{
    my $strip_fn_part = $strip_ec ? ".ec-stripped" : "";
    my $strip_msg = $strip_ec ? " (EC numbers stripped)" : "";
    for my $type (@export_types)
    {
	$meta->add_log_entry($0, "Exporting type $type");

	my $filename = "$genome${strip_fn_part}.$export_suffix{$type}";
	
	my $p = {
	    virtual_genome_directory => $genome_dir,
	    genome => $genome,
	    directory => "$export_dir/",
	    filename => "$export_dir/$filename",
	    export_format => $type,
	    strip_ec => $strip_ec,
	};
	eval {
	    SeedExport::export($p);
	    print I "$filename\t$export_names{$type}$strip_msg\n";
	};
	if ($@)
	{
	    &fatal("Error exporting type $type of genome $genome to $export_dir: $@");
	}
    }
}

#
# Also export Artemis format; this uses the RASTtk exporter.
# We may swing everything to that at some point.
#

system("rast-export-genome",
       "-i", $rasttk_file,
       "-o", "$export_dir/$genome.merged.gbk",
       "genbank_merged");
print I "$genome.merged.gbk\tGenbank merged (for use in e.g. Artemis)\n";
symlink("$genome_dir/contigs", "$export_dir/$genome.contigs.fa");
print I "$genome.contigs.fa\tDNA Contigs\n";
    
I->autoflush(1);


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Also export the entire genome directory as a tgz file.
#-----------------------------------------------------------------------
my @cmd = ("tar", "-C", "$jobdir/rp", "-z", "-c", "-f", "$export_dir/$genome.tgz", $genome);
my $rc = system(@cmd);
if ($rc != 0)
{
    &fatal("error $rc creating tarfile with: @cmd");
}

print I "$genome.tgz\tGenome directory\n";


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# And the fasta files.
#-----------------------------------------------------------------------
###...generating '.faa' from scratch is wasteful, and gets "special" proteins wrong
### $genetic_code = 11 if $genetic_code eq '';
### $rc = system("$FIG_Config::bin/get_fasta_for_tbl_entries -code=$genetic_code $genome_dir/contigs < $genome_dir/Features/peg/tbl > $export_dir/$genome.faa");

@cmd = ("cp", "$genome_dir/Features/peg/fasta", "$export_dir/$genome.faa");
$rc = system(@cmd);
if ($rc != 0)
{
    warn "error $rc writing faa export\n";
}
print I "$genome.faa\tAmino-Acid FASTA file\n";


$rc = system("$FIG_Config::bin/get_dna $genome_dir/contigs $genome_dir/Features/peg/tbl > $export_dir/$genome.fna");
if ($rc != 0)
{
    warn "error $rc writing fna export\n";
}
print I "$genome.fna\tNucleic-Acid FASTA file\n";

close(I);


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Write the spreadsheets.
#-----------------------------------------------------------------------
$rc = system("$FIG_Config::bin/rp_write_spreadsheets", $jobdir);
if ($rc = 0)
{
    warn "error $rc writing spreadsheets\n";
}

$meta->set_metadata("export.running", "no");
$meta->set_metadata("status.export", "complete");

exit(0);



sub fatal
{
    my($msg) = @_;

    if ($meta)
    {
	$meta->add_log_entry($0, ['fatal error', $msg]);
	$meta->set_metadata("export.running", "no");
	$meta->set_metadata("status.export", "error");
    }
    croak "$0: $msg";
}
    
