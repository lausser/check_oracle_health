package DBD::Oracle::Server::Database;

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
    invalidobjects => {
        invalid_objects => undef,
        invalid_indexes => undef,
        invalid_ind_partitions => undef,
    },
    staleobjects => undef,
    tablespaces => [],
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::database::tablespace/) {
    DBD::Oracle::Server::Database::Tablespace::init_tablespaces(%params);
    if (my @tablespaces = 
        DBD::Oracle::Server::Database::Tablespace::return_tablespaces()) {
      $self->{tablespaces} = \@tablespaces;
    } else {
      $self->add_nagios_critical("unable to aquire tablespace info");
    }
  } elsif ($params{mode} =~ /server::database::invalidobjects/) {
    $self->init_invalid_objects(%params);
  } elsif ($params{mode} =~ /server::database::stalestats/) {
    $self->init_stale_objects(%params);
  }
}

sub init_invalid_objects {
  my $self = shift;
  my %params = @_;
  my $invalid_objects = undef;
  my $invalid_indexes = undef;
  my $invalid_ind_partitions = undef;
  my $unrecoverable_datafiles = undef;
  $self->{invalidobjects}->{invalid_objects} =
      $self->{handle}->fetchrow_array(q{
          SELECT COUNT(*) 
          FROM dba_objects 
          WHERE status = 'INVALID' AND object_name NOT LIKE 'BIN$%'
      });
  # should be only N/A or VALID
  $self->{invalidobjects}->{invalid_indexes} =
      $self->{handle}->fetchrow_array(q{
          SELECT COUNT(DISTINCT STATUS) 
          FROM dba_indexes 
          WHERE status <> 'VALID' AND status <> 'N/A'
      });
  # should be only USABLE
  $self->{invalidobjects}->{invalid_ind_partitions} =
      $self->{handle}->fetchrow_array(q{
          SELECT COUNT(DISTINCT STATUS) 
          FROM dba_ind_partitions 
          WHERE status <> 'USABLE'
      });
  if (! defined $self->{invalidobjects}->{invalid_objects} ||
      ! defined $self->{invalidobjects}->{invalid_indexes} ||
      ! defined $self->{invalidobjects}->{invalid_ind_partitions}) {
    $self->add_nagios_critical("unable to get invalid objects");
    return undef;
  }
}

sub init_stale_objects {
  my $self = shift;
  my %params = @_;
  if ($self->version_is_minimum("10.x")) {
    $self->{staleobjects} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM sys.dba_tab_statistics WHERE stale_stats = 'YES'
    });
  } else {
    # oracle9 + sqlplus nix gut
    $self->{handle}->func( 10000, 'dbms_output_enable' );
    $self->{handle}->execute(q{
      DECLARE
        l_objList dbms_stats.objectTab;
      BEGIN
        DBMS_OUTPUT.ENABLE (1000000);
        dbms_stats.gather_database_stats( 
          options => 'LIST STALE',
          objlist => l_objList );
        dbms_output.put_line( l_objList.COUNT);
        -- FOR i IN 1 .. l_objList.COUNT
        -- LOOP
        --  dbms_output.put_line( l_objList(i).objType );
        --  dbms_output.put_line( l_objList(i).objName );
        -- END LOOP;
      END;
    });
    $self->{staleobjects} = $self->{handle}->func( 'dbms_output_get' );
  }
  if (! defined $self->{staleobjects}) {
    $self->add_nagios_critical("unable to get stale objects");
    return undef;
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::database::tablespace::listtablespaces/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{tablespaces}}) {
	printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::database::tablespace/) {
      foreach (@{$self->{tablespaces}}) {
        # sind hier noch nach pctused sortiert
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::database::invalidobjects/) {
      my @message = ();
      push(@message, sprintf "%d invalid objects",
          $self->{invalidobjects}->{invalid_objects}) if
          $self->{invalidobjects}->{invalid_objects};
      push(@message, sprintf "%d invalid indexes",
          $self->{invalidobjects}->{invalid_indexes}) if
          $self->{invalidobjects}->{invalid_indexes};
      push(@message, sprintf "%d invalid index partitions",
          $self->{invalidobjects}->{invalid_ind_partitions}) if
          $self->{invalidobjects}->{invalid_ind_partitions};
      if (scalar(@message)) {
        $self->add_nagios($self->check_thresholds(
            $self->{invalidobjects}->{invalid_objects} +
            $self->{invalidobjects}->{invalid_indexes} +
            $self->{invalidobjects}->{invalid_ind_partitions}, 0.1, 0.1),
            join(", ", @message));
      } else {
        $self->add_nagios_ok("no invalid objects found");
      }
      foreach (sort keys %{$self->{invalidobjects}}) {
        $self->add_perfdata(sprintf "%s=%d", $_, $self->{invalidobjects}->{$_});
      }
    } elsif ($params{mode} =~ /server::database::stalestats/) {
      $self->add_nagios(
          $self->check_thresholds($self->{staleobjects}, "10", "100"),
          sprintf "%d objects with stale statistics", $self->{staleobjects});
      $self->add_perfdata(sprintf "stale_stats_objects=%d;%s;%s",
          $self->{staleobjects},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


1;
