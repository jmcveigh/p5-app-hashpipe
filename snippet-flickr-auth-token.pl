# get an auth_token for use with flickr_upload.
# read about the flickr API here:
# http://www.flickr.com/services/api/
use Flickr::API;
use Flickr::Upload;

# get a flickr API key here:
# http://www.flickr.com/services/api/keys/
my $flickr_key = 'dd70e9458910f1638a30992e41feef08';
my $flickr_secret = '5e4c8975f1431500';

my $ua = Flickr::Upload->new(
{
'key' => $flickr_key,
'secret' => $flickr_secret
});
$ua->agent( "Flickr::Upload::SOD" );

# get a "frob"
my $frob = getFrob( $ua );
print "FROB:$frob;\n";

my $url = $ua->request_auth_url('write', $frob);
print "1. Enter the following URL into your browser\n\n",
"$url\n\n",
"2. Follow the instructions on the web page\n",
"3. Hit when finished.\n\n";

<>;

my $auth_token = getToken( $ua, $frob );
die "Failed to get authentication token!" unless defined $auth_token;

print "Token is $auth_token\n";

sub getFrob {
my $ua = shift;

my $res = $ua->execute_method("flickr.auth.getFrob");
return undef unless defined $res and $res->{success};

# FIXME: error checking, please. At least look for the node named 'frob'.
return $res->{tree}->{children}->[1]->{children}->[0]->{content};
}

sub getToken {
my $ua = shift;
my $frob = shift;

my $res = $ua->execute_method("flickr.auth.getToken",
{ 'frob' => $frob ,
'perms' => 'write'} );
return undef unless defined $res and $res->{success};

# FIXME: error checking, please.
return $res->{tree}->{children}->[1]->{children}->[1]->{children}->[0]->{content};
} 