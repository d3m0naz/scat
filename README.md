# scat

A Bash terminal UI to watch and manage servers over SSH: keep a list of
servers, watch their status and system metrics, look at processes, open a
shell, and run saved commands. Docker and Kubernetes support are planned (see below).

```
 scat · Servers                                               2 servers · 12:03:55
   NAME             TARGET                    CPU   MEM   LOAD   UPTIME STATUS
 ── production ──
 ▶● web1            deploy@203.0.113.10:22     12%   37%   0.52   12d 3h Ubuntu 24.04 LTS
 ── ungrouped ──
  ● db1             db.internal via bastion     -     -      -        - authentication failed - …
```

## Installation

scat is a Bash script that runs on the machine you work on. It is written
for any system with Bash 5 or newer and the usual Unix tools. So far it has
been run on macOS (macOS 26, Apple Silicon, Bash 5.3); Linux and FreeBSD as
the machine running scat have not been tested yet.

### Bash 5 or newer

Bash 5 is needed on the machine that runs scat (not on your servers). Check
with `bash --version`.

| System | How to get Bash 5 |
|---|---|
| macOS | `brew install bash`, then put `/opt/homebrew/bin` first in `PATH` (e.g. `export PATH="/opt/homebrew/bin:$PATH"` in `~/.zshrc`). The system `/bin/bash` is 3.2 and is not supported. |
| Linux | Usually installed already; otherwise from the package manager: `apt install bash`, `dnf install bash` or `pacman -S bash`. |
| FreeBSD / OPNsense | `pkg install bash` (installs `/usr/local/bin/bash`). |

The script starts with `#!/usr/bin/env bash`, so the first `bash` in `PATH`
must be Bash 5. Older versions are refused with a short message. Besides
Bash, scat uses `ssh`, `tput`, `stty`, `awk`, `sed`, `sort`, `mktemp`,
`grep` and `pkill`; on macOS they ship with the system. If one is missing,
startup lists it (the install hint printed there is currently written for
Homebrew). `jq` is not needed.

### Install scat

```sh
# install the latest release (verifies the SHA-256 of the archive first)
curl -fsSL https://raw.githubusercontent.com/d3m0naz/scat/main/install.sh | bash
scat --help
```

The installer runs with the first `bash` in `PATH`, so set up Bash 5 first.
It downloads the release archive, compares its SHA-256 with the value pinned
in `install.sh` and installs nothing if they differ. scat goes into
`~/.local/share/scat-<version>`, and `~/.local/bin/scat` links to it. Use
`SCAT_PREFIX=/some/dir` to choose another location. If `~/.local/bin` is not
on your `PATH`, add it, e.g. `export PATH="$HOME/.local/bin:$PATH"` in your
shell's startup file (`~/.zshrc`, `~/.bashrc`, …).

Releases and checksums: https://github.com/d3m0naz/scat/releases

To work from a clone instead (for development), run it in place:

```sh
git clone https://github.com/d3m0naz/scat.git && cd scat
./scat
```

### Remote hosts

Your servers do not need Bash: scat only needs SSH access and a POSIX `sh`
with `awk`, `ps` and `df` there. Tested live: Linux (Debian 13, arm64) and
FreeBSD 15 (OPNsense). Linux and FreeBSD get full metrics; FreeBSD has no
iowait figure. macOS hosts work on a best-effort basis (the collector has
only been run locally on macOS, not over SSH). Other BSDs show no CPU or
network rates; the status page says so instead of showing numbers.

## Usage

```sh
scat                    # interactive TUI
scat --list             # print configured servers
scat --check web1       # one-shot metrics summary; exit 0 if reachable
scat --config-dir DIR   # use another config directory
scat --help | --version
```

The TUI needs a terminal of at least **80×24** (a common default size, e.g.
in macOS Terminal).
In a smaller window it draws no view, only a centered notice such as
`Terminal too small: at least 80×24 needed (now 70×20)`. `q` still leaves
the current view (and quits on the server list), Ctrl-C quits, and as soon
as the window is large enough again the view returns. `--list` and
`--check` have no size requirement.

### Authentication: keys only, no passwords

