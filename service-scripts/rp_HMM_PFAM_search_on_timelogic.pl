#provide job dir as first argument and genome id as second argument
my $jobdir = shift(@ARGV);
my $genome = shift(@ARGV);
$input_file = $jobdir."/rp/$genome/Features/peg/fasta";
$output_file = $jobdir."/$genome_PFAM_HMM_search_results.txt";
$command = "/decypher/cli/bin/dc_template_rt -template hmm_aa_vs_hmm -query $input_file -targ HMMs_of_global_pfam > $output_file";
system $command;
