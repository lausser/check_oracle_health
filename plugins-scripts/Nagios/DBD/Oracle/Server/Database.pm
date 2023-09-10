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
        invalid_registry_components => undef,
    },
    staleobjects => undef,
    corruptedblocks => undef,
    tablespaces => [],
    num_datafiles => undef,
    num_datafiles_max => undef,
    dbusers => [],
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::[c]*database::tablespace/) {
    DBD::Oracle::Server::Database::Tablespace::init_tablespaces(%params);
    if (my @tablespaces = 
        DBD::Oracle::Server::Database::Tablespace::return_tablespaces()) {
      $self->{tablespaces} = \@tablespaces;
    } else {
      $self->add_nagios_critical("unable to aquire tablespace info");
    }
  } elsif ($params{mode} =~ /server::[c]*database::flash_recovery_area/) {
    my $has_flash = "NO";
    if ($self->version_is_minimum("10.x")) {
      $has_flash = $params{handle}->fetchrow_array(q{
          select FLASHBACK_ON from v$database;
      });
    }
    if ($has_flash eq "NO") {
      $self->add_nagios_ok("flashback is not enabled");
      $self->{flash_recovery_areas} = [];
    } else {
      DBD::Oracle::Server::Database::FlashRecoveryArea::init_flash_recovery_areas(%params);
      if (my @flash_recovery_areas = 
          DBD::Oracle::Server::Database::FlashRecoveryArea::return_flash_recovery_areas()) {
        $self->{flash_recovery_areas} = \@flash_recovery_areas;
      } else {
        $self->add_nagios_critical("unable to aquire flash recovery area info");
      }
    }
  } elsif ($params{mode} =~ /server::database::dataguard/) {
    $self->{dataguard} = DBD::Oracle::Server::Database::Dataguard->new(%params);
  } elsif ($params{mode} =~ /server::database::asm/) {
    $self->{asm} = DBD::Oracle::Server::Database::Asm->new(%params);
  } elsif ($params{mode} =~ /server::database::invalidobjects/) {
    $self->init_invalid_objects(%params);
  } elsif ($params{mode} =~ /server::database::stalestats/) {
    $self->init_stale_objects(%params);
  } elsif ($params{mode} =~ /server::database::blockcorruption/) {
    $self->init_corrupted_blocks(%params);
  } elsif ($params{mode} =~ /server::database::datafilesexisting/) {
    $self->{num_datafiles_max} = $self->{handle}->fetchrow_array(q{
        SELECT value FROM v$system_parameter WHERE name  = 'db_files'
    });
    $self->{num_datafiles} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM sys.dba_data_files
    });
    if (! defined $self->{num_datafiles_max} ||
      ! defined $self->{num_datafiles}) {
      $self->add_nagios_critical("unable to get number of datafiles");
    }
  } elsif ($params{mode} =~ /server::database::datafilesoffline/) {
    @{$self->{offline_datafiles}} = $self->{handle}->fetchall_array(q{
        SELECT name, tablespace_name, status FROM v$datafile_header WHERE status != 'ONLINE'
    });
  } elsif ($params{mode} =~ /server::database::datafilesrecovery/) {
    @{$self->{recover_datafiles}} = $self->{handle}->fetchall_array(q{
        SELECT name, tablespace_name, recover, error FROM v$datafile_header WHERE recover = 'YES' OR (recover IS NULL AND error IS NOT NULL)
    });
  } elsif ($params{mode} =~ /server::database::expiredpw/ ||
      $params{mode} =~ /server::database::accountlocked/) {
    DBD::Oracle::Server::Database::User::init_users(%params);
    if (my @users = 
        DBD::Oracle::Server::Database::User::return_users()) {
      $self->{users} = \@users;
    } else {
      $self->add_nagios_critical("unable to aquire user info");
    }
  }
}

