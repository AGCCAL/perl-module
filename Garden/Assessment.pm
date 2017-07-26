package Garden::Assessment;
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

use constant
{
  ANSWER_TYPE_LIKERT => 0,
  ANSWER_TYPE_LIKERT_WITH_LEADING_NA => 1, # not yet implemented
  ANSWER_TYPE_LIKERT_WITH_TRAILING_NA => 2, # not yet implemented
  ANSWER_TYPE_TEXT => 3,
  ANSWER_TYPE_TEXTAREA => 4,
  ANSWER_TYPE_LISTBOX => 5,
  ANSWER_TYPE_MULTI_CHOICE => 6
};



# refine this in future to make them shorter
sub dimension_codes
{
  my ($self,@dimensions) = @_;
  my @codes;
  foreach my $dimension (@dimensions)
  {
    $dimension =~ tr/[a-z]/[A-Z]/;
    $dimension =~ s/\s+/_/g;
    $dimension =~ s/\W+//g;
    push @codes,$dimension;
  }
  return @codes;
}


sub email_assessment
{
  my $self = shift;
  my $resp = $self->test_params([qw(instance_id)]);
  my $dbh = $self->database;
  unless (defined($resp))
  {
    my $user_id = $self->get_user_id_from_cookie();
    unless (defined($user_id))
    {
      $resp = $self->redirect_via_login($self->request->uri);
    }

    unless (defined($resp))
    {
      my $instance_id = $self->params->{"instance_id"};

      my $sth = $dbh->prepare("select count(instance_id) from emailable_assessment where instance_id = ?;");
      $sth->bind_param(1, $instance_id);
      $sth->execute;
      my $count = $sth->fetch->[0];

      unless($count)
      {
        $sth = $dbh->prepare("insert into emailable_assessment values(?);");
        $sth->bind_param(1, $instance_id);
        $sth->execute;
      }

      my %hashy;
      $hashy{"output"} = "Please check your email for a copy of the assessment results.";

      $resp = $self->success_response(%hashy);
    }
  }
  return $resp;
}

sub archive_assessment
{
  my $self = shift;
  return $self->change_assessment_state(Garden::STATE_ARCHIVED);
}

sub publish_assessment
{
  my $self = shift;
  return $self->change_assessment_state(Garden::STATE_PUBLISHED);
}

