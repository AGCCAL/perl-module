package Garden::Group;
use Garden;

use 5.010;
use strict;
use warnings;
use JSON;
use Data::Dumper;
use HTML::Entities;
use Garden::User;

use Text::Markdown 'markdown';

our @ISA = qw(Garden);



sub create_group_new
{
  my $self = shift;
  my $resp;

  my $dbh = $self->database;
  my $caml = $self->caml;

  my @available_users;
  my @available_assessments;

  my $sth = $dbh->prepare("select user_id, user_name, real_name, email from user;");
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($user_id, $user_name, $real_name, $email) = @{$row};
    my $user;
    $user->{user_id} = $user_id;
    $user->{user_name} = $user_name;
    $user->{real_name} = $real_name;
    $user->{email} = $email;
    push (@available_users,$user);
  }
  
  $sth = $dbh->prepare("select assessment_id, name from assessment where state = ?");
  $sth->bind_param(1,Garden::STATE_PUBLISHED);
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($assessment_id, $name) = @{$row};
    my $assessment;
    $assessment->{assessment_id} = $assessment_id;
    $assessment->{name} = $name;
    push (@available_assessments,$assessment);
  }
  

  my $group;
  my $user_id = $self->get_user_id_from_cookie();

  $group->{banner} = $self->banner($user_id);

  $group->{available_users} = \@available_users;
  $group->{available_assessments} = \@available_assessments;
  
  

  $sth = $dbh->prepare("select group_id, group_name from user_group where group_id > 1 order by group_name;");
  $sth->execute;
  
  
  my @groups;
  my $blank_group;
  $blank_group->{group_id} = 1;
  $blank_group->{name} = "";
  $blank_group->{selected_or_nothing} = " selected";
  
  push (@groups, $blank_group);

  while (my $row = $sth->fetch)
  {
    my ($group_id, $name) = @{$row};
    my $parent;
    $parent->{group_id} = $group_id;
    $parent->{name} = $name;
    push(@groups, $parent);  
  }
  $group->{parent_group_list} = \@groups;
  $group->{show_parent_groups} = 1;

  my $output = $caml->render_file('create_group', $group);
  utf8::encode($output);
  return $self->response_as_html($output);


}

sub create_group
{
  my $self = shift;
  my $resp;

  my $dbh = $self->database;
  my $caml = $self->caml;

  # Ensure we're logged in as an admin
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless ($self->user_id_is_an_admin($user_id))
  {
    $user_id = undef;
  }

  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }


  # At this point, we're definitely an administrator.

  $resp = $self->test_params([qw(name)]);

  unless (defined($resp))
  {
    my $group_id = $self->params->{"g"};

    unless(defined($group_id))
    {
      # If we don't already have a group id, we need to generate one by
      # inserting and then fetching. Otherwise we'll be updating an existing
      # group.
      #
      # Do the whole thing in a transaction to keep it sane.

      $dbh->prepare("begin transaction")->execute;

      $resp = $self->test_params([qw(name chosen_users chosen_assessments parent is_admin_group)]);
      unless (defined($resp))
      {
        my $name = $self->params->{"name"};
        my $parent = $self->params->{"parent"};
        my $is_admin_group = $self->params->{"is_admin_group"};
  
        utf8::upgrade($name);
  
        $name = $self->clean_input($name);
  
        my $ass_sth = $dbh->prepare("insert into user_group values (null, ?,?);");
        $ass_sth->bind_param(1,$name);
        $ass_sth->bind_param(2,$is_admin_group);
        $ass_sth->execute;
  
        $ass_sth = $dbh->prepare("select group_id from user_group where group_name = ?;");
        $ass_sth->bind_param(1,$name);
        $ass_sth->execute;
  
        $group_id = $ass_sth->fetch->[0];
  
        my @chosen_users = @{$self->params->{"chosen_users"}};
        foreach my $user (@chosen_users)
        {
          $user =~ s:^user::;
          if ($user =~ /^\d+$/)
          {
            my $sth = $dbh->prepare("insert into group_member values (?,?,0)");
            $sth->bind_param(1,$group_id);
            $sth->bind_param(2,$user);
            $sth->execute;
          }
        }

        my @chosen_assessments = @{$self->params->{"chosen_assessments"}};
        foreach my $assessment (@chosen_assessments)
        {
          $assessment =~ s:^assessment::;
          if ($assessment =~ /^\d+$/)
          {
            my $sth = $dbh->prepare("insert into assessment_group values (?,?)");
            $sth->bind_param(1,$assessment);
            $sth->bind_param(2,$group_id);
            $sth->execute;
          }
        }


        
        $ass_sth = $dbh->prepare("delete from group_member where member_id = ? and member_type = 1;");
        $ass_sth->bind_param(1,$group_id);
        $ass_sth->execute;
        
        $ass_sth = $dbh->prepare("insert into group_member values(?,?,1);");
        $ass_sth->bind_param(1,$parent);
        $ass_sth->bind_param(2,$group_id);
        $ass_sth->execute;
        
        
      }
      $dbh->prepare("end transaction")->execute;
      return $self->update_group($group_id);
    }
  }
  
  return $self->create_group_new;
}