sub init_invalid_objects {
  my $self = shift;
  my %params = @_;
  my $invalid_objects = undef;
  my $invalid_indexes = undef;
  my $invalid_ind_partitions = undef;
  my $invalid_ind_subpartitions = undef;
  my $unrecoverable_datafiles = undef;
  @{$self->{invalidobjects}->{invalid_objects_list}} =
      $self->{handle}->fetchall_array(q{
          SELECT
            'dba_objects', O.object_type||' '||O.owner||'.'||O.object_name||' is '||O.status
          FROM
            dba_objects O
          LEFT OUTER JOIN
            DBA_MVIEW_refresh_times V
          ON
            O.object_name = V.NAME
          AND
            O.owner = V.owner
          WHERE
            (LAST_REFRESH <= (SELECT sysdate - ? FROM dual) OR LAST_REFRESH is null)
          AND
            STATUS = 'INVALID'
          AND
            O.object_name NOT LIKE 'BIN$%'
      }, ($params{lookback} || 2));
  # should be only N/A or VALID
  @{$self->{invalidobjects}->{invalid_indexes_list}} =
      $self->{handle}->fetchall_array(q{
          SELECT 'dba_indexes', index_type||' index '||owner||'.'||index_name||' of '||table_owner||'.'||table_name||' is '||status
          FROM dba_indexes
          WHERE status <> 'VALID' AND status <> 'N/A'
      });
  # should be only USABLE
  @{$self->{invalidobjects}->{invalid_ind_partitions_list}} =
      $self->{handle}->fetchall_array(q{
          SELECT 'dba_ind_partitions', partition_name||' of '||index_owner||'.'||index_name||' is '||status
          FROM dba_ind_partitions
          WHERE status <> 'USABLE' AND status <> 'N/A'
      });
  if ($self->version_is_minimum("10.x")) {
    # should be only USABLE
    @{$self->{invalidobjects}->{invalid_ind_subpartitions_list}} =
        $self->{handle}->fetchall_array(q{
            SELECT 'dba_ind_subpartitions', subpartition_name||' of '||partition_name||' of '||index_owner||'.'||index_name||' is '||status
            FROM dba_ind_subpartitions
            WHERE status <> 'USABLE' AND status <> 'N/A'
        });
  } else {
    $self->{invalidobjects}->{invalid_ind_subpartitions_list} = [];
  }
  # should be only VALID
  if ($self->version_is_minimum("10.x")) {
    @{$self->{invalidobjects}->{invalid_registry_components_list}} =
        $self->{handle}->fetchall_array(q{
            SELECT 'dba_registry', namespace||'.'||comp_name||'-'||version||' is '||status
            FROM dba_registry
            WHERE status <> 'VALID' AND status NOT IN ('OPTION OFF', 'REMOVED')
        });
  } else {
    @{$self->{invalidobjects}->{invalid_registry_components_list}} =
        $self->{handle}->fetchall_array(q{
            SELECT 'dba_registry', 'SCHEMA.'||comp_name||'-'||version||' is '||status
            FROM dba_registry
            WHERE status <> 'VALID' AND status NOT IN ('OPTION OFF', 'REMOVED')
        });
  }
  if (! defined $self->{invalidobjects}->{invalid_objects} ||
      ! defined $self->{invalidobjects}->{invalid_indexes} ||
      ! defined $self->{invalidobjects}->{invalid_registry_components} ||
      ! defined $self->{invalidobjects}->{invalid_ind_subpartitions} ||
      ! defined $self->{invalidobjects}->{invalid_ind_partitions}) {
    #$self->add_nagios_critical("unable to get invalid objects");
    #return undef;
  }
  foreach my $cat (qw(invalid_objects_list invalid_indexes_list invalid_ind_partitions_list invalid_ind_subpartitions_list invalid_registry_components_list)) {
    my @tmp_list = ();
    foreach my $element (@{$self->{invalidobjects}->{$cat}}) {
      next if $params{name2} && (lc $params{name2} ne lc $element->[0]);
      my $name = $element->[1];
      if ($params{regexp}) {
        # can be used to pick system an application accounts
        # --name 'of (SYS|SYSTEM|OUTLN|SCOTT|ADAMS|JONES|CLARK|BLAKE|WOOD|STEEL|CLOTH|PAPER|HR|OE|SH|OE|SH|DEMO|ANONYMOUS|%APEX%|AURORA\$ORB\$UNAUTHENTICATED|AWR_STAGE|CSMIG|CTXSYS|DBSNMP|DIP|DMSYS|DSSYS|EXFSYS|LBACSYS|MDSYS|ORACLE_OCM|ORDPLUGINS|ORDSYS|PERFSTAT|TRACESVR|TSMSYS|XDB|TSDSADM|APPQOSSYS)\.'
        if ($params{selectname} && substr($params{selectname}, 0, 1) eq '!') {
          my $selectname = substr($params{selectname}, 1);
          next if $name =~ /$selectname/;
        } else {
          next if $params{selectname} && $name !~ /$params{selectname}/i;
        }
      } else {
        next if $params{selectname} && (lc $params{selectname} ne lc $name);
      }
      push(@tmp_list, $element);
    }
    @{$self->{invalidobjects}->{$cat}} = @tmp_list;
  }
  $self->{invalidobjects}->{invalid_objects} = scalar(@{$self->{invalidobjects}->{invalid_objects_list}});
  $self->{invalidobjects}->{invalid_indexes} = scalar(@{$self->{invalidobjects}->{invalid_indexes_list}});
  $self->{invalidobjects}->{invalid_ind_partitions} = scalar(@{$self->{invalidobjects}->{invalid_ind_partitions_list}});
  $self->{invalidobjects}->{invalid_ind_subpartitions} = scalar(@{$self->{invalidobjects}->{invalid_ind_subpartitions_list}});
  $self->{invalidobjects}->{invalid_registry_components} = scalar(@{$self->{invalidobjects}->{invalid_registry_components_list}});
}

