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
  if ($params{mode} =~ /server::database::dataguard::lag/) {
    ($self->{last_applied_time}, $self->{lag_minutes}) =
        $self->{handle}->fetchrow_array(q{
          select to_char(max(first_time),'YYYYMMDDHH24MISS')
            , ceil((sysdate-max(first_time))*24*60)
          from v$archived_log
          where applied='YES' and registrar='RFS'
        });     
    if (! defined $self->{last_applied_time}) {
      $self->add_nagios_critical("Unable to get archived log apply time");
    }
  } elsif ($params{mode} =~ /server::database::dataguard::mrp_status/) {
    ($self->{log_transport}) =
        $self->{handle}->fetchrow_array(q{
          select decode(count(*),0,'ARCH','LGWR') as log_transport
          from v$managed_standby
          where client_process='LGWR'
        });     
    if (! defined $self->{log_transport}) {
      $self->add_nagios_critical("Unable to identify log transport method");
    }

    ($self->{mrp_process}, $self->{mrp_status}) =
        $self->{handle}->fetchrow_array(q{
          select process, status
          from v$managed_standby
          where process like 'MR%'
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
      $self->add_perfdata(sprintf "dataguard_mrp_status=%s", $self->{mrp_status});
      $self->add_perfdata(sprintf "dataguard_log_transport=%s", $self->{log_transport});
    }
  }
}