scat never asks for or stores passwords. Monitoring connections use
`ssh -o BatchMode=yes`, so they can only authenticate with SSH keys, keys in
`ssh-agent`, or whatever your `~/.ssh/config` provides. Load your key once
(`ssh-add ~/.ssh/id_ed25519`; on macOS, `--apple-use-keychain` keeps it in
the keychain) or set an *Identity file* on the server.

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
| Server detail | `p`/`Enter` processes · `s` ssh · `x` snippets · `e` edit · `m` modules · `r` refresh · `↑`/`↓` scroll one row · `PgUp`/`PgDn` one page · `Home`/`End` or `g`/`G` top/bottom |
| Processes | `c`/`m`/`p`/`n` sort by CPU/memory/PID/name · `K` send SIGTERM (asks first) · `r` refresh |
| Snippets | `Enter` run on the current server (asks first) · `a`/`e`/`d` add/edit/delete |
| Forms | `Enter` edit field · `s` save · `t` test connection · `Esc` cancel |
| Line editor | `←`/`→`, `Home`/`End` (`Ctrl-A`/`Ctrl-E`), `Backspace`/`Del`, `Ctrl-U`/`Ctrl-K`, `Enter` accept, `Esc` cancel |

The list refreshes every 15 s and the detail and process views every 5 s.
Collection runs in the background, so the UI stays responsive. Screens are
redrawn only when data arrives, a key is pressed or the window is resized,
and only the changed rows are rewritten.

## Configuration

Everything lives in `~/.config/scat/` (or `$XDG_CONFIG_HOME/scat`); the
environment variable `SC_CONFIG_DIR` or `--config-dir DIR` selects another
directory.

**Migration:** older versions were called servercat and used
`~/.config/servercat/`. If only that directory exists, scat keeps using it
and prints a short notice (on stderr, or in the TUI status line); rename
the directory to `~/.config/scat` to switch. If both exist, the new one is
used.

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
| `group` | optional group; the list shows servers under group headings |

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
| `theme` | default | see below | color theme of the TUI |

**Themes:** `default` (the original colors, for dark terminals), `light`
(for light terminal backgrounds), `solarized` (Solarized Dark), `nord`
(Nord) and `high-contrast` (bright colors on black; tx bars are hatched and
empty bar cells dotted, so rx and tx differ without color). Themes only set
text and accent colors; the terminal's own background is kept. `scat --theme
NAME` overrides the setting for one run; an unknown name in `settings.conf`
gives a warning and `default`. `NO_COLOR` turns colors off in every theme,
and the help screen (`?`) shows the active theme.

Comments must be on their own lines (`#` or `;`). Text after `=` is taken
literally.

### Server list

Without any `group` the list shows the servers in config order, and `J`/`K`
move the selected server down/up (saved to `servers.conf`). As soon as one
server has a group, the list is grouped:

- a heading row per group, `── production ──` in the accent color (cyan,
  bold; `-- production --` in ASCII mode);
- groups sorted A–Z, ignoring case; servers A–Z within a group;
- servers without a group last, under `── ungrouped ──`;
- headings can't be selected: ↑↓, PgUp/PgDn, Home/End always land on a
  server, and Enter, `e`, `d`, `s` act on that server;
- when the list scrolls and a group's heading has moved out of view, it is
  drawn in place of the first row, so the group of the visible servers is
  always shown;
- `J`/`K` show a notice instead of reordering, because the order follows the
  names;
- the group name is no longer repeated in each row; the detail view shows
  it next to the target.

`--list` uses the same order with plain `-- production --` heading lines and
keeps the GROUP column. Without groups its output is unchanged.

### Status page

The server detail view and `--check` show the same sections in this order:

1. **CPU**, followed by memory, swap and load
2. **Disks**: usage per mounted filesystem; on FreeBSD each ZFS pool is one
   line (`zroot (zfs)`, used and usable size of the pool, snapshots included),
   because all datasets of a pool share its free space. Repeated mounts of
   a listed filesystem are shown at their first mount only: the same source
   again (Linux bind mounts), or, for sources that are not `/dev/…` devices,
   the same size, used and available space as an earlier row (FreeBSD nullfs
   mounts such as `/lib` on `/var/unbound/lib`). Known limit: two different
   non-device filesystems with exactly the same three numbers (for example
   two NFS/SMB shares backed by one NAS volume) appear as one line. Two
   block devices are never merged
3. **Network**: one row per physical interface with a split bar (receive
   rate rx left, transmit rate tx right) and both rates
4. **Processes**: PID, user, CPU %, memory %, RSS, command

Network rates are megabytes per second (1 MB = 1,000,000 bytes, two
decimals), averaged over the same 1-second sampling window that is used for
the CPU rates.

The Network rows use the columns of the Disks rows: name, bar, and the
values where the disks show percentage and size. The bar column is split:
rx (left half), a one-cell gap, tx (right half). The unit appears once at
the end. At 80 columns (the minimum size):