sub delete_assessment
{
  my $self = shift;
  my $assessment_id = shift;

  my $dbh = $self->database;
  my $sth = $dbh->prepare("select assessment_type, name from assessment where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  my $row = $sth->fetch;
  if (defined($row))
  {
    my ($assessment_type, $name) = @{$row};

    $sth = $dbh->prepare("delete from assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    $sth = $dbh->prepare("delete from assessment_instance where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    
    $sth = $dbh->prepare("delete from assessment_instance_likert_answer where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    $sth = $dbh->prepare("delete from assessment_group where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    if ($assessment_type == 1)
    {
      #regular assessment — delete the questions and dimensions

      $sth = $dbh->prepare("delete from assessment_dimension where assessment_id = ?");
      $sth->bind_param(1, $assessment_id);
      $sth->execute;

      $sth = $dbh->prepare("delete from question where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;

      $sth = $dbh->prepare("delete from question_dimension where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      
    }
    else
    {
      $sth = $dbh->prepare("select sub_assessment_id from combined_assessment where assessment_id = ? order by index_id;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      my @subs;
      my $index_id = 0;
      while (my $row = $sth->fetch)
      {
        my $sub_assessment_id = $row->[0];
        $self->duplicate_assessment($sub_assessment_id);
      }
      
      $sth = $dbh->prepare("delete from combined_assessment where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      
    }
    return $name;
  }
  return undef;
}

sub duplicate_assessment
{
  my $self = shift;
  my $assessment_id = shift;

  my $dbh = $self->database;
  my $sth = $dbh->prepare("select max(assessment_id)+1 from assessment;");
  $sth->execute;
  my $new_assessment_id = $sth->fetch->[0];


  $sth = $dbh->prepare("select assessment_type, name, introduction, summary, summary2 from assessment where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  my $row = $sth->fetch;
  if (defined($row))
  {
    my ($assessment_type, $name, $introduction, $summary, $summary2) = @{$row};
    $name .= " (copy)";

    $sth = $dbh->prepare("insert into assessment values(?,?,?,?,?,?,0)");
    $sth->bind_param(1,$new_assessment_id);
    $sth->bind_param(2,$assessment_type);
    $sth->bind_param(3,$name);
    $sth->bind_param(4,$introduction);
    $sth->bind_param(5,$summary);
    $sth->bind_param(6,$summary2);
    $sth->execute;

    if ($assessment_type == 1)
    {
      #regular assessment — copy the questions and dimensions

      $sth = $dbh->prepare("select dimension_id, code, name, summary from assessment_dimension where assessment_id = ?");
      $sth->bind_param(1, $assessment_id);
      $sth->execute;
      while (my $row = $sth->fetch)
      {
        my ($dimension_id, $code, $name, $summary) = @{$row};
        my $sth2 = $dbh->prepare("insert into assessment_dimension values (?,?,?,?,?);");
        $sth2->bind_param(1,$new_assessment_id);
        $sth2->bind_param(2,$dimension_id);
        $sth2->bind_param(3,$code);
        $sth2->bind_param(4,$name);
        $sth2->bind_param(5,$summary);
        $sth2->execute;
      }

      $sth = $dbh->prepare("select question_id, question_text, answer_type_id from question where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      while (my $row = $sth->fetch)
      {
        my ($question_id, $question_text, $answer_type_id) = @{$row};
        my $sth2 = $dbh->prepare("insert into question values (?,?,?,?);");
        $sth2->bind_param(1,$new_assessment_id);
        $sth2->bind_param(2,$question_id);
        $sth2->bind_param(3,$question_text);
        $sth2->bind_param(4,$answer_type_id);
        $sth2->execute;
      }

      $sth = $dbh->prepare("select question_id, dimension_id, negate from question_dimension where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      while (my $row = $sth->fetch)
      {
        my ($question_id, $dimension_id, $negate) = @{$row};
        my $sth2 = $dbh->prepare("insert into question_dimension values (?,?,?,?);");
        $sth2->bind_param(1,$new_assessment_id);
        $sth2->bind_param(2,$question_id);
        $sth2->bind_param(3,$dimension_id);
        $sth2->bind_param(4,$negate);
        $sth2->execute;
      }
    }
    else
    {
      $sth = $dbh->prepare("select sub_assessment_id from combined_assessment where assessment_id = ? order by index_id;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      my @subs;
      my $index_id = 0;
      while (my $row = $sth->fetch)
      {
        my $sub_assessment_id = $row->[0];
        my $new_sub_assessment_id = $self->duplicate_assessment($sub_assessment_id);
        if (defined($new_sub_assessment_id))
        {
          my $sth2 = $dbh->prepare("insert into combined_assessment values (?,?,?);");
          $sth2->bind_param(1, $new_assessment_id);
          $sth2->bind_param(2, $index_id++);
          $sth2->bind_param(3, $new_sub_assessment_id);
          $sth2->execute;
        }
      }
    }
    return $new_assessment_id;
  }
  return undef;
}

sub duplicate_assessment_script
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

  my $assessment_id = $self->params->{"a"};
  my $new_assessment_id = $self->duplicate_assessment($assessment_id);

  my %hashy;

  return $self->success_response(%hashy);
}


sub change_assessment_state
{
  my $self = shift;
  my $state = shift;
  
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
  
  my $assessment_id = $self->params->{"a"};
  my $sth = $dbh->prepare("update assessment set state = ? where assessment_id = ?");
  $sth->bind_param(1,$state);
  $sth->bind_param(2,$assessment_id);
  $sth->execute;
  
  my %hashy;

  return $self->success_response(%hashy);
}


sub add_assessment_dimension
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

  my $assessment_id = $self->params->{"assessment_id"};


  $dbh->prepare("begin transaction")->execute;

  my $sth = $dbh->prepare("select count(*) from assessment_dimension where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;

  my $dimension_id = $sth->fetch->[0];

  $sth = $dbh->prepare("insert into assessment_dimension values(?,?,?,?,?);");
  $sth->bind_param(1,$assessment_id);
  $sth->bind_param(2,$dimension_id);
  $sth->bind_param(3,"DIMENSION_$dimension_id");
  $sth->bind_param(4,"Dimension $dimension_id");
  $sth->bind_param(5,"You scored {{DIMENSION_$dimension_id}}% for “Dimension $dimension_id”.");

  $sth->execute;

  $dbh->prepare("end transaction")->execute;

  my %hashy;

  return $self->success_response(%hashy);
}

sub delete_assessment_dimension
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

  my $assessment_id = $self->params->{"assessment_id"};
  my $dimension_id = $self->params->{"dimension_id"};


  $dbh->prepare("begin transaction")->execute;

  my $sth = $dbh->prepare("select count(*) from assessment_dimension where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;

  my $dimension_count = $sth->fetch->[0];

  $sth = $dbh->prepare("delete from assessment_dimension where assessment_id = ? and dimension_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->bind_param(2,$dimension_id);
  $sth->execute;

  $sth = $dbh->prepare("delete from question_dimension where assessment_id = ? and dimension_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->bind_param(2,$dimension_id);
  $sth->execute;

  for (my $i = $dimension_id; $i < $dimension_count; $i++)
  {
    $sth = $dbh->prepare("update assessment_dimension set dimension_id = ? where dimension_id = ? and assessment_id = ?");
    $sth->bind_param(1, $i);
    $sth->bind_param(2, $i+1);
    $sth->bind_param(3, $assessment_id);
    $sth->execute;

    $sth = $dbh->prepare("update question_dimension set dimension_id = ? where dimension_id = ? and assessment_id = ?");
    $sth->bind_param(1, $i);
    $sth->bind_param(2, $i+1);
    $sth->bind_param(3, $assessment_id);
    $sth->execute;
  }

  $dbh->prepare("end transaction")->execute;

  my %hashy;

  return $self->success_response(%hashy);
}




sub add_assessment_question
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

  my $assessment_id = $self->params->{"assessment_id"};


  $dbh->prepare("begin transaction")->execute;

  my $sth = $dbh->prepare("select count(*) from question where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;

  my $question_id = $sth->fetch->[0];

  $sth = $dbh->prepare("insert into question values(?,?,?,1);");
  $sth->bind_param(1,$assessment_id);
  $sth->bind_param(2,$question_id);
  $sth->bind_param(3,"Question ".($question_id+1));


  $sth->execute;

  $dbh->prepare("end transaction")->execute;

  my %hashy;

  return $self->success_response(%hashy);
}


sub delete_assessment_question
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

  my $assessment_id = $self->params->{"assessment_id"};
  my $question_id = $self->params->{"question_id"};


  $dbh->prepare("begin transaction")->execute;

  my $sth = $dbh->prepare("select count(*) from question where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;

  my $question_count = $sth->fetch->[0];

  $sth = $dbh->prepare("delete from question where assessment_id = ? and question_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->bind_param(2,$question_id);
  $sth->execute;

  $sth = $dbh->prepare("delete from question_dimension where assessment_id = ? and question_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->bind_param(2,$question_id);
  $sth->execute;

  for (my $i = $question_id; $i < $question_count; $i++)
  {
    $sth = $dbh->prepare("update question set question_id = ? where question_id = ? and assessment_id = ?");
    $sth->bind_param(1, $i);
    $sth->bind_param(2, $i+1);
    $sth->bind_param(3, $assessment_id);
    $sth->execute;

    $sth = $dbh->prepare("update question_dimension set question_id = ? where question_id = ? and assessment_id = ?");
    $sth->bind_param(1, $i);
    $sth->bind_param(2, $i+1);
    $sth->bind_param(3, $assessment_id);
    $sth->execute;
  }

  $dbh->prepare("end transaction")->execute;

  my %hashy;

  return $self->success_response(%hashy);
}



sub create_assessment_new
{
  my $self = shift;
  my $resp;

  my $dbh = $self->database;
  my $caml = $self->caml;

  my @answer_types;
  my @available_subs;

  my $sth = $dbh->prepare("select type_id, name from answer_type order by name;");
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($type_id, $name) = @{$row};
    my $answer_type;
    $answer_type->{type_id} = $type_id;
    $answer_type->{name} = $name;
    push (@answer_types,$answer_type);
  }

  $sth = $dbh->prepare("select assessment_id, name from assessment where assessment_type = 1 and state != ? order by name;");
  $sth->bind_param(1,Garden::STATE_ARCHIVED);
  $sth->execute;

  while (my $row = $sth->fetch)
  {
    my ($sub_id, $sub_name) = @{$row};
    my $sub;
    $sub->{sub_id} = $sub_id;
    $sub->{sub_name} = $sub_name;
    push (@available_subs,$sub);
  }

  my $assessment;
  my $user_id = $self->get_user_id_from_cookie();

  $assessment->{banner} = $self->banner($user_id);

  $assessment->{answer_types} = \@answer_types;
  $assessment->{available_subs} = \@available_subs;


  my $output = $caml->render_file('create_assessment', $assessment);
  utf8::encode($output);
  return $self->response_as_html($output);


}

sub create_assessment
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

  $resp = $self->test_params([qw(name introduction summary summary2 assessment_type)]);

  unless (defined($resp))
  {
    my $assessment_id = $self->params->{"a"};

    unless(defined($assessment_id))
    {
      # If we don't already have an assessment id, we need to generate one by
      # inserting and then fetching. Otherwise we'll be updating an existing
      # assessment.
      #
      # Do the whole thing in a transaction to keep it sane.

      $dbh->prepare("begin transaction")->execute;

      my $assessment_type = $self->params->{"assessment_type"};

      my $name = $self->params->{"name"};
      my $introduction = $self->params->{"introduction"};
      my $summary = $self->params->{"summary"};
      my $summary2 = $self->params->{"summary2"};

      utf8::upgrade($name);
      utf8::upgrade($introduction);
      utf8::upgrade($summary);
      utf8::upgrade($summary2);

      $name = $self->clean_input($name);
      $introduction = $self->clean_input($introduction);
      $summary = $self->clean_input($summary);
      $summary2 = $self->clean_input($summary2);

      my $ass_sth = $dbh->prepare("insert into assessment values (null, ?,?,?,?,?,?);");
      $ass_sth->bind_param(1,$assessment_type);
      $ass_sth->bind_param(2,$name);
      $ass_sth->bind_param(3,$introduction);
      $ass_sth->bind_param(4,$summary);
      $ass_sth->bind_param(5,$summary2);
      $ass_sth->bind_param(6,Garden::STATE_UNPUBLISHED);
      $ass_sth->execute;

      $ass_sth = $dbh->prepare("select assessment_id from assessment where assessment_type=? and name=? and introduction=? and summary=? and summary2=? and state=?;");
      $ass_sth->bind_param(1,$assessment_type);
      $ass_sth->bind_param(2,$name);
      $ass_sth->bind_param(3,$introduction);
      $ass_sth->bind_param(4,$summary);
      $ass_sth->bind_param(5,$summary2);
      $ass_sth->bind_param(6,Garden::STATE_UNPUBLISHED);
      $ass_sth->execute;

      $assessment_id = $ass_sth->fetch->[0];

      if ($assessment_type == 1)
      {
        $resp = $self->test_params([qw(questions dimensions default_answer_type)]);
        unless (defined($resp))
        {

          my $questions = $self->params->{"questions"};
          my $dimensions = $self->params->{"dimensions"};
          my $default_answer_type = $self->params->{"default_answer_type"};

          utf8::upgrade($questions);
          utf8::upgrade($dimensions);

          $questions = $self->clean_input($questions);
          $dimensions = $self->clean_input($dimensions);

          $questions =~ s:^\s+::;
          $questions =~ s:\n+:\n:g;
          $questions =~ s:\s+$::;
          my @questions = split(/\n/,$questions);

          for (my $i = 0; $i < scalar(@questions); $i++)
          {
            $questions[$i] =~ s:^\s+::;
            $questions[$i] =~ s:\s+$::;

            my $sth = $dbh->prepare("insert into question values (?,?,?,?);");
            $sth->bind_param(1,$assessment_id);
            $sth->bind_param(2,$i);
            $sth->bind_param(3,$questions[$i]);
            $sth->bind_param(4,$default_answer_type);

            $sth->execute;
          }

          $dimensions =~ s:^\s+::;
          $dimensions =~ s:\n+:\n:g;
          $dimensions =~ s:\s+$::;
          my @dimensions = split(/\n/,$dimensions);
          my @codes = $self->dimension_codes(@dimensions);

          for (my $i = 0; $i < scalar(@dimensions); $i++)
          {
            $dimensions[$i] =~ s:^\s+::;
            $dimensions[$i] =~ s:\s+$::;

            my $sth = $dbh->prepare("insert into assessment_dimension values (?,?,?,?,null);");
            $sth->bind_param(1,$assessment_id);
            $sth->bind_param(2,$i);
            $sth->bind_param(3,$codes[$i]);
            $sth->bind_param(4,$dimensions[$i]);

            $sth->execute;
          }
        }
      }
      else
      {
        $resp = $self->test_params([qw(chosen_subs)]);
        unless (defined($resp))
        {
          my @chosen_subs = @{$self->params->{"chosen_subs"}};
          my $index = 0;
          foreach my $sub (@chosen_subs)
          {
            $sub =~ s:^sub::;
            if ($sub =~ /^\d+$/)
            {
              my $sth = $dbh->prepare("insert into combined_assessment values (?,?,?)");
              $sth->bind_param(1,$assessment_id);
              $sth->bind_param(2,$index);
              $sth->bind_param(3,$sub);
              $sth->execute;
              $index++;
            }
          }
        }
      }
      $dbh->prepare("end transaction")->execute;
      return $self->update_assessment($assessment_id);
    }
  }
  
  return $self->create_assessment_new;
}


sub update_assessment
{
  my $self = shift;

  my $resp;

  my $dbh = $self->database;
  my $sth;
  my $caml = $self->caml;

  my $assessment;

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


  # if we're called from create_assessment, we had the assessment_id passed as
  # an argument. Otherwise, we need to get it from the HTTP params.

  my $assessment_id = shift;
  unless(defined($assessment_id))
  {
    $assessment_id = $self->params->{"a"};
  }

  $assessment->{a} = $assessment_id;

  my $name = $self->params->{"name"};
  my $introduction = $self->params->{"introduction"};
  my $summary = $self->params->{"summary"};
  my $summary2 = $self->params->{"summary2"};
  my $assessment_type = $self->params->{"assessment_type"};

  if ((defined($name)) &&
      (defined($introduction)) &&
      (defined($summary)) &&
      (defined($summary2)) &&
      (defined($assessment_type)))
  {
    utf8::upgrade($name);
    utf8::upgrade($introduction);
    utf8::upgrade($summary);
    utf8::upgrade($summary2);

    $name = $self->clean_input($name);
    $introduction = $self->clean_input($introduction);
    $summary = $self->clean_input($summary);
    $summary2 = $self->clean_input($summary2);

    $sth = $dbh->prepare("update assessment set name = ?, introduction = ?, summary = ?, summary2 = ?  where assessment_id = ?");
    $sth->bind_param(1,$name);
    $sth->bind_param(2,$introduction);
    $sth->bind_param(3,$summary);
    $sth->bind_param(4,$summary2);
    $sth->bind_param(5,$assessment_id);
    $sth->execute;


    if ($assessment_type == 1)
    {
      # update the dimensions.

      $sth = $dbh->prepare("select count(*) from assessment_dimension where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      my $dimension_count = $sth->fetch->[0];

      for (my $i = 0; $i < $dimension_count; $i++)
      {
        my $dn = $self->params->{"dn$i"};
        my $dc = $self->params->{"dc$i"};
        my $ds = $self->params->{"ds$i"};
        if (defined($dc) && defined($dn) && defined($ds))
        {
          utf8::upgrade($dc);
          utf8::upgrade($dn);
          utf8::upgrade($ds);
          $dc = $self->clean_input($dc);
          $dn = $self->clean_input($dn);
          $ds = $self->clean_input($ds);

          $sth = $dbh->prepare("update assessment_dimension set name = ?, code = ?, summary = ? where assessment_id = ? and dimension_id = ?;");
          $sth->bind_param(1,$dn);
          $sth->bind_param(2,$dc);
          $sth->bind_param(3,$ds);
          $sth->bind_param(4,$assessment_id);
          $sth->bind_param(5,$i);
          $sth->execute;

        }
      }

      # update the questions.

      $sth = $dbh->prepare("select count(*) from question where assessment_id = ?;");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;
      my $question_count = $sth->fetch->[0];

      for (my $i = 0; $i < $question_count; $i++)
      {
        my $qt = $self->params->{"qt$i"};
        my $qat = $self->params->{"qat$i"};
        if (defined($qt) && defined($qat))
        {
          utf8::upgrade($qt);
          utf8::upgrade($qat);
          $qt = $self->clean_input($qt);
          $qat = $self->clean_input($qat);

          $sth = $dbh->prepare("update question set question_text = ?, answer_type_id = ? where assessment_id = ? and question_id = ?;");
          $sth->bind_param(1,$qt);
          $sth->bind_param(2,$qat);
          $sth->bind_param(3,$assessment_id);
          $sth->bind_param(4,$i);
          $sth->execute;
        }
      }

      # update the question dimensions.

      for (my $i = 0; $i < $question_count; $i++)
      {
        for (my $j = 0; $j < $dimension_count; $j++)
        {
          my $qd = $self->params->{"q$i"."d$j"};
          if (defined($qd))
          {
            utf8::upgrade($qd);
            $qd = $self->clean_input($qd);

            $sth = $dbh->prepare("delete from question_dimension where assessment_id = ? and question_id = ? and dimension_id = ?;");
            $sth->bind_param(1,$assessment_id);
            $sth->bind_param(2,$i);
            $sth->bind_param(3,$j);
            $sth->execute;

            if ($qd != 0)
            {
              my $neg = ($qd == 2)?1:0;
              $sth = $dbh->prepare("insert into question_dimension values (?,?,?,?);");
              $sth->bind_param(1,$assessment_id);
              $sth->bind_param(2,$i);
              $sth->bind_param(3,$j);
              $sth->bind_param(4,$neg);
              $sth->execute;
            }
          }
        }
      }
    }
    else
    {
      my $sth = $dbh->prepare("delete from combined_assessment where assessment_id = ?");
      $sth->bind_param(1,$assessment_id);
      $sth->execute;


      $sth = $dbh->prepare("select assessment_id, name from assessment where assessment_type = 1 and state != ? order by name;");
      $sth->bind_param(1,Garden::STATE_ARCHIVED);
      $sth->execute;

      my @chosen_subs = @{$self->params->{"chosen_subs"}};
      my $index = 0;
      foreach my $sub (@chosen_subs)
      {
        $sub =~ s:^sub::;
        if ($sub =~ /^\d+$/)
        {
          my $sth = $dbh->prepare("insert into combined_assessment values (?,?,?)");
          $sth->bind_param(1,$assessment_id);
          $sth->bind_param(2,$index);
          $sth->bind_param(3,$sub);
          $sth->execute;
          $index++;
        }
      }
    }
  }



  # Now pull all the latest values from the database.


  $sth = $dbh->prepare("select assessment_type, name, introduction, summary, summary2, state from assessment where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  my $row = $sth->fetch;
  if ($row)
  {
    my $state;
    ($assessment_type, $name,$introduction,$summary,$summary2, $state) = @{$row};

    #TODO: If state is "published", we need to kill this assessment and make a new one.

    utf8::decode($name);
    utf8::decode($introduction);
    utf8::decode($summary);
    utf8::decode($summary2);

    $assessment->{name} = $name;
    $assessment->{introduction} = $introduction;
    $assessment->{summary} = $summary;
    $assessment->{summary2} = $summary2;
  }

  $assessment->{banner} = $self->banner($user_id);

  if ($assessment_type == 1)
  {
    my @answer_types;
    $sth = $dbh->prepare("select type_id, name from answer_type order by name;");
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my ($type_id, $name) = @{$row};
      my $answer_type;
      $answer_type->{type_id} = $type_id;
      $answer_type->{name} = $name;
      push (@answer_types,$answer_type);
    }


    $sth = $dbh->prepare("select dimension_id, code, name, summary from assessment_dimension where assessment_id = ? order by dimension_id;");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    my @dimensions;
    while ($row = $sth->fetch)
    {
      my ($dimension_id, $code, $name, $summary) = @{$row};
      my $dimension;
      $dimension->{dimension_id} = $dimension_id;

      utf8::decode($code);
      utf8::decode($name);
      utf8::decode($summary);

      $dimension->{code} = $code;
      $dimension->{name} = $name;
      $dimension->{summary} = $summary;

      push @dimensions, $dimension;
    }

    $assessment->{dimensions} = \@dimensions;

    $sth = $dbh->prepare("select question_id, question_text, answer_type_id from question where assessment_id = ? order by question_id;");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    my @questions;
    while ($row = $sth->fetch)
    {
      my ($question_id, $question_text, $answer_type_id) = @{$row};
      my $question;
      $question->{question_id} = $question_id;
      $question->{question_number} = $question_id+1;

      utf8::decode($question_text);
      $question->{question_text} = $question_text;

      my @answer_types_for_question;
      foreach my $answer_type (@answer_types)
      {
        my $answer_type_for_question;
        $answer_type_for_question->{type_id} = $answer_type->{type_id};
        $answer_type_for_question->{name} = $answer_type->{name};
        if ($answer_type_for_question->{type_id} == $answer_type_id)
        {
          $answer_type_for_question->{selected_or_nothing} = " selected";
        }
        else
        {
          $answer_type_for_question->{selected_or_nothing} = "";
        }

        push (@answer_types_for_question,$answer_type_for_question);

      }

      $question->{answer_type_list} = \@answer_types_for_question;
      $question->{answer_type_id} = $answer_type_id;

      my @question_dimensions;
      foreach my $dimension (@dimensions)
      {
        my $dimension_id = $dimension->{dimension_id};
        my $sth = $dbh->prepare("select negate from question_dimension where assessment_id = ? and question_id = ? and dimension_id = ?");
        $sth->bind_param(1,$assessment_id);
        $sth->bind_param(2,$question_id);
        $sth->bind_param(3,$dimension_id);
        $sth->execute;
        my $selected = 0;

        if (my $row = $sth->fetch)
        {
          my $negate = $row->[0];
          if ($negate)
          {
            $selected = 2;
          }
          else
          {
            $selected = 1;
          }
        }

        my @option_text = ("&nbsp;","+","-");

        my $question_dimension;
        $question_dimension->{dimension_id} = $dimension_id;
        $question_dimension->{option} = $option_text[$selected];
        $question_dimension->{value} = $selected;
        push @question_dimensions,$question_dimension;
      }
      $question->{dimensions} = \@question_dimensions;

      push @questions, $question;
    }

    $assessment->{questions} = \@questions;
    $assessment->{row_width} = (350 + (41*scalar(@dimensions)) + 200);

    my %hashy;
    my $output = $caml->render_file('update_regular_assessment', $assessment);

    $hashy{"output"} = $output;

    return $self->success_response(%hashy);

  }
  else
  {

    my @available_subs;
    $sth = $dbh->prepare("select assessment_id, name from assessment where assessment_type = 1 and assessment_id != ? and assessment_id not in (select sub_assessment_id from combined_assessment where assessment_id = ?) and state != ? order by name;");
    $sth->bind_param(1,$assessment_id);
    $sth->bind_param(2,$assessment_id);
    $sth->bind_param(3,Garden::STATE_ARCHIVED);

    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my ($sub_id, $sub_name) = @{$row};
      my $sub;
      $sub->{sub_id} = $sub_id;
      $sub->{sub_name} = $sub_name;
      push (@available_subs,$sub);
    }

    my @chosen_subs;
    $sth = $dbh->prepare("select a.assessment_id, a.name from assessment a, combined_assessment c where a.assessment_id = c.sub_assessment_id and c.assessment_id = ? order by c.index_id;");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my ($sub_id, $sub_name) = @{$row};
      my $sub;
      $sub->{sub_id} = $sub_id;
      $sub->{sub_name} = $sub_name;
      push (@chosen_subs,$sub);
    }

    $assessment->{available_subs} = \@available_subs;
    $assessment->{chosen_subs} = \@chosen_subs;


    my %hashy;
    my $output = $caml->render_file('update_combined_assessment', $assessment);

    $hashy{"output"} = $output;

    return $self->success_response(%hashy);
  }
}


sub modify_assessment
{
  my $self = shift;
  my $resp = $self->update_assessment;
  
  if ($resp->code == 200)
  {
    my $content = decode_json($resp->content);
    my $output = $content->{output};
    utf8::encode($output);
    my $assessment;
    my $user_id = $self->get_user_id_from_cookie();

    $assessment->{banner} = $self->banner($user_id);

    $assessment->{output} = $output;
    my $caml = $self->caml;
    $output = $caml->render_file('modify_assessment', $assessment);
    $resp = $self->response_as_html($output);
  }
  return $resp;
}

sub assessment_groups
{
  my $self = shift;
  my $resp = $self->update_assessment_groups;
  
  if ($resp->code == 200)
  {
    my $content = decode_json($resp->content);
    my $output = $content->{output};
    utf8::encode($output);
    my $assessment;
    my $user_id = $self->get_user_id_from_cookie();

    $assessment->{banner} = $self->banner($user_id);

    $assessment->{output} = $output;
    my $caml = $self->caml;
    $output = $caml->render_file('modify_assessment_groups', $assessment);
    $resp = $self->response_as_html($output);
  }
  return $resp;
}


sub update_assessment_groups
{
  my $self = shift;

  my $resp;

  my $dbh = $self->database;
  my $caml = $self->caml;

  my $assessment;

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


  my $assessment_id = $self->params->{"a"};

  $assessment->{a} = $assessment_id;

  if (defined($self->params->{"chosen_groups"}))
  {
    my $sth = $dbh->prepare("delete from assessment_group where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    
    my @chosen_groups = @{$self->params->{"chosen_groups"}};
    foreach my $group (@chosen_groups)
    {
      $group =~ s:^group::;
      if ($group =~ /^\d+$/)
      {
        my $sth = $dbh->prepare("insert into assessment_group values (?,?)");
        $sth->bind_param(1,$assessment_id);
        $sth->bind_param(2,$group);
        $sth->execute;
      }
    }
  }
  
  # Now pull all the latest values from the database.


  {

    my $sth = $dbh->prepare("select group_id from assessment_group where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    
    my %chosen_groups;
    while (my $row = $sth->fetch)
    {
      my $group_id = $row->[0];
      $chosen_groups{$group_id} = 1;
    }
    
    my @available_groups;
    my @chosen_groups;
    
    $sth = $dbh->prepare("select group_id, group_name from user_group order by group_name;");
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my ($group_id, $group_name) = @{$row};
      my $group;
      $group->{group_id} = $group_id;
      $group->{group_name} = $group_name;
      if (defined($chosen_groups{$group_id}))
      {
        push (@chosen_groups, $group);
      }
      else
      {
        push (@available_groups, $group);
      }
    }

    $assessment->{available_groups} = \@available_groups;
    $assessment->{chosen_groups} = \@chosen_groups;


    my %hashy;
    my $output = $caml->render_file('update_assessment_groups', $assessment);

    $hashy{"output"} = $output;

    return $self->success_response(%hashy);
  }
}




# Generate the HTML for an assessment. It will either be new, in-progress,
# or completed. The assessment_id and instance_id parameters will help us
# to determine which.
sub generate_assessment
{
  my $self = shift;
  my $resp;
  
  # Ensure we're logged in
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }
  
  my $dbh = $self->database;

  my $user = Garden::User->new;
  my $has_accepted_tos = $user->has_accepted_tos($user_id);
  unless ($has_accepted_tos)
  {
    my $tos;
    my $caml = $self->caml;

    $tos->{banner} = $self->banner($user_id);
    $tos->{redirect} = $self->request->uri;
    my $output = $caml->render_file('tos', $tos);
    return $self->response_as_html($output);
  }



  # We need to be called with either an assessment_id (for a new assessment)
  # or an instance_id (for an existing assessment). If we haven't got at least
  # one of them, redirect to the profile.
  my $assessment_id = $self->params->{"a"};
  my $instance_id = $self->params->{"instance_id"};


  # If there's an invitation_id, process it first to ensure the user is in the
  # relevant group
  my $invitation_id = $self->params->{"inv"};
  if (defined($invitation_id))
  {
    $user->process_invitation($user_id, $invitation_id);
  }
  
  my $assessment_is_complete = 0;
  
  if (defined($instance_id))
  {
    # Get some info about this instance.
    my $sth = $dbh->prepare("select assessment_id, user_id, completion_date from assessment_instance where instance_id = ?;");
    $sth->bind_param(1,$instance_id);
    $sth->execute;
    my $row = $sth->fetch;
    my $error = 0;
    
    if ($row)
    {
      my ($ass, $user, $completion_date) = @{$row};
      
      # Override the assessment id to be the one for the instance, just in case
      # someone sent us garbage.
      $assessment_id = $ass;
      
      unless ($user_id == $user)
      {
        # We were opened via a link to another user's instance. Create a new
        # instance via a redirection.
        $resp = HTTP::Response->new(302);
        $resp->header("Location", "./a?a=$assessment_id");
        return $resp;
      }
      
      $assessment_is_complete = (defined($completion_date));
    }
    else
    {
      $instance_id = undef;
    }
  }

  my @groups = $self->group_ids_for_user_id($user_id);
  my $group_list = join (",",@groups);

  if (defined($assessment_id))
  {
    my $sth = $dbh->prepare("select state from assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    my $row = $sth->fetch;
    if ($row)
    {
      my $state = $row->[0];

      my $can_view = ($assessment_is_complete || ($self->user_id_is_an_admin($user_id)));

      if ((!$can_view) && ($state == Garden::STATE_PUBLISHED))
      {
        my $sth = $dbh->prepare("select count(*) from assessment_group ag where ag.assessment_id = ? and ag.group_id in ($group_list);");
        $sth->bind_param(1,$assessment_id);
        $sth->execute;
        $can_view = $sth->fetch->[0];

      }

      if ($can_view)
      {
        my $output = $self->generate_assessment_html($assessment_id, $instance_id, $assessment_is_complete, 0, $user_id);
        return $self->response_as_html($output);
      }
    }
  }

  $resp = HTTP::Response->new(302);
  $resp->header("Location", "./profile");
  return $resp;
}



sub generate_assessment_html
{
  my $self = shift;
  my ($assessment_id, $instance_id, $assessment_is_complete, $is_a_sub, $user_id) = @_;

  my $dbh = $self->database;
  my $caml = $self->caml;

  my $assessment;

  my $sth = $dbh->prepare("select assessment_type, name, state, introduction from assessment a where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  my $row = $sth->fetch;
  my ($assessment_type, $name, $state, $introduction) = @{$row};

  $assessment->{assessment_id} = $assessment_id;
  $assessment->{name} = $name;
  $assessment->{introduction} = markdown($introduction);
  
  if (!$is_a_sub)
  {
    if ($self->user_id_is_an_admin($user_id))
    {
      $assessment->{show_admin} = 1;
      if ($state == Garden::STATE_PUBLISHED)
      {
        my $count_sth = $dbh->prepare("select count(instance_id),count(distinct user_id) from assessment_instance where assessment_id = ?");
        $count_sth->bind_param(1,$assessment_id);
        $count_sth->execute;
        my ($instance_count, $user_count) = @{$count_sth->fetch};
        
        my $state = "<i>This assessment is published and available to users. ";
        if ($instance_count != 0)
        {
          $state .= "It has so far been taken " . (($instance_count == 1)?"once":(($instance_count == 2)?"twice":"$instance_count times"));
          if ($instance_count > 1)
          {
            $state .= " by $user_count user";
            if ($user_count > 1)
            {
              $state .= "s";
            }
          }
          $state .= ".";
          
        }
        $state .= "</i>";
        
        $assessment->{show_state} = $state;
        $assessment->{show_modify} = 1;
        $assessment->{show_publish} = 0;
        $assessment->{show_groups} = 1;
        $assessment->{show_archive} = 1;
        $assessment->{show_duplicate} = 1;
        $assessment->{show_export} = 1;
      } 
      elsif ($state == Garden::STATE_UNPUBLISHED)
      {
        $assessment->{show_state} = "<i>This assessment is currently unpublished.</i>";
        $assessment->{show_modify} = 1;
        $assessment->{show_publish} = 1;
        $assessment->{show_groups} = 1;
        $assessment->{show_archive} = 1;
        $assessment->{show_duplicate} = 1;
        $assessment->{show_export} = 0;
      }
      elsif ($state == Garden::STATE_ARCHIVED)
      {
        $assessment->{show_state} = "<i>This assessment is archived.</i>";
        $assessment->{show_modify} = 0;
        $assessment->{show_publish} = 0;
        $assessment->{show_groups} = 0;
        $assessment->{show_archive} = 0;
        $assessment->{show_duplicate} = 1;
        $assessment->{show_export} = 1;
      }
    }    
  }
  
  
  
  if ($assessment_is_complete)
  {
    my $summary = $self->generate_summary($instance_id, $assessment_id);
    utf8::encode($summary);
    $assessment->{summary} = $summary;
  }
  else
  {
    my %magic;
    $magic{a} = $assessment_id;
    unless(defined($instance_id))
    {
      $instance_id = $self->hex_token(10);
    }
    $magic{instance_id} = $instance_id;
    my $magic = encode_json(\%magic);
    $assessment->{magic} = $magic;

  }
  $assessment->{completed} = $assessment_is_complete;
  $assessment->{banner} = $self->banner($user_id);

  my $output;

  if ($assessment_type == 1)
  {

    $sth = $dbh->prepare("select q.question_id, q.question_text, at.super_type, q.answer_type_id from question q, answer_type at where assessment_id = ? and q.answer_type_id = at.type_id order by question_id");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    my @questions;
    while (my $row = $sth->fetch)
    {
      my ($question_id, $question_text, $super_type, $answer_type_id) = @{$row};
      my $question;
      $question->{question_id} = $question_id;
      $question->{question_number} = $question_id + 1;
      $question->{question_text} = markdown($question_text);
      $question->{answer_type} = $super_type;

      if (($super_type == ANSWER_TYPE_LIKERT) || ($super_type == ANSWER_TYPE_LISTBOX) || ($super_type == ANSWER_TYPE_MULTI_CHOICE))
      {
        $question->{type_likert} = ($super_type == ANSWER_TYPE_LIKERT);
        $question->{type_listbox} = ($super_type == ANSWER_TYPE_LISTBOX);
        $question->{type_multichoice} = ($super_type == ANSWER_TYPE_MULTI_CHOICE);        

        my $answer_sth = $dbh->prepare("select step_id, name from likert_step where type_id = ? order by step_id");
        $answer_sth->bind_param(1,$answer_type_id);
        $answer_sth->execute;
  
        my @answer_steps;
        my $min=999999;
        my $max=0;
        my $selected_step_id = undef;
  
        if (defined($instance_id))
        {
          my $instance_answer_sth = $dbh->prepare("select step_id from assessment_instance_likert_answer where instance_id = ? and assessment_id = ? and question_id = ?;");
          $instance_answer_sth->bind_param(1, $instance_id);
          $instance_answer_sth->bind_param(2, $assessment_id);
          $instance_answer_sth->bind_param(3, $question_id);
          $instance_answer_sth->execute;
          my $row = $instance_answer_sth->fetch;
          if (defined($row))
          {
            $selected_step_id = $row->[0];
          }
        }
  
        while (my $row = $answer_sth->fetch)
        {
          my ($step_id, $name) = @{$row};
          if ($step_id < $min)
          {
            $min = $step_id;
          }
          if ($step_id > $max)
          {
            $max = $step_id;
          }
  
          my $step;
          $step->{step_id} = $step_id;
          $step->{name} = $name;

          if (defined($selected_step_id))
          {
            if ($super_type == ANSWER_TYPE_MULTI_CHOICE)
            {
              if ($selected_step_id & (1 << $step_id))
              {
                $step->{selected_or_nothing} = " checked";
              }
            }
            elsif ($step_id == $selected_step_id)
            {
              $step->{selected_or_nothing} = " selected";              
            }
          }
          
          if (($super_type == ANSWER_TYPE_LIKERT) || (!$assessment_is_complete))
          {
            push (@answer_steps, $step);
          }
          elsif (defined($selected_step_id))
          {
            if ($super_type == ANSWER_TYPE_MULTI_CHOICE)
            {
              if ($selected_step_id & (1 << $step_id))
              {
                push (@answer_steps, $step);
              }
            }
            elsif ($step_id == $selected_step_id)
            {
              push (@answer_steps, $step);
            }
          }          
        }
  
        unless ($assessment_is_complete)
        {
          foreach my $step(@answer_steps)
          {          
            my $step_id = $step->{step_id};
            if ($super_type == ANSWER_TYPE_LIKERT)
            {
              $step->{onclick} = "onclick=\"javascript:select($assessment_id,$question_id,$min,$max,$step_id,0);\"";
              $step->{onmouseover} = "onmouseover=\"javascript:over($assessment_id,$question_id,$min,$max,$step_id);\"";
              $step->{onmouseout} = "onmouseout=\"javascript:out($assessment_id,$question_id,$min,$max,$step_id);\"";
            }
            elsif ($super_type == ANSWER_TYPE_MULTI_CHOICE)
            {
              $step->{onchange} = "onchange=\"javascript:change_checkbox($assessment_id,$question_id,$min,$max,$step_id,0);\"";              
            }
          }
          
        }
        $question->{min} = $min;
        $question->{max} = $max;
        $question->{answer_steps} = \@answer_steps;
        
        if ($super_type == ANSWER_TYPE_LISTBOX)
        {
          $question->{onchange} = "onchange=\"javascript:change($assessment_id,$question_id,0);\"";          
        }
  
        
      }
      elsif (($super_type == ANSWER_TYPE_TEXT) ||
             ($super_type == ANSWER_TYPE_TEXTAREA))
      {
        $question->{type_text} = ($super_type == ANSWER_TYPE_TEXT);
        $question->{type_textarea} = ($super_type == ANSWER_TYPE_TEXTAREA);
        if (defined($instance_id))
        {
          my $instance_answer_sth = $dbh->prepare("select answer from assessment_instance_text_answer where instance_id = ? and assessment_id = ? and question_id = ?;");
          $instance_answer_sth->bind_param(1, $instance_id);
          $instance_answer_sth->bind_param(2, $assessment_id);
          $instance_answer_sth->bind_param(3, $question_id);
          $instance_answer_sth->execute;
          my $row = $instance_answer_sth->fetch;
          if (defined($row))
          {
            $question->{answer_text} = $row->[0];
          }
        }
        $question->{onblur} = "onblur=\"javascript:change($assessment_id,$question_id,0);\"";          
      }


      push (@questions,$question);
    }

    $assessment->{questions} = \@questions;

    if ($is_a_sub)
    {
      $output = $caml->render_file('sub_assessment', $assessment);
    }
    else
    {
      $output = $caml->render_file('assessment', $assessment);
    }
    return $output;

  }
  elsif ($assessment_type == 2)
  {
    my $sub_output = "";

    my $sth = $dbh->prepare("select sub_assessment_id from combined_assessment where assessment_id = ? order by index_id;");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my $sub_assessment_id = $row->[0];
      $sub_output .= $self->generate_assessment_html($sub_assessment_id, $instance_id, $assessment_is_complete,1, $user_id);
      $sub_output .= "\n";
    }

    $assessment->{sub_assessments} = $sub_output;

    $output = $caml->render_file('super_assessment', $assessment);

    return $output;
  }

  return "An error occurred — invalid assessment type\n";
}


# Attempt to select an answer to an in-progress assessment. We need to fail
# if the assessment isn't real, isn't owned by the user, or is already complete
sub select_answer
{
  my $self = shift;
  
  my $resp = $self->test_method('POST'); return $resp if defined $resp;
  
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }
  
  unless( defined $self->test_params([qw(magic question answer)]) )
  {
    my %dimensions;
    my $dbh = $self->database;
    my %magic = %{decode_json($self->params->{"magic"})};
    
    my $assessment_id = $magic{"a"};
    my $instance_id = $magic{"instance_id"};
    my $question = $self->params->{"question"};
    my $answer = $self->params->{"answer"};
    my $sub_assessment_id = $self->params->{"assessment"};
    
    
    if (defined($assessment_id) &&
        defined($sub_assessment_id) &&
        defined($instance_id) &&
        defined($question) &&
        defined($answer))
    {
      $dbh->prepare("begin transaction")->execute;
      
      # get some info about this instance.
      my $sth = $dbh->prepare("select assessment_id, user_id, completion_date from assessment_instance where instance_id = ?;");
      $sth->bind_param(1,$instance_id);
      $sth->execute;
      my $row = $sth->fetch;
      my $error = 0;

      $dbh->prepare("end transaction")->execute;

      if ($row)
      {
        # The instance exists. Check that it's for the assessment we're trying
        # to update, that it's owned by the correct user, and that it's not
        # complete.
        
        my ($ass, $user, $completion_date) = @{$row};
        unless (($assessment_id == $ass) && ($user_id == $user))
        {
          $error = 1;
        }
        
        if (defined($completion_date))
        {
          $error = 1;
        }
      }
      else
      {
        # New instance. Check the user has rights to access this assessment.
        $dbh->prepare("begin transaction")->execute;

        my @groups = $self->group_ids_for_user_id($user_id);
        my $group_list = join (",",@groups);


        $sth = $dbh->prepare("select a.assessment_id from assessment a, assessment_group ag where a.assessment_id = ? and ag.assessment_id = a.assessment_id and ag.group_id in ($group_list);");
        $sth->bind_param(1,$assessment_id);
        $sth->execute;
        if (my $row = $sth->fetch)
        {
          my $ass = $row->[0];
          if ($ass != $assessment_id)
          {
            $error = 1;
          }
        }
        $dbh->prepare("end transaction")->execute;

        unless($error)
        {
          $dbh->prepare("begin transaction")->execute;
          $sth = $dbh->prepare("insert into assessment_instance values (?, ?, ?, (select datetime('now')), null);");
          $sth->bind_param(1,$instance_id);
          $sth->bind_param(2,$user_id);
          $sth->bind_param(3,$assessment_id);
          $sth->execute;
          $dbh->prepare("end transaction")->execute;
        }
      }
      
      unless($error)
      {
        # At this point, we can be confident that we can enter a row
        
        $dbh->prepare("begin transaction")->execute;
        
        $sth = $dbh->prepare("select at.super_type from answer_type at, question q where q.answer_type_id = at.type_id and q.assessment_id = ? and q.question_id = ?");
        $sth->bind_param(1,$sub_assessment_id);
        $sth->bind_param(2,$question);
        $sth->execute;
        my $super_type = $sth->fetch->[0];
        
        if (($super_type == ANSWER_TYPE_LIKERT) ||
            ($super_type == ANSWER_TYPE_LISTBOX) ||
            ($super_type == ANSWER_TYPE_MULTI_CHOICE))
        {
          # Delete any old answers for this question, as they're no longer relevant.
          $sth = $dbh->prepare("delete from assessment_instance_likert_answer where instance_id = ? and assessment_id = ? and question_id = ?");
          $sth->bind_param(1,$instance_id);
          $sth->bind_param(2,$sub_assessment_id);
          $sth->bind_param(3,$question);
          $sth->execute;

          if ($super_type == ANSWER_TYPE_MULTI_CHOICE)
          {
            my $tmp = $answer;
            my $bit = 0;
            $answer = 0;
            
            
            while (my $char = chop($tmp))
            {
              if ($char eq "X")
              {
                $answer |= (1<<$bit);
              }
              $bit++;
            }
          }
          
          # Now insert the answer
          $sth = $dbh->prepare("insert into assessment_instance_likert_answer values(?,?,?,?);");
          $sth->bind_param(1,$instance_id);
          $sth->bind_param(2,$sub_assessment_id);
          $sth->bind_param(3,$question);
          $sth->bind_param(4,$answer);
          $sth->execute;
          
        }
        elsif (($super_type == ANSWER_TYPE_TEXT) ||
               ($super_type == ANSWER_TYPE_TEXTAREA))
        {

          $sth = $dbh->prepare("delete from assessment_instance_text_answer where instance_id = ? and assessment_id = ? and question_id = ?");
          $sth->bind_param(1,$instance_id);
          $sth->bind_param(2,$sub_assessment_id);
          $sth->bind_param(3,$question);
          $sth->execute;
          
          $sth = $dbh->prepare("insert into assessment_instance_text_answer values(?,?,?,?);");
          $sth->bind_param(1,$instance_id);
          $sth->bind_param(2,$sub_assessment_id);
          $sth->bind_param(3,$question);
          $sth->bind_param(4,$answer);
          $sth->execute;

        }            


        $dbh->prepare("end transaction")->execute;
      }
      
      unless ($error)
      {
        return $self->success_response();
      }
    }
  }
  return $self->failure_response("Invalid parameters", 400);
}



# Submit an answer set. We need to fail if the assessment isn't real, it isn't
# owned by the user, is already completed, or is missing answers.
sub perform_assessment
{
  my $self = shift;

  my $resp = $self->test_method('POST'); return $resp if defined $resp;

  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }
  
  unless( defined $self->test_params([qw(magic)]) )
  {
    my $dbh = $self->database;
    my %magic = %{decode_json($self->params->{"magic"})};
    
    my $instance_id = $magic{"instance_id"};
    my $assessment_id = undef;
    
    if (defined($instance_id))
    {

      # get some info about this instance.
      $dbh->prepare("begin transaction")->execute;
      my $sth = $dbh->prepare("select assessment_id, user_id, completion_date from assessment_instance where instance_id = ?;");
      $sth->bind_param(1,$instance_id);
      $sth->execute;
      my $row = $sth->fetch;
      my $error = 0;
      $dbh->prepare("end transaction")->execute;

      if ($row)
      {
        # The instance exists. Check that it's owned by the correct user, and
        # that it's not complete.
        
        my ($ass, $user, $completion_date) = @{$row};
        unless ($user_id == $user)
        {
          $error = 1;
        }
        
        if (defined($completion_date))
        {
          $error = 1;
        }
        
        unless ($error)
        {
          $assessment_id = $ass;          
        }
      }
      else
      {
        # It doesn't exist, so create it.
        $assessment_id = $magic{"a"};
        
        $dbh->prepare("begin transaction")->execute;
        $sth = $dbh->prepare("insert into assessment_instance values (?, ?, ?, (select datetime('now')), null);");
        $sth->bind_param(1,$instance_id);
        $sth->bind_param(2,$user_id);
        $sth->bind_param(3,$assessment_id);
        $sth->execute;
        $dbh->prepare("end transaction")->execute;

      }
      
      
      # Check that all questions have been answered.
      unless ($error)
      {

        # First insert any new answers that were sent along with the submit.
        foreach my $question_item (sort keys %{$self->params})
        {
          if ($question_item =~ /^a(\d+)_(\d+)$/)
          {
            my $sub_assessment_id = $1;
            my $question = $2;
            my $answer = $self->params->{$question_item};
            
            $sth = $dbh->prepare("select at.super_type from answer_type at, question q where q.answer_type_id = at.type_id and q.assessment_id = ? and q.question_id = ?");
            $sth->bind_param(1,$sub_assessment_id);
            $sth->bind_param(2,$question);
            $sth->execute;
            my $super_type = $sth->fetch->[0];
            
            if (($super_type == ANSWER_TYPE_LIKERT) ||
                ($super_type == ANSWER_TYPE_LISTBOX) ||
                ($super_type == ANSWER_TYPE_MULTI_CHOICE))
            {
              if ($super_type == ANSWER_TYPE_MULTI_CHOICE)
              {
                my $tmp = $answer;
                my $bit = 0;
                $answer = 0;
                
                while (my $char = chop($tmp))
                {
                  if ($char eq "X")
                  {
                    $answer |= (1<<$bit);
                  }
                  $bit++;
                }
              }
              
              if ($answer =~ /^\d+$/)
              {
                # Delete any old answers for this question, as they're no longer relevant.
                $dbh->prepare("begin transaction")->execute;
                $sth = $dbh->prepare("delete from assessment_instance_likert_answer where instance_id = ? and assessment_id = ? and question_id = ?");
                $sth->bind_param(1,$instance_id);
                $sth->bind_param(2,$sub_assessment_id);
                $sth->bind_param(3,$question);
                $sth->execute;
  
                # Now insert the answer
                $sth = $dbh->prepare("insert into assessment_instance_likert_answer values(?,?,?,?);");
                $sth->bind_param(1,$instance_id);
                $sth->bind_param(2,$sub_assessment_id);
                $sth->bind_param(3,$question);
                $sth->bind_param(4,$answer);
                $sth->execute;
                $dbh->prepare("end transaction")->execute;
              }
            }
            elsif (($super_type == ANSWER_TYPE_TEXT) ||
                   ($super_type == ANSWER_TYPE_TEXTAREA))
            {

              $dbh->prepare("begin transaction")->execute;
              $sth = $dbh->prepare("delete from assessment_instance_text_answer where instance_id = ? and assessment_id = ? and question_id = ?");
              $sth->bind_param(1,$instance_id);
              $sth->bind_param(2,$sub_assessment_id);
              $sth->bind_param(3,$question);
              $sth->execute;
              
              $sth = $dbh->prepare("insert into assessment_instance_text_answer values(?,?,?,?);");
              $sth->bind_param(1,$instance_id);
              $sth->bind_param(2,$sub_assessment_id);
              $sth->bind_param(3,$question);
              $sth->bind_param(4,$answer);
              $sth->execute;

              $dbh->prepare("end transaction")->execute;            
            }            
          }
        }

        # Now check that we have a full set of answers.
        my ($assessment_question_count, $instance_question_count);
        
        $assessment_question_count = $self->expected_answers($assessment_id);

        $dbh->prepare("begin transaction")->execute;
        $sth = $dbh->prepare("select count(*) from assessment_instance_likert_answer where instance_id = ?");
        $sth->bind_param(1,$instance_id);
        $sth->execute;
        $instance_question_count = $sth->fetch->[0];

        $sth = $dbh->prepare("select count(*) from assessment_instance_text_answer where instance_id = ?");
        $sth->bind_param(1,$instance_id);
        $sth->execute;
        $instance_question_count += $sth->fetch->[0];
        $dbh->prepare("end transaction")->execute;

        if ($assessment_question_count != $instance_question_count)
        {
          my @missing_answers = $self->missing_answers($instance_id, $assessment_id);

          return $self->response_as_json(200,{success => 0, reason => "missing answers.", missing_answers => \@missing_answers});
        }
      }
    
      unless ($error)
      {
        $dbh->prepare("begin transaction")->execute;
        my $sth = $dbh->prepare("update assessment_instance set completion_date = (select datetime('now')) where instance_id = ?;");
        $sth->bind_param(1,$instance_id);
        $sth->execute;
        $dbh->prepare("end transaction")->execute;
      }
      
      unless ($error)
      {
        my $output = $self->generate_summary($instance_id, $assessment_id);
        return $self->success_response("output" => $output);
      }
    }
  }
  
  return $self->failure_response("invalid parameters.", 400);
}


sub missing_answers
{
  my $self = shift;
  my $instance_id = shift;
  my $assessment_id = shift;
  my @missing_answers;

  my $dbh = $self->database;
  my $sth = $dbh->prepare("select assessment_type from assessment where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  my $assessment_type = $sth->fetch->[0];

  if ($assessment_type == 2)
  {
    $sth = $dbh->prepare("select sub_assessment_id from combined_assessment where assessment_id = ? order by index_id");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    while (my $row = $sth->fetch)
    {
      my $sub_assessment_id = $row->[0];
      @missing_answers = (@missing_answers, $self->missing_answers($instance_id, $sub_assessment_id));
    }
  }
  else
  {

    $sth = $dbh->prepare("select question_id from question where assessment_id = ? and question_id not in (select question_id from assessment_instance_likert_answer where instance_id = ? and assessment_id = ?) and question_id not in (select question_id from assessment_instance_text_answer where instance_id = ? and assessment_id = ?) order by question_id");
    $sth->bind_param(1,$assessment_id);
    $sth->bind_param(2,$instance_id);
    $sth->bind_param(3,$assessment_id);
    $sth->bind_param(4,$instance_id);
    $sth->bind_param(5,$assessment_id);
    $sth->execute;

    while (my $row = $sth->fetch)
    {
      my $answer;
      $answer->{"assessment_id"} = $assessment_id;
      $answer->{"question_id"} = $row->[0];

      push @missing_answers, $answer;
    }
  }

  return @missing_answers;

}

sub expected_answers
{
  my $self = shift;
  my $assessment_id = shift;
  my $count = 0;

  my $dbh = $self->database;
  my $sth = $dbh->prepare("select assessment_type from assessment where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  my $assessment_type = $sth->fetch->[0];

  if ($assessment_type == 2)
  {
    $sth = $dbh->prepare("select sub_assessment_id from combined_assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    while (my $row = $sth->fetch)
    {
      my $sub_assessment_id = $row->[0];
      $count += $self->expected_answers($sub_assessment_id);
    }
    return $count;
  }
  else
  {
    $sth = $dbh->prepare("select count(*) from question where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    $count = $sth->fetch->[0];
  }

  return $count;
}


sub generate_summary
{
  my ($self, $instance_id, $assessment_id) = @_;
  my $dbh = $self->database;
  my $output="";

  my $summary_sth = $dbh->prepare("select assessment_type, summary, summary2 from assessment where assessment_id = ?");
  $summary_sth->bind_param(1,$assessment_id);
  $summary_sth->execute();
  my $summary_row = $summary_sth->fetch;

  my $assessment_type = $summary_row->[0];
  my $summary = $summary_row->[1];
  my $summary2 = $summary_row->[2];

  if (defined($summary))
  {
    $summary = markdown($summary);
  }

  if (defined($summary2))
  {
    $summary2 = markdown($summary2);
  }

  my $dummy;
  $dummy->{dummy} = 1;
  if ($assessment_type == 2)
  {
    {
      my $caml = Text::Caml->new;
      $summary = $caml->render($summary,$dummy);
      $output .= "<p>$summary</p>";
    }

    my $sth = $dbh->prepare("select ca.sub_assessment_id, a.name from combined_assessment ca, assessment a where a.assessment_id = ca.sub_assessment_id and ca.assessment_id = ? order by ca.index_id");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    while (my $row = $sth->fetch)
    {
      my $sub_assessment_id = $row->[0];
      my $name = $row->[1];
      $output .= "<h1>$name</h1>\n";
      $output .= $self->generate_summary($instance_id, $sub_assessment_id);
      $output .= "<hr/>\n";
    }

    {
      my $caml = Text::Caml->new;
      $summary2 = $caml->render($summary2,$dummy);
      $output .= "<p>$summary2</p>\n";
    }
  }
  else
  {

    my %dimensions = $self->dimensions_for_assessment_instance($assessment_id, $instance_id);
    my %average_dimensions = $self->dimensions_for_assessment_averages($assessment_id);

    my %coded_scores;

    foreach my $dimension_id (sort keys %dimensions)
    {
      my $code = $dimensions{$dimension_id}{code};
      my $name = $dimensions{$dimension_id}{name};
      
      my $normalized_score = $dimensions{$dimension_id}{score}/$dimensions{$dimension_id}{count};
      $normalized_score++;
      $normalized_score *= 50;
      $coded_scores{$code} = int($normalized_score+0.5);

      my $normalized_average_score = $average_dimensions{$dimension_id}{score}/$average_dimensions{$dimension_id}{count};
      $normalized_average_score++;
      $normalized_average_score *= 50;
      $coded_scores{"average($code)"} = int($normalized_average_score+0.5);


      my $score = $coded_scores{$code};
      
      $score = $coded_scores{$code};
      my $average = $coded_scores{"average($code)"};
      
      my @gradients = ("royg","gyor","roygyor","oygyo");
      
      foreach my $gradient (@gradients)
      {
        $coded_scores{"$gradient"."($code)"} = gradient_box_html_for_gradient($gradient, $score);
        $coded_scores{"$gradient"."_with_average($code)"} = gradient_box_with_average_html_for_gradient($gradient, $score, $average);        
      }
      
      my %colour_map = 
      (
        "red"=>"#e00",
        "orange"=>"rgb(243,112,33)",
        "yellow"=>"#ee0",
        "green"=>"rgb(130,195,65)",
        "blue"=>"#44f"
      );
      
      foreach my $name (keys %colour_map)
      {
        my $colour = $colour_map{$name};
        $coded_scores{"$name"."($code)"} = gradient_box_html_for_colour($colour, $score);
        $coded_scores{"$name"."_with_average($code)"} = gradient_box_with_average_html_for_colour($colour, $score, $average);                
      }
      
      
      my $bar = '<div class="bar-container"><div class="bar" style="width:'.$score.'%"></div><div class="bar-label">&nbsp;'.$name.' — '.$score.'%</div></div>';
      $coded_scores{"bar($code)"} = $bar;
      
      $score *= 60;
      $score /= 100;
      $score -= 30;
      my $str = '<div class="arc-container"><div class="arc-inner-container"><div class="arc-outer-circle"><div class="arc-indicator" style="transform:rotate('.$score.'deg)"></div><div class="arc-inner-circle"></div><div class="arc-left-mask"></div><div class="arc-right-mask"></div></div></div></div>';
      $coded_scores{"arc($code)"} = $str;
    
      my $average_bar = '<div class="bar-container"><div class="average bar" style="width:'.$average.'%"></div><div class="bar-label">&nbsp;'.$name.' (average) — '.$average.'%</div></div>';
      $coded_scores{"bar(average($code))"} = $average_bar;
      
    }


    {
      my $caml = Text::Caml->new;
      $summary = $caml->render($summary,\%coded_scores);
      $output .= "<p>$summary</p>";
    }

    foreach my $dimension_id (sort keys %dimensions)
    {

      my $dim_sum = $dimensions{$dimension_id}{summary};
      my $caml = Text::Caml->new;
      if (defined($dim_sum))
      {
        $dim_sum = $caml->render($dim_sum, \%coded_scores);
        $dim_sum .= "<br/><br/>";
      }
      else
      {
        my $code = $dimensions{$dimension_id}{code};
        my $normalized_score = $coded_scores{$code};
        $dim_sum = "$dimensions{$dimension_id}{name}: $normalized_score\%<br/>";
      }
      $output .= $dim_sum;
    }
    
    {
      my $caml = Text::Caml->new;
      $summary2 = $caml->render($summary2,\%coded_scores);
      $output .= "<p>$summary2</p>";
    }
  }
  
  utf8::decode($output);
  
  return $output;
}


sub gradient_box_html_for_colour
{
  my ($colour,$score) = @_;
  my $html = '<div class="gradient" style="background:'.$colour.'"><div class="gradient-marker-container" style="margin-left:'.$score.'%"><div class="gradient-marker">'.$score.'%</div></div></div>';
  return $html;
}

sub gradient_box_with_average_html_for_colour
{
  my ($colour,$score,$average) = @_;
  my $html = '<div class="gradient" style="background:'.$colour.'"><div class="gradient-marker-container" style="margin-left:'.$score.'%"><div class="gradient-marker">'.$score.'%</div></div><div class="gradient-marker-container average" style="margin-left:'.$average.'%"><div class="gradient-marker average">'.$average.'%</div></div></div>';
  return $html;
}

sub gradient_box_html_for_gradient
{
  my ($gradient,$score) = @_;
  my $html = '<div class="gradient '.$gradient.'"><div class="gradient-marker-container" style="margin-left:'.$score.'%"><div class="gradient-marker">'.$score.'%</div></div></div>';
  return $html;
}

sub gradient_box_with_average_html_for_gradient
{
  my ($gradient,$score,$average) = @_;
  my $html = '<div class="gradient '.$gradient.'"><div class="gradient-marker-container" style="margin-left:'.$score.'%"><div class="gradient-marker">'.$score.'%</div></div><div class="gradient-marker-container average" style="margin-left:'.$average.'%"><div class="gradient-marker average">'.$average.'%</div></div></div>';
  return $html;
}


sub dimensions_for_assessment_averages
{
  my ($self, $assessment_id) = @_;
  my $dbh = $self->database;
  my %dimensions;

  my $dim_sth = $dbh->prepare("select dimension_id, code, name from assessment_dimension where assessment_id = ?");
  $dim_sth->bind_param(1,$assessment_id);
  $dim_sth->execute();

  while (my $row = $dim_sth->fetch)
  {
    my ($dimension_id, $code, $name) = @{$row};
    my %dimension;
    $dimension{"score"} = 0;
    $dimension{"count"} = 0;
    $dimension{"code"} = $code;
    $dimension{"name"} = $name;
    $dimensions{$dimension_id} = \%dimension;
  }

  my $qdim_sth = $dbh->prepare("select question_id, dimension_id, negate from question_dimension where assessment_id = ?");
  $qdim_sth->bind_param(1,$assessment_id);
  $qdim_sth->execute();

  my %question_dimensions;

  while (my $row = $qdim_sth->fetch)
  {
    my ($question_id, $dimension_id, $negate) = @{$row};
    $question_dimensions{$question_id}{$dimension_id} = $negate;
  }

  my %type_counts;

  my $chosen_answer_sth = $dbh->prepare('select at.type_id, aila.question_id, aila.step_id from assessment_instance_likert_answer aila, assessment_instance ai, question q, answer_type at where aila.instance_id = ai.instance_id and ai.completion_date != "" and q.question_id = aila.question_id and q.assessment_id = aila.assessment_id and aila.assessment_id = ? and q.answer_type_id = at.type_id and at.super_type = ?');
  $chosen_answer_sth->bind_param(1,$assessment_id);
  $chosen_answer_sth->bind_param(2,ANSWER_TYPE_LIKERT);
  $chosen_answer_sth->execute;
  
  while (my $row = $chosen_answer_sth->fetch)
  {
    my ($answer_type_id, $question_id, $chosen_answer) = @{$row};
    
    my $count = $type_counts{$answer_type_id};
    unless (defined($count))
    {
      my $answer_type_sth = $dbh->prepare("select count(*) from likert_step where type_id = ?");
      $answer_type_sth->bind_param(1,$answer_type_id);
      $answer_type_sth->execute();
      
      $count = $answer_type_sth->fetch->[0];
      $type_counts{$answer_type_id} = $count;
    }



    # convert 1..n into -1..1 because it's easier to handle reverse scoring and
    # assessments with different answer types
    $chosen_answer --;
    $chosen_answer /= ($count-1);
    $chosen_answer *= 2;
    $chosen_answer --;

    if (defined($question_dimensions{$question_id}))
    {            
      my %qdim = %{$question_dimensions{$question_id}};
      for my $dimension_id (keys %qdim)
      {
        my $negate = $qdim{$dimension_id};
        if (defined($negate))
        {
          if ($negate)
          {
            $dimensions{$dimension_id}{"score"} -= $chosen_answer;
          }
          else
          {
            $dimensions{$dimension_id}{"score"} += $chosen_answer;
          }
          $dimensions{$dimension_id}{"count"}++;
        }
      }
    }
  }
    
  
  return %dimensions;

}







sub slow_dimensions_for_assessment_averages
{
  my ($self, $assessment_id) = @_;
  my $dbh = $self->database;
  my %dimensions;
  
  my $sth = $dbh->prepare('select instance_id from assessment_instance where completion_date != "" and assessment_id = ?');
  $sth->bind_param(1,$assessment_id);
  $sth->execute;
  
  my $i = 0;
  while (my $row = $sth->fetch)
  {
    my $instance_id = $row->[0];
    my %tmp_dimensions = $self->dimensions_for_assessment_instance($assessment_id, $instance_id);
    if ($i == 0)
    {
      %dimensions = %tmp_dimensions;
    }
    else
    {
      foreach my $dimension_id (sort keys %dimensions)
      {
        $dimensions{$dimension_id}{score} += $tmp_dimensions{$dimension_id}{score};
        $dimensions{$dimension_id}{count} += $tmp_dimensions{$dimension_id}{count};
      }    
    }
    $i++;
  }
    
  return %dimensions;
}





sub dimensions_for_assessment_instance
{
  my ($self, $assessment_id, $instance_id) = @_;
  
  my $dbh = $self->database;
  
  my %dimensions;

  my $dim_sth = $dbh->prepare("select dimension_id, code, name, summary from assessment_dimension where assessment_id = ?");
  $dim_sth->bind_param(1,$assessment_id);
  $dim_sth->execute();

  while (my $row = $dim_sth->fetch)
  {
    my ($dimension_id, $code, $name, $summary) = @{$row};
    my %dimension;
    $dimension{"score"} = 0;
    $dimension{"count"} = 0;
    $dimension{"code"} = $code;
    $dimension{"name"} = $name;
    $dimension{"summary"} = defined($summary)?markdown($summary):undef;
    $dimensions{$dimension_id} = \%dimension;
  }

  my $question_sth = $dbh->prepare("select q.question_id, at.super_type, at.type_id from question q, answer_type at where q.assessment_id = ? and q.answer_type_id = at.type_id order by question_id");
  $question_sth->bind_param(1,$assessment_id);
  $question_sth->execute;

  while (my $row = $question_sth->fetch)
  {
    my ($question_id, $super_type, $answer_type_id) = @{$row};

    if ($super_type == ANSWER_TYPE_LIKERT)
    {
      my $chosen_answer_sth = $dbh->prepare("select step_id from assessment_instance_likert_answer where instance_id = ? and assessment_id = ? and question_id = ?");
      $chosen_answer_sth->bind_param(1,$instance_id);
      $chosen_answer_sth->bind_param(2,$assessment_id);
      $chosen_answer_sth->bind_param(3,$question_id);
      $chosen_answer_sth->execute;

      my $row = $chosen_answer_sth->fetch;
      if (defined($row))
      {
        my $chosen_answer = $row->[0];
  
        my $answer_type_sth = $dbh->prepare("select count(*) from likert_step where type_id = ?");
        $answer_type_sth->bind_param(1,$answer_type_id);
        $answer_type_sth->execute();
        
        my $count = $answer_type_sth->fetch->[0];
  
        # convert 1..n into -1..1 because it's easier to handle reverse scoring and
        # assessments with different answer types
        $chosen_answer --;
        $chosen_answer /= ($count-1);
        $chosen_answer *= 2;
        $chosen_answer --;
  
        my $qdim_sth = $dbh->prepare("select dimension_id, negate from question_dimension where assessment_id = ? and question_id = ?");
        $qdim_sth->bind_param(1,$assessment_id);
        $qdim_sth->bind_param(2,$question_id);
        $qdim_sth->execute();
  
        while (my $row = $qdim_sth->fetch)
        {
          my ($dimension_id, $negate) = @{$row};
          if ($negate)
          {
            $dimensions{$dimension_id}{"score"} -= $chosen_answer;
          }
          else
          {
            $dimensions{$dimension_id}{"score"} += $chosen_answer;
          }
          $dimensions{$dimension_id}{"count"}++;
        }
        
      }
    }
  }
  
  return %dimensions;
}



sub generate_assessment_pdf
{
  my $self = shift;
  my $resp;
  
  # Ensure we're logged in
  my $user_id = $self->get_user_id_from_cookie() unless (defined($resp));
  unless (defined($user_id))
  {
    return $self->redirect_via_login($self->request->uri);
  }
  
  my $dbh = $self->database;
  my $caml = $self->caml;

  my $user = Garden::User->new;
  my $has_accepted_tos = $user->has_accepted_tos($user_id);
  unless ($has_accepted_tos)
  {
    my $tos;
    my $caml = $self->caml;

    $tos->{banner} = $self->banner($user_id);
    $tos->{redirect} = $self->request->uri;
    my $output = $caml->render_file('tos', $tos);
    return $self->response_as_html($output);
  }



  my $assessment_id;
  my $instance_id = $self->params->{"instance_id"};


  # If there's an invitation_id, process it first to ensure the user is in the
  # relevant group
  my $invitation_id = $self->params->{"inv"};
  if (defined($invitation_id))
  {
    $user->process_invitation($user_id, $invitation_id);
  }
  
  my $assessment_is_complete = 0;
  
  if (defined($instance_id))
  {
    # Get some info about this instance.
    my $sth = $dbh->prepare("select assessment_id, user_id, completion_date from assessment_instance where instance_id = ?;");
    $sth->bind_param(1,$instance_id);
    $sth->execute;
    my $row = $sth->fetch;
    my $error = 0;
    
    if ($row)
    {
      my ($ass, $user, $completion_date) = @{$row};
      
      # Override the assessment id to be the one for the instance, just in case
      # someone sent us garbage.
      $assessment_id = $ass;
      
      unless ($user_id == $user)
      {
        # We were opened via a link to another user's instance. Create a new
        # instance via a redirection.
        $resp = HTTP::Response->new(302);
        $resp->header("Location", "./a?a=$assessment_id");
        return $resp;
      }
      
      $assessment_is_complete = (defined($completion_date));
    }
    else
    {
      $instance_id = undef;
    }
  }

  my @groups = $self->group_ids_for_user_id($user_id);
  my $group_list = join (",",@groups);

  if (defined($assessment_id))
  {
    my $sth = $dbh->prepare("select state from assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    my $row = $sth->fetch;
    if ($row)
    {
      my $state = $row->[0];

      my $can_view = ($assessment_is_complete || ($self->user_id_is_an_admin($user_id) && $state != Garden::STATE_ARCHIVED));

      if ((!$can_view) && ($state == Garden::STATE_PUBLISHED))
      {
        my $sth = $dbh->prepare("select count(*) from assessment_group ag where ag.assessment_id = ? and ag.group_id in ($group_list);");
        $sth->bind_param(1,$assessment_id);
        $sth->execute;
        $can_view = $sth->fetch->[0];

      }

      if ($can_view && $assessment_is_complete)
      {
        open (PDF,"/tmp/$instance_id.pdf");
        binmode(PDF);
        my $pdf = join ("",<PDF>);
        close (PDF);
        return $self->response_as_pdf($pdf);
      }
    }
  }
  $resp = HTTP::Response->new(302);
  $resp->header("Location", "./profile");
  return $resp;
}


# Answer type management

sub create_answer_type_new
{
  my $self = shift;
  my $resp;

  my $dbh = $self->database;
  my $caml = $self->caml;

  my @super_types;

  my $sth;
  
  push @super_types, {"super_type_id" => ANSWER_TYPE_LIKERT, "name" => "Likert scale"};
  push @super_types, {"super_type_id" => ANSWER_TYPE_LISTBOX, "name" => "Drop-down list"};
  push @super_types, {"super_type_id" => ANSWER_TYPE_MULTI_CHOICE, "name" => "Multiple-choice list"};

  my $answer_type;
  my $user_id = $self->get_user_id_from_cookie();

  $answer_type->{banner} = $self->banner($user_id);

  $answer_type->{super_types} = \@super_types;

  my $output = $caml->render_file('create_answer_type', $answer_type);
  utf8::encode($output);
  return $self->response_as_html($output);

}

sub create_answer_type
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

  $resp = $self->test_params([qw(name super_type options)]);

  unless (defined($resp))
  {
    my $name = $self->params->{"name"};
    my $super_type = $self->params->{"super_type"};    
    my $options = $self->params->{"options"};

    utf8::upgrade($options);

    $options = $self->clean_input($options);

    $options =~ s:^\s+::;
    $options =~ s:\n+:\n:g;
    $options =~ s:\s+$::;
    my @options = split(/\n/,$options);

    for (my $i = 0; $i < scalar(@options); $i++)
    {
      $options[$i] =~ s:^\s+::;
      $options[$i] =~ s:\s+$::;
    }
    
    my $sth = $dbh->prepare("select count(*) from answer_type where name = ?");
    $sth->bind_param(1, $name);
    $sth->execute;
    
    my $count = $sth->fetch->[0];
    if ($count)
    {
      return $self->failure_response("There's already an answer type called “$name”. Please choose a different name.", 400);
    }

    $count = scalar(@options);
    if (($super_type == ANSWER_TYPE_MULTI_CHOICE) && ($count > 50))
    {
      return $self->failure_response("Multiple-choice answers can have a maximum of 50 options. You supplied $count.", 400);
    }
    else
    {
      
      $sth = $dbh->prepare("insert into answer_type values (null, ?, ?)");
      $sth->bind_param(1, $name);
      $sth->bind_param(2, $super_type);
      $sth->execute;
      
      $sth = $dbh->prepare("select type_id from answer_type where name = ?");
      $sth->bind_param(1,$name);
      $sth->execute;
      
      my $type_id = $sth->fetch->[0];
      
      for (my $i = 0; $i < $count; $i++)      
      {
        my $option = $options[$i];
        $sth = $dbh->prepare("insert into likert_step values (?,?,?)");
        $sth->bind_param(1, $type_id);
        $sth->bind_param(2, $i);
        $sth->bind_param(3, $option);
        $sth->execute;
      }
        
      my %hashy;
      $hashy{"output"} = "Your new answer type was created successfully. You can now use it when creating or modifying an assessment.";
      return $self->success_response(%hashy);
    }
  }
  return $self->create_answer_type_new;
}


sub export_assessment
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

  my $assessment_id = $self->params->{"a"};
  my $include_user_details = (defined($self->params->{"u"}))?1:0;
  my $sanity = $self->params->{"x"};
  
  # if we were passed the flag for including user details (whether it was yes or no)
  # then we are being asked to generate the CSV. Otherwise present the page which
  # asks about including user details.
  
  if (defined($sanity))
  {
    my $filename = "/tmp/".rand(65536).".".rand(65536).".csv";
    generate_assessment_csv($filename, $include_user_details, $assessment_id);
    
    open (CSV,$filename);
    my $csv = join ("",<CSV>);
    close (CSV);
    system("rm $filename");
    
    my $sth = $dbh->prepare ("select name from assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    
    my $assessment_name = $sth->fetch->[0];
    $filename = $assessment_id . "_" . $assessment_name . ".csv";
    $filename =~ s:\s+:_:g;  
    return $self->response_as_csv($csv, $filename);

  }
  else
  {
    my $export = {};
    my $sth = $dbh->prepare("select name from assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    
    my $name = $sth->fetch->[0];
    $export->{a} = $assessment_id;
    $export->{name} = $name;
    $export->{banner} = $self->banner($user_id);
    
    my $output = $caml->render_file('assessment_export', $export);
    utf8::encode($output);
    return $self->response_as_html($output);

  }
}

sub generate_assessment_csv
{
  my $garden = Garden->new;
  my $dbh = $garden->database;
  my $filename = shift;
  my $include_user_details = shift;
  
  while (my $assessment_id = shift)
  {
    my @column_headings;
    my @rows;
    my @instance_ids;
    
    
    my $sth = $dbh->prepare ("select name from assessment where assessment_id = ?");
    $sth->bind_param(1,$assessment_id);
    $sth->execute;
    
    my $assessment_name = $sth->fetch->[0];

    unless (defined($filename))
    {
        $filename = $assessment_id . "_" . $assessment_name . ".csv";
        $filename =~ s:\s+:_:g;  
    }
    
    push @column_headings, "Date";
    
    if ($include_user_details)
    {
      push @column_headings, "User";
      push @column_headings, "UCID";
      push @column_headings, "Instance";
    }
    
    push @rows, \@column_headings;
    
    my $instance_sth = $dbh->prepare ('select ai.instance_id, ai.user_id, ai.completion_date, u.real_name, u.ucid from assessment_instance ai, user u where ai.assessment_id = ? and ai.completion_date != "" and u.user_id = ai.user_id order by ai.completion_date');
    $instance_sth->bind_param(1, $assessment_id);
    $instance_sth->execute;
    while (my $row = $instance_sth->fetch)
    {
      my $ignore_this_row = 0;
      my ($instance_id, $user_id, $completion_date, $real_name, $ucid) = @{$row};
      my @row;
      push (@row, $completion_date);      
      if ($include_user_details)
      {
        push (@row, $real_name);
        push (@row, $ucid);
        push (@row, $instance_id);
      }
      push @rows, \@row;
  
      push @instance_ids, $instance_id;
      
    }
    
    my @tmp_rows = rows_for_assessment_csv($dbh, $assessment_id, \@instance_ids);
    for (my $i = 0; $i < scalar(@rows); $i++)
    {
      my $row = $rows[$i];
      my $tmp_row = $tmp_rows[$i];
      my @row = @{$row};
      my @tmp_row = @{$tmp_row};
      my @new_row = (@row,@tmp_row);
      $rows[$i] = \@new_row;
    }      
    
    my $csv = Text::CSV->new ( { binary => 1 } )  # should set binary attribute.
                   or die "Cannot use CSV: ".Text::CSV->error_diag ();
                   
    $csv->eol ("\r\n");                 
    open my $fh, ">:encoding(utf8)", $filename or die "$filename: $!";
    $csv->print ($fh, $_) for @rows;
    close $fh or die "$filename: $!";
    
  }
}

sub rows_for_assessment_csv
{
  my $dbh = shift;
  my $assessment_id = shift;
  my $instance_ids = shift;
  my @instance_ids = @{$instance_ids};
  
  my @column_headings;
  my @rows;
  my @question_ids;

  my $sth = $dbh->prepare ("select assessment_type from assessment where assessment_id = ?");
  $sth->bind_param(1,$assessment_id);
  $sth->execute;

  my $assessment_type = $sth->fetch->[0];
  if ($assessment_type == 2)
  {
    my $sub_sth = $dbh->prepare("select sub_assessment_id from combined_assessment where assessment_id = ? order by index_id");
    $sub_sth->bind_param(1,$assessment_id);
    $sub_sth->execute;
    while (my $row = $sub_sth->fetch)
    {
      my $sub_assessment_id = $row->[0];
      my @tmp_rows = rows_for_assessment_csv($dbh, $sub_assessment_id, \@instance_ids);
      for (my $i = 0; $i < scalar(@tmp_rows); $i++)
      {
        my $row = $rows[$i];
        my $tmp_row = $tmp_rows[$i];
        my @row = (defined($row)?@{$row}:());
        my @tmp_row = @{$tmp_row};
        my @new_row = (@row,@tmp_row);
        $rows[$i] = \@new_row;
      }      
    }
  }
  else
  {    
    my $question_sth = $dbh->prepare ("select question_id, question_text from question where assessment_id = ? order by question_id");
    $question_sth->bind_param(1, $assessment_id);
    $question_sth->execute;
    while (my $row = $question_sth->fetch)
    {
      my ($question_id, $question_text) = @{$row};
      push (@question_ids, $question_id);
      push (@column_headings, $question_text);
    }
  
    push @rows, \@column_headings;
    
    foreach my $instance_id (@instance_ids)
    {      
      my @row;
      foreach my $question_id (@question_ids)
      {
        my $super_type_sth = $dbh->prepare("select super_type from answer_type where type_id = (select answer_type_id from question where assessment_id = ? and question_id = ?)");
        $super_type_sth->bind_param(1,$assessment_id);
        $super_type_sth->bind_param(2,$question_id);
        $super_type_sth->execute;
        my $row = $super_type_sth->fetch;
        if (defined($row))
        {
          my $super_type = $row->[0];
          if ($super_type == ANSWER_TYPE_TEXT || $super_type == ANSWER_TYPE_TEXTAREA)
          {
            my $answer_sth = $dbh->prepare("select answer from assessment_instance_text_answer where instance_id = ? and assessment_id = ? and question_id = ?");
            $answer_sth->bind_param(1,$instance_id);
            $answer_sth->bind_param(2,$assessment_id);
            $answer_sth->bind_param(3,$question_id);
            $answer_sth->execute;
            my $row = $answer_sth->fetch;
            if (defined($row))
            {
              my $answer = $row->[0];
              push @row, $answer;
            }
            else
            {
              push @row, "???";
            }        
          }
          else
          {
            my $answer_sth = $dbh->prepare("select step_id from assessment_instance_likert_answer where instance_id = ? and assessment_id = ? and question_id = ?");
            $answer_sth->bind_param(1,$instance_id);
            $answer_sth->bind_param(2,$assessment_id);
            $answer_sth->bind_param(3,$question_id);
            $answer_sth->execute;
            my $row = $answer_sth->fetch;
            if (defined($row))
            {
              my $step_id = $row->[0];
              push @row, $step_id;
            }
            else
            {
              push @row, "???";
            }        
          }
        }
        else
        {
          push @row, "???";
        }                
      }
      push @rows, \@row;
    }
  }
  return @rows;
}




1;
