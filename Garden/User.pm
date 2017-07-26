package Garden::User;
use Garden;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt);
use strict;
use warnings;
use JSON;
use utf8;

our @ISA = qw(Garden);


sub process_invitation
{
  my ($self, $user_id, $invitation_id) = @_;
  if (defined($user_id) && defined($invitation_id))
  {
    my $dbh = $self->database;
    
    $dbh->prepare("begin transaction;")->execute;
    my $sth = $dbh->prepare("select group_id from invitation where invitation_id = ?");
    $sth->bind_param(1,$invitation_id);
    $sth->execute;
    
    while (my $row = $sth->fetch())
    {
      my $group_id = $row->[0];
      my $sth2 = $dbh->prepare("select count(*) from group_member where group_id = ? and member_id = ? and member_type = 0;");
      $sth2->bind_param(1, $group_id);
      $sth2->bind_param(2, $user_id);
      $sth2->execute;
      
      my $count = $sth2->fetch()->[0];
      if (!$count)
      {
        $sth2 = $dbh->prepare("insert into group_member values(?,?,0);");
        $sth2->bind_param(1, $group_id);
        $sth2->bind_param(2, $user_id);
        $sth2->execute;        
      }
    }
    
    $dbh->prepare("end transaction;")->execute;
  }  
}

sub has_accepted_tos
{
  my ($self, $user_id) = @_;

  my $dbh = $self->database;
  my $sth = $dbh->prepare("select count(*) from has_accepted_tos where user_id = ?;");
  $sth->bind_param(1,$user_id);
  $sth->execute;

  my $row = $sth->fetch();
  if (defined($row) && ($row->[0] == 1))
  {
    return 1;
  }
  return 0;
}

sub accept_tos
{
  my $self = shift;
  my $resp = undef;
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));

  my $agree = $self->params->{"agree"};

  if (defined($user_id))
  {
    my $dbh = $self->database;
    $dbh->prepare("begin transaction;");
    
    my $sth = $dbh->prepare("select count(*) from has_accepted_tos where user_id = ?;");
    $sth->bind_param(1,$user_id);
    $sth->execute;
    my $count = $sth->fetch->[0];
    
    if (!$count)
    {
      $sth = $dbh->prepare("insert into has_accepted_tos values (?,?);");
      $sth->bind_param(1,$user_id);
      $sth->bind_param(2,$agree);
      my $ret = $sth->execute;      
    }
    
    $dbh->prepare("end transaction;");

    $resp = HTTP::Response->new(302);
    $resp->header("Location", $self->params->{"redirect"});
    return $resp;

  }

  return $self->redirect_via_login("./");
}

sub check_password
{
  my ($self, $user_id, $password) = @_;
  
  my $dbh = $self->database;
  my $sth = $dbh->prepare("select salt, hash from user where user_id = ?;");
  $sth->bind_param(1,$user_id);
  $sth->execute;
  
  my $row = $sth->fetch();
  if (defined($row))
  {
    my ($salt, $hash) = @{$row};

    my $computed_old_hash = bcrypt($password,"\$2a\$10\$".$salt);
    if ($computed_old_hash eq $hash)
    {
      return 1;
    }
  }
  return 0;
}


sub logout
{
  my $self = shift;
  my $resp = undef;
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  if (defined($user_id))
  {
    my $dbh = $self->database;
    my $sth = $dbh->prepare("delete from session where user_id = ?;");
    $sth->bind_param(1,$user_id);
    my $ret = $sth->execute;
  }
  
  return $self->redirect_via_login("./");
}


sub update_password_for_user_id
{
  my $self = shift;
  my $user_id = shift;
  my $new = shift;
  
  my $dbh = $self->database;
  
  
  my $salt = $self->salty(4);
  my $salted_password = $salt.$new;
  my $digest = bcrypt($new,"\$2a\$10\$".$salt);
  
  my $update_sth = $dbh->prepare("update user set salt = ?, hash = ? where user_id = ?");
  $update_sth->bind_param(1, $salt);
  $update_sth->bind_param(2, $digest);
  $update_sth->bind_param(3, $user_id);
  my $ret = $update_sth->execute;
  return $ret;
}


