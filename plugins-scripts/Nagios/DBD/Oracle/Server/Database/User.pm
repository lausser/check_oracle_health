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
    valid_days => $params{name} || 999999,
    status => $params{status},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
printf "%s\n", Data::Dumper::Dumper($self);
}

sub nagios {
  my $self = shift;
}

1;




