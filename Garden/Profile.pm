package Garden::Profile;
use Garden;
use Garden::User;

use 5.010;
use strict;
use warnings;
use JSON;


our @ISA = qw(Garden);

sub generate_admin_profile
{
  my $self = shift;
  my $resp;
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    return $self->redirect_via_login("./");
  }


  my $dbh = $self->database;
  my $caml = $self->caml;


  my $profile;

  $profile->{show_create} = 0;


  my $is_an_admin = $self->user_id_is_an_admin($user_id);
  if ($is_an_admin)
  {
    my @archived;
    my @unpublished;
    my @published;
    my @admin_groups;

    my $sth = $dbh->prepare("select assessment_id, name, state from assessment order by name;");
    $sth->execute;
    while (my $row = $sth->fetch)
    {
      my ($assessment_id, $name, $state) = @{$row};
      my $assessment;
      $assessment->{a} = $assessment_id;
      $assessment->{name} = $name;

      if ($state == Garden::STATE_UNPUBLISHED)
      {
        push @unpublished, $assessment;
      }
      elsif ($state == Garden::STATE_PUBLISHED)
      {
        push @published, $assessment;
      }
      elsif ($state == Garden::STATE_ARCHIVED)
      {
        push @archived, $assessment;
      }
    }

    $profile->{published} = \@published;
    $profile->{show_published} = scalar(@published);

    $profile->{unpublished} = \@unpublished;
    $profile->{show_unpublished} = scalar(@unpublished);

    $profile->{archived} = \@archived;
    $profile->{show_archived} = scalar(@archived);

    $profile->{show_create} = 1;
    
    
    $sth = $dbh->prepare("select group_id, group_name from user_group order by group_name collate nocase;");
    $sth->execute;
    
    while (my $row = $sth->fetch)
    {
      my ($group_id, $name) = @{$row};
      my $group;
      $group->{g} = $group_id;
      $group->{name} = $name;
      push @admin_groups, $group;
    }
    
    $profile->{show_admin_groups} = 1;    
    $profile->{admin_groups} = \@admin_groups;

  }

  $profile->{banner} = $self->banner($user_id);

  my $output = $caml->render_file('profile', $profile);
  return $self->response_as_html($output);
}

sub generate_profile
{
  my $self = shift;
  my $resp;
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }
  
  my $dbh = $self->database;
  my $caml = $self->caml;
  
  
  my $profile;

  $profile->{banner} = $self->banner($user_id);

  my $user = Garden::User->new;
  my $has_accepted_tos = $user->has_accepted_tos($user_id);
  unless ($has_accepted_tos)
  {
    $profile->{redirect} = $self->request->uri;
    my $output = $caml->render_file('tos', $profile);

    return $self->response_as_html($output);
  }


  # If there's an invitation_id, process it first to ensure the user is in the
  # relevant group
  if (defined($self->params))
  {
    my $invitation_id = $self->params->{"inv"};
    if (defined($invitation_id))
    {
      $user->process_invitation($user_id, $invitation_id);
    }
  }


  my @groups = $self->group_ids_for_user_id($user_id);
  my $group_list = join (",",@groups);
  
  $profile->{show_create} = 0;


  my @historic;
  my @in_progress;

  my $sth = $dbh->prepare("select ai.instance_id, a.name, ai.start_date, ai.completion_date from assessment a, assessment_instance ai where a.assessment_id = ai.assessment_id and ai.user_id = ? order by ai.start_date desc");
  $sth->bind_param(1,$user_id);
  $sth->execute;
  while (my $row = $sth->fetch)
  {
    my ($instance_id, $name, $start_date, $completion_date) = @{$row};
    my $date;
    if (defined($completion_date))
    {
      $date = $completion_date;
    }
    else
    {
      $date = $start_date;
    }

    $date =~ s/ /T/;
    $date .="Z";


    my $ass;
    $ass->{instance_id} = $instance_id;
    $ass->{name} = $name;
    $ass->{date} = $date;

    if (defined($completion_date))
    {
      push (@historic, $ass);
    }
    else
    {
      push (@in_progress, $ass);
    }


    $profile->{in_progress} = \@in_progress;
    $profile->{show_in_progress} = scalar(@in_progress);
    
    $profile->{historic} = \@historic;
    $profile->{show_historic} = scalar(@historic);
  }

  my @available;

  $sth = $dbh->prepare("select distinct a.assessment_id, a.name from assessment a, assessment_group ag where a.assessment_id = ag.assessment_id and ag.group_id in ($group_list);");
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($assessment_id, $name) = @{$row};
    my $available;
    $available->{a} = $assessment_id;
    $available->{name} = $name;
    push @available, $available;
  }
  $profile->{available} = \@available;
  $profile->{show_available} = scalar(@available);


  my $output = $caml->render_file('profile', $profile);
  return $self->response_as_html($output);
}

1;