sub update_settings
{
  my $self = shift;
  
  my $resp = $self->test_method("POST");
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    $resp = $self->redirect_via_login($self->request->uri);
  }
  
  $resp = $self->test_params(["realname","email","ucid","old","new"]) unless (defined($resp));
  if (defined($resp))
  {
    return $resp;
  }
  
  
  my $old = $self->params->{"old"};
  my $new = $self->params->{"new"};
  my $realname = $self->params->{"realname"};
  my $email = $self->params->{"email"};
  my $ucid = $self->params->{"ucid"};

  utf8::decode($old);
  utf8::decode($new);
  utf8::decode($realname);
  utf8::decode($email);
  utf8::decode($ucid);

  $email = $self->clean_input($email);
  $realname = $self->clean_input($realname);
  $ucid = $self->clean_input($ucid);


  my $dbh = $self->database;

  my $sth = $dbh->prepare("select count(*) from user where user_id != ? and email = ?");
  $sth->bind_param(1,$user_id);
  $sth->bind_param(2,$email);
  $sth->execute;
  my $count = $sth->fetch->[0];
  if ($count)
  {
    return $self->failure_response("Email address is already in use.", 403);
  }

  if (length($ucid))
  {
    $sth = $dbh->prepare("select count(*) from user where user_id != ? and ucid = ?");
    $sth->bind_param(1,$user_id);
    $sth->bind_param(2,$ucid);
    $sth->execute;
    $count = $sth->fetch->[0];
    if ($count)
    {
      return $self->failure_response("UC ID is already in use.", 403);
    }
  }


  if (length($old) || length($new))
  {
    unless ($self->check_password($user_id, $old))
    {
      return $self->failure_response("Old password does not match.",403);
    }

    if ($new eq $old)
    {
      return $self->failure_response("Old and new passwords must be different.",403);
    }

    if (length($new) < 8)
    {
      return $self->failure_response("New password must be a minimum of 8 characters.",403);
    }

    my $ret = $self->update_password_for_user_id($user_id, $new);
    if ($ret != 1)
    {
      return $self->failure_response("Database error. Please try later", 403);
    }
  }

  $sth = $dbh->prepare("update user set email = ?, ucid = ?, real_name = ? where user_id = ?");
  $sth->bind_param(1,$email);
  $sth->bind_param(2,$ucid);
  $sth->bind_param(3,$realname);
  $sth->bind_param(4,$user_id);
  $sth->execute;

  return $self->success_response();
}


sub recover_password
{
  my $self = shift;
  my $resp;
  my $token = $self->params->{"token"};
  my $caml = $self->caml;
  my $output;
  my $dbh = $self->database;
  
  my $sth = $dbh->prepare("select user_id, expiry, datetime('now') from recovery where token = ?;");
  $sth->bind_param(1,$token);
  $sth->execute;
  
  my $row = $sth->fetch;
  
  if (defined($row))
  {
    my ($user_id, $expiry, $now) = @{$row};
    
    if ($now gt $expiry)
    {
      $output = $caml->render_file('recovery_token_expired', undef);
      $resp = $self->response_as_html($output);
    }
    else
    {
      my $new = $self->params->{"new"};
      if (defined($new) && length($new) >= 8)
      {
        utf8::decode($new);
        my $ret = $self->update_password_for_user_id($user_id, $new);
        
        if ($ret == 1)
        {
          $sth = $dbh->prepare("delete from recovery where user_id = ?");
          $sth->bind_param(1, $user_id);
          $sth->execute;
          
          my $cookie;
          
          for (;;)
          {
            $cookie = $self->hex_token(20);
            my $sth = $dbh->prepare("insert into session values (?, ?, (select datetime('now','+1 hour')));");
            $sth->bind_param(1,$cookie);
            $sth->bind_param(2,$user_id);
            my $ret = $sth->execute;
            last if ($ret == 1);
          }

          my $stuff;
          $stuff->{banner} = $self->banner($user_id);
          $output = $caml->render_file('recovery_password_reset', $stuff);
          $resp = $self->response_as_html($output);
          $resp->header("Set-Cookie","session_id=$cookie");
        }
      }
      else
      {
        my $recovery_info;
        $recovery_info->{token} = $token;
        $output = $caml->render_file('recovery_change_password', $recovery_info);
        $resp = $self->response_as_html($output);
      }
    }
  }
  else
  {
    $output = $caml->render_file('recovery_token_expired', undef);
    $resp = $self->response_as_html($output);
  }
  return $resp;
}



