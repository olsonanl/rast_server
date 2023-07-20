#
# Chunk a fasta file into pieces suitable for cluster BLAST calculations.
#
# We are provided the NR and peg.synonyms files that should be used for this.
#
# Usage: rp_chunk_sims fasta-file nr peg.synonyms sims-job-dir
#
# We write a file task.list into sims-job-dir that contains the list of work units.
#
# The work units will write raw sims into sims-job-dir/sims.raw
#

use strict;
use File::Basename;
use Cwd 'abs_path';

my $usage = "Usage: $0 [-size max-size] [-include-self] [-self-fasta fasta-file] fasta-file nr peg.synonyms sims-job-dir";

my $max_size = 10_000;
my $include_self = 0;
my $self_fasta;

while (@ARGV > 0 and $ARGV[0] =~ /^-/)
{
    my $arg = shift @ARGV;
    if ($arg =~ /^-size/)
    {
	$max_size = shift @ARGV;
    }
    elsif ($arg =~ /^-include-self/)
    {
	$include_self++;
    }
    elsif ($arg =~ /^-self-fasta/)
    {
	$self_fasta = shift @ARGV;
    }
    else
    {
	die $usage;
    }
}

@ARGV == 4 or die $usage;

my $fasta = shift;
my $nr_file = shift;
my $pegsyn = shift;
my $jobdir = shift;

if (!defined($self_fasta))
{
    $self_fasta = $fasta;
}

-d $jobdir or mkdir $jobdir or die "Cannot mkdir $jobdir: $!\n";

my $next_task = 1;
my $last_task;

my $task_file = "$jobdir/task.list";
my $input_dir = "$jobdir/sims.in";
my $output_dir = "$jobdir/sims.raw";
my $error_dir = "$jobdir/sims.err";

-d $input_dir or mkdir $input_dir or die "Cannot mkdir $input_dir: $!\n";
-d $output_dir or mkdir $output_dir or die "Cannot mkdir $output_dir: $!\n";
-d $error_dir or mkdir $error_dir or die "Cannot mkdir $error_dir: $!\n";

my $flags = "-m 8 -e 1.0e-5 -FF -p blastp";

my @fasta_files = ($fasta);

open(TASK, ">$task_file") or die "Cannot write $task_file: $!";

#
# Buzz through once to ensure we can open them.
#
for my $file (@fasta_files, $self_fasta)
{
    open(F, "<$file") or die "Cannot open $file: $!\n";
    close(F);
}


#
# Prepare and submit self-sims.
#
if ($include_self)
{
    #
    # hack - leftover from legacy chunking code that wanted multiple
    # directories of sims. we need to direct the output all to the
    # same directory.
    #
    my $base = basename($fasta);
    my $file = abs_path($self_fasta);

    system("$FIG_Config::ext_bin/formatdb", "-p", "t", "-i", $file);
    my $task = $next_task++;
    print TASK join("\t", $task, $file, $file, $flags,
		    "$output_dir/$base/out.$task", "$error_dir/$base/err.$task"), "\n";
}

for my $file (@fasta_files)
{
    my $cur_size = 0;
    my $cur_input = '';

    my $base = basename($file);
    $file = abs_path($file);
	
    open(F, "<$file") or die "Cannot open $file: $!\n";

    print "Chunk file $file\n";
    
    while (<F>)
    {
	if (/^>/)
	{
	    if ($cur_size >= $max_size)
	    {
		write_task($base, $input_dir, $output_dir, $error_dir, $cur_input);
		$cur_size = 0;
		$cur_input = '';
	    }
	    $cur_input .= $_;
	    $cur_size += length($_);
	}
	else
	{
	    $cur_input .= $_;
	    $cur_size += length($_);
	}
    }
    if ($cur_size >= 0)
    {
	write_task($base, $input_dir, $output_dir, $error_dir, $cur_input);
	$cur_size = 0;
	$cur_input = '';
    }
    close(F);
}

close(TASK);

print "tasks\t1\t$last_task\n";

#
# Write an input chunk to $dir.
# Write a line on the 
sub write_task
{
    my($base, $input_dir, $output_dir, $error_dir, $fasta) = @_;

    my $task = $next_task++;

    my $idir = "$input_dir/$base";
    my $odir = "$output_dir/$base";
    my $edir = "$error_dir/$base";

    -d $idir or mkdir($idir) or die "Cannot mkdir $idir: $!\n";
    -d $odir or mkdir($odir) or die "Cannot mkdir $odir: $!\n";
    -d $edir or mkdir($edir) or die "Cannot mkdir $edir: $!\n";

    my $in = "$idir/in.$task";
    my $out = "$odir/out.$task";
    my $err = "$edir/err.$task";
    
    open(I, ">$in") or die "Cannot write $in: $!";
    print I $fasta;
    close(I);
    print TASK join("\t", $task, $in, $nr_file, $flags, $out, $err), "\n";
    $last_task = $task;
}
