# Building check_oracle_health

## Prerequisites

- `autoconf` / `automake`
- `perl`
- `make`

## Steps

```bash
autoreconf -fi
./configure
make
```

The output is a single self-contained Perl script at:

```
plugins-scripts/check_oracle_health
```

## Configure options

| Option | Default | Description |
|--------|---------|-------------|
| `--with-statefiles-dir` | `/var/tmp/check_oracle_health` | Directory for state files used by rate checks |
| `--with-nagios-user` | `nagios` | User that will run the plugin |
| `--with-nagios-group` | `nagios` | Group that will run the plugin |
| `--with-mymodules-dir` | `/usr/local/nagios/libexec` | Directory for optional extension modules |
| `--with-perl` | *(autodetected)* | Path to Perl interpreter |

### Cross-platform builds

If building on a different OS than the target (e.g. building on Arch Linux to run on OEL),
specify the Perl path of the **target** system so the shebang line is correct:

```bash
./configure --with-perl=/usr/bin/perl
make clean && make
```

## Install

```bash
make install
```

## Notes

- Clock skew warnings from `make` during `./configure` are harmless (WSL filesystem timing).
- This build includes PR #40 (SysTimeModel and SysWaitClass modes) and a fix for
  ASM diskgroup usage calculation to account for NORMAL/HIGH redundancy mirror factors.
