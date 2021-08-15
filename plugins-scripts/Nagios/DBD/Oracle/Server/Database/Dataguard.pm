package DBD::Oracle::Server::Database::Dataguard;

use strict;

our @ISA = qw(DBD::Oracle::Server::Database);

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    verbose => $params{verbose},
    handle => $params{handle},
    name => $params{name},
    last_applied_time => undef,
    lag_minutes => undef,
    log_transport => undef,
    mrp_process => undef,
    mrp_status => undef,
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  ($self->{database_role}) =
      $self->{handle}->fetchrow_array(q{
          SELECT
              name, database_role
          FROM
              v$database
      });
  if ($params{mode} =~ /server::database::dataguard::lag/) {
    ($self->{last_applied_time}, $self->{lag_minutes}) =
        $self->{handle}->fetchrow_array(q{
          SELECT
              TO_CHAR(MAX(first_time),'YYYYMMDDHH24MISS'),
              CEIL((SYSDATE - MAX(first_time)) * 24 * 60)
          FROM
              v$archived_log
          WHERE
              applied NOT IN ('NO') AND registrar = 'RFS'
        });     
#    ($self->{last_applied_time}, $self->{lag_minutes}) =
#        $self->{handle}->fetchrow_array(q{
#          -- returns NULL on the primary node
#          SELECT
#              SYSDATE +
#              TO_NUMBER(SUBSTR(value, 2, 2)) +
#              TO_NUMBER(SUBSTR(value, 5, 2)) / 24 +
#              TO_NUMBER(SUBSTR(value, 8, 2)) / 24 / 60 AS max_first_time,
#              ((TO_NUMBER(substr(value, 2, 2))) * 24 + TO_NUMBER(SUBSTR(value, 5, 2))) * 60 +
#              TO_NUMBER(SUBSTR(value, 8, 2)) AS dg_apply_lag_minutes
#          FROM
#              V$DATAGUARD_STATS
#          WHERE
#              name = 'apply lag'
#        });
    if (! defined $self->{last_applied_time} || $self->{last_applied_time} eq "") {
      $self->add_nagios_critical("Unable to get archived log apply time");
    }
  } elsif ($params{mode} =~ /server::database::dataguard::mrp_status/) {
    ($self->{log_transport}) =
        $self->{handle}->fetchrow_array(q{
          SELECT
              DECODE(COUNT(*),0,'ARCH','LGWR') AS log_transport
          FROM
              v$managed_standby
          WHERE
              client_process = 'LGWR'
        });     
    if (! defined $self->{log_transport}) {
      $self->add_nagios_critical("Unable to identify log transport method");
    }

    ($self->{mrp_process}, $self->{mrp_status}) =
        $self->{handle}->fetchrow_array(q{
          SELECT
              process, status
          FROM
              v$managed_standby
          WHERE
              process LIKE 'MR%'
        });     
    if (! defined $self->{mrp_process}) {
      $self->add_nagios_critical("Unable to find MRP process, managed recovery may be stopped");
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::database::dataguard::lag/) {
      $self->add_nagios(
          $self->check_thresholds($self->{lag_minutes}, "60", "120"),
          sprintf "Dataguard standby lag %d minutes.", $self->{lag_minutes});
      $self->{warningrange} =~ s/://g;
      $self->{criticalrange} =~ s/://g;
      $self->add_perfdata(sprintf "dataguard_lag=%d;%d;%d",
          $self->{lag_minutes}, 
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::database::dataguard::mrp_status/) {
      my $mrp_message = sprintf "Dataguard managed recovery process %s status is %s.", $self->{mrp_process}, $self->{mrp_status};
      if ($self->{mrp_status} eq "APPLYING_LOG") {
        $self->add_nagios_ok($mrp_message);
      } elsif ($self->{mrp_status} eq "WAIT_FOR_LOG") {
	# OK if log_transport is ARCH, but not if LGWR
        $mrp_message .= sprintf " Log transport is %s.", $self->{log_transport};
        if ($self->{log_transport} eq "LGWR") {
          $self->add_nagios_warning($mrp_message);
        } else {
          $self->add_nagios_ok($mrp_message);
        }
      } else {
        $self->add_nagios_critical($mrp_message);
      }
    }
  }
}