sub update_group
{
  my $self = shift;

  my $resp;

  my $dbh = $self->database;
  my $sth;
  my $caml = $self->caml;

  my $group;

  # Ensure we're logged in as an admin
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless ($self->user_id_is_an_admin($user_id))
  {
    $user_id = undef;
  }

  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }

  # at this point, we're logged in as an administrator


  # if we're called from create_group, we had the group_id passed as
  # an argument. Otherwise, we need to get it from the HTTP params.

  my $group_id = shift;
  unless(defined($group_id))
  {
    $group_id = $self->params->{"g"};
  }

  $group->{g} = $group_id;

  my $name = $self->params->{"name"};
  my $parent_id = $self->params->{"parent"};
  my $is_admin_group = $self->params->{"is_admin_group"};

  if (defined($name))
  {
    utf8::upgrade($name);

    $name = $self->clean_input($name);

    $sth = $dbh->prepare("update user_group set group_name = ?, is_admin_group = ? where group_id = ?");
    $sth->bind_param(1,$name);
    $sth->bind_param(2,($group_id == 0) ? 1 : ($group_id == 1) ? 0 : $is_admin_group ? 1:0);
    $sth->bind_param(3,$group_id);
    $sth->execute;


    $sth = $dbh->prepare("delete from group_member where group_id = ?");
    $sth->bind_param(1,$group_id);
    $sth->execute;


    my @chosen_users = @{$self->params->{"chosen_users"}};
    foreach my $user (@chosen_users)
    {
      $user =~ s:^user::;
      if ($user =~ /^\d+$/)
      {
        my $sth = $dbh->prepare("insert into group_member values (?,?,0)");
        $sth->bind_param(1,$group_id);
        $sth->bind_param(2,$user);
        $sth->execute;
      }
    }
    
    $sth = $dbh->prepare("delete from group_member where member_id = ? and member_type = 1;");
    $sth->bind_param(1,$group_id);
    $sth->execute;
    
    if (defined($parent_id))
    {
      $sth = $dbh->prepare("insert into group_member values(?,?,1);");
      $sth->bind_param(1,$parent_id);
      $sth->bind_param(2,$group_id);
      $sth->execute;
    }

    $sth = $dbh->prepare("delete from assessment_group where group_id = ?");
    $sth->bind_param(1,$group_id);
    $sth->execute;
    
    my @chosen_assessments = @{$self->params->{"chosen_assessments"}};
    foreach my $assessment (@chosen_assessments)
    {
      $assessment =~ s:^assessment::;
      if ($assessment =~ /^\d+$/)
      {
        my $sth = $dbh->prepare("insert into assessment_group values (?,?)");
        $sth->bind_param(1,$assessment);
        $sth->bind_param(2,$group_id);
        $sth->execute;
      }
    }

  }



  # Now pull all the latest values from the database.


  $sth = $dbh->prepare("select group_name, is_admin_group from user_group where group_id = ?");
  $sth->bind_param(1,$group_id);
  $sth->execute;
  my $row = $sth->fetch;
  if ($row)
  {
    my $state;
    ($name, $is_admin_group) = @{$row};

    utf8::decode($name);

    $group->{name} = $name;
    $group->{is_admin_group} = $is_admin_group? " checked" : "";
  }

  $group->{banner} = $self->banner($user_id);

  my %chosen_users;
  $sth = $dbh->prepare("select u.user_id from user u, group_member gm where gm.group_id = ? and gm.member_id = u.user_id and gm.member_type = 0;");
  $sth->bind_param(1,$group_id);
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my $user_id = $row->[0];
    $chosen_users{$user_id} = 1;
  }
  
  
  my @available_users;
  my @chosen_users;
  $sth = $dbh->prepare("select u.user_id, u.user_name, u.real_name, u.email from user u;");
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($user_id, $user_name, $real_name, $email) = @{$row};
    my $user;
    $user->{user_id} = $user_id;
    $user->{user_name} = $user_name;
    $user->{real_name} = $real_name;
    $user->{email} = $email;
    
    if (defined($chosen_users{$user_id}))
    {
      push (@chosen_users,$user);      
    }
    else
    {
      push (@available_users,$user);
    }    
  }

  $group->{available_users} = \@available_users;
  $group->{chosen_users} = \@chosen_users;


  my %chosen_assessments;
  $sth = $dbh->prepare("select assessment_id from assessment_group where group_id = ?");
  $sth->bind_param(1,$group_id);
  $sth->execute;
  while (my $row = $sth->fetch)
  {
    my $assessment_id = $row->[0];
    $chosen_assessments{$assessment_id} = 1;
  }
  
  my @available_assessments;
  my @chosen_assessments;
  $sth = $dbh->prepare("select assessment_id, name from assessment where state = ?;");
  $sth->bind_param(1,Garden::STATE_PUBLISHED);
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($assessment_id, $name) = @{$row};
    my $assessment;
    $assessment->{assessment_id} = $assessment_id;
    $assessment->{name} = $name;
        
    if (defined($chosen_assessments{$assessment_id}))
    {
      push (@chosen_assessments,$assessment);      
    }
    else
    {
      push (@available_assessments,$assessment);
    }    
  }

  $group->{available_assessments} = \@available_assessments;
  $group->{chosen_assessments} = \@chosen_assessments;



  $sth = $dbh->prepare("select group_id from group_member where member_id = ? and member_type = 1;");
  $sth->bind_param(1,$group_id);
  $sth->execute;
  
  $parent_id = 1;
  
  if (my $row = $sth->fetch)
  {
    $parent_id = $row->[0];
  }

  $sth = $dbh->prepare("select group_id, group_name from user_group where (group_id > 1) and group_id != ? order by group_name;");
  $sth->bind_param(1,$group_id);
  $sth->execute;
  my @groups;
  
  my $blank_group;
  $blank_group->{group_id} = 1;
  $blank_group->{name} = "";
  if ($parent_id == 1)
  {
    $blank_group->{selected_or_nothing} = " selected";
  }
  else
  {
    $blank_group->{selected_or_nothing} = "";
  }
  push (@groups, $blank_group);


  
  while (my $row = $sth->fetch)
  {
    my ($group_id, $name) = @{$row};
    my $parent;
    $parent->{group_id} = $group_id;
    $parent->{name} = $name;
    if ($group_id == $parent_id)
    {
      $parent->{selected_or_nothing} = " selected";
    }
    else
    {
      $parent->{selected_or_nothing} = "";
    }

    push(@groups, $parent);  
  }
  
  $group->{parent_group_list} = \@groups;
  $group->{show_parent_groups} = ($group_id > 1);



  my %hashy;
  my $output = $caml->render_file('update_group', $group);

  $hashy{"output"} = $output;

  return $self->success_response(%hashy);
}


