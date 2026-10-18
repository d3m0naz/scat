# ServerCat (terminal edition)

A Bash TUI for macOS that recreates the server part of the iOS app
[ServerCat](https://servercat.app): keep a list of servers, watch their status
and system metrics over SSH, look at processes, open a shell, and run saved
commands. Docker and Kubernetes support are planned (see below).

```
 ServerCat · Servers                                          2 servers · 12:03:55
   NAME             TARGET                    CPU   MEM   LOAD   UPTIME STATUS
 ▶● web1            deploy@203.0.113.10:22     12%   37%   0.52   12d 3h [prod] Ubuntu 24.04 LTS
  ● db1             db.internal via bastion     -     -      -        - authentication failed - …
```

## Installation

Requirements: macOS (tested on macOS 26 / Darwin 25.6, Apple Silicon) with
**Bash 5 from Homebrew**. The system `/bin/bash` is 3.2 and is not supported.

```sh
brew install bash                      # installs /opt/homebrew/bin/bash (5.3)
# make sure /opt/homebrew/bin comes first in PATH, e.g. in ~/.zshrc:
export PATH="/opt/homebrew/bin:$PATH"

# optional: put servercat on your PATH (symlinks are resolved)
ln -s "$PWD/servercat" /opt/homebrew/bin/servercat
```

The script starts with `#!/usr/bin/env bash` and refuses to run on Bash < 5,
printing the instructions above. Everything else it needs ships with macOS:
`ssh`, `tput`, `stty`, `awk`, `sed`, `sort`, `mktemp`, `grep`, `pkill`.
If any of these is missing, startup prints a `brew install …` hint. `jq` is
not needed.

Remote hosts need a POSIX `sh` plus `awk`, `ps` and `df`. Linux gets full
metrics. macOS and FreeBSD hosts work on a best-effort basis (FreeBSD has no
CPU or network rates; the status page says so instead of showing numbers).

## Usage

```sh
servercat                       # interactive TUI
servercat --list                # print configured servers
servercat --check web1          # one-shot metrics summary; exit 0 if reachable
servercat --config-dir DIR      # use another config directory
servercat --help | --version
```

### Authentication: keys only, no passwords

ServerCat never asks for or stores passwords. Monitoring connections use
`ssh -o BatchMode=yes`, so they can only authenticate with SSH keys, keys in
`ssh-agent`, or whatever your `~/.ssh/config` provides. Load your key once
(`ssh-add --apple-use-keychain ~/.ssh/id_ed25519`) or set an *Identity file*
on the server.

Host keys are verified as usual against `~/.ssh/known_hosts`. For a new
server, press `s` once and accept the fingerprint in the interactive session.
After that, monitoring works. The interactive session (`s`) runs without
BatchMode, so typing a passphrase or password there works; nothing you type
is saved.

`~/.ssh/config` applies to every connection, so a server's *Host* can simply
be an alias defined there.

### Keybindings

| Where | Keys |
|---|---|
| Everywhere | `↑`/`↓` or `j`/`k` move · `PgUp`/`PgDn` · `g`/`G` top/bottom · `Enter` open · `Esc`/`q` back · `Ctrl-C` quit · `Ctrl-Z` suspend |
| Server list | `a` add · `e` edit · `d` delete · `J`/`K` move down/up · `s` ssh shell · `r` refresh now · `?` help · `q`/`Esc` quit |
| Server detail | `p`/`Enter` processes · `s` ssh · `x` snippets · `e` edit · `m` modules · `r` refresh |
| Processes | `c`/`m`/`p`/`n` sort by CPU/memory/PID/name · `K` send SIGTERM (asks first) · `r` refresh |
| Snippets | `Enter` run on the current server (asks first) · `a`/`e`/`d` add/edit/delete |
| Forms | `Enter` edit field · `s` save · `t` test connection · `Esc` cancel |
| Line editor | `←`/`→`, `Home`/`End` (`Ctrl-A`/`Ctrl-E`), `Backspace`/`Del`, `Ctrl-U`/`Ctrl-K`, `Enter` accept, `Esc` cancel |

The list refreshes every 15 s and the detail and process views every 5 s.
Collection runs in the background, so the UI stays responsive. Screens are
redrawn only when data arrives, a key is pressed or the window is resized,
and only the changed rows are rewritten.

## Configuration

Everything lives in `~/.config/servercat/` (or `$XDG_CONFIG_HOME/servercat`).
The directory is created with mode `700`, files with `600`. Files are parsed
as data (never `eval`ed or sourced). Invalid entries are skipped with a
warning shown in the status line or on stderr. The app rewrites a file
atomically when you change something in the TUI, and hand-written comments
are lost when that happens.

`servers.conf`:

```ini
[web1]
host = 203.0.113.10
port = 22
user = deploy
identity = ~/.ssh/id_ed25519
jump = admin@bastion:22
group = production
```

| Key | Meaning |
|---|---|
| `host` | required: hostname, IP address or `~/.ssh/config` alias |
| `port`, `user` | optional, otherwise from `~/.ssh/config` / ssh defaults |
| `identity` | optional private key file (never a password) |
| `jump` | optional ProxyJump, `[user@]host[:port]`, comma-separated chains |
| `group` | optional tag shown in the list |

Section names (server names) are 1–32 characters: `A-Z a-z 0-9 . _ -`.

`snippets.conf`: saved commands, run with `sh` on the remote host. There is
no tty, so `sudo` only works with NOPASSWD.

```ini
[disk-usage]
command = df -h
```

`settings.conf`: section `[settings]`, all keys optional:

| Key | Default | Range | Meaning |
|---|---|---|---|
| `list_refresh` | 15 | 5–3600 | seconds between server list refreshes |
| `detail_refresh` | 5 | 2–3600 | seconds between detail/process refreshes |
| `connect_timeout` | 5 | 1–60 | ssh `ConnectTimeout` |
| `command_timeout` | 20 | 5–600 | hard limit for one metrics run |
| `snippet_timeout` | 60 | 5–3600 | hard limit for one snippet run |
| `multiplex` | 1 | 0/1 | reuse connections via ssh ControlMaster |
| `ascii` | 0 | 0/1 | ASCII instead of Unicode glyphs |

Comments must be on their own lines (`#` or `;`). Text after `=` is taken
literally.

### Status page

The server detail view and `--check` show the same sections in this order:

1. **CPU**, followed by memory, swap and load
2. **Disks**: usage per mounted filesystem
3. **Network**: two rows per physical interface, the current receive rate
   (rx) and below it the transmit rate (tx), each with a bar
4. **Processes**: PID, user, CPU %, memory %, RSS, command

Network rates are megabytes per second (1 MB = 1,000,000 bytes, two
decimals), averaged over the same 1-second sampling window that is used for
the CPU rates.

Each interface takes two rows: rx with the interface name, tx below it
with the name column left blank.

```
  Network
  eth0        rx  52.40 MB/s  ████████████▋░░░░░░░░░░░
              tx   0.01 MB/s  ▏░░░░░░░░░░░░░░░░░░░░░░░
```

- **Fixed scale:** 100 MB/s fills a bar; faster rates (for example on
  10 Gbit links) are shown as a full bar. The scale does not adapt, so bars
  of different servers and refreshes are directly comparable.
- **Resolution:** eighth-cell steps with `▏▎▍▌▋▊▉█`. Any traffic above zero
  shows at least `▏`, even when the rate rounds to `0.00 MB/s`.
- **Colors:** rx green (terminal palette green), tx a muted red
  (256-color #af5f5f; palette red on 8-color terminals). The muted red keeps a
  contrast of at least 3:1 on common light and dark backgrounds (white,
  Solarized Light, black, #1e1e1e, One Dark). The empty part of a bar is
  dimmed. `NO_COLOR` turns colors off.
- **Width:** the bars fill the space after the name and rate columns, at
  most as wide as the CPU/memory bars and at least 4 cells (20 cells at 60
  columns, 36 at 110). `--check` uses the same rx-above-tx rows with 10-cell
  bars and no colors.
- **Height:** the Network section needs 1 heading row plus 2 rows per
  interface (5 rows for two interfaces) and a blank separator. The detail
  view does not scroll, so on short terminals the sections at the bottom are
  cut off: with two disks and two interfaces the Network section is fully
  visible from a terminal height of 20 rows.
- **ASCII:** with `ascii = 1` (or a non-UTF-8 locale) bars use `#` and `.`
  like the other bars, in whole cells.

*Physical* interfaces are real NICs, not loopback, bridges, tunnels, Docker,
veth or other virtual interfaces:

- **Linux:** interfaces from `/proc/net/dev` that have a `device` link in
  `/sys/class/net/<name>/` (PCI, USB, SDIO or platform NICs such as `eth0`,
  `wlan0`, `enp3s0`, `wlp2s0`). Names of known virtual types (`lo`, `veth*`,
  `docker*`, `br-*`, `virbr*`, `tun*`, `wg*`, `bond*`, …) are always excluded.
  Without sysfs the usual NIC names (`eth*`, `en*`, `wl*`, `ww*`, `em*`,
  `ib*`) are used instead.
- **macOS:** the `en0`, `en1`, … interfaces from `netstat -ibn`. Idle ports
  (for example unused Thunderbolt ports) are listed with 0.00 MB/s.
- **FreeBSD and other systems:** no per-interface rates; the Network section
  shows a note instead.

Interfaces that are physical but down are still listed (with 0.00 MB/s).

## Features: implemented vs. planned

| ServerCat feature | Status |
|---|---|
| Server list with add / edit / delete / reorder, persisted | ✅ |
| Live status per server (online, CPU %, memory %, load, uptime, OS) | ✅ |
| Detail view: CPU (user/sys/iowait), memory, swap, load, disks, rx/tx per physical network interface in MB/s, top processes | ✅ |
| Process list with sorting and SIGTERM | ✅ |
| Interactive SSH terminal | ✅ (your normal `ssh` in the same terminal window) |
| Snippets (saved commands) run on a server | ✅ |
| Jump host / ProxyJump, identity files, `~/.ssh/config` aliases | ✅ |
| Connection test from the form | ✅ |
| **Docker** containers (list, logs, start/stop) | ⏳ planned – extension point `lib/modules/` |
| **Kubernetes** pods | ⏳ planned – extension point `lib/modules/` |
| Historical charts, alerts/notifications, iCloud sync, SFTP | ❌ not planned for now |
| Password authentication for monitoring | ❌ by design (keys / agent only) |

### Extension point for Docker / pods

`lib/modules.sh` keeps a small registry. Every `lib/modules/*.sh` file is
sourced at startup and calls
`sc_module_register <id> <label> <view-function>`. Registered modules appear
under `m` in the server detail view. Remote calls go through
`sc_ssh_run_script`, so they get the same BatchMode, timeouts and connection
reuse. `lib/modules/docker.sh.example` is a non-functional skeleton (rename it
to `.sh` to see the wiring), and `lib/modules/README.md` describes the
contract.

## Layout

```
servercat               entry point: version check, option parsing, startup
lib/core.sh             helpers: validation, formatting, timeout runner
lib/config.sh           INI parsing, servers/snippets/settings persistence
lib/ssh.sh              ssh argv construction, async metric collection, errors
lib/ui.sh               terminal state, keys, differential rendering, widgets
lib/views.sh            server list, detail, processes, snippets, forms, help
lib/cli.sh              --list / --check
lib/modules.sh          module registry (extension point)
lib/modules/            modules (docker.sh.example skeleton)
lib/remote/metrics.sh   POSIX sh collector executed on the server via `sh -s`
tests/run_tests.sh      tests for the non-interactive parts
tests/tui_smoke.exp     expect-driven end-to-end test of the TUI
```

## How it works

- **Collection:** `lib/remote/metrics.sh` is sent to the host on stdin
  (`ssh … -- host 'sh -s' < metrics.sh`). Nothing is installed remotely, and
  the remote login shell doesn't matter. It samples `/proc/stat` and
  `/proc/net/dev` one second apart for CPU and network rates and prints
  `key=value` lines (`netif=name|rx|tx` in bytes/s per physical interface).
- **Robustness:** each run has `ConnectTimeout`, `ServerAliveInterval` and a
  hard kill timeout (macOS has no `timeout(1)`; `sc_run_timeout` implements
  it). ssh errors are turned into short messages ("authentication failed",
  "unknown host key", "connection timed out", …). All remote text has
  control characters stripped before display, so a host can't inject
  terminal escape sequences.
- **Connection reuse:** `ControlMaster=auto` with sockets in a private
  `/tmp/servercat.<uid>.<pid>.*` directory. It is removed on exit, and a later
  start also removes directories left by an instance that was killed.
- **Terminal:** alternate screen, hidden cursor, `stty -echo -icanon`. Exit,
  Ctrl-C, SIGTERM, SIGHUP and Ctrl-Z (suspend/resume) all restore the
  terminal. A terminal smaller than 60×12 shows a notice instead of a broken
  layout.

## Tests

```sh
tests/run_tests.sh                       # unit tests (SC_TEST_NETWORK=0 skips the ssh failure tests)
tests/tui_smoke.exp "$(mktemp -d)/cfg"   # drives the real TUI in a pty via expect
```
