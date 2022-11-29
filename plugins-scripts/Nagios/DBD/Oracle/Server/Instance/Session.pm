package DBD::Oracle::Server::Instance::Session;

use strict;

our @ISA = qw(DBD::Oracle::Server::Instance);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  our @sessions = ();
  our $initerrors = undef;
  our $session_usage = 0;

  sub add_session {
    push(@sessions, shift);
  }

  sub return_sessions {
    return reverse 
        sort { $a->{name} cmp $b->{name} } @sessions;
  }

  sub init_sessions {
    my %params = @_;
    my $num_sessions = 0;
    if ($params{mode} =~ /server::instance::session::usage/) {
      $session_usage = $params{handle}->fetchrow_array(q{
          SELECT
              current_utilization / limit_value * 100
          FROM
              v$resource_limit
          WHERE
              resource_name = 'sessions'
          -- FROM v$resource_limit WHERE resource_name LIKE '%sessions%'
      });
      if (! defined $session_usage) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::instance::session::blocked/) {
      my @sessionresults = $params{handle}->fetchall_array(q{
        -- https://www.dbmasters.at/db/masters/artikel/monitoring-aber-richtig-teil-1-blocking-sessions
        WITH v_session AS (
           SELECT username,
                  osuser,
                  inst_id,
                  sid,
                  serial#,
                  terminal,
                  event,
                  sql_id,
                  status,
                  seconds_in_wait,
                  blocking_instance,
                  blocking_session
              FROM gv$session)
        SELECT  lpad(' ',level) || username AS username_,
                osuser osuser_,
                inst_id,
                sid AS sid_,
                serial#,
                terminal AS terminal_,
                event AS event_,
                sql_id,
                status,
                seconds_in_wait,
                blocking_instance,
                blocking_session AS blocker_
           FROM v_session s
           START WITH blocking_session IS NULL
              AND EXISTS (
                 SELECT 1
                    FROM v_session i_s
                    WHERE i_s.blocking_session = s.sid
                      AND i_s.blocking_instance = s.inst_id)
           CONNECT BY blocking_session = PRIOR sid
                  AND blocking_instance = PRIOR inst_id
      });
      foreach (@sessionresults) {
        my ($username, $osuser, $inst_id, $sid, $serial, $terminal, $event,
            $sql_id, $status, $seconds_in_wait, $blocking_instance,
            $blocking_session) = @{$_};
        my %thisparams = %params;
        $thisparams{username} = $username;
        $thisparams{osuser} = $osuser;
        $thisparams{inst_id} = $inst_id;
        $thisparams{sid} = $sid;
        $thisparams{serial} = $serial;
        $thisparams{terminal} = $terminal;
        $thisparams{event} = $event;
        $thisparams{sql_id} = $sql_id;
        $thisparams{status} = $status;
        $thisparams{seconds_in_wait} = $seconds_in_wait;
        $thisparams{blocking_instance} = $blocking_instance;
        $thisparams{blocking_session} = $blocking_session;
        my $session = DBD::Oracle::Server::Instance::Session->new(
            %thisparams);
        add_session($session);
        $num_sessions++;
      }
      if (! $num_sessions && $params{mode} !~ /server::instance::session::blocked/) {
        $initerrors = 1;
        return undef;
      }
    }
  }
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {};
  foreach my $key (qw(username osuser inst_id sid serial terminal
      event sql_id status seconds_in_wait blocking_instance blocking_session
      warningrange criticalrange)) {
    if (exists $params{$key}) {
      $self->{$key} = $params{$key};
      $self->{$key} =~ s/^\s*//g if $self->{$key};
      $self->{$key} =~ s/\s*$//g if $self->{$key};
    }
  }
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::session::blocked/) {
    # sind eh alle blocked und somit fehlerhaft
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::session::blocked/) {
      my $user = $self->{username};
      $user .= sprintf " (os-user: %s)", $self->{osuser};
      $self->add_nagios_critical(
          sprintf "session %s of user %s is blocking since %ds",
              $self->{sid}, $user, $self->{seconds_in_wait});
    }
  }
}


1;
