package Garden;

use 5.010;
use strict;
use warnings;
use JSON;
use HTTP::Response;
use Data::Dumper;
use Crypt::Eksblowfish::Bcrypt qw(en_base64);

our $VERSION = '2.0.0';

sub params { shift->{params}}
sub request { shift->{request}}
sub mode { shift->{mode}}

sub add_to_log {
  my $self = shift;
  my @args = @_;
  open LOG, ">>/logs/garden.log" or die "couldn't open logfile";
  print LOG @args;
  print LOG "\n";
  close LOG;
}

use DBI;
use Text::Caml;


use constant
{
  STATE_UNPUBLISHED => 0,
  STATE_PUBLISHED => 1,
  STATE_ARCHIVED => 2,
};

sub redirect_via_login
{
  my ($self, $uri) = @_;
  
  my $resp = HTTP::Response->new(302);
  $uri =~ s:=:%3d:g;
  $uri =~ s:&:%26:g;
  $uri =~ s:\?:%3f:g;
  $uri =~ s/^http:/https:/;
  $resp->header("Location", "./login?redirect=".$uri);
  return $resp;
}

sub database
{
  my $self = shift;
  unless (defined($self->{dbh}))
  {
    my $database = "assessmentgarden_org_";
    my $driver = "mysql";
    my $dsn = "DBI:$driver:dbname=$database";
    
    my $userid = "assessmentgarden";
    my $password = "bDsi1$wNxxya5Qg5";
    my $dbh = DBI->connect($dsn, $userid, $password, { RaiseError => 1 }) or die $DBI::errstr;
    
    $self->{dbh} = $dbh;
  }
  return $self->{dbh};
}

sub caml
{
  my $caml = Text::Caml->new;
  $caml->set_templates_path("templates");
  return $caml;
}

sub banner
{
  my ($self, $user_id) = @_;
  
  my $dbh = $self->database;
  my $caml = $self->caml;
  
  my $sth = $dbh->prepare("select real_name, email, ucid from user where user_id = ?");
  $sth->bind_param(1,$user_id);
  $sth->execute;
  my $row = $sth->fetch;
  unless (defined($row))
  {
    return undef;
  }
  
  my ($real_name, $email, $ucid) = @{$row};
  my $settings;
  $settings->{real_name} = $real_name;
  $settings->{email} = $email;
  $settings->{ucid} = $ucid;
  $settings->{user_id_is_an_admin} = $self->user_id_is_an_admin($user_id);

  my $output = $caml->render_file('banner_logged_in', $settings);



  #fixme: not sure if we want to do this — need to test with a username containing emoji.
  utf8::encode($output);
  
  
  return $output;
}


sub salty
{
  my $self = shift;
  my $iterations = shift;
  
  my $cookie = "";
  for (my $i = 0; $i < $iterations; $i++)
  {
    my $rand = int(rand(65536*65536));
    $cookie .= pack("h8",sprintf("%08x",$rand));
  }
  $cookie = en_base64($cookie);
  return $cookie;
}

sub hex_token
{
  my $self = shift;
  my $iterations = shift;
  
  my $token = "";
  for (my $i = 0; $i < $iterations; $i++)
  {
    my $rand = rand(65536);
    $token .= sprintf("%04x",$rand);
  }
  return $token;
}

sub get_user_id_from_cookie
{
  my $self = shift;
  my $cookies = $self->request->header("Cookie");
  
  if (length($cookies))
  {
    my @cookies = split (/;/,$cookies);
    foreach my $cookie (@cookies)
    {
      my ($name,$value) = split(/=/,$cookie);
      $name =~ s:^\s*(\S*)\s*$:$1:;
      $value =~ s:^\s*(\S*)\s*$:$1:;
      if ($name eq "session_id")
      {
        my $dbh = $self->database;
        my $sth = $dbh->prepare("select user_id from session where cookie = ?;");
        $sth->bind_param(1,$value);
        my $ret = $sth->execute;
        my $row = $sth->fetch();
        my $user_id = $row->[0];
        if (defined($user_id))
        {
          $sth = $dbh->prepare("update user set last_seen = (select datetime('now')) where user_id = ?");
          $sth->bind_param(1, $user_id);
          $sth->execute;
        }
        
        return $user_id;
      }
    }
  }
  return undef;
}


sub group_ids_for_group_id
{
  my ($self, $group_id) = @_;
  my @groups;

  if (defined($group_id))
  {
    my %groups;
    my $dbh = $self->database;
    my $sth = $dbh->prepare("select group_id from group_member where member_id = ? and member_type = 1;");
    $sth->bind_param(1,$group_id);
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my $group_id = $row->[0];
      $groups{$group_id} = 1;
    }
    
    
    foreach my $group_id (keys %groups)
    {
      my @super_groups = $self->group_ids_for_group_id($group_id);
      foreach my $super_group_id (@super_groups)
      {
        $groups{$super_group_id} = 1;
      }
    }
    
    foreach my $group_id (keys %groups)
    {
      push(@groups, $group_id);
    }
  }

  return @groups;

}



sub group_ids_for_user_id
{
  my ($self, $user_id) = @_;
  my @groups;
  
  if (defined($user_id))
  {
    my %groups;
    my $dbh = $self->database;
    my $sth = $dbh->prepare("select group_id from group_member where member_id = ? and member_type = 0;");
    $sth->bind_param(1,$user_id);
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my $group_id = $row->[0];
      $groups{$group_id} = 1;
    }
    
    
    foreach my $group_id (keys %groups)
    {
      my @super_groups = $self->group_ids_for_group_id($group_id);
      foreach my $super_group_id (@super_groups)
      {
        $groups{$super_group_id} = 1;
      }
    }
    
    foreach my $group_id (keys %groups)
    {
      push(@groups, $group_id);
    }

  }

  return @groups;
}