sub modify_group
{
  my $self = shift;
  my $resp = $self->update_group;
  
  if ($resp->code == 200)
  {
    my $content = decode_json($resp->content);
    my $output = $content->{output};
    utf8::encode($output);
    my $group;
    my $user_id = $self->get_user_id_from_cookie();

    $group->{banner} = $self->banner($user_id);

    $group->{output} = $output;
    my $caml = $self->caml;
    $output = $caml->render_file('modify_group', $group);
    $resp = $self->response_as_html($output);
  }
  return $resp;
}

sub delete_group
{
  my $self = shift;
  my $group_id = shift;
  my $dbh = $self->database;
  my $sth = $dbh->prepare("select group_name from user_group where group_id = ?;");
  $sth->bind_param(1, $group_id);
  $sth->execute;
  my $name = $sth->fetch->[0];
  
  if (defined($name))
  {
    $sth = $dbh->prepare("delete from user_group where group_id = ?;");
    $sth->bind_param(1, $group_id);
    $sth->execute;
    
    $sth = $dbh->prepare("delete from group_member where group_id = ?;");
    $sth->bind_param(1, $group_id);
    $sth->execute;
  
    $sth = $dbh->prepare("delete from group_member where member_id = ? and member_type = 1;");
    $sth->bind_param(1, $group_id);
    $sth->execute;
    
    $sth = $dbh->prepare("delete from assessment_group where group_id = ?");
    $sth->bind_param(1, $group_id);
    $sth->execute;
  
  }
  return $name;
}