```
  Disks
  /           ██████████████░░░░░░░░░░░░   52%  20.0G / 39.1G

  Network
  eth0        ██████▎░░░░░ ▏░░░░░░░░░░░░ rx  52.40  tx   0.01 MB/s
  wlan0       ░░░░░░░░░░░░ ░░░░░░░░░░░░░ rx   0.00  tx   0.00 MB/s
```

- **Fixed scale:** each half has its own scale; 100 MB/s fills it. Faster rates (for example on
  10 Gbit links) are shown as a full half. The scale does not adapt, so bars
  of different servers and refreshes are directly comparable.
- **Resolution:** eighth-cell steps with `▏▎▍▌▋▊▉█`. Any traffic above zero
  shows at least `▏`, even when the rate rounds to `0.00 MB/s`.
- **Colors:** rx green (terminal palette green), tx a muted red
  (256-color #af5f5f; palette red on 8-color terminals). The muted red keeps a
  contrast of at least 3:1 on common light and dark backgrounds (white,
  Solarized Light, black, #1e1e1e, One Dark). The empty part of a bar is
  dimmed. `NO_COLOR` turns colors off.
- **Width:** the bar column is as wide as the Disks and CPU bars (26 cells at
  80 columns: 12 rx + gap + 13 tx; 36 at 110: 17 + gap + 18). With an even
  width the tx half is one cell longer. `--check` prints one line per
  interface with a 10 + gap + 10 bar and no colors:
  `Network   eth0       ▏░░░░░░░░░ ▏░░░░░░░░░  rx   0.52  tx   0.01 MB/s`.
- **Height:** the Network section needs 1 heading row plus 1 row per
  interface (3 rows for two interfaces) and a blank separator. At 80×24 a
  server with two disks and two interfaces fits completely, with 4 process
  rows.
- **Scrolling:** when the page is longer than the screen (up to 6 disks and
  6 interfaces are shown), the content below the title row scrolls:
  `↑`/`↓` one row, `PgUp`/`PgDn` one page, `Home`/`End` (`g`/`G`) top and
  bottom. Title and footer stay in place. The status line shows the visible
  rows at the right, e.g. `1-21/28`; without overflow there is no
  indicator. After a resize or refresh the position is clamped to the new
  content. Processes fill the rest of the screen, at least 3 rows (`p`
  shows the full list).
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
- **FreeBSD / OPNsense:** interfaces from `netstat -ibnW` that belong to a
  NIC driver, i.e. have a `dev.<driver>.<unit>` sysctl node (`vtnet0`,
  `em0`, `igb0`, `ix0`, `re0`, `ue0`), plus `wlan*`. Cloned interfaces (`lo0`,
  `pflog0`, `pfsync0`, `enc0`, `bridge*`, `lagg*`, `vlan*`, `wg*`, `tun*`,
  `tap*`, `gif*`, `gre*`, `vxlan*`, `epair*`, `ovpn*`, VLANs like `igb0.10`)
  have none and are excluded. CPU comes from `kern.cp_time`, swap from
  `swapinfo -k`; the `idle` kernel process is left out of the process list.
- **Other systems:** no per-interface rates; the Network section shows a note
  instead.

Interfaces that are physical but down are still listed (with 0.00 MB/s).

## Features: implemented vs. planned

| Feature | Status |
|---|---|
| Server list with add / edit / delete / reorder, group headings, persisted | ✅ |
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
scat                    entry point: version check, option parsing, startup
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
  `/proc/net/dev` (FreeBSD: `kern.cp_time` and `netstat -ibnW`) one second
  apart for CPU and network rates and prints
  `key=value` lines (`netif=name|rx|tx` in bytes/s per physical interface).
- **Robustness:** each run has `ConnectTimeout`, `ServerAliveInterval` and a
  hard kill timeout (macOS has no `timeout(1)`; `sc_run_timeout` implements
  it). ssh errors are turned into short messages ("authentication failed",
  "unknown host key", "connection timed out", …). All remote text has
  control characters stripped before display, so a host can't inject
  terminal escape sequences.
- **Connection reuse:** `ControlMaster=auto` with sockets in a private
  `/tmp/scat.<uid>.<pid>.*` directory. It is removed on exit, and a later
  start also removes directories left by an instance that was killed.
- **Terminal:** alternate screen, hidden cursor, `stty -echo -icanon`. Exit,
  Ctrl-C, SIGTERM, SIGHUP and Ctrl-Z (suspend/resume) all restore the
  terminal. Below 80×24 a centered notice replaces the views (see Usage).

## Tests

```sh
tests/run_tests.sh                       # unit tests (SC_TEST_NETWORK=0 skips the ssh failure tests)
tests/tui_smoke.exp "$(mktemp -d)/cfg"   # drives the real TUI in a pty via expect
```