sub forgot_password
{
  my $self = shift;
  my $resp;
  my $username = $self->params->{"user"};
  if (defined($username) && length($username))
  {
    utf8::decode($username);
    my $dbh = $self->database;
    my $sth = $dbh->prepare("select user_id from user where user_name = ? collate nocase or email = ? collate nocase or ucid = ? collate nocase");
    $sth->bind_param(1,$username);
    $sth->bind_param(2,$username);
    $sth->bind_param(3,$username);
    $sth->execute;
    my $row = $sth->fetch;
    if (defined($row))
    {
      my $userid = $row->[0];
      $sth = $dbh->prepare("delete from recovery where user_id = ?");
      $sth->bind_param(1, $userid);
      $sth->execute;
      
      my $token = $self->hex_token(20);
      $sth = $dbh->prepare("insert into recovery values (?,?,0,(select datetime('now','+1 hour')));");
      $sth->bind_param(1,$userid);
      $sth->bind_param(2,$token);
      $sth->execute;
      
    }
    my $caml = $self->caml;
    my $output = $caml->render_file('recovery_sent', undef);
    $resp = $self->response_as_html($output);
  }
  else
  {
    my $caml = $self->caml;
    my $output = $caml->render_file('forgot', undef);
    $resp = $self->response_as_html($output);
  }
  
  return $resp;
}


sub signup
{
  my $self = shift;
  
  my $resp = $self->test_method("POST");
  
  $resp = $self->test_params(["username", "password", "rpassword", "email", "remail", "ucid", "realname"]) unless (defined($resp));
  if (defined($resp))
  {
    return $resp;
  }
  
  my $dbh = $self->database;
  
  my $username = $self->params->{"username"};
  my $realname = $self->params->{"realname"};
  my $password = $self->params->{"password"};
  my $rpassword = $self->params->{"rpassword"};
  my $email = $self->params->{"email"};
  my $remail = $self->params->{"remail"};
  my $ucid = $self->params->{"ucid"};
  my $url = $self->params->{"redirect"};




  unless (defined($url))
  {
    $url = "./";
  }

  utf8::decode($username);
  utf8::decode($realname);
  utf8::decode($password);
  utf8::decode($rpassword);
  utf8::decode($email);
  utf8::decode($remail);
  utf8::decode($ucid);
  utf8::decode($url);

  my $error = 0;
  my $signup;
  

  $username = lc($username);
  
  if ($username =~ /\W/)
  {
    my $str = "Sorry, usernames can only contain characters a–z, A–Z, 0–9 and _ (underscore).";
    utf8::decode($str);
    return $self->failure_response($str, 403);
  }

  unless ($username =~ /[a-zA-Z]/)
  {
    my $str = "Sorry, usernames must contain at least one letter.";
    utf8::decode($str);
    return $self->failure_response($str, 403);
  }


  if (length($password) < 8)
  {
    return $self->failure_response("For security reasons, your password must be at least 8 characters.", 403);
  }

  if ($password ne $rpassword)
  {
    return $self->failure_response("Passwords do not match. Please verify and try again.", 403);
  }



  unless ($email =~ /^[^\@]+\@[^\@]+\.[^\@]+/)
  {
    return $self->failure_response("Please enter a valid email address.", 403);
  }

  if ($email ne $remail)
  {
    return $self->failure_response("Email addresses do not match. Please verify that you have entered your address correctly, and try again.", 403);
  }


  if ($ucid =~ /\D/)
  {
    return $self->failure_response("If you provide a UC ID, it must be numeric.", 403);
  }
  
  
  my $sth;
  if (length($ucid))
  {
    $sth = $dbh->prepare("select count(*) from user where user_name = ? or email = ? or ucid = ?;");
    $sth->bind_param(3, $ucid);
  }
  else
  {
    $sth = $dbh->prepare("select count(*) from user where user_name = ? or email = ?;");
  }
  $sth->bind_param(1, $username);
  $sth->bind_param(2, $email);
  $sth->execute;
  my $count = $sth->fetch->[0];

  if ($count)
  {
    return $self->failure_response("Sorry, an account for this user already exists.", 403);
  }

  my $salt = $self->salty(4);
  my $digest = bcrypt($password,"\$2a\$10\$".$salt);
  $sth = $dbh->prepare("insert into user values (null,?,?,?,?,?,?,(select datetime('now')))");
  $sth->bind_param(1,$username);
  $sth->bind_param(2,$realname);
  $sth->bind_param(3,$email);
  $sth->bind_param(4,$ucid);
  $sth->bind_param(5,$salt);
  $sth->bind_param(6,$digest);
  $sth->execute;

  $sth = $dbh->prepare("select user_id from user where user_name = ?");
  $sth->bind_param(1,$username);
  $sth->execute;
  my $user_id = $sth->fetch->[0];

  $sth = $dbh->prepare("insert into group_member values (1,?,0);");
  $sth->bind_param(1,$user_id);
  $sth->execute;

  my $cookie;

  for (;;)
  {
    $cookie = $self->hex_token(20);
    my $sth = $dbh->prepare("insert into session values (?, ?, (select datetime('now','+1 hour')));");
    $sth->bind_param(1,$cookie);
    $sth->bind_param(2,$user_id);
    my $ret = $sth->execute;
    last if ($ret == 1);
  }

  $resp = $self->success_response("redirect" => $url);
  $resp->header("Set-Cookie","session_id=$cookie");
  return $resp;

}







