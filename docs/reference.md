<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="logo-dark.svg">
    <img src="logo-light.svg" width="470" alt="scat">
  </picture>
</p>

# scat

**Watch and manage your servers over SSH, from the terminal.**

[![Release](https://img.shields.io/github/v/release/d3m0naz/scat?label=release)](https://github.com/d3m0naz/scat/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](../LICENSE)
[![Bash 5+](https://img.shields.io/badge/bash-5%2B-4EAA25.svg)](#bash-5-or-newer)

scat is a Bash terminal UI. Keep a list of servers, watch CPU, memory, load,
disks and network per interface, look at processes, open a shell or run saved
commands. Your servers need nothing but SSH and a POSIX `sh`. Docker
containers are shown read-only; Kubernetes support is planned (see below).

- **Live status** for every server with ping time and CPU temperature, grouped by your own group names
- **Detail view** with CPU, memory, swap, load, disks, network bars and processes
- **Docker, read only:** containers with status, health, CPU and memory
- **Drives:** temperature and SMART health of every disk, without waking sleeping disks
- **Keys only:** no passwords are asked for or stored
- **Plain config:** INI files, parsed as data and written with mode 600
- **Five colour themes**, including high-contrast for bright or dim terminals
- **Few dependencies:** Bash 5 and standard Unix tools, no `jq` or other extras

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/d3m0naz/scat/main/install.sh | bash
scat
```

The installer checks the SHA-256 of the release archive before it installs
anything. Bash 5 is needed first (see [Bash 5 or newer](#bash-5-or-newer)).

```
 scat · Servers                                                               2 servers · 12:03:55
   NAME                PING   CPU  TEMP   MEM   LOAD   UPTIME STATUS
 ── production ──
▶● web1               14 ms   12%  52°C   37%   0.52   12d 3h Ubuntu 24.04 LTS
 ── ungrouped ──
 ● db1                 jump     -     -     -      -        - authentication failed - check key / s…
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
| Server list | `a` add · `e` edit · `d` delete · `J`/`K` move down/up · `s` ssh shell · `r` refresh now · `t` group headings on/off (this session) · `f` °C/°F (this session) · `?` help · `q`/`Esc` quit |
| Server detail | `p`/`Enter` processes · `s` ssh · `x` snippets · `e` edit · `m` modules (Docker) · `r` refresh · `↑`/`↓` scroll one row · `PgUp`/`PgDn` one page · `Home`/`End` or `g`/`G` top/bottom |
| Processes | `c`/`m`/`p`/`n` sort by CPU/memory/PID/name · `K` send SIGTERM (asks first) · `r` refresh |
| Snippets | `Enter` run on the current server (asks first) · `a`/`e`/`d` add/edit/delete |
| Docker | `↑`/`↓` move · `r` refresh now · `Esc` back (no actions) |
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
| `ping` | 1 | 0/1 | PING column in the server list |
| `group_headings` | 1 | 0/1 | group heading rows in the server list at start (`t` toggles them for the session) |
| `temp_unit` | c | c/f | CPU temperature in °C or °F at start (`f` toggles it for the session) |
| `drives` | 1 | 0/1 | Drives section (SMART temperature and health) in the detail view |
| `drives_refresh` | 300 | 60–3600 | seconds between drive queries |

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

With `group_headings = 0` the list keeps the same order but shows no heading
rows (and no sticky heading); the detail view still shows the group. `t` in
the list switches the headings on and off at once, for the running session
only: `settings.conf` is not changed, and the next start uses
`group_headings` again.

`--list` uses the same order with plain `-- production --` heading lines and
keeps the GROUP column, whatever `group_headings` says. Without groups its
output is unchanged.

**PING column:** at every list refresh scat sends one ping from your machine
to each server's `host` and shows the round trip (`14 ms`, `<1 ms`). `-`
means no reply within 2 seconds (many firewalls drop ping although ssh
works), `!` that the host name can't be resolved, `…` that no answer has
arrived yet. ping does not know `~/.ssh/config` aliases, so an alias shows
`!`. Servers behind a jump host show `jump` and are not pinged, because a
ping from here would not say anything about them. The list never waits for
ping. With the PING and TEMP columns, TARGET appears from 102 terminal
columns on. Turn PING off with `ping = 0`.

**TEMP column:** the CPU temperature, measured on the server in °C and shown
in whole degrees (`52°C`, or `126°F` with `temp_unit = f`; `f` in the list
switches the unit for the session without changing `settings.conf`). Colors
follow the Celsius value: yellow from 70 °C, red from 85 °C. Only sensors of
the CPU itself are read:

- Linux: thermal zones of a CPU type (`x86_pkg_temp`, `cpu-thermal`,
  `soc-thermal`, as on Intel and Raspberry Pi), otherwise the hwmon drivers
  `coretemp` (package sensor), `k10temp` / `zenpower` (AMD, Tdie before
  Tctl) and `cpu_thermal`. Other sensors (ACPI, NVMe, Wi-Fi, GPU, mainboard
  chips, which often report bogus values) are never used.
- FreeBSD / OPNsense: the hottest core from `dev.cpu.N.temperature`, which
  needs the `coretemp` or `amdtemp` driver.
- Otherwise, and for virtual machines without sensors, `-`.

Values outside −40…150 °C are ignored. The detail view shows the
temperature at the end of the Load line.

### Status page

The server detail view and `--check` show the same sections in this order:

1. **CPU**, followed by memory, swap and load (with the CPU temperature)
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
4. **Processes**, with the total and how many are shown: PID, user, CPU %,
   memory %, RSS, command
5. **Docker** (only if the server has a `docker` command), with the count
   (`4 running / 6 total`) in the heading, then 5 containers in the grid
   of the process rows: name (as wide as PID and user), CPU %, memory %
   and memory under the process columns, then status with health (the
   image after it from 84 columns on). Running containers come first, highest CPU
   first (equal CPU by name), then running ones without CPU data yet (`…`),
   then stopped ones by name. The processes are cut to 5 rows
   then; `p` still shows all of them, `m` all containers. Without Docker
   the page looks as before

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
| CPU temperature in the list and the detail view (°C/°F) | ✅ |
| Drive temperature and SMART health (`smartctl`), problems in the list | ✅ (see [Drives](#drives-smart)) |
| Process list with sorting and SIGTERM | ✅ |
| Interactive SSH terminal | ✅ (your normal `ssh` in the same terminal window) |
| Snippets (saved commands) run on a server | ✅ |
| Jump host / ProxyJump, identity files, `~/.ssh/config` aliases | ✅ |
| Connection test from the form | ✅ |
| **Docker** containers, read only: status, health, CPU, memory | ✅ (`m` in the detail view, see [Docker](#docker-read-only)) |
| Docker actions (logs, start/stop, compose), Podman | ❌ not planned for now |
| **Kubernetes** pods | ⏳ planned – extension point `lib/modules/` |
| Historical charts, alerts/notifications, iCloud sync, SFTP | ❌ not planned for now |
| Password authentication for monitoring | ❌ by design (keys / agent only) |

### Docker (read only)

The collector reports whether the server has a `docker` command (it does
not contact the daemon). If it has, the detail view gets a Docker section
and `m` offers the Docker view: a table of all containers (`docker ps -a`)
with name, image, status, health, CPU % and memory (`docker stats
--no-stream`), running containers first. CPU and memory are shown like in
the process list (`59.7`, `159.6M`). The detail view uses the same data.
Docker is asked at most every 15 s, in the background; `docker stats` takes
1–2 s on the server. Nothing is started, stopped or changed, there is no
Compose support and no Podman.

Docker prints one JSON object per line; scat reads them without `jq`. Lines
that are not valid JSON are skipped and counted ("2 unreadable line(s)
skipped"). Control characters are removed from every value before it is
shown, like all other remote text.

**Security:** Docker only answers users who may open its socket
(`/var/run/docker.sock`), usually root or members of the `docker` group.
Access to that socket is equivalent to root on the server, even if scat only
reads from it. Only give the SSH user scat logs in with that access if it
may have root rights anyway. Without access the Docker section shows
Docker's error ("permission denied … docker.sock").

### Drives (SMART)

The detail view shows a **Drives** section after Disks: one row per disk
with model, type (HDD, SSD, NVMe), size, temperature and health. A disk
with a problem also shows in the STATUS column of the server list instead
of the OS, for example `sdb: 8 pending` (yellow) or `sda: FAILING` (red).

```
  Drives      2 drives · all OK · as of 15:42
  DEVICE      MODEL              TYPE   SIZE  TEMP HEALTH DETAIL
  sda         WDC WD40EFRX-68N   HDD    3.6T  37°C OK     pend 0 · realloc 0
  nvme0n1     Samsung SSD 980 1… NVMe   931G  47°C OK     used 3% · spare 100%
```

Health comes from `smartctl -A` alone:

- SATA: **FAIL** if an attribute is failing now; **WARN** if one failed in
  the past or there are reallocated, pending or uncorrectable sectors
  (attributes 5, 197, 198).
- NVMe: **FAIL** on a critical warning or when the spare blocks fall below
  their threshold; **WARN** from 90 % wear or with media errors.
- SAS: **WARN** with grown defects.

Temperatures follow `temp_unit` / `f`. Hard disks turn yellow from 50 °C and
red from 60 °C, SSDs and NVMe from 70 °C and 80 °C.

**Sleeping disks:** reading SMART data wakes a hard disk that has spun
down. scat asks at most every `drives_refresh` seconds (default 300), in the
background, and uses `smartctl -n standby`, which leaves a sleeping disk
alone (shown as `SLEEP`).

**Permissions:** smartctl needs root. scat runs it as root if it logs in as
root, otherwise through `sudo -n`, which fails instead of asking for a
password. A sudo rule for exactly these commands is enough (`sudo visudo
-f /etc/sudoers.d/scat`; use the path `command -v smartctl` shows):

```
<scat-user> ALL=(root) NOPASSWD: /usr/sbin/smartctl -n standby -A /dev/sd[a-z], \
    /usr/sbin/smartctl -n standby -A /dev/sd[a-z][a-z], \
    /usr/sbin/smartctl -n standby -A /dev/nvme[0-9]n[0-9]
```

If the rule only allows `smartctl -A` (without `-n standby`), scat falls back
to it and says so in the section ("sleeping disks are woken"); it tries the
`-n standby` form once per session (and again on `r`), so sudo logs one
refusal, not one per query. Without any rule the section shows "sudo
smartctl -A not allowed". Servers without `smartctl` show no section.

Not covered: disks behind USB bridges that need `-d sat` (shown as "not
readable"), and RAID controllers.

### Extension point for modules

`lib/modules.sh` keeps a small registry. Every `lib/modules/*.sh` file is
sourced at startup and calls
`sc_module_register <id> <label> <view-function>`. Registered modules appear
under `m` in the server detail view; optional hooks add a section to the
detail view or hide the module for servers it does not apply to. Remote
calls go through `sc_ssh_run_script`, so they get the same BatchMode,
timeouts and connection reuse. `lib/modules/docker.sh` is the example, and
`lib/modules/README.md` describes the contract.

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
lib/modules/            modules (docker.sh: Docker containers; drives.sh: SMART)
lib/remote/metrics.sh   POSIX sh collector executed on the server via `sh -s`
lib/remote/docker.sh    POSIX sh Docker query (docker ps / docker stats)
lib/remote/drives.sh    POSIX sh drive query (smartctl --scan / -A)
tests/run_tests.sh      tests for the non-interactive parts
tests/tui_smoke.exp     expect-driven end-to-end test of the TUI
tests/fixtures/         docker and smartctl output for the tests
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

## License

MIT. See [LICENSE](../LICENSE). Copyright (c) 2026 d3m0naz.
