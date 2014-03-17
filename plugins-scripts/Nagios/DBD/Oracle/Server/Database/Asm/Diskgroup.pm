package DBD::Oracle::Server::Database::Asm::Diskgroup;

use strict;

our @ISA = qw(DBD::Oracle::Server::Database::Asm);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @diskgroups = ();
  my $initerrors = undef;
 
  sub add_diskgroup {
    push(@diskgroups, shift);
  }
  
  sub return_diskgroups {
    return @diskgroups;
    	#sort { $a->{name} cmp $b->{name} } @diskgroups;
  }
  
  sub init_diskgroups {
    my %params = @_;
    my $num_diskgroups = 0;
  
    my @diskgroupresult = ();
    @diskgroupresult = $params{handle}->fetchall_array(q{
          SELECT
                  name,
                  state,
                  type,
                  total_mb,
                  usable_file_mb,
                  offline_disks
          FROM
                  V$ASM_DISKGROUP
  
    });
  
    if ($params{mode} =~ /server::database::asm::diskgroup::(usage|free|listdiskgroups)/) {
        foreach (@diskgroupresult) {
          my ($name, $state, $type, $total_mb, $usable_file_mb, $offline_disks) = @{$_};
          if ($params{regexp}) {
            next if $params{selectname} && $name !~ /$params{selectname}/;
          } else {
            next if $params{selectname} && lc $params{selectname} ne lc $name;
          }
  
  	  my %thisparams = %params;
          $thisparams{name} = $name;
          $thisparams{state} = lc $state;
          $thisparams{type} = lc $type;
          $thisparams{total_mb} = $total_mb;
          $thisparams{usable_file_mb} = $usable_file_mb;
          $thisparams{offline_disks} = $offline_disks;
  
          my $diskgroup = DBD::Oracle::Server::Database::Asm::Diskgroup->new(
              %thisparams);
          add_diskgroup($diskgroup);
          $num_diskgroups++;
        }
        if (! $num_diskgroups) {
          $initerrors = 1;
          return undef;
        }
    } # end mode usage 
  }
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    verbose => $params{verbose},
    handle => $params{handle},
    name => $params{name},
    state => $params{state},
    type => $params{type},
    total_mb => $params{total_mb},
    usable_file_mb => $params{usable_file_mb},
    offline_disks => $params{offline_disks},
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
  $self->set_local_db_thresholds(%params);
  if ($params{mode} =~ /server::database::asm::diskgroup::(usage|free)/) {
    $self->{percent_used} =
	($self->{total_mb} - $self->{usable_file_mb}) / $self->{total_mb} * 100;
    $self->{percent_free} = 100 - $self->{percent_used};
    $self->{bytes_free} = $self->{usable_file_mb} * 1024 * 1024;
    $self->{bytes_max} = $self->{total_mb} * 1024 * 1024;

    my $tlen = 20;
    my $len = int((($params{mode} =~ /asm::diskgroup::usage/) ?
        $self->{percent_used} : $self->{percent_free} / 100 * $tlen) + 0.5);
    $self->{percent_as_bar} = '=' x $len . '_' x ($tlen - $len);

  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::database::asm::diskgroup/) {
      ## if offline disk is greater 0 and is redundancy is external then critical
      # TODO: add check for voting disk
      if ( ($self->{offline_disks} > 0 && $self->{type} eq 'extern' ) ||
           ($self->{offline_disks} > 1 && $self->{type} eq 'high' ) ) { 
           
        $self->add_nagios(
            defined $params{mitigation} ? $params{mitigation} : 2,
                sprintf("dg %s has %s offline disks", $self->{name}, $self->{offline_disks})
        );
      } elsif ($self->{offline_disks} > 0 && ( $self->{type} eq 'normal' || $self->{type} eq 'high') ) {
           $self->add_nagios(
               defined $params{mitigation} ? $params{mitigation} : 1,
                   sprintf("dg %s has %s offline disks", $self->{name}, $self->{offline_disks})
           );
      }

      if ($self->{state} eq 'mounted' || $self->{state} eq 'dismounted' || $self->{state} eq 'connected') {
        # 'dg_system_usage_pct'=99.01%;90;98 percent used, warn, crit
        # 'dg_system_usage'=693MB;630;686;0;700 used, warn, crit, 0, max=total
        if ($params{mode} =~ /server::database::asm::diskgroup::usage/) {
          $self->add_nagios(
              $self->check_thresholds($self->{percent_used}, "90", "98"),
              $params{eyecandy} ?
                  sprintf("[%s] %s", $self->{percent_as_bar}, $self->{name}) :
                  sprintf("dg %s usage is %.2f%%",
                      $self->{name}, $self->{percent_used})
          );
  
          $self->add_perfdata(sprintf "\'dg_%s_usage_pct\'=%.2f%%;%d;%d",
              lc $self->{name},
              $self->{percent_used},
              $self->{warningrange}, $self->{criticalrange});
          $self->add_perfdata(sprintf "\'dg_%s_usage\'=%dMB;%d;%d;%d;%d",
              lc $self->{name},
              $self->{usable_file_mb},
              $self->{warningrange} * $self->{total_mb} / 100,
              $self->{criticalrange} * $self->{total_mb} / 100,
              0, $self->{total_mb});
        } elsif ($params{mode} =~ /server::database::asm::diskgroup::free/) {
          if (! $params{units}) {
            $params{units} = "%";
          }
          if ($params{units} eq "%") {
            $self->add_nagios(
                $self->check_thresholds($self->{percent_free}, "5:", "2:"),
                sprintf("dg %s has %.2f%% free space left",
                    $self->{name}, $self->{percent_free})
            );
            $self->{warningrange} =~ s/://g;
            $self->{criticalrange} =~ s/://g;
            $self->add_perfdata(sprintf "\'dg_%s_free_pct\'=%.2f%%;%d:;%d:",
                lc $self->{name},
                $self->{percent_free},
                $self->{warningrange}, $self->{criticalrange});
            $self->add_perfdata(sprintf "\'dg_%s_free\'=%dMB;%.2f:;%.2f:;0;%.2f",
                lc $self->{name},
                $self->{bytes_free} / 1048576,
                $self->{warningrange} * $self->{bytes_max} / 100 / 1048576,
                $self->{criticalrange} * $self->{bytes_max} / 100 / 1048576,
                $self->{bytes_max} / 1048576);
          } else {
            my $factor = 1024 * 1024; # default MB
            if ($params{units} eq "GB") {
              $factor = 1024 * 1024 * 1024;
            } elsif ($params{units} eq "MB") {
              $factor = 1024 * 1024;
            } elsif ($params{units} eq "KB") {
              $factor = 1024;
            }
            $self->{warningrange} ||= "5:";
            $self->{criticalrange} ||= "2:";
            my $saved_warningrange = $self->{warningrange};
            my $saved_criticalrange = $self->{criticalrange};
            # : entfernen weil gerechnet werden muss
            $self->{warningrange} =~ s/://g;
            $self->{criticalrange} =~ s/://g;
            $self->{warningrange} = $self->{warningrange} ?
                $self->{warningrange} * $factor : 5 * $factor;
            $self->{criticalrange} = $self->{criticalrange} ?
                $self->{criticalrange} * $factor : 2 * $factor;
            $self->{percent_warning} = 100 * $self->{warningrange} / $self->{bytes_max};
            $self->{percent_critical} = 100 * $self->{criticalrange} / $self->{bytes_max};
            $self->{warningrange} .= ':';
            $self->{criticalrange} .= ':';
            $self->add_nagios(
                $self->check_thresholds($self->{bytes_free}, "5242880:", "1048576:"),
                    sprintf("dg %s has %.2f%s free space left", $self->{name},
                        $self->{bytes_free} / $factor, $params{units})
            );
            $self->{warningrange} = $saved_warningrange;
            $self->{criticalrange} = $saved_criticalrange;
            $self->{warningrange} =~ s/://g;
            $self->{criticalrange} =~ s/://g;
            $self->add_perfdata(sprintf "\'dg_%s_free_pct\'=%.2f%%;%.2f:;%.2f:",
                lc $self->{name},
                $self->{percent_free}, $self->{percent_warning},
                $self->{percent_critical});
            $self->add_perfdata(sprintf "\'dg_%s_free\'=%.2f%s;%.2f:;%.2f:;0;%.2f",
                lc $self->{name},
                $self->{bytes_free} / $factor, $params{units},
                $self->{warningrange},
                $self->{criticalrange},
                $self->{bytes_max} / $factor);
          }
        }
      } else {
        $self->add_nagios(
          defined $params{mitigation} ? $params{mitigation} : 2,
            sprintf("dg %s has a problem, state is %s", $self->{name}, $self->{state})
        );
      }
    } 
  }
}