sub group_id_is_member_of_group
{
  my ($self, $sub_group_id, $group_id) = @_;
  if (defined($sub_group_id))
  {
    my @groups;
    
    my $dbh = $self->database;
    my $sth = $dbh->prepare("select group_id from group_member where member_id = ? and member_type = 1;");
    $sth->bind_param(1,$sub_group_id);
    $sth->execute;
    
    while (my $row = $sth->fetch)
    {
      my $a_group_id = $row->[0];
      if ($a_group_id == $group_id)
      {
        return 1;
      }
      push (@groups, $a_group_id);
    }
    
    foreach my $sub_group_id (@groups)
    {
      if ($self->group_id_is_member_of_group($sub_group_id, $group_id))
      {
        return 1;
      }
    }
  }
  return 0;
}

sub user_id_is_member_of_group
{
  my ($self, $user_id, $group_id) = @_;
  
  if (defined($user_id))
  {
    my @groups;
    my $dbh = $self->database;
    my $sth = $dbh->prepare("select group_id from group_member where member_id = ? and member_type = 0;");
    $sth->bind_param(1,$user_id);
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my $a_group_id = $row->[0];
      if ($a_group_id == $group_id)
      {
        return 1;
      }
      push (@groups, $a_group_id);
    }
    
    foreach my $sub_group_id (@groups)
    {
      if ($self->group_id_is_member_of_group($sub_group_id, $group_id))
      {
        return 1;
      }
    }
  }

  return 0;
}

sub user_id_is_an_admin
{
  my $self = shift;
  my $user_id = shift;
  
  return $self->user_id_is_member_of_group($user_id, 0);
}

sub clean_input
{
  my ($self, $text) = @_;

  $text=~s:&:&amp;:g;

  $text=~s:\<:&lt;:g;
  $text=~s:\>:&gt;:g;

  $text=~s:\":&quot;:g;

  $text=~s:\':&apos;:g;

  $text=~s:\r:\n:g;

  return $text;

}



sub test_params {
  my($self, $required, $code) = @_;
  $code = 400 unless defined $code;
  return $self->failure_response("invalid parameters", $code) unless exists $self->{params};
  foreach my $key (@$required) {
    unless (defined $self->params->{$key}) {
      return $self->failure_response("invalid parameters", $code)
    }
  }
  return undef;
}

sub test_method {
  my($self, $method) = @_;
  return $self->failure_response('invalid method', 400) unless $self->request->method eq $method;
  return undef;
}

sub response_as_json {
  my($self, $status, $payload) = @_;
  my $resp = HTTP::Response->new($status);
  $resp->content_type("application/json");
  $resp->content_type_charset("UTF-8");
  my $json_payload = encode_json($payload);
  $resp->content($json_payload);
  return $resp;
}


sub response_as_html {
  my($self, $payload) = @_;
  my $resp = HTTP::Response->new(200);
  $resp->content_type("text/html");
  $resp->content_type_charset("UTF-8");
  $resp->content($payload);
  return $resp;
}


sub response_as_pdf {
  my($self, $payload) = @_;
  my $resp = HTTP::Response->new(200);
  $resp->content_type("application/pdf");
  $resp->content_length(length($payload));
  $resp->content($payload);
  return $resp;
}

sub response_as_csv {
  my($self, $payload, $filename) = @_;
  my $resp = HTTP::Response->new(200);
  $resp->content_type("text/csv");
  $resp->header("Content-disposition"=>"attachment;filename=$filename");
  $resp->content_length(length($payload));
  $resp->content($payload);
  return $resp;
}


sub failure_response {
  my($self, $reason, $code) = @_;
  $code = 500 unless defined $code;
  return $self->response_as_json($code, {success => 0, reason => $reason});
}

sub success_response {
  my($self, %payload) = @_;
  $payload{success} = 1;
  return $self->response_as_json(200, \%payload);
}

sub new {
  my($class, %params) = @_;
  $params{'decode-content'} = 1 unless exists $params{'decode-content'};
  $params{mode} = 'production' unless exists $params{mode};
  my $self = bless {%params}, $class;
  if (exists $params{request}) {
    if ($params{'decode-content'}) {
      my $content = $params{request}->content;
      if (length($content) > 0) {
        $self->{params} = decode_json($content);
      }
    }
    else
    {
      if (defined($params{request}->content)) {
        foreach my $part (split(/&/,$params{request}->content)) {
          $part =~ s/\+/ /g;
          my ($key, $value) = split(/=/,$part);
          s/(\%([0-9a-f]{2}))/pack("H2",$2)/egi for ($key,$value);
          $self->{params}->{$key}=$value;
        }
      }
    }
    
    if (defined($params{request}->uri) && $params{request}->uri =~ /\?(.*)$/) {
      foreach my $part (split(/&/,$1)) {
        $part =~ s/\+/ /g;
        my ($key, $value) = split(/=/,$part);
        s/(\%([0-9a-f]{2}))/pack("H2",$2)/egi for ($key,$value);
        $self->{params}->{$key}=$value;
      }
    }
    
  }
  
  $self->{dbh} = undef;
  
  return $self;
}


1;
__END__
