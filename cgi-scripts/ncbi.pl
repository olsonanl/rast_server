#!/vol/cee-2007-1108/linux-debian-x86_64/bin/perl
use LWP::UserAgent;
use Data::Dumper;
use XML::LibXML;
use strict;
use Data::Dumper;
use JSON::Any;

my %param;
while (<>)
{
chomp;
if (/^([^=]*)=(.*)/)
{
$param{$1} = $2;
}
}

print "Content-type: text/xml\n\n";

my $tax_id = $param{tax_id};
my $info = get_taxonomy_data($tax_id);

print JSON::Any->objToJson($info);

exit 0;

sub get_taxonomy_data
{
    my($tax_id) = @_;

    my $ua = LWP::UserAgent->new();

    my $res = url_get($ua, "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=taxonomy&id=$tax_id&report=sgml&mode=text");
    if ($res->is_success)
    {
	my $ent = {};
	my $doc = XML::LibXML->new->parse_string($res->content);
#	print STDERR $res->content;
	my $lin = $doc->findvalue('//Taxon/Lineage');

	my $sci = $doc->findvalue('/TaxaSet/Taxon/ScientificName');

	my @lin = split(/;\s+/, $lin);
	# print STDERR Dumper(\@lin, $lin[0]);
	shift(@lin) if $lin[0] eq 'cellular organisms';
	# print STDERR Dumper(\@lin);
	push(@lin, $sci) if @lin == 0;
	$lin = join("; ", @lin);

	# print STDERR "\n\nSCI=$sci lin=$lin\n";

	if ($lin eq '')
	{
	    # Empty lineage means we picked a toplevel domain. Pull the scentific name in there
	    $lin = $sci;
	}
	my $domain = $lin;
	$domain =~ s/;.*$//;
	my $code = $doc->findvalue('//Taxon/GeneticCode/GCId');

	if ($sci =~ /^(\S+)\s+(\S+)(\s+(.*))?\s*$/)
	{
	    $ent->{scientific_name} = $sci;
	    $ent->{genus} = $1;
	    $ent->{species} = $2;
	    $ent->{strain} = "" . $4;
	}
	
	$ent->{domain} = $domain;
	$ent->{taxonomy} = $lin;
	$ent->{genetic_code} = $code;
#print Dumper($res->content, $ent);
	return $ent;
    }
    return undef;
}

=head3 url_get

Use the LWP::UserAgent in $self to make a GET request on the given URL. If the
request comes back with one of the transient error codes, retry.

=cut

sub url_get
{
    my($ua, $url) = @_;

    my @retries = (1, 5, 20);

    my %codes_to_retry = map { $_ => 1 } qw(408 500 502 503 504);

    my $res;
    while (1)
    {
	$res = $ua->get($url);

	if ($res->is_success)
	{
	    return $res;
	}

	my $code = $res->code;
	if (!$codes_to_retry{$code})
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
