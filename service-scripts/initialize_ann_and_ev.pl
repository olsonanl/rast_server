
$usage = "usage: initialize_attr_and_ev Dir";

(
 ($dir = shift @ARGV)
)
    || die $usage;

if (-s "$dir/assigned_functions")
{ 
    &create_ann($dir,"assigned_functions","from original annotations",0); 
}

if (-s "$dir/proposed_functions")
{ 
    &create_ann($dir,"proposed_functions","based on FIGfams",1); 
}

if (-s "$dir/proposed_non_ff_functions")
{ 
    &create_ann($dir,"proposed_non_ff_functions","based on unreliable automated assignments",2); 
}

&create_ev_attributes($dir);

sub create_ann 
{
    my($dir,$file,$note,$delta) = @_;

    if (open(ANN,">>$dir/annotations") && open(ASSIGN,"<$dir/$file"))
    {
	$now = time;
	$ts = int($now + $delta - (24 * 60 * 60 * (-M $file)));

	while (defined($_ = <ASSIGN>))
	{
	    if ($_ =~ /^(\S+\.peg\.\d+)\t(\S.*\S)/)
	    {
		print ANN join("\n",($1,$ts,"rapid_propagation","Set function to",$2,$note)),"\n//\n";
	    }
	}
	close(ASSIGN);
	close(ANN);
    }
}

sub create_ev_attributes {
    my($dir) = @_;
    my($i,$j,$sub);

    my %found = map { ($_ =~ /^(\S+)/) ? ($1 => 1) : () } `cut -f1 $dir/found`;

    if (open(BINDINGS,"<$dir/Subsystems/bindings") && 
	open(TBL,"<$dir/Features/peg/tbl") &&
	open(ATTR,">$dir/evidence.codes"))
    {
	my %by_contig;
	while (defined($_ = <TBL>))
	{
	    if ($_ =~ /^(\S+)\t(\S+)_(\d+)_(\d+)\s/)
	    {
		push(@{$by_contig{$2}},[$1,($3 + $4) / 2]);
	    }
	}
	close(TBL);

	my %close;
	foreach $contig (keys(%by_contig))
	{
	    my $x = $by_contig{$contig};
	    my @entries = sort { $a->[1] <=> $b->[1] } @$x;
	    for ($i=0; ($i < @entries); $i++)
	    {
		my $close = [];
		my($peg,$loc) = @{$entries[$i]};
		for ($j=$i-1; ($j >= 0) && (($loc - $entries[$j]->[1]) <= 5000); $j--)
		{
		    push(@$close,$entries[$j]->[0]);
		}
		for ($j=$i+1; ($j < @entries) && (($entries[$j]->[1] - $loc) <= 5000); $j++)
		{
		    push(@$close,$entries[$j]->[0]);
		}
		$close{$peg} = $close;
	    }
	}

	while (defined($_ = <BINDINGS>))
	{
	    chop;
	    my($sub,$role,$peg) = split(/\t/,$_);
	    $hash{$sub}->{$role}->{$peg} = 1;
	}
	close(BINDINGS);

	foreach $sub (keys(%hash))
	{
	    my $roleH = $hash{$sub};
	    my(%idu,%isu,%icw,%in_sub);

	    foreach my $role (keys(%$roleH))
	    {
		my $pegH = $roleH->{$role};
		my @pegs = keys(%$pegH);

		foreach my $peg (@pegs)
		{
		    if (@pegs > 1) 
		    {
			$idu{$peg} = @pegs - 1;
		    }
		    else
		    {
			$isu{$peg} = 1;
		    }
		    $in_sub{$peg} = 1;
		}

		foreach my $peg (@pegs)
		{
		    delete($found{$peg});
		    my $x = $close{$peg};

		    for ($i=0,$icw=0; ($i < @$x); $i++)
		    {
			if ($in_sub{$x->[$i]}) { $icw++; }
		    }
		    if ($icw > 0)
		    {
			print ATTR "$peg\ticw($icw);$sub\n";
		    }
		    elsif ($isu{$peg})
		    {
			print ATTR "$peg\tisu;$sub\n";
		    }
		    else
		    {
			print ATTR "$peg\tidu($idu{$peg});$sub\n";
		    }
		}
	    }
	}
	foreach $peg (keys(%found))
	{
	    print ATTR "$peg\tff\n";
	}
	close(ATTR);
    }
}