sub login
{
  my $self = shift;

  my $resp = $self->test_method("POST");
  
  $resp = $self->test_params(["username", "password", "remember"]) unless (defined($resp));
  if (defined($resp))
  {
    return $resp;
  }
  
  
  my $username = $self->params->{"username"};
  my $password = $self->params->{"password"};
  my $remember = $self->params->{"remember"};
  my $url = $self->params->{"redirect"};
  
  utf8::decode($username);
  utf8::decode($password);
  utf8::decode($url);

  
  
  unless (defined($url))
  {
    $url = "./";
  }
  
  my $dbh = $self->database;
  
  my $sth = $dbh->prepare("select user_id from user where user_name = ? collate nocase or email = ? collate nocase");
  $sth->bind_param(1,$username);
  $sth->bind_param(2,$username);
  $sth->execute;

  my $user_id = undef;

  my $row = $sth->fetch;
  if (defined($row))
  {
    $user_id = $row->[0];
  }
  
  if (!$self->check_password($user_id, $password))
  {
    return $self->failure_response('Your username or password did not match our records. Please check and try again.<br/><br/>If you are having trouble logging in, please email the Canadian Centre for Advanced Leadership in Business (CCAL) at the University of Calgary at <a href="mailto:leadership@haskayne.ucalgary.ca">leadership@haskayne.ucalgary.ca</a> AND <a href="mailto:joan.bassett@haskayne.ucalgary.ca">joan.bassett@haskayne.ucalgary.ca</a>.  We will respond within one business day of receiving your request.',403);
  }

  
  my $cookie;

  my $period = "hour";
  if ($remember)
  {
    $period = "year";
  }
  
  for (;;)
  {
    $cookie = $self->hex_token(20);
    my $sth = $dbh->prepare("insert into session values (?, ?, (select datetime('now','+1 $period')));");
    $sth->bind_param(1,$cookie);
    $sth->bind_param(2,$user_id);
    my $ret = $sth->execute;
    last if ($ret == 1);
  }
  
  $resp = $self->success_response("redirect" => $url);
  $resp->header("Set-Cookie","session_id=$cookie");
  return $resp;
}


sub generate_login_page
{
  my $self = shift;
  my $redirect = "/";

  if (defined($self->params) && defined($self->params->{"redirect"}))
  {
    $redirect = $self->params->{"redirect"};
  }
  my $caml = $self->caml;
  my $info;
  $info->{redirect} = $redirect;
  
  my $output = $caml->render_file('login', $info);
  return $self->response_as_html($output);

}



1;
