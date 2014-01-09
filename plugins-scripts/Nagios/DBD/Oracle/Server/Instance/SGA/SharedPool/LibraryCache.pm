package DBD::Oracle::Server::Instance::SGA::SharedPool::LibraryCache;

use strict;

our @ISA = qw(DBD::Oracle::Server::Instance::SGA::SharedPool);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    sum_gets => undef,
    sum_gethits => undef,
    sum_pins => undef,
    sum_pinhits => undef,
    get_hitratio => undef,
    pin_hitratio => undef,
    reloads => undef,
    invalidations => undef,
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
  if ($params{mode} =~ 
      /server::instance::sga::sharedpool::librarycache::(reloads|.*hitratio)/) {
    # http://download.oracle.com/docs/cd/B10500_01/server.920/a96533/sqlviews.htm
    # Look for the following when querying this view:
    # 
    # High RELOADS or INVALIDATIONS
    # Low GETHITRATIO or GETPINRATIO
    #
    # High number of RELOADS could be due to the following:
    #
    # Objects being invalidated (large number of INVALIDATIONS)
    # Objects getting swapped out of memory
    #
    # Low GETHITRATIO could indicate that objects are getting swapped out of memory.
    #
    # Low PINHITRATIO could indicate the following:
    #
    # Session not executing the same cursor multiple times (even though it might be shared across different sessions)
    # Session not finding the cursor shared
    #
    # The next step is to query V$DB_OBJECT_CACHE/V$SQLAREA to see if problems are limited to certain objects or spread across different objects. If invalidations are high, then it might be worth investigating which of the (invalidated object's) underlying objects are being changed.
    #
    ($self->{sum_gethits}, $self->{sum_gets}, $self->{sum_pinhits},
        $self->{sum_pins}, $self->{reloads}, $self->{invalidations}) =
        $self->{handle}->fetchrow_array(q{
            SELECT SUM(gethits), SUM(gets), SUM(pinhits), SUM(pins),
              SUM(reloads), SUM(invalidations)
            FROM v$librarycache
        });
    if (! defined $self->{sum_gets} || ! defined $self->{sum_pinhits}) {
      $self->add_nagios_critical("unable to get sga lc");
    } else {
      $self->valdiff(\%params, qw(sum_gets sum_gethits sum_pins sum_pinhits reloads invalidations));
      $self->{get_hitratio} = $self->{delta_sum_gets} ? 
          (100 * $self->{delta_sum_gethits} / $self->{delta_sum_gets}) : 0;
      $self->{pin_hitratio} = $self->{delta_sum_pins} ? 
          (100 * $self->{delta_sum_pinhits} / $self->{delta_sum_pins}) : 0;
      $self->{reload_rate} = $self->{delta_reloads} / $self->{delta_timestamp};
      $self->{invalidation_rate} = $self->{delta_invalidations} / $self->{delta_timestamp};
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ 
        /server::instance::sga::sharedpool::librarycache::(get)*hitratio/) {
      $self->add_nagios(
          $self->check_thresholds($self->{get_hitratio}, "98:", "95:"),
          sprintf "SGA library cache (get) hit ratio %.2f%%", $self->{get_hitratio});
      $self->add_perfdata(sprintf "sga_library_cache_hit_ratio=%.2f%%;%s;%s",
          $self->{get_hitratio}, $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ 
        /server::instance::sga::sharedpool::librarycache::pinhitratio/) {
      $self->add_nagios(
          $self->check_thresholds($self->{pin_hitratio}, "98:", "95:"),
          sprintf "SGA library cache (pin) hit ratio %.2f%%", $self->{pin_hitratio});
      $self->add_perfdata(sprintf "sga_library_cache_hit_ratio=%.2f%%;%s;%s",
          $self->{pin_hitratio}, $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ 
        /server::instance::sga::sharedpool::librarycache::reloads/) {
      $self->add_nagios(
          $self->check_thresholds($self->{reload_rate}, "10", "100"),
          sprintf "SGA library cache reloads %.2f/sec", $self->{reload_rate});
      $self->add_perfdata(sprintf "sga_library_cache_reloads_per_sec=%.2f;%s;%s",
          $self->{reload_rate}, $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "sga_library_cache_invalidations_per_sec=%.2f",
          $self->{invalidation_rate});
    }
  }
}


1;
