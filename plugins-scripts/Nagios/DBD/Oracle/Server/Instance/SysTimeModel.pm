package DBD::Oracle::Server::Instance::SysTimeModel;

use strict;

our @ISA = qw(DBD::Oracle::Server::Instance);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @systimemodel = ();
  my $initerrors = undef;

  sub add_systimemodel {
    push(@systimemodel, shift);
  }

  sub return_systimemodel {
    return reverse
        sort { $a->{name} cmp $b->{name} } @systimemodel;
  }

  sub init_systimemodel {
    my %params = @_;
    my $num_systimemodel = 0;
    my %longnames = ();
    if (($params{mode} =~ /server::instance::systimemodel::rate/) ||
        ($params{mode} =~ /server::instance::systimemodel::listsystimemodel/)) {
      my @systimemodelresults = $params{handle}->fetchall_array(q{
          SELECT stat_id, stat_name, value FROM v$sys_time_model
      });
      foreach (@systimemodelresults) {
        my ($number, $name, $value) = @{$_};
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
        $thisparams{value} = $value;

        my $systimemodel = DBD::Oracle::Server::Instance::SysTimeModel->new(
            %thisparams);
        add_systimemodel($systimemodel);
        $num_systimemodel++;
      }
      if (! $num_systimemodel) {
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
    
    value => $params{value},
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
  if ($params{mode} =~ /server::instance::systimemodel::rate/) {
    $params{differenciator} = lc $self->{name};
    $self->valdiff(\%params, qw(value));
    $self->{rate} = $self->{delta_value} / $self->{delta_timestamp};
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::systimemodel::rate/) {
      $self->add_nagios(
          $self->check_thresholds($self->{rate}, "10", "100"),
          sprintf "%.6f %s/sec", $self->{rate}, $self->{name});
      $self->add_perfdata(sprintf "'%s_per_sec'=%.6f;%s;%s",
          $self->{name},
          $self->{rate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "'%s'=%u",
          $self->{name},
          $self->{delta_value});
    }
  }
}

1;