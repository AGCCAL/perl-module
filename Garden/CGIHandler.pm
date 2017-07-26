package Garden::CGIHandler;

use 5.010;
use strict;
use warnings;
use Data::Dumper;
use HTTP::Request;

our $VERSION = '1.0.0';
$VERSION = eval $VERSION;  # see L<perlmodstyle>

sub request { shift->{request}}

sub send_response {
  my($self, $response) = @_;
  
  print "Status: ".$response->as_string."\n";
}

sub new {
  my $class = shift;
      
  my $request = HTTP::Request->new;
  
  $request->method($ENV{REQUEST_METHOD});
  
  $request->header('Content-Length', $ENV{CONTENT_LENGTH});
  $request->header('Content-Type', $ENV{CONTENT_TYPE});
  my $proto = 'https';
  foreach my $env (keys %ENV) {
    my $header = $env;
    if ($header =~ s/^(HTTPS?)_//) {
      $proto = 'https' if $1 eq 'HTTPS';
      $header =~ s/_/-/g;
      $header = lc($header);
      $request->header($header, $ENV{$env});
    }
  }
  
  my $uri = sprintf("%s://%s", $proto, $ENV{SERVER_NAME});
  if (($proto eq 'http' && $ENV{SERVER_PORT} != 80) ||
      ($proto eq 'https' && $ENV{SERVER_PORT} != 443)) {
    $uri = sprintf("%s:%d", $uri, $ENV{SERVER_PORT});
  }
  $uri = sprintf("%s%s", $uri, $ENV{SCRIPT_NAME});
  if ((defined($ENV{PATH_INFO})) && (length($ENV{PATH_INFO}) > 0)) {
    $uri = sprintf("%s/%s", $uri, $ENV{PATH_INFO});
  }
  if (length($ENV{QUERY_STRING}) > 0) {
    $uri = sprintf("%s?%s", $uri, $ENV{QUERY_STRING});
  }
  $request->uri($uri);
  
  
  while (<STDIN>) {
    $request->add_content($_);
  }
  
  bless {
    request => $request
  }, $class;
}

1;
__END__
