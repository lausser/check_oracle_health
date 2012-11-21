package DBD::Oracle::Server::Database::User;

use strict;

our @ISA = qw(DBD::Oracle::Server::Database);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @users = ();
  my $initerrors = undef;

  sub add_user {
    push(@users, shift);
  }

  sub return_users {
    return reverse
        sort { $a->{name} cmp $b->{name} } @users;
  }

  sub init_users {
    my %params = @_;
    my $num_users = 0;
    if (($params{mode} =~ /server::database::expiredpw/)) {
      my @pwresult = $params{handle}->fetchall_array(q{
          SELECT
              username, expiry_date - sysdate, account_status
          FROM
              dba_users
      });
      foreach (@pwresult) {
        my ($name, $valid_days, $status) = @{$_};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{valid_days} = $valid_days;
        $thisparams{status} = $status;
        my $user = DBD::Oracle::Server::Database::User->new(
            %thisparams);
        add_user($user);
        $num_users++;
      }
      if (! $num_users) {
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
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    name => $params{name},
    valid_days => $params{valid_days} || 999999,
    status => $params{status},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  $self->init_nagios();
}

sub nagios {
  my $self = shift;
  if ($self->{status} eq "EXPIRED") {
    $self->add_nagios_critical(sprintf "password of user %s has expired",
        $self->{name});
  } elsif ($self->{status} eq "EXPIRED (GRACE)") {
    $self->add_nagios_warning(sprintf "password of user %s soon expires",
        $self->{name});
  } elsif ($self->{status} eq "LOCKED (TIMED)") {
    $self->add_nagios_warning(sprintf "user %s is temporarily locked",
        $self->{name});
  } elsif ($self->{status} eq "LOCKED") {
    $self->add_nagios_critical(sprintf "user %s is locked",
        $self->{name});
  } elsif ($self->{status} eq "EXPIRED & LOCKED(TIMED)") {
    $self->add_nagios_critical(sprintf "password of user %s has expired and is temporarily locked",
        $self->{name});
  } elsif ($self->{status} eq "EXPIRED(GRACE) & LOCKED(TIMED)") {
    $self->add_nagios_warning(sprintf "password of user %s soon expires and is temporarily locked",
        $self->{name});
  } elsif ($self->{status} eq "EXPIRED & LOCKED") {
    $self->add_nagios_critical(sprintf "password of user %s has expired and is locked",
        $self->{name});
  } elsif ($self->{status} eq "EXPIRED(GRACE) & LOCKED") {
    $self->add_nagios_critical(sprintf "password of user %s soon expires and is locked",
        $self->{name});
  }
  if ($self->{status} eq "OPEN") {
    if (defined $self->{valid_days}) {
      $self->add_nagios(
          $self->check_thresholds($self->{valid_days}, "7:", "3:"),
          sprintf("password of user %s will expire in %d days",
              $self->{name}, $self->{valid_days}));
      $self->add_perfdata(sprintf "\'pw_%s_valid\'=%.2f;%s;%s",
          lc $self->{name}, $self->{valid_days},
          $self->{warningrange}, $self->{criticalrange});
    } else {
      $self->add_nagios_ok(sprintf "password of user %s will never expire",
          $self->{name});
      $self->add_perfdata(sprintf "\'pw_%s_valid\'=0;0;0",
          lc $self->{name});
    }
  }
}

1;