sub create_group_invitation_new
{
  my $self = shift;
  my $resp;

  my $dbh = $self->database;
  my $caml = $self->caml;

  my @available_groups;

  my $sth = $dbh->prepare("select group_id, group_name from user_group where group_id != 1;");
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($group_id, $group_name) = @{$row};
    my $group;
    $group->{group_id} = $group_id;
    $group->{group_name} = $group_name;
    push (@available_groups, $group);
  }
  
  my $group;
  my $user_id = $self->get_user_id_from_cookie();

  $group->{banner} = $self->banner($user_id);
  $group->{available_groups} = \@available_groups;

  my $output = $caml->render_file('create_group_invitation', $group);
  utf8::encode($output);
  return $self->response_as_html($output);

}


sub create_group_invitation
{
  my $self = shift;

  my $resp;

  my $dbh = $self->database;
  my $sth;
  my $caml = $self->caml;

  my $group;

  # Ensure we're logged in as an admin
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless ($self->user_id_is_an_admin($user_id))
  {
    $user_id = undef;
  }

  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }

  # at this point, we're logged in as an administrator

  $resp = $self->test_params([qw(chosen_groups)]);

  unless (defined($resp))
  {
    my @chosen_groups = @{$self->params->{"chosen_groups"}};
    my $invitation_id = $self->hex_token(10);

    my $in_groups_string = "(";
    foreach my $group (@chosen_groups)
    {
      $group =~ s:^group::;
      if ($group =~ /^\d+$/)
      {
        my $sth = $dbh->prepare("insert into invitation values (?,?)");
        $sth->bind_param(1,$invitation_id);
        $sth->bind_param(2,$group);
        $sth->execute;
        $in_groups_string .= "$group, ";
      }
    }
    
    $in_groups_string =~ s/, $/)/;
    
    
    
    my $invitation;
    my @assessments;
    my @group_names;
  
    
    my $sth = $dbh->prepare("select distinct a.assessment_id, a.name from assessment a, assessment_group ag where a.state = ? and ag.group_id in $in_groups_string and a.assessment_id = ag.assessment_id order by a.name;");
    $sth->bind_param(1,Garden::STATE_PUBLISHED);    
    $sth->execute;
    
    while (my $row = $sth->fetch)
    {
      my ($assessment_id, $name) = @{$row};
      my $assessment;
      $assessment->{assessment_id} = $assessment_id;
      $assessment->{name} = $name;
      push (@assessments, $assessment);  
    }
  
    $sth = $dbh->prepare("select group_name from user_group where group_id in $in_groups_string order by group_name;");
    $sth->execute;
    while (my $row = $sth->fetch)
    {
      my $group_name;
      $group_name->{group_name} = $row->[0];
      push (@group_names, $group_name);
    }
      
    $invitation->{invitation_id} = $invitation_id;
    $invitation->{assessments} = \@assessments;
    $invitation->{group_names} = \@group_names;
    
    my $output = $caml->render_file("invitation_list", $invitation);
    utf8::encode($output);
    
    my %hashy;
    $hashy{"output"} = $output;
    
    return $self->success_response(%hashy);

  }

  return $self->create_group_invitation_new;
}

1;