sub init_stale_objects {
  my $self = shift;
  my %params = @_;
  if ($self->version_is_minimum("10.x")) {
    $self->{staleobjects} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM sys.dba_tab_statistics WHERE stale_stats = 'YES'
            AND owner NOT IN ('SYS','SYSTEM','EXFSYS','DBSNMP','CTXSYS','DMSYS','MDDATA','MDSYS','OLAPSYS','ORDSYS','TSMSYS','WMSYS')
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

sub init_corrupted_blocks {
  my $self = shift;
  my %params = @_;
  $self->{numcorruptedblocks} = $self->{handle}->fetchrow_array(q{
      SELECT COUNT(*) FROM v$database_block_corruption
  });
  if (! defined $self->{numcorruptedblocks}) {
    $self->add_nagios_critical("unable to get corrupted blocks");
    return undef;
  }
  @{$self->{corruptedobjects}->{extents_list}} =
      $self->{handle}->fetchall_array(q{
      WITH
      block_corruption AS (
          SELECT /*+ materialize */
              *
          FROM
              v$database_block_corruption
      ),
      mytable AS (
      SELECT /*+ LEADING(vdbc dbe) USE_NL(vdbc dbe) */
          dbe.owner db_owner,
          dbe.segment_name obj_name,
          dbe.partition_name part_name,
          dbe.segment_type typ,
          vdbc.corruption_type corruption_type,
          vdbc.file# file_number,
          vdbc.block# block_number,
          GREATEST(dbe.block_id, vdbc.block#) corr_start_block,
          LEAST(dbe.block_id+dbe.blocks-1, vdbc.block#+vdbc.blocks-1) corr_end_block,
          LEAST(dbe.block_id+dbe.blocks-1, vdbc.block#+vdbc.blocks-1) - GREATEST(dbe.block_id, vdbc.block#) + 1 blocks_corrupted,
          'dba_extents' description
      FROM
          dba_extents dbe,
          block_corruption vdbc
      WHERE 1=1
      AND dbe.file_id = vdbc.file#
      AND dbe.block_id <= vdbc.block# + vdbc.blocks - 1
      AND dbe.block_id + dbe.blocks - 1 >= vdbc.block#
      )
      SELECT
         description, db_owner||'.'||obj_name||' is '||corruption_type||' corrupted'
      FROM mytable
  });
  @{$self->{corruptedobjects}->{segments_list}} =
      $self->{handle}->fetchall_array(q{
      WITH mytable AS (
          SELECT
              dbs.owner db_owner,
              dbs.segment_name obj_name,
              dbs.partition_name part_name,
              dbs.segment_type typ,
              vdbc.corruption_type corruption_type,
              vdbc.file# file_number,
              vdbc.block# block_number,
              dbs.header_block corr_start_block,
              dbs.header_block corr_end_block,
              1 blocks_corrupted,
              'dba_segments' description
          FROM
              dba_segments dbs,
              v$database_block_corruption vdbc
          WHERE 1=1
          AND dbs.header_file = vdbc.file#
          AND dbs.header_block BETWEEN vdbc.block# AND vdbc.block#+vdbc.blocks-1
      )
      SELECT
         description, db_owner||'.'||obj_name||' is '||corruption_type||' corrupted'
      FROM mytable
  });
  @{$self->{corruptedobjects}->{free_list}} =
      $self->{handle}->fetchall_array(q{
      WITH mytable AS (
          SELECT
              'SYS' db_owner,
              'file'||vdbc.file#||'block'||vdbc.block# obj_name,
              'noname' part_name,
              'free' typ,
              vdbc.corruption_type corruption_type,
              vdbc.file# file_number,
              vdbc.block# block_number,
              GREATEST(dbf.block_id, vdbc.block#) corr_start_block,
              LEAST(dbf.block_id+dbf.blocks-1, vdbc.block#+vdbc.blocks-1) corr_end_block,
              LEAST(dbf.block_id+dbf.blocks-1, vdbc.block#+vdbc.blocks-1) - GREATEST(dbf.block_id, vdbc.block#) + 1 blocks_corrupted,
              'dba_free_space' description
          FROM
              dba_free_space dbf,
              v$database_block_corruption vdbc
          WHERE 1=1
          AND dbf.file_id = vdbc.file#
          AND dbf.block_id <= vdbc.block# + vdbc.blocks -1
          AND dbf.block_id + dbf.blocks - 1 >= vdbc.block#
      )
      SELECT
         description, db_owner||'.'||obj_name||' is '||corruption_type||' corrupted'
      FROM mytable
  });
  foreach my $cat (qw(extents_list segments_list free_list)) {
    my @tmp_list = ();
    foreach my $element (@{$self->{corruptedobjects}->{$cat}}) {
      next if $params{name2} && (lc $params{name2} ne lc $element->[0]);
      my $name = $element->[1];
      if ($params{regexp}) {
        if ($params{selectname} && substr($params{selectname}, 0, 1) eq '!') {
          my $selectname = substr($params{selectname}, 1);
          next if $name =~ /$selectname/;
        } else {
          next if $params{selectname} && $name !~ /$params{selectname}/i;
        }
      } else {
        next if $params{selectname} && (lc $params{selectname} ne lc $name);
      }
      push(@tmp_list, $element);
    }
    @{$self->{corruptedobjects}->{$cat}} = @tmp_list;
  }
  $self->{corruptedobjects}->{extents} = scalar(@{$self->{corruptedobjects}->{extents_list}});
  $self->{corruptedobjects}->{segments} = scalar(@{$self->{corruptedobjects}->{segments_list}});
  $self->{corruptedobjects}->{free} = scalar(@{$self->{corruptedobjects}->{free_list}});
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::[c]*database::tablespace::listtablespaces/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{tablespaces}}) {
	printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::[c]*database::tablespace/) {
      foreach (@{$self->{tablespaces}}) {
        # sind hier noch nach pctused sortiert
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::database::tablespace::listflash_recovery_areas/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{flash_recovery_areas}}) {
        printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::database::flash_recovery_area/) {
      foreach (@{$self->{flash_recovery_areas}}) {
        # sind hier noch nach pctused sortiert
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::database::dataguard/) {
      $self->{dataguard}->nagios(%params);
      $self->merge_nagios($self->{dataguard});
    } elsif ($params{mode} =~ /server::database::asm/) {
      $self->{asm}->nagios(%params);
      $self->merge_nagios($self->{asm});
    } elsif ($params{mode} =~ /server::database::invalidobjects/) {
      my @message = ();
      my $message = undef;
      my $level = undef;
      push(@message, sprintf "%d invalid objects",
          $self->{invalidobjects}->{invalid_objects}) if
          $self->{invalidobjects}->{invalid_objects};
      push(@message, sprintf "%d invalid indexes",
          $self->{invalidobjects}->{invalid_indexes}) if
          $self->{invalidobjects}->{invalid_indexes};
      push(@message, sprintf "%d invalid index partitions",
          $self->{invalidobjects}->{invalid_ind_partitions}) if
          $self->{invalidobjects}->{invalid_ind_partitions};
      push(@message, sprintf "%d invalid index subpartitions",
          $self->{invalidobjects}->{invalid_ind_subpartitions}) if
          $self->{invalidobjects}->{invalid_ind_subpartitions};
      push(@message, sprintf "%d invalid registry components",
          $self->{invalidobjects}->{invalid_registry_components}) if
          $self->{invalidobjects}->{invalid_registry_components};
      if (scalar(@message)) {
        my $level = $self->check_thresholds(
            $self->{invalidobjects}->{invalid_objects} +
            $self->{invalidobjects}->{invalid_indexes} +
            $self->{invalidobjects}->{invalid_registry_components} +
            $self->{invalidobjects}->{invalid_ind_subpartitions} +
            $self->{invalidobjects}->{invalid_ind_partitions}, 0, 0);
        $self->add_nagios($level, join(", ", @message));
        $message = $ERRORCODES{$level}.' - '.join(", ", @message);
        $self->supress_nagios($level) if $self->{nagios_level} && $params{report} eq "html";
      } else {
        $self->add_nagios_ok("no invalid objects found");
        $message = "OK - no invalid objects found";
        $self->supress_nagios(0) if $self->{nagios_level} && $params{report} eq "html";
      }
      # invalid_objects_list invalid_indexes_list invalid_registry_components_list invalid_ind_partitions_list
      # dba_objects dba_indexes dba_ind_partitions dba_registry
      if ($params{name2}) {
        my $category = {
            'dba_objects' => 'invalid_objects_list',
            'dba_indexes' => 'invalid_indexes_list',
            'dba_ind_partitions' => 'invalid_ind_partitions_list',
            'dba_ind_subpartitions' => 'invalid_ind_subpartitions_list',
            'dba_registry' => 'invalid_registry_components_list',
        }->{$params{name2}};
        $self->add_perfdata(sprintf "%s=%d", $category, $self->{invalidobjects}->{$category});
      } else {
        foreach (grep !/_list$/, sort keys %{$self->{invalidobjects}}) {
          $self->add_perfdata(sprintf "%s=%d", $_, $self->{invalidobjects}->{$_});
        }
      }
      if ($self->{nagios_level} && $params{report} eq "html") {
        require List::Util;
        my $maxlines = 10;
        my $invalid_lines = 0;
        my $linespercategory = {};

        foreach my $list (qw(invalid_objects_list invalid_indexes_list invalid_registry_components_list invalid_ind_partitions_list invalid_ind_subpartitions_list)) {
          $invalid_lines += scalar(@{$self->{invalidobjects}->{$list}});
          $linespercategory->{$list} = 0;
        }
        my $output_lines = List::Util::sum(values %{$linespercategory});
        my $full = 0;
        do {
          foreach my $list (qw(invalid_objects_list invalid_indexes_list invalid_registry_components_list invalid_ind_partitions_list invalid_ind_subpartitions_list)) {
            $linespercategory->{$list}++ if scalar(@{$self->{invalidobjects}->{$list}}) > $linespercategory->{$list};
            $output_lines = List::Util::sum(values %{$linespercategory});
            $full = 1 if ($output_lines >= $maxlines || $output_lines >= $invalid_lines);
            last if $full;
          }
        } while (! $full);
        printf "%s\n", $message;
        printf "<table style=\"border-collapse:collapse; border: 1px solid black;\">";
        foreach my $list (qw(invalid_objects_list invalid_indexes_list invalid_registry_components_list invalid_ind_partitions_list invalid_ind_subpartitions_list)) {
          if ($linespercategory->{$list}) {
        printf "<tr>";
        foreach (qw(Table Object)) {
          printf "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">%s</th>", $_;
        }
        printf "</tr>";
            foreach my $object (@{$self->{invalidobjects}->{$list}}[0..$linespercategory->{$list} - 1]) {

              printf "<tr>";
              printf "<tr style=\"border: 1px solid black;\">";
              printf "<td class=\"serviceCRITICAL\" style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">%s</td>", $object->[0];
              printf "<td class=\"serviceCRITICAL\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; white-space: nowrap\">%s</td>", $object->[1];
              printf "</tr>";
            }
            if ($linespercategory->{$list} < scalar(@{$self->{invalidobjects}->{$list}})) {
              printf "<tr style=\"border: 1px solid black;\">";
              printf "<td colspan=\"2\" class=\"serviceCRITICAL\" style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">... (%d more)</td>", scalar(@{$self->{invalidobjects}->{$list}}) - $linespercategory->{$list};
              printf "</tr>";
            }
          }
        }
        printf "</table>\n";
        printf "<!--\nASCII_NOTIFICATION_START\n";
        foreach (qw(Table Object)) {
          printf "%-20s", $_;
        }
        printf "\n";
        foreach my $object (
            @{$self->{invalidobjects}->{invalid_objects_list}},
            @{$self->{invalidobjects}->{invalid_indexes_list}},
            @{$self->{invalidobjects}->{invalid_registry_components_list}},
            @{$self->{invalidobjects}->{invalid_ind_partitions_list}},
            @{$self->{invalidobjects}->{invalid_ind_subpartitions_list}}) {
          printf "%-20s%s", $object->[0], $object->[1];
          printf "\n";
        }
        printf "ASCII_NOTIFICATION_END\n-->\n";
      }
    } elsif ($params{mode} =~ /server::database::stalestats/) {
      $self->add_nagios(
          $self->check_thresholds($self->{staleobjects}, "10", "100"),
          sprintf "%d objects with stale statistics", $self->{staleobjects});
      $self->add_perfdata(sprintf "stale_stats_objects=%d;%s;%s",
          $self->{staleobjects},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::database::blockcorruption/) {
      #$self->add_nagios(
      #    $self->check_thresholds($self->{corruptedblocks}, "1", "10"),
      #    sprintf "%d database blocks are corrupted", $self->{corruptedblocks});
      #$self->add_perfdata(sprintf "corrupted_blocks=%d;%s;%s",
      #    $self->{corruptedblocks},
      #    $self->{warningrange}, $self->{criticalrange});
      my @message = ();
      my $message = undef;
      my $level = undef;
      push(@message, sprintf "%d corrupt extents",
          $self->{corruptedobjects}->{extents}) if
          $self->{corruptedobjects}->{extents};
      push(@message, sprintf "%d corrupt segment headers",
          $self->{corruptedobjects}->{segments}) if
          $self->{corruptedobjects}->{segments};
      push(@message, sprintf "%d corrupt free blocks",
          $self->{corruptedobjects}->{free}) if
          $self->{corruptedobjects}->{free};
      if (scalar(@message)) {
        my $level = $self->check_thresholds(
            $self->{corruptedobjects}->{extents} +
            $self->{corruptedobjects}->{segments} +
            $self->{corruptedobjects}->{free}, 0.1, 0.1);
        $self->add_nagios($level, join(", ", @message));
        $message = $ERRORCODES{$level}.' - '.join(", ", @message);
        $self->supress_nagios($level) if $self->{nagios_level} && $params{report} eq "html";
      } else {
        $self->add_nagios_ok("no corrupt blocks found");
        $message = "OK - no corrupt blocks found";
        $self->supress_nagios(0) if $self->{nagios_level} && $params{report} eq "html";
      }
      foreach (grep !/_list$/, sort keys %{$self->{corruptedobjects}}) {
        $self->add_perfdata(sprintf "%s=%d", $_, $self->{corruptedobjects}->{$_});
      }
      if ($self->{nagios_level} && $params{report} eq "html") {
        require List::Util;
        my $maxlines = 10;
        my $invalid_lines = 0;
        my $linespercategory = {};

        foreach my $list (qw(extents_list segments_list free_list)) {
          $invalid_lines += scalar(@{$self->{corruptedobjects}->{$list}});
          $linespercategory->{$list} = 0;
        }
        my $output_lines = List::Util::sum(values %{$linespercategory});
        my $full = 0;
        do {
          foreach my $list (qw(extents_list segments_list free_list)) {
            $linespercategory->{$list}++ if scalar(@{$self->{corruptedobjects}->{$list}}) > $linespercategory->{$list};
            $output_lines = List::Util::sum(values %{$linespercategory});
            $full = 1 if ($output_lines >= $maxlines || $output_lines >= $invalid_lines);
            last if $full;
          }
        } while (! $full);
        printf "%s\n", $message;
        printf "<table style=\"border-collapse:collapse; border: 1px solid black;\">";
        foreach my $list (qw(extents_list segments_list free_list)) {
          if ($linespercategory->{$list}) {
        printf "<tr>";
        foreach (qw(Table Object)) {
          printf "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">%s</th>", $_;
        }
        printf "</tr>";
            foreach my $object (@{$self->{corruptedobjects}->{$list}}[0..$linespercategory->{$list} - 1]) {

              printf "<tr>";
              printf "<tr style=\"border: 1px solid black;\">";
              printf "<td class=\"serviceCRITICAL\" style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">%s</td>", $object->[0];
              printf "<td class=\"serviceCRITICAL\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; white-space: nowrap\">%s</td>", $object->[1];
              printf "</tr>";
            }
            if ($linespercategory->{$list} < scalar(@{$self->{corruptedobjects}->{$list}})) {
              printf "<tr style=\"border: 1px solid black;\">";
              printf "<td colspan=\"2\" class=\"serviceCRITICAL\" style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">... (%d more)</td>", scalar(@{$self->{corruptedobjects}->{$list}}) - $linespercategory->{$list};
              printf "</tr>";
            }
          }
        }
        printf "</table>\n";
        printf "<!--\nASCII_NOTIFICATION_START\n";
        foreach (qw(Table Object)) {
          printf "%-20s", $_;
        }
        printf "\n";
        foreach my $object (@{$self->{corruptedobjects}->{extents_list}}, @{$self->{corruptedobjects}->{segments_list}}, @{$self->{corruptedobjects}->{free_list}}) {
          printf "%-20s%s", $object->[0], $object->[1];
          printf "\n";
        }
        printf "ASCII_NOTIFICATION_END\n-->\n";
      }
    } elsif ($params{mode} =~ /server::database::datafilesexisting/) {
        my $datafile_usage = $self->{num_datafiles} / 
            $self->{num_datafiles_max} * 100;
      $self->add_nagios(
          $self->check_thresholds($datafile_usage, "80", "90"),
          sprintf "you have %.2f%% of max possible datafiles (%d of %d max)",
              $datafile_usage, $self->{num_datafiles}, $self->{num_datafiles_max});
      $self->add_perfdata(sprintf "datafiles_pct=%.2f%%;%s;%s",
          $datafile_usage,
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "datafiles_num=%d;%s;%s;0;%d",
          $self->{num_datafiles},
          $self->{num_datafiles_max} / 100 * $self->{warningrange},
          $self->{num_datafiles_max} / 100 * $self->{criticalrange},
          $self->{num_datafiles_max});
    } elsif ($params{mode} =~ /server::database::datafilesoffline/) {
      my $num_offlines = scalar(@{$self->{offline_datafiles}});
      $self->add_nagios(
          $self->check_thresholds($num_offlines, 0, 0),
          sprintf "you have %d offline datafiles", $num_offlines);
      if ($self->{nagios_level}) {
        $self->add_nagios_ok(join(", ", map {
          # name, tablespace_name, status
          sprintf "%s(%s) is %s", $_->[0], $_->[1], $_->[2];
        } @{$self->{offline_datafiles}}));
      }
    } elsif ($params{mode} =~ /server::database::datafilesrecovery/) {
      my $num_recover = scalar(@{$self->{recover_datafiles}});
      $self->add_nagios(
          $self->check_thresholds($num_recover, 0, 0),
          sprintf "%d datafiles require media recovery", $num_recover);
      if ($self->{nagios_level}) {
        $self->add_nagios_ok(join(", ", map {
          # name, tablespace_name, recover, error
          if ($_->[2]) {
            sprintf "%s(%s) needs to be recovered", $_->[0], $_->[1];
          } else {
            sprintf "%s(%s) has error %s", $_->[0], $_->[1], $_->[3];
          }
        }@{$self->{recover_datafiles}}));
      }
    } elsif ($params{mode} =~ /server::database::expiredpw/) {
      foreach (@{$self->{users}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    }
  }
}


1;
