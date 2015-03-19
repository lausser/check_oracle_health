package DBD::Oracle::Server::Database::Asm;

use strict;

our @ISA = qw(DBD::Oracle::Server::Database);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    diskgroups => [],
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::database::asm::diskgroup/) {
    DBD::Oracle::Server::Database::Asm::Diskgroup::init_diskgroups(%params);
    if (my @diskgroups =
        DBD::Oracle::Server::Database::Asm::Diskgroup::return_diskgroups()) {
      $self->{diskgroups} = \@diskgroups;
    } else {
      $self->add_nagios_critical("unable to aquire diskgroup info");
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::database::asm::diskgroup::listdiskgroups/) {
	my $list = "Available DG: ";
      foreach ( sort { $a->{name} cmp $b->{name} }  @{$self->{diskgroups}} ) {
        $list .= $_->{name} . ", ";
      }
      $self->add_nagios_ok($list);
    } elsif ($params{mode} =~ /asm::diskgroup/) {
      foreach (@{$self->{diskgroups}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    }
  } 
}

