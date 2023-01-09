package DBD::Oracle::Server::Instance::SysWaitClass;

use strict;

our @ISA = qw(DBD::Oracle::Server::Instance);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @syswaitclass = ();
  my $initerrors = undef;

  sub add_syswaitclass {
    push(@syswaitclass, shift);
  }

  sub return_syswaitclass {
    return reverse
        sort { $a->{name} cmp $b->{name} } @syswaitclass;
  }

  sub init_syswaitclass {
    my %params = @_;
    my $num_syswaitclass = 0;
    my %longnames = ();
    if (($params{mode} =~ /server::instance::syswaitclass::rate/) ||
        ($params{mode} =~ /server::instance::syswaitclass::listsyswaitclass/)) {
      my @syswaitclassresults = $params{handle}->fetchall_array(q{
          SELECT WAIT_CLASS_ID, WAIT_CLASS, TOTAL_WAITS, TOTAL_WAITS_FG, TIME_WAITED, TIME_WAITED_FG FROM v$system_wait_class
      });
      foreach (@syswaitclassresults) {
        my ($number, $name, $total_waits, $total_waits_fg, $time_waited, $time_waited_fg) = @{$_};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if ($params{selectname} && (
              ($params{selectname} !~ /^\d+$/ && (lc $params{selectname} ne lc $name)) ||
              ($params{selectname} =~ /^\d+$/ && ($params{selectname} != $number))));
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{number} = $number;
        $thisparams{total_waits} = $total_waits;
        $thisparams{total_waits_fg} = $total_waits_fg;
        $thisparams{time_waited} = $time_waited;
        $thisparams{time_waited_fg} = $time_waited_fg;

        my $syswaitclass = DBD::Oracle::Server::Instance::SysWaitClass->new(
            %thisparams);
        add_syswaitclass($syswaitclass);
        $num_syswaitclass++;
      }
      if (! $num_syswaitclass) {
        $initerrors = 1;
        return undef;
      }
    }
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    name => $params{name},
    number => $params{number},
    total_waits => $params{total_waits},
    total_waits_fg => $params{total_waits_fg},
    time_waited => $params{time_waited},
    time_waited_fg => $params{time_waited_fg},
    rate => $params{rate},
    count => $params{count},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  #$self->{name} =~ s/^\s+//;
  #$self->{name} =~ s/\s+$//;
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::syswaitclass::rate/) {
    $params{differenciator} = lc $self->{name};
    $self->valdiff(\%params, qw(time_waited));
    my $timedelta=$self->{delta_timestamp};
    $self->{time_waited_rate} = $self->{delta_time_waited} / $timedelta;
    $self->valdiff(\%params, qw(time_waited_fg));
    $self->{time_waited_fg_rate} = $self->{delta_time_waited_fg} / $timedelta;
    $self->valdiff(\%params, qw(total_waits));
    $self->{total_waits_rate} = $self->{delta_total_waits} / $timedelta;
    $self->valdiff(\%params, qw(total_waits_fg));
    $self->{total_waits_fg_rate} = $self->{delta_total_waits_fg} / $timedelta;

  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::syswaitclass::rate/) {
      $self->add_nagios(
          $self->check_thresholds($self->{time_waited_rate}, "10", "100"),
          sprintf "%.6f %s/sec", $self->{time_waited_rate}, $self->{name});
      $self->add_perfdata(sprintf "'%s_%s_per_sec'=%.6f;%s;%s",
          $self->{name},'time_waited',
          $self->{time_waited_rate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "'%s_%s_per_sec'=%.6f;%s;%s",
          $self->{name},'time_waited_fg',
          $self->{time_waited_fg_rate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "'%s_%s_per_sec'=%.6f;%s;%s",
          $self->{name},'total_waits',
          $self->{total_waits_rate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "'%s_%s_per_sec'=%.6f;%s;%s",
          $self->{name},'total_waits_fg',
          $self->{total_waits_fg_rate},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}

1;
