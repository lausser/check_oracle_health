package DBD::Oracle::Server::Instance;

use strict;

our @ISA = qw(DBD::Oracle::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    sga => undef,
    processes => {},
    events => [],
    enqueues => [],
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::sga/) {
    $self->{sga} = DBD::Oracle::Server::Instance::SGA->new(%params);
  } elsif ($params{mode} =~ /server::instance::pga/) {
    $self->{pga} = DBD::Oracle::Server::Instance::PGA->new(%params);
  } elsif ($params{mode} =~ /server::instance::sysstat/) {
    DBD::Oracle::Server::Instance::Sysstat::init_sysstats(%params);
    if (my @sysstats =
        DBD::Oracle::Server::Instance::Sysstat::return_sysstats(%params)) {
      $self->{sysstats} = \@sysstats;
    } else {
      $self->add_nagios_critical("unable to aquire sysstats info");
    }
  } elsif ($params{mode} =~ /server::instance::event/) {
    DBD::Oracle::Server::Instance::Event::init_events(%params);
    if (my @events =
        DBD::Oracle::Server::Instance::Event::return_events(%params)) {
      $self->{events} = \@events;
    } else {
      $self->add_nagios_critical("unable to aquire event info");
    }
  } elsif ($params{mode} =~ /server::instance::enqueue/) {
    DBD::Oracle::Server::Instance::Enqueue::init_enqueues(%params);
    if (my @enqueues =
        DBD::Oracle::Server::Instance::Enqueue::return_enqueues(%params)) {
      $self->{enqueues} = \@enqueues;
    } else {
      $self->add_nagios_critical("unable to aquire enqueue info");
    }
  } elsif ($params{mode} =~ /server::instance::session/) {
    DBD::Oracle::Server::Instance::Session::init_sessions(%params);
    if ($DBD::Oracle::Server::Instance::Session::initerrors) {
      $self->add_nagios_critical("unable to aquire session info");
    } else {
      @{$self->{sessions}} =
          @DBD::Oracle::Server::Instance::Session::sessions;
    }
  } elsif ($params{mode} =~ /server::instance::connectedusers/) {
    $self->{connected_users} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM v$session WHERE type = 'USER' 
    });
  } elsif ($params{mode} =~ /server::instance::rman::backup::problems/) {
    $self->{rman_backup_problems} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM v$rman_status 
        WHERE
          operation = 'BACKUP'
        AND
          status != 'COMPLETED'
        AND          
          status != 'RUNNING' 
        AND
          start_time > sysdate-3
    });
  } elsif ($params{mode} =~ /server::instance::processusage/) {
    $self->{process_usage} = $self->{handle}->fetchrow_array(q{
        SELECT current_utilization/limit_value*100 
        FROM v$resource_limit WHERE resource_name LIKE '%processes%'
    });
  } elsif ($params{mode} =~ /server::instance::jobs::failed/) {
    @{$self->{failed_jobs}} = $self->{handle}->fetchall_array(q{
        SELECT
          job_log.job_name, job_log.log_date
        FROM
          dba_scheduler_job_log job_log, (
              SELECT
                MAX(log_date) max_date, job_name
              FROM
                dba_scheduler_job_log
              GROUP BY
                job_name
          ) last_run
        WHERE
          job_log.status = 'FAILED' AND
          job_log.log_date > sysdate - (? / 1440) AND
          last_run.max_date = job_log.log_date AND
          -- stream propagation jobs are oracle internal
          job_class <> 'AQ$_PROPAGATION_JOB_CLASS'
    }, ($params{lookback} || 30));
  } elsif ($params{mode} =~ /server::instance::jobs::scheduled/) {
    ($self->{num_scheduled_jobs}) = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM dba_scheduler_jobs
    });
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if ($params{mode} =~ /server::instance::sga/) {
    $self->{sga}->nagios(%params);
    $self->merge_nagios($self->{sga});
  } elsif ($params{mode} =~ /server::instance::pga/) {
    $self->{pga}->nagios(%params);
    $self->merge_nagios($self->{pga});
  } elsif ($params{mode} =~ /server::instance::event::listevents/) {
    foreach (sort { $a->{name} cmp $b->{name} } @{$self->{events}}) {
      printf "%10u%s %s %s\n", $_->{event_id}, $_->{idle} ? '*' : '', $_->{shortname}, $_->{name};
    }
    $self->add_nagios_ok("have fun");
  } elsif ($params{mode} =~ /server::instance::event/) {
    foreach (@{$self->{events}}) {
      $_->nagios(%params);
      $self->merge_nagios($_);
    }
    if (! $self->{nagios_level} && ! $params{selectname}) {
      $self->add_nagios_ok("no wait problems");
    }
  } elsif ($params{mode} =~ /server::instance::sysstat::listsysstat/) {
    foreach (sort { $a->{name} cmp $b->{name} } @{$self->{sysstats}}) {
      printf "%10d %s\n", $_->{number}, $_->{name};
    }
    $self->add_nagios_ok("have fun");
  } elsif ($params{mode} =~ /server::instance::sysstat/) {
    foreach (@{$self->{sysstats}}) {
      $_->nagios(%params);
      $self->merge_nagios($_);
    }
    if (! $self->{nagios_level} && ! $params{selectname}) {
      $self->add_nagios_ok("no wait problems");
    }
  } elsif ($params{mode} =~ /server::instance::enqueue::listenqueues/) {
    foreach (sort { $a->{name} cmp $b->{name} } @{$self->{enqueues}}) {
      printf "%s\n", $_->{name};
    }
    $self->add_nagios_ok("have fun");
  } elsif ($params{mode} =~ /server::instance::enqueue/) {
    foreach (@{$self->{enqueues}}) {
      $_->nagios(%params);
      $self->merge_nagios($_);
    }
    if (! $self->{nagios_level} && ! $params{selectname}) {
      $self->add_nagios_ok("no enqueue problem");
    }
  } elsif ($params{mode} =~ /server::instance::connectedusers/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connected_users}, 50, 100),
          sprintf "%d connected users",
              $self->{connected_users});
      $self->add_perfdata(sprintf "connected_users=%d;%d;%d",
          $self->{connected_users},
          $self->{warningrange}, $self->{criticalrange});
  } elsif ($params{mode} =~ /server::instance::rman::backup::problems/) {
      $self->add_nagios(
          $self->check_thresholds($self->{rman_backup_problems}, 1, 2),
          sprintf "rman had %d problems during the last 3 days",
              $self->{rman_backup_problems});
      $self->add_perfdata(sprintf "rman_backup_problems=%d;%d;%d",
          $self->{rman_backup_problems},
          $self->{warningrange}, $self->{criticalrange});
  } elsif ($params{mode} =~ /server::instance::session::usage/) {
      $self->{session_usage} =
          $DBD::Oracle::Server::Instance::Session::session_usage;
      $self->add_nagios(
          $self->check_thresholds($self->{session_usage}, 80, 100),
          sprintf "%.2f%% of session resources used",
              $self->{session_usage});
      $self->add_perfdata(sprintf "session_usage=%.2f%%;%d;%d",
          $self->{session_usage},
          $self->{warningrange}, $self->{criticalrange});
  } elsif ($params{mode} =~ /server::instance::session::blocked/) {
    if (! @{$self->{sessions}}) {
      $self->add_nagios_ok("no blocking sessions");
    } else {
      foreach (@{$self->{sessions}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
      #if (! $self->{nagios_level} && ! $params{selectname}) {
      #  $self->add_nagios_ok("no enqueue problem");
      #}
    }
  } elsif ($params{mode} =~ /server::instance::processusage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{process_usage}, 80, 100),
          sprintf "%.2f%% of process resources used",
              $self->{process_usage});
      $self->add_perfdata(sprintf "process_usage=%.2f%%;%d;%d",
          $self->{process_usage},
          $self->{warningrange}, $self->{criticalrange});
  } elsif ($params{mode} =~ /server::instance::jobs::failed/) {
    $self->add_nagios(
        $self->check_thresholds(scalar(@{$self->{failed_jobs}}), 0, 0),
        sprintf "%d jobs have failed in the last %d minutes",
            scalar(@{$self->{failed_jobs}}), $params{lookback} || 30);
    if ($self->{nagios_level}) {
      $self->add_nagios_ok(join(", ", map {
        $_->[0].'@'.$_->[1];
      } @{$self->{failed_jobs}}));
    }
  } elsif ($params{mode} =~ /server::instance::jobs::scheduled/) {
      $self->add_nagios(
          $self->check_thresholds($self->{num_scheduled_jobs}, 200, 300),
          sprintf "%d scheduler jobs", $self->{num_scheduled_jobs});
      $self->add_perfdata(sprintf "num_scheduler_jobs=%.2f;%s;%s",
          $self->{num_scheduled_jobs}, $self->{warningrange}, $self->{criticalrange});
  }
}


1;
