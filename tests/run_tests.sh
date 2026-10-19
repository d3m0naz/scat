#!/usr/bin/env bash
# Tests for the non-interactive parts: config read/write, validation, ssh
# command construction, error classification, metric parsing, formatting,
# the timeout runner and the local run of the remote collector.
# Usage: tests/run_tests.sh   (set SC_TEST_NETWORK=0 to skip ssh failure tests,
#                              SC_TEST_RELEASE=1 to require install.sh = SC_VERSION)

if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
    echo "tests need Bash 5 (brew install bash)" >&2
    exit 1
fi

SC_ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sc-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
export SC_CONFIG_DIR=$TMP/config

for lib in core config ssh ui cli modules views; do
    # shellcheck source=/dev/null
    source "$SC_ROOT/lib/$lib.sh"
done

PASS=0 FAIL=0

ok() {
    ((PASS++))
    printf '  ok    %s\n' "$1"
}

nok() {
    ((FAIL++))
    printf '  FAIL  %s\n' "$1"
    [[ -n ${2:-} ]] && printf '        %s\n' "$2"
}

eq() { # description expected actual
    if [[ $2 == "$3" ]]; then ok "$1"; else nok "$1" "expected [$2], got [$3]"; fi
}

assert() { # description command...
    local d=$1
    shift
    if "$@"; then ok "$d"; else nok "$d"; fi
}

refute() {
    local d=$1
    shift
    if "$@"; then nok "$d"; else ok "$d"; fi
}

section() {
    printf '\n%s\n' "$1"
}

perm() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# ------------------------------------------------------------------------------
section "config: init and permissions"
sc_config_init
assert "config init succeeds" test -d "$SC_CONFIG_DIR"
eq "config dir mode" 700 "$(perm "$SC_CONFIG_DIR")"
eq "servers.conf mode" 600 "$(perm "$SC_SERVERS_FILE")"
eq "snippets.conf mode" 600 "$(perm "$SC_SNIPPETS_FILE")"
eq "settings.conf mode" 600 "$(perm "$SC_SETTINGS_FILE")"
sc_config_load_all
eq "no servers initially" 0 "${#SC_SERVERS[@]}"
assert "default snippets seeded" test "${#SC_SNIPPETS[@]}" -ge 3
eq "default settings" "15/5" "${SC_SET[list_refresh]}/${SC_SET[detail_refresh]}"

section "config: add, edit, rename, reorder, delete, round trip"
assert "add web1" sc_server_upsert "" web1 203.0.113.10 2222 deploy "~/.ssh/id_ed25519" "" production
assert "add db1" sc_server_upsert "" db1 db.example.com "" "" "" "admin@bastion:22" ""
refute "duplicate name rejected" sc_server_upsert "" web1 other.example.com "" "" "" "" ""
eq "duplicate error message" "a server named 'web1' already exists" "$SC_ERR"
refute "invalid port rejected" sc_server_upsert "" bad host.example.com 70000 "" "" "" ""
eq "invalid port message" "Port: port must be a number between 1 and 65535" "$SC_ERR"
eq "rejected servers not added" "web1 db1" "${SC_SERVERS[*]}"
eq "file mode after save" 600 "$(perm "$SC_SERVERS_FILE")"

sc_config_load_servers
eq "reload: order" "web1 db1" "${SC_SERVERS[*]}"
eq "reload: host" 203.0.113.10 "${SC_SRV[web1|host]}"
eq "reload: port" 2222 "${SC_SRV[web1|port]}"
eq "reload: identity keeps ~" "~/.ssh/id_ed25519" "${SC_SRV[web1|identity]}"
eq "reload: jump" "admin@bastion:22" "${SC_SRV[db1|jump]}"
eq "reload: empty field" "" "${SC_SRV[db1|port]}"
eq "no warnings" 0 "${#SC_CONFIG_WARNINGS[@]}"

assert "rename web1 -> web2" sc_server_upsert web1 web2 203.0.113.11 "" deploy "" "" production
sc_config_load_servers
eq "rename keeps position" "web2 db1" "${SC_SERVERS[*]}"
refute "old name gone" sc_server_exists web1
eq "edited host" 203.0.113.11 "${SC_SRV[web2|host]}"
assert "move db1 up" sc_server_move db1 -1
eq "order after move" "db1 web2" "${SC_SERVERS[*]}"
refute "move past top fails" sc_server_move db1 -1
assert "delete db1" sc_server_delete db1
sc_config_load_servers
eq "after delete" "web2" "${SC_SERVERS[*]}"

section "config: tolerant parsing of hand-edited files"
cat >"$SC_SERVERS_FILE" <<'EOF'
# comment
; another comment
[ok-1]
host = ok.example.com
PORT = 22
user=root
unknown = x

[bad name!]
host = x

[ok-1]
host = dup.example.com

[inject]
host = $(touch /tmp/sc-pwned)
port = 22; rm -rf /
garbage line
EOF
sc_config_load_all
eq "valid sections loaded" "ok-1 inject" "${SC_SERVERS[*]}"
eq "keys are case-insensitive" 22 "${SC_SRV[ok-1|port]}"
eq "duplicate section ignored" ok.example.com "${SC_SRV[ok-1|host]}"
eq "injection host rejected" "" "${SC_SRV[inject|host]}"
eq "injection port rejected" "" "${SC_SRV[inject|port]}"
refute "nothing was executed" test -e /tmp/sc-pwned
eq "warnings collected" 6 "${#SC_CONFIG_WARNINGS[@]}"
printf '        %s\n' "${SC_CONFIG_WARNINGS[@]}"

section "config directory (renamed from servercat, fallback to the old path)"
H=$TMP/home
scat_env() { # HOME-relative run without SC_CONFIG_DIR/XDG_CONFIG_HOME
    env -u SC_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$H" "$BASH" "$SC_ROOT/scat" "$@"
}
mkdir -p "$H"
out=$(scat_env --list 2>&1)
assert "new install: ~/.config/scat is created" test -d "$H/.config/scat"
refute "new install: no old directory created" test -e "$H/.config/servercat"
eq "new install: no notice" "" "$(grep 'old config directory' <<<"$out")"
rm -rf "$H/.config"
mkdir -p "$H/.config/servercat"
printf '[legacy1]\nhost = 192.0.2.7\n' >"$H/.config/servercat/servers.conf"
chmod 600 "$H/.config/servercat/servers.conf"
out=$(scat_env --list 2>"$TMP/legacy.err")
eq "only old directory: its servers are used" 1 "$(grep -c '^legacy1 ' <<<"$out")"
eq "only old directory: notice on stderr" "scat: using the old config directory ~/.config/servercat; rename it to ~/.config/scat" "$(cat "$TMP/legacy.err")"
refute "only old directory: new directory not created" test -e "$H/.config/scat"
eq "only old directory: --help names it" 1 "$(scat_env --help | grep -c 'instead of ~/.config/servercat$')"
eq "explicit --config-dir on the old path: no notice" "" "$(scat_env --config-dir "$H/.config/servercat" --list 2>&1 >/dev/null)"
eq "SC_CONFIG_DIR wins, no notice" "" "$(env -u XDG_CONFIG_HOME SC_CONFIG_DIR="$TMP/envdir" HOME="$H" "$BASH" "$SC_ROOT/scat" --list 2>&1 >/dev/null)"
mkdir -p "$H/.config/scat"
out=$(scat_env --list 2>&1)
eq "both directories: the new one is used" 0 "$(grep -c 'legacy1\|old config directory' <<<"$out")"
rm -rf "$H/.config/scat" "$H/xdg"
mkdir -p "$H/xdg/servercat"
eq "XDG_CONFIG_HOME: same fallback" 1 \
    "$(env -u SC_CONFIG_DIR XDG_CONFIG_HOME="$H/xdg" HOME="$H" "$BASH" "$SC_ROOT/scat" --list 2>&1 >/dev/null | grep -c 'old config directory ~/xdg/servercat; rename it to ~/xdg/scat')"

section "config: settings"
cat >"$SC_SETTINGS_FILE" <<'EOF'
[settings]
list_refresh = 30
connect_timeout = 999
multiplex = 0
EOF
sc_config_load_all
eq "valid setting applied" 30 "${SC_SET[list_refresh]}"
eq "out-of-range setting ignored" 5 "${SC_SET[connect_timeout]}"
eq "multiplex off" 0 "${SC_SET[multiplex]}"

section "config: snippets"
assert "add snippet" sc_snippet_upsert "" uptime-check "uptime"
refute "multi-line command rejected" sc_snippet_upsert "" bad $'ls\nrm -rf /'
assert "rename snippet" sc_snippet_upsert uptime-check up "uptime -p"
sc_config_load_snippets
eq "snippet reloaded" "uptime -p" "${SC_SNIP[up]}"
refute "old snippet gone" test -n "${SC_SNIP[uptime-check]+x}"
assert "delete snippet" sc_snippet_delete up
sc_config_load_snippets
refute "snippet deleted" test -n "${SC_SNIP[up]+x}"

# ------------------------------------------------------------------------------
section "validation"
assert "name ok" sc_valid_name web-01.prod
refute "name with space" sc_valid_name "web 1"
refute "name starting with -" sc_valid_name -web
refute "name too long" sc_valid_name "$(printf 'a%.0s' {1..33})"
assert "host IPv4" sc_valid_host 192.168.1.10
assert "host IPv6" sc_valid_host 2001:db8::1
assert "host alias" sc_valid_host my_alias
refute "host option injection" sc_valid_host -oProxyCommand=evil
refute "host with space" sc_valid_host "a b"
refute "host with ;" sc_valid_host "a;b"
refute "empty host" sc_valid_host ""
assert "port empty allowed" sc_valid_port ""
refute "port 0" sc_valid_port 0
refute "port text" sc_valid_port 22a
assert "user ok" sc_valid_user deploy
refute "user with space" sc_valid_user "de ploy"
refute "identity .pub" sc_valid_identity_syntax ~/.ssh/id_ed25519.pub
refute "identity missing file" sc_valid_identity "$TMP/nope"
touch "$TMP/key"
assert "identity existing file" sc_valid_identity "$TMP/key"
assert "jump chain" sc_valid_jump "a@b:22,c"
refute "jump with space" sc_valid_jump "a b"
refute "group with newline" sc_valid_group $'a\nb'

# ------------------------------------------------------------------------------
section "ssh command construction"
SC_SET[connect_timeout]=5 SC_SET[multiplex]=1
SC_RUNTIME_DIR=/tmp/sc-rt
sc_ssh_build batch host.example.com 2222 deploy "~/.ssh/id_ed25519" "admin@bastion"
eq "batch argv" \
    "ssh|-o|ConnectTimeout=5|-o|ServerAliveInterval=5|-o|ServerAliveCountMax=2|-T|-o|BatchMode=yes|-o|ControlMaster=auto|-o|ControlPath=/tmp/sc-rt/cm-%C|-o|ControlPersist=60|-p|2222|-l|deploy|-i|$HOME/.ssh/id_ed25519|-o|IdentitiesOnly=yes|-J|admin@bastion|--|host.example.com" \
    "$(IFS='|'; echo "${SC_SSH_CMD[*]}")"
sc_ssh_build interactive host.example.com "" "" "" ""
eq "interactive argv (no BatchMode, no multiplexing)" \
    "ssh|-o|ConnectTimeout=5|-o|ServerAliveInterval=5|-o|ServerAliveCountMax=2|--|host.example.com" \
    "$(IFS='|'; echo "${SC_SSH_CMD[*]}")"
SC_SET[multiplex]=0
sc_ssh_build batch h "" "" "" ""
refute "multiplex=0 drops ControlMaster" test "${SC_SSH_CMD[*]}" != "${SC_SSH_CMD[*]/ControlMaster/}"
refute "build rejects bad host" sc_ssh_build batch "-oProxyCommand=x" "" "" "" ""
sc_server_upsert "" spaced "host.example.com" "" "" "$TMP/dir with space/key" "" "" >/dev/null
sc_ssh_build_for spaced batch
eq "path with spaces stays one argument" "$TMP/dir with space/key" "${SC_SSH_CMD[$((${#SC_SSH_CMD[@]} - 5))]}"
refute "build_for unknown server" sc_ssh_build_for nope
SC_RUNTIME_DIR=

section "ssh error classification"
classify() {
    printf '%s\n' "$2" >"$TMP/err"
    sc_ssh_error_summary "$1" "$TMP/err" 20
    printf '%s' "$REPLY"
}
eq "timeout" "timed out after 20s" "$(classify 124 '')"
eq "auth" "authentication failed - check key / ssh-agent (ssh-add -l)" \
    "$(classify 255 'deploy@h: Permission denied (publickey).')"
eq "unknown host key" "unknown host key - press 's' to connect once and verify it" \
    "$(classify 255 $'No ED25519 host key is known for h and you have requested strict checking.\nHost key verification failed.')"
eq "dns" "cannot resolve hostname" \
    "$(classify 255 'ssh: Could not resolve hostname x: nodename nor servname provided, or not known')"
eq "refused" "connection refused" "$(classify 255 'ssh: connect to host h port 22: Connection refused')"
eq "connect timeout" "connection timed out" "$(classify 255 'ssh: connect to host h port 22: Operation timed out')"
eq "remote exit status" "exit status 127: sh: not found" "$(classify 127 'sh: not found')"
eq "escape sequences stripped" "ssh failed: evil[31mred" "$(classify 255 $'evil\e[31mred')"

# ------------------------------------------------------------------------------
section "metrics parsing"
cat >"$TMP/res" <<'EOF'
rc=0
ts=1700000000
os=Linux
hostname=web1
distro=Ubuntu 24.04 LTS
uptime=93784
load=0.52 0.48 0.40
cores=4
cpu_busy=31.2
mem_total=8000000
mem_used=2000000
swap_total=0
netif=eth0|523000|12000
netif=wlan0|0|0
netif=bad name|1|2
netif=eth1|x|1
disk=/|41000000|21000000|52
disk=/data|100000000|10000000|10
proc=1|root|0.0|0.1|1200|systemd
proc=900|www-data|25.5|3.2|250000|nginx: worker process
bogus=ignored
EOF
printf 'hostname=\e]0;pwned\a-x\n' >>"$TMP/res"
sc_metrics_load web2 "$TMP/res"
cp "$TMP/res" "$TMP/res.full"
assert "online" sc_metrics_online web2
eq "cpu" 31.2 "${SC_M[web2|cpu_busy]}"
eq "two disks" 2 "$(grep -c . <<<"${SC_M[web2|disks]}")"
eq "process with spaces kept" "900|www-data|25.5|3.2|250000|nginx: worker process" "$(sed -n 2p <<<"${SC_M[web2|procs]}")"
eq "unknown key ignored" "" "${SC_M[web2|bogus]-}"
eq "valid netif lines kept, malformed dropped" $'eth0|523000|12000\nwlan0|0|0' "${SC_M[web2|netifs]}"
eq "control chars stripped" "]0;pwned-x" "${SC_M[web2|hostname]}"
sc_sort_procs web2 cpu
eq "sort by cpu" 900 "${SC_PROC_ROWS[0]%%|*}"
sc_sort_procs web2 pid
eq "sort by pid" 1 "${SC_PROC_ROWS[0]%%|*}"
printf 'rc=255\nts=1\nerr=connection refused\n' >"$TMP/res"
sc_metrics_load web2 "$TMP/res"
refute "offline after error" sc_metrics_online web2
eq "old metrics cleared" "" "${SC_M[web2|cpu_busy]-}"

section "cli output"
cat >"$TMP/res2" <<'EOF'
rc=0
ts=1700000000
os=Linux
mem_total=8200000
mem_used=4450000
proc=766271|root|3.3|0.1|11872|sshd-session: pi [priv]
proc=935|root|2.8|1.4|121088|dockerd
EOF
SC_SRV[web2|host]=203.0.113.11
sc_metrics_load web2 "$TMP/res2"
out=$(sc_print_summary web2)
eq "memory used / total" "  Memory    4.2G / 7.8G (54%)" "$(grep Memory <<<"$out")"
eq "process header aligned" "        PID USER         CPU%   MEM%     RSS COMMAND" "$(grep -m1 'PID' <<<"$out")"
eq "process row aligned" "     766271 root          3.3    0.1   11.5M sshd-session: pi [priv]" "$(grep -m1 766271 <<<"$out")"
sc_proc_line "1|u|0.0|0.0|1|$(printf 'x%.0s' {1..100})" 60
eq "process row width honoured" 60 "${#REPLY}"
eq "unknown server is an error" "scat: error: unknown server 'nope' (see --list)" "$(sc_cli_check nope 2>&1)"
sc_cli_check nope 2>/dev/null; eq "unknown server exit 2" 2 "$?"
eq "help names the default config dir" 1 "$("$SC_ROOT/scat" --config-dir "$TMP/other" --help | grep -c "instead of ${SC_CONFIG_DIR_DEFAULT/#$HOME/\~}\$")"

section "section order (CPU, Disks, Network, processes)"
# Renders into stdout instead of the terminal; prints the row of the first
# line matching each section marker.
order_of() {
    awk '/(^|  )CPU /{c=c?c:NR} /Disks|  Disk  /{d=d?d:NR} /Network/{n=n?n:NR} /PID USER/{p=p?p:NR}
         END { print (c && c < d && d < n && n < p) ? "ordered" : "c=" c " d=" d " n=" n " p=" p }'
}
SC_G_FULL='█' SC_G_EMPTY='░' SC_G_EIGHTHS=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
sc_metrics_load web2 "$TMP/res.full"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=100; sc_draw_detail web2)
eq "detail view order" ordered "$(order_of <<<"$detail")"
# Network rows of a rendered detail view: from the "Network" heading up to
# the next blank line, trailing padding removed.
net_rows() {
    awk '/^  Network/ { on = 1; next } on && /^ *$/ { exit } on' | sed 's/ *$//'
}
r15=$(printf '░%.0s' {1..15}) r16=$(printf '░%.0s' {1..16})
eq "detail: one row per interface, split bar (100 cols: 16 rx + gap + 16 tx cells)" "  eth0        ▏$r15 ▏$r15 rx   0.52  tx   0.01 MB/s
  wlan0       $r16 $r16 rx   0.00  tx   0.00 MB/s" "$(net_rows <<<"$detail")"
eq "detail: 1 row per interface" 2 "$(net_rows <<<"$detail" | grep -c .)"
# Same columns as the Disks rows: bar start, and values where the disk
# percentage field starts (bar column + 1 space).
dl=$(grep '^  /data ' <<<"$detail" | sed $'s/\e\\[[0-9;]*[mK]//g')
nl=$(net_rows <<<"$detail" | sed -n 2p)
pre=${dl%%[█░]*}; dbar=${#pre}; rest=${dl:dbar}; bars=${rest%% *}
pre=${nl%%[░▏█]*}; nbar=${#pre}; npre=${nl%%rx *}
eq "detail: network bar and values in the Disks columns" "$dbar $((dbar + ${#bars} + 1))" "$nbar ${#npre}"
# Edge case below the 80x24 minimum: the layout itself still fits 60 columns.
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_MIN_COLS=60 SC_MIN_ROWS=12 SC_ROWS=40 SC_COLS=60; sc_draw_detail web2)
eq "detail at 60 columns: rows exactly 60 wide, no wrap" "60 60" "$(net_rows <<<"$detail" | while IFS= read -r l; do printf '%s ' "${#l}"; done | sed 's/ $//')"
eq "detail at 60 columns: values complete" "rx   0.52  tx   0.01 MB/s" "$(net_rows <<<"$detail" | head -n 1 | grep -o 'rx .*')"
eq "detail order at 60 columns" ordered "$(order_of <<<"$detail")"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=110; sc_draw_detail web2)
eq "detail at 110 columns: rows 76 wide (36-cell bar column)" "76 76" "$(net_rows <<<"$detail" | while IFS= read -r l; do printf '%s ' "${#l}"; done | sed 's/ $//')"
eq "network section height: heading + 1 per interface + blank" 4 "$(awk '/^  Network/ { on = 1 } on { n++ } on && /^ *$/ { exit } END { print n }' <<<"$detail")"
summary=$(sc_print_summary web2)
eq "--check order" ordered "$(order_of <<<"$summary")"
r9=$(printf '░%.0s' {1..9}) r10=$(printf '░%.0s' {1..10})
eq "--check: one line per interface, split 10+10 bar" "  Network   eth0       ▏$r9 ▏$r9  rx   0.52  tx   0.01 MB/s
  Network   wlan0      $r10 $r10  rx   0.00  tx   0.00 MB/s" "$(grep '^  Network' <<<"$summary")"
printf 'rc=0\nts=1\nos=OpenBSD\nnet_note=per-interface rates are not collected on OpenBSD\n' >"$TMP/res3"
sc_metrics_load web2 "$TMP/res3"
eq "--check shows the limitation" "  Network   per-interface rates are not collected on OpenBSD" "$(sc_print_summary web2 | grep Network)"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=100; sc_draw_detail web2)
eq "detail shows the limitation" 1 "$(grep -c '^  per-interface rates are not collected on OpenBSD' <<<"$detail")"

section "network rate bars (100 MB/s = full bar)"
bar() { # rate width -> "filled|rest|units"
    sc_rate_bar "$1" "$2"
    printf '%s|%s|%s' "$REPLY" "$SC_BAR_REST" "$SC_BAR_UNITS"
}
eq "0 MB/s is empty" "|░░░░░░░░░░|0" "$(bar 0 10)"
eq "50 MB/s is half" "█████|░░░░░|40" "$(bar 50000000 10)"
eq "100 MB/s is full" "██████████||80" "$(bar 100000000 10)"
eq "150 MB/s is clamped to full" "██████████||80" "$(bar 150000000 10)"
eq "12.5 MB/s uses eighth cells" "█▎|░░░░░░░░|10" "$(bar 12500000 10)"
eq "1 byte/s shows the smallest step" "▏|░░░░░░░░░|1" "$(bar 1 10)"
eq "0.6 MB/s (rounds to 0) still visible" "▏|░░░░░░░░░|1" "$(bar 600000 10)"
eq "invalid rate is empty" "|░░░░|0" "$(bar x 4)"
widths=
for v in 0 1 600000 12500000 33333333 50000000 99999999 100000000 150000000; do
    for w in 4 7 27; do
        sc_rate_bar "$v" "$w"; widths+="$((${#REPLY} + ${#SC_BAR_REST} == w))"
    done
done
eq "bar is always exactly the requested width" "$(printf '1%.0s' {1..27})" "$widths"
split() { # rx tx width -> bar without color codes
    sc_netif_bar "$1" "$2" "$3"
    sed $'s/\e\\[[0-9;]*m//g' <<<"$REPLY"
}
eq "split bar: rx left (9), gap, tx right (10) at width 20" "████▌░░░░ ▏░░░░░░░░░" "$(split 50000000 1 20)"
eq "split bar: each half has its own 100 MB/s scale" "█████████ ██████████" "$(split 100000000 150000000 20)"
widths=
for w in 10 20 21 33 36 40; do l=$(split 12500000 600000 "$w"); widths+="${#l} "; done
eq "split bar is exactly the bar column wide" "10 20 21 33 36 40 " "$widths"
sc_netif_bar 1 1 6
eq "split bar colors: rx green before tx red" 1 "$([[ $REPLY == *"$C_RX"*" $C_TX"* ]] && echo 1)"
sc_netif_values 523000 12000; eq "values: unit once at the end" "rx   0.52  tx   0.01 MB/s" "$REPLY"
sc_netif_values 125000000 x; eq "values: 1 GbE line rate fits 25 columns" "rx 125.00  tx      - MB/s" "$REPLY"
SC_COLS=80
SC_SET[ascii]=1; sc_glyphs_init
eq "ascii: no eighth cells" 0 "${#SC_G_EIGHTHS[@]}"
eq "ascii: 0 MB/s" "|..........|0" "$(bar 0 10)"
eq "ascii: 50 MB/s" "#####|.....|5" "$(bar 50000000 10)"
eq "ascii: 150 MB/s clamped" "##########||10" "$(bar 150000000 10)"
eq "ascii: 12.5 MB/s rounds to whole cells" "#|.........|1" "$(bar 12500000 10)"
eq "ascii: tiny rate still visible" "#|.........|1" "$(bar 1 10)"
sc_metrics_load web2 "$TMP/res.full"
eq "ascii: --check row" "  Network   eth0       #......... #.........  rx   0.52  tx   0.01 MB/s" "$(sc_print_summary web2 | grep 'Network   eth0')"
SC_SET[ascii]=0 SC_G_FULL='█' SC_G_EMPTY='░' SC_G_EIGHTHS=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
eq "colors: rx green, tx muted red" $'\e[32m|\e[38;5;131m' "$(TERM=xterm-256color; unset NO_COLOR; sc_ui_colors; printf '%s|%s' "$C_RX" "$C_TX")"
eq "colors: 8-color tx falls back to palette red" $'\e[31m' "$(TERM=xterm; unset NO_COLOR; sc_ui_colors; printf '%s' "$C_TX")"
eq "colors: NO_COLOR disables bar colors" "|" "$(TERM=xterm-256color NO_COLOR=1; sc_ui_colors; printf '%s|%s' "$C_RX" "$C_TX")"

eq "renderer clears a row before writing it (keeps the last column)" $'\e[1;1H\e[0m\e[Kabc\e[0m' \
    "$(SC_ROWS=1 SC_FULL_REDRAW=0 SC_SCREEN=() SC_FRAME=(abc); sc_ui_render)"

section "server list groups"
SC_G_HLINE='─' SC_G_TIMES='×' SC_G_SEL='▶' SC_G_DOT='●' SC_G_HOLLOW='○'
# Renders a server list frame to stdout (colors removed, trailing blanks kept).
list_frame() { # rows cols sel top
    (
        sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }
        SC_ROWS=$1 SC_COLS=$2
        sc_list_scroll "$3" "$4" $((SC_ROWS - 4))
        sc_draw_servers "$3" "$REPLY"
    ) | sed $'s/\e\\[[0-9;]*[mK]//g'
}
list_rows() { # "h:name s:name ..." of SC_LIST_*
    local i out=
    for i in "${!SC_LIST_KIND[@]}"; do out+="${SC_LIST_KIND[i]}:${SC_LIST_VAL[i]} "; done
    printf '%s' "${out% }"
}
SC_SERVERS=() SC_SRV=() SC_M=()
for s in web2:production zeta: alpha:Lab web1:production db: Beta:lab2; do
    sc_server_upsert "" "${s%%:*}" 192.0.2.1 "" "" "" "" "${s#*:}" >/dev/null || nok "upsert $s"
done
sc_list_build
eq "groups A-Z (case-insensitive), servers A-Z, ungrouped last" \
    "h:Lab s:alpha h:lab2 s:Beta h:production s:web1 s:web2 h:ungrouped s:db s:zeta" "$(list_rows)"
eq "--list: same order with plain headings" "NAME                 TARGET                                   GROUP
-- Lab --
alpha                192.0.2.1                                Lab
-- lab2 --
Beta                 192.0.2.1                                lab2
-- production --
web1                 192.0.2.1                                production
web2                 192.0.2.1                                production
-- ungrouped --
db                   192.0.2.1
zeta                 192.0.2.1" "$(sc_cli_list | sed 's/ *$//')"
nav() { # row key -> new row
    SC_KEY=$2
    sc_list_nav "$1" && printf '%s' "$REPLY"
}
eq "down skips the heading" 3 "$(nav 1 DOWN)"
eq "up skips the heading" 1 "$(nav 3 UP)"
eq "up from the first server stays on it" 1 "$(nav 1 UP)"
eq "home selects the first server, not the heading" 1 "$(SC_ROWS=24; nav 6 HOME)"
eq "end selects the last server" 9 "$(SC_ROWS=24; nav 1 END)"
eq "page up never lands on a heading" 1 "$(SC_ROWS=24; nav 9 PGUP)"
sc_list_fix 0 1; eq "initial selection is the first server" 1 "$REPLY"
sc_list_fix 7 1; eq "selection on a heading moves to the next server" 8 "$REPLY"
eq "every selectable row is a server" "s s s s s s" \
    "$(for r in 1 3 5 6 8 9; do SC_KEY=DOWN; sc_list_nav $r; printf '%s ' "${SC_LIST_KIND[REPLY]}"; done | sed 's/ $//')"
frame=$(list_frame 24 80 1 0)
eq "list: heading row in the frame" " ── Lab ──" "$(sed -n 3p <<<"$frame" | sed 's/ *$//')"
eq "list: no [group] tag in server rows" 0 "$(grep -c '\[production\]' <<<"$frame")"
eq "list at 80 columns: no row wider than 80" 0 "$(while IFS= read -r l; do ((${#l} > 80)) && echo x; done <<<"$frame" | grep -c x)"
# Small window: 5 list rows. With zeta (last row) selected the window
# starts inside "production"; its heading is drawn in place of the first row.
frame=$(SC_MIN_ROWS=9 SC_MIN_COLS=60; list_frame 9 80 9 0)
eq "scrolled list starts with the group heading (sticky)" " ── production ──| ○ web2| ── ungrouped ──| ○ db|▶○ zeta" \
    "$(sed -n 3,7p <<<"$frame" | awk '{ print substr($0, 1, 30) }' | sed 's/ *$//; s/^\(.. [a-z0-9]*\) .*/\1/' | paste -sd '|' -)"
frame=$(SC_MIN_ROWS=9 SC_MIN_COLS=60; list_frame 9 80 3 4)
eq "scrolling up to the first server of a group shows its heading above it" " ── lab2 ──" "$(sed -n 3p <<<"$frame" | sed 's/ *$//')"
frame=$(SC_MIN_ROWS=12 SC_MIN_COLS=60; list_frame 12 60 9 0)
eq "edge case 60 columns: no row wider than 60" 0 "$(while IFS= read -r l; do ((${#l} > 60)) && echo x; done <<<"$frame" | grep -c x)"
eq "group_headings defaults to 1" 1 "${SC_SET[group_headings]}"
sc_list_build 0
eq "group_headings = 0: same order, no heading rows" "s:alpha s:Beta s:web1 s:web2 s:db s:zeta" "$(list_rows)"
sc_list_fix 0 1; eq "group_headings = 0: first row is selectable" 0 "$REPLY"
frame=$(SC_MIN_ROWS=9 SC_MIN_COLS=60; list_frame 9 80 5 0)
eq "group_headings = 0: scrolled list has no sticky heading" "○ Beta|○ web1|○ web2|○ db|▶○ zeta" \
    "$(sed -n 3,7p <<<"$frame" | awk '{ print $1, $2 }' | paste -sd '|' -)"
eq "group_headings = 0: no heading anywhere in the frame" 0 "$(grep -c '──' <<<"$frame")"
SC_SET[group_headings]=0
sc_list_build
eq "without argument the setting is used" "s:alpha s:Beta s:web1 s:web2 s:db s:zeta" "$(list_rows)"
eq "--list keeps its headings with group_headings = 0" 4 "$(sc_cli_list | grep -c '^-- ')"
SC_SET[group_headings]=1
sc_list_build

# Key t: toggles the headings for the session; settings.conf is not written.
sc_config_load_settings
cp "$SC_SETTINGS_FILE" "$TMP/settings.before-t"
rows_on=$(list_rows)
sc_list_row web2
sc_list_toggle_headings "$REPLY"; sel=$REPLY
eq "t: headings off in the list" "s:alpha s:Beta s:web1 s:web2 s:db s:zeta" "$(list_rows)"
eq "t: same server stays selected" web2 "${SC_LIST_VAL[sel]}"
eq "t: session value is 0" 0 "${SC_SET[group_headings]}"
assert "t: settings.conf stays byte for byte the same" cmp -s "$TMP/settings.before-t" "$SC_SETTINGS_FILE"
sc_list_toggle_headings "$sel"; sel=$REPLY
eq "t again: headings back" "$rows_on" "$(list_rows)"
eq "t again: same server stays selected" web2 "${SC_LIST_VAL[sel]}"
eq "t again: session value is 1" 1 "${SC_SET[group_headings]}"
assert "t again: settings.conf still unchanged" cmp -s "$TMP/settings.before-t" "$SC_SETTINGS_FILE"
eq "next start reads the start value from settings.conf, not the toggled one" 1 \
    "$(SC_SET[group_headings]=0; sc_list_toggle_headings 1 >/dev/null; SC_SET[group_headings]=1; SC_CONFIG_WARNINGS=(); sc_config_load_settings; printf '%s' "${SC_SET[group_headings]}")"
eq "settings writer for t is gone" "" "$(declare -F sc_setting_save)"
frame=$(SC_G_UPDOWN='↑↓' SC_G_ENTER='⏎'; list_frame 24 80 1 0)
eq "list footer: all keys, t included" " ↑↓ move  ⏎ open  a add  e edit  d del  s ssh  r refresh  t grp  ? help  q quit " "$(sed -n 24p <<<"$frame")"
line=$(sed -n 24p <<<"$frame")
eq "list footer: exactly 80 columns" 80 "${#line}"
SC_SERVERS=() SC_SRV=()
for s in c b a; do sc_server_upsert "" "$s" 192.0.2.1 "" "" "" "" "" >/dev/null; done
sc_list_build
eq "no groups: config order, no headings" "s:c s:b s:a" "$(list_rows)"
eq "no groups: --list unchanged" "NAME TARGET GROUP|c 192.0.2.1|b 192.0.2.1|a 192.0.2.1" \
    "$(sc_cli_list | awk '{ $1 = $1; print }' | paste -sd '|' -)"
SC_SET[ascii]=1; sc_glyphs_init
sc_list_heading prod; eq "ascii heading" " -- prod --" "$(sed $'s/\e\\[[0-9;]*m//g; s/ *$//' <<<"$REPLY")"
SC_SET[ascii]=0 SC_G_FULL='█' SC_G_EMPTY='░' SC_G_EIGHTHS=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉') SC_G_HLINE='─' SC_G_TIMES='×' SC_G_SEL='▶'

section "minimum terminal size 80x24"
small=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=24 SC_COLS=79; sc_draw_servers 0 0)
eq "79x24: notice instead of the layout" 1 "$(grep -c 'Terminal too small: at least 80×24 needed (now 79×24)' <<<"$small")"
eq "79x24: no list header" 0 "$(grep -c 'NAME' <<<"$small")"
eq "notice is centred" "             Terminal too small: at least 80×24 needed (now 79×24)" "$(sed -n 12p <<<"$small" | sed $'s/\e\\[[0-9;]*m//g; s/ *$//')"
small=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=23 SC_COLS=80; sc_draw_detail web2)
eq "80x23: notice in the detail view too" 1 "$(grep -c 'now 80×23' <<<"$small")"
sc_metrics_load web2 "$TMP/res.full"
SC_SRV[web2|host]=203.0.113.11
full=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=24 SC_COLS=80; sc_draw_detail web2 | sed $'s/\e\\[[0-9;]*[mK]//g')
eq "80x24: full detail layout" ordered "$(order_of <<<"$full")"
eq "80x24: both disks, both interfaces, process rows" "2 2 2" \
    "$(printf '%s %s %s' "$(grep -c '^  /\(data\)\{0,1\} ' <<<"$full")" "$(grep -c '^  \(eth0\|wlan0\) ' <<<"$full")" "$(grep -c '^ *[0-9]\+ \(root\|www-data\) ' <<<"$full")")"
eq "80x24: no row wider than 80" 0 "$(while IFS= read -r l; do ((${#l} > 80)) && echo x; done <<<"$full" | grep -c x)"

section "detail view scrolling (80x24)"
SC_G_SEP='·'
{
    printf 'rc=0\nts=1\nos=Linux\nhostname=bigbox\ncpu_busy=42\nmem_total=65000000\nmem_used=40000000\nswap_total=0\nload=1 1 1\n'
    for i in 1 2 3 4 5 6; do printf 'disk=/data%d|1000000000|%d00000000|%d0\n' "$i" "$i" "$i"; done
    for i in 0 1 2 3 4 5; do printf 'netif=eth%d|%d000000|%d00000\n' "$i" $((i * 15 + 1)) $((i + 1)); done
    for i in {1..30}; do printf 'proc=%d|svc%d|%d.0|1.0|10000|worker-%02d\n' $((1000 + i)) "$i" $((31 - i)) "$i"; done
} >"$TMP/big.res"
sc_metrics_load big "$TMP/big.res"
SC_SRV[big|host]=fixture-big.invalid
# Draws the detail view at scroll position $1 in $2 x $3; prints the frame
# without colors, then "pos max status" as the last line.
det() { # scroll [cols] [rows]
    (
        sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }
        SC_COLS=${2:-80} SC_ROWS=${3:-24} SC_DET_SCROLL=$1
        sc_draw_detail big
        printf '%s %s %s\n' "$SC_DET_SCROLL" "$SC_DET_SCROLL_MAX" "${SC_FRAME_STATUS:--}"
    ) | sed $'s/\e\\[[0-9;]*[mK]//g'
}
f=$(det 0)
eq "top: header and title row fixed, indicator 1-21/28" "0 7 1-21/28" "$(tail -n 1 <<<"$f")"
eq "top: frame is 24 rows" 24 "$(sed '$d' <<<"$f" | wc -l | tr -d ' ')"
eq "indicator at the right end of the status line" "1-21/28" "$(sed -n 23p <<<"$f" | sed 's/^ *//; s/ *$//')"
eq "footer fits 80 columns" 1 "$(sed -n 24p <<<"$f" | awk '{ print (length($0) <= 80) }')"
eq "scrolling up past the top is clamped" "0 7 1-21/28" "$(det -5 | tail -n 1)"
eq "scrolling down past the end is clamped" "7 7 8-28/28" "$(det 100 | tail -n 1)"
f=$(det 7)
eq "header stays while scrolled" " scat · big" "$(sed -n 1p <<<"$f" | cut -c1-11)"
eq "end: last process row is the last content row" 1 "$(sed -n 22p <<<"$f" | grep -c 'worker-03')"
all=$(for p in 0 1 2 3 4 5 6 7; do det "$p" | sed -n '2,22p'; done | sort -u)
eq "max size (6 disks, 6 interfaces): all reachable by scrolling" "6 6 1" \
    "$(printf '%s %s %s' "$(grep -c '^  /data[1-6] ' <<<"$all")" "$(grep -c '^  eth[0-5] ' <<<"$all")" "$(grep -c 'PID USER' <<<"$all")")"
key() { # start key -> position after the key (clamped by a redraw)
    (
        SC_ROWS=24 SC_COLS=80 SC_DET_SCROLL=$1 SC_KEY=$2
        sc_ui_render() { :; }
        sc_draw_detail big; sc_detail_scroll_key || echo unhandled; sc_draw_detail big
        printf '%s' "$SC_DET_SCROLL"
    )
}
eq "down: one row" 1 "$(key 0 DOWN)"
eq "up: one row" 4 "$(key 5 UP)"
eq "up at the top stays" 0 "$(key 0 UP)"
eq "down at the end stays" 7 "$(key 7 DOWN)"
eq "page down: one page (21 rows), clamped at the end" 7 "$(key 0 PGDN)"
eq "page up: one page, clamped at the top" 0 "$(key 7 PGUP)"
eq "end / home" "7 0" "$(key 2 END) $(key 5 HOME)"
eq "other keys are not scroll keys" "unhandled" "$(key 0 p | head -c 9)"
f=$(sc_ui_render() { :; }; SC_COLS=80 SC_ROWS=24 SC_DET_SCROLL=0 SC_KEY=PGDN; sc_draw_detail big; sc_detail_scroll_key; sc_draw_detail big
    SC_ROWS=40; sc_draw_detail big; printf '%s %s %s' "$SC_DET_SCROLL" "$SC_DET_SCROLL_MAX" "${SC_FRAME_STATUS:--}")
eq "resize to 80x40: position clamped, no overflow, no indicator" "0 0 -" "$f"
f=$(sc_ui_render() { :; }; SC_COLS=80 SC_ROWS=24 SC_DET_SCROLL=7; sc_draw_detail big; SC_ROWS=27; sc_draw_detail big
    printf '%s %s' "$SC_DET_SCROLL" "$SC_DET_SCROLL_MAX")
eq "resize to 80x27: position clamped to the new end" "4 4" "$f"
sc_metrics_load web2 "$TMP/res.full"
f=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_COLS=80 SC_ROWS=24 SC_DET_SCROLL=0; sc_draw_detail web2; printf '%s\n' "${SC_FRAME_STATUS:--}")
eq "no overflow (2 disks, 2 interfaces): no indicator" - "$(tail -n 1 <<<"$f")"
eq "no overflow: status line empty" "" "$(sed -n 23p <<<"$f" | sed $'s/\e\\[[0-9;]*m//g; s/ *$//')"
help=$(sc_view_pager() { printf '%s\n' "${SC_PAGER_LINES[@]}"; }; sc_view_help)
eq "help lists the scroll keys" 2 "$(grep -c 'scroll one row\|top / bottom' <<<"$help")"
eq "help lines fit 80 columns (79 + pager margin)" 0 "$(while IFS= read -r l; do ((${#l} > 79)) && echo x; done <<<"$help" | grep -c x)"

section "color themes"
tokens() { # theme term [NO_COLOR] -> all color tokens, one per line
    (
        TERM=$2
        if [[ -n ${3-} ]]; then export NO_COLOR=1; else unset NO_COLOR; fi
        SC_SET[theme]=$1
        sc_ui_colors
        printf '%q\n' "$C_HDR" "$C_FOOT" "$C_SEL" "$C_EDIT" "$C_DIM" "$C_ACCENT" "$C_OK" "$C_WARN" "$C_CRIT" "$C_RX" "$C_TX"
    )
}
# The colors before themes existed; default must keep them exactly.
eq "default, 256 colors: unchanged codes" "$(printf '%q\n' $'\e[1;97;44m' $'\e[38;5;252;48;5;237m' $'\e[48;5;24m' $'\e[4;48;5;236m' $'\e[2m' $'\e[36m' $'\e[32m' $'\e[33m' $'\e[31m' $'\e[32m' $'\e[38;5;131m')" "$(tokens default xterm-256color)"
eq "default, 8 colors: unchanged codes" "$(printf '%q\n' $'\e[1;97;44m' $'\e[30;47m' $'\e[7m' $'\e[4m' $'\e[2m' $'\e[36m' $'\e[32m' $'\e[33m' $'\e[31m' $'\e[32m' $'\e[31m')" "$(tokens default xterm)"
nocolor=$(printf '%q\n' $'\e[7m' $'\e[7m' $'\e[7m' $'\e[4m' $'\e[2m' '' '' '' '' '' '')
for t in "${SC_THEMES[@]}"; do
    eq "$t: NO_COLOR wins (no colors, only reverse/underline/faint)" "$nocolor" "$(tokens "$t" xterm-256color 1)"
done
eq "five themes" "default light solarized nord high-contrast" "${SC_THEMES[*]}"
eq "themes differ from each other (256 colors)" 5 "$(for t in "${SC_THEMES[@]}"; do tokens "$t" xterm-256color | paste -sd ' ' -; done | sort -u | wc -l | tr -d ' ')"
eq "high-contrast uses bright colors on 8/16-color terminals" $'\e[92m|\e[91m' "$(TERM=xterm; unset NO_COLOR; SC_SET[theme]=high-contrast; sc_ui_colors; printf '%s|%s' "$C_RX" "$C_TX")"

printf '[settings]\ntheme = solarized\n' >"$TMP/theme.conf"
eq "theme setting is read" solarized "$(SC_SETTINGS_FILE=$TMP/theme.conf; SC_CONFIG_WARNINGS=(); sc_config_load_settings; printf '%s' "${SC_SET[theme]}")"
printf '[settings]\ntheme = purple\n' >"$TMP/theme.conf"
eq "invalid theme: warning, default kept" "default|settings.conf:2: theme must be one of: default, light, solarized, nord, high-contrast (got 'purple')" \
    "$(SC_SETTINGS_FILE=$TMP/theme.conf; SC_SET[theme]=default; SC_CONFIG_WARNINGS=(); sc_config_load_settings; printf '%s|%s' "${SC_SET[theme]}" "${SC_CONFIG_WARNINGS[0]-}")"
eq "--theme with an unknown name is an error" "scat: --theme must be one of: default, light, solarized, nord, high-contrast (got 'purple')|1" \
    "$("$SC_ROOT/scat" --config-dir "$TMP/themecfg" --theme purple --list 2>&1 | tr -d '\n'; printf '|%s' "${PIPESTATUS[0]}")"
eq "--theme with a valid name is accepted" 0 "$("$SC_ROOT/scat" --config-dir "$TMP/themecfg" --theme nord --list >/dev/null 2>&1; printf '%s' "$?")"
eq "--theme without a name is an error" 1 "$("$SC_ROOT/scat" --config-dir "$TMP/themecfg" --theme >/dev/null 2>&1; printf '%s' "$?")"

# Every theme draws the list and the detail view at 80x24 without overflow.
sc_metrics_load web2 "$TMP/res.full"
for t in "${SC_THEMES[@]}"; do
    f=$(
        sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }
        TERM=xterm-256color; unset NO_COLOR
        SC_SET[theme]=$t SC_SET[ascii]=0; sc_glyphs_init; sc_ui_colors
        SC_ROWS=24 SC_COLS=80 SC_DET_SCROLL=0
        sc_list_build; sc_draw_servers 0 0; sc_draw_detail web2
    )
    plain=$(sed $'s/\e\\[[0-9;]*[mK]//g' <<<"$f")
    eq "$t: list + detail are 2 x 24 rows" 48 "$(wc -l <<<"$plain" | tr -d ' ')"
    eq "$t: no row wider than 80 columns" 0 "$(while IFS= read -r l; do ((${#l} > 80)) && echo x; done <<<"$plain" | grep -c x)"
done

hc_bar() { # ascii rx tx -> split bar without colors, high-contrast theme
    (
        SC_SET[theme]=high-contrast SC_SET[ascii]=$1; sc_glyphs_init
        sc_netif_bar "$2" "$3" 21
        sed $'s/\e\\[[0-9;]*m//g' <<<"$REPLY"
    )
}
eq "high-contrast: rx solid, tx hatched, empty cells dotted" "█████····· ▒▒▒▒▒·····" "$(hc_bar 0 50000000 50000000)"
eq "high-contrast ascii: rx '#', tx '='" "#####..... =====....." "$(hc_bar 1 50000000 50000000)"
eq "other themes: tx bar not hatched" "█████░░░░░ █████░░░░░" "$(SC_SET[theme]=nord SC_SET[ascii]=0; sc_glyphs_init; sc_netif_bar 50000000 50000000 21; sed $'s/\e\\[[0-9;]*m//g' <<<"$REPLY")"
SC_SET[theme]=default SC_SET[ascii]=0; sc_glyphs_init

section "formatting"
sc_fmt_mbs 523000; eq "MB/s two decimals" "0.52 MB/s" "$REPLY"
sc_fmt_mbs 0; eq "MB/s zero" "0.00 MB/s" "$REPLY"
sc_fmt_mbs 5000; eq "MB/s rounds half up" "0.01 MB/s" "$REPLY"
sc_fmt_mbs 4999; eq "MB/s rounds down" "0.00 MB/s" "$REPLY"
sc_fmt_mbs 12345678; eq "MB/s is decimal (1e6), not MiB" "12.35 MB/s" "$REPLY"
sc_fmt_mbs 125000000; eq "MB/s for 1 Gbit/s" "125.00 MB/s" "$REPLY"
sc_fmt_mbs abc; eq "MB/s invalid" "-" "$REPLY"
sc_fmt_duration 93784; eq "duration days" "1d 2h" "$REPLY"
sc_fmt_duration 3700; eq "duration hours" "1h 1m" "$REPLY"
sc_fmt_duration 42; eq "duration seconds" "42s" "$REPLY"
sc_fmt_kib 512; eq "kib" "512K" "$REPLY"
sc_fmt_kib 1536; eq "mib" "1.5M" "$REPLY"
sc_fmt_kib 8000000; eq "gib" "7.6G" "$REPLY"
sc_fmt_bytes 100; eq "bytes" "100B" "$REPLY"
sc_pct 2000000 8000000; eq "percent" 25 "$REPLY"
refute "percent of zero" sc_pct 1 0
SC_G_ELL='…'
sc_fit "äöü-umlaut" 5; eq "fit truncates by characters" "äöü-…" "$REPLY"
sc_fit "ab" 4; eq "fit pads" "ab  " "$REPLY"
sc_fit_right "ab" 4; eq "fit right" "  ab" "$REPLY"

# ------------------------------------------------------------------------------
section "timeout runner"
start=$SECONDS
sc_run_timeout 1 /dev/null sleep 5
rc=$?
eq "kills after timeout (rc 124)" 124 "$rc"
assert "returns promptly" test $((SECONDS - start)) -le 3
sc_run_timeout 5 /dev/null sh -c 'exit 3'
eq "passes exit status through" 3 "$?"
echo hello >"$TMP/in"
eq "feeds stdin from file" hello "$(sc_run_timeout 5 "$TMP/in" cat)"

section "remote collector (run locally with sh on $(uname -s))"
sh "$SC_ROOT/lib/remote/metrics.sh" >"$TMP/local.out" 2>"$TMP/local.err"
eq "exit status" 0 "$?"
for key in os hostname kernel uptime load cores cpu_busy mem_total mem_used disk proc; do
    if grep -q "^$key=" "$TMP/local.out"; then ok "emits $key"; else nok "emits $key"; fi
done
eq "no stderr output" "" "$(cat "$TMP/local.err")"
if [[ $(uname -s) == Darwin ]]; then
    eq "only en* interfaces on macOS" "" "$(grep '^netif=' "$TMP/local.out" | grep -v '^netif=en[0-9]*|')"
fi
assert "emits netif or net_note" grep -Eq '^(netif|net_note)=' "$TMP/local.out"

section "physical interface filter (Linux collector functions, fake /proc and /sys)"
mkdir -p "$TMP/sys"
cat >"$TMP/netdev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 9000 10 0 0 0 0 0 0 9000 10 0 0 0 0 0 0
  eth0: 1000000 10 0 0 0 0 0 0 200000 10 0 0 0 0 0 0
 wlan0: 50 1 0 0 0 0 0 0 60 1 0 0 0 0 0 0
enp3s0: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
docker0: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
br-1a2b3c: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
veth12ab: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
  tun0: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
   wg0: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
 virbr0: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
  usb0: 7 0 0 0 0 0 0 0 7 0 0 0 0 0 0 0
EOF
for i in lo eth0 wlan0 enp3s0 docker0 br-1a2b3c veth12ab tun0 wg0 virbr0 usb0; do mkdir -p "$TMP/sys/$i"; done
for i in eth0 wlan0 enp3s0 usb0 veth12ab; do ln -s /dev/null "$TMP/sys/$i/device"; done
collector() { # function-name args... (runs the POSIX sh functions with the test files)
    SCAT_METRICS_LIB=1 sh -c '. "$1"; NET_DEV=$2 SYS_NET=$3; shift 3; "$@"' sh \
        "$SC_ROOT/lib/remote/metrics.sh" "$TMP/netdev" "$NET_SYS" "$@"
}
NET_SYS=$TMP/sys
eq "sysfs: NICs with a device link, virtual names excluded" "eth0 wlan0 enp3s0 usb0 " "$(collector linux_phys_ifaces)"
NET_SYS=$TMP/no-sysfs
eq "no sysfs: NIC name patterns" "eth0 wlan0 enp3s0 " "$(collector linux_phys_ifaces)"
eq "sample only selected interfaces" $'eth0 1000000 200000\nwlan0 50 60' "$(collector linux_net_sample "eth0 wlan0 ")"
eq "rates over 1 s" $'netif=eth0|523000|12000\nnetif=wlan0|0|0' \
    "$(collector print_netifs $'eth0 1000 500\nwlan0 5 5' $'eth0 524000 12500\nwlan0 5 5' 1)"
eq "rates over 2 s, counter reset clamps to 0" $'netif=eth0|500|0' \
    "$(collector print_netifs 'eth0 1000 900' 'eth0 2000 100' 2)"
eq "no interfaces gives a note" "net_note=no physical network interface found" "$(collector print_netifs '' '' 1)"

section "FreeBSD / OPNsense collector (simulated: fake uname, sysctl, netstat, swapinfo, zfs, df, ps)"
# Whole collector run with FreeBSD commands replaced by shell functions that
# print recorded-style output. "sleep" switches the fakes to the second sample.
F=$TMP/fbsd
mkdir -p "$F"
cat >"$F/netstat.1" <<'EOF'
Name      Mtu Network            Address                   Ipkts Ierrs Idrop     Ibytes    Opkts Oerrs     Obytes  Coll
vtnet0   1500 <Link#1>           52:54:00:aa:bb:01        100000     0     0   50000000    80000     0   20000000     0
vtnet0      - 192.168.1.0/24     192.168.1.1                5000     -     -     400000     4000     -     300000     -
em0      1500 <Link#2>           00:1b:21:aa:bb:02            10     0     0       1000       10     0       1000     0
lo0     16384 <Link#3>           lo0                         320     0     0      25600      320     0      25600     0
lo0         - ::1/128            ::1                           0     -     -          0        0     -          0     -
pflog0  33152 <Link#4>                                         0     0     0          0     1234     0     456789     0
pfsync0  1500 <Link#5>                                         0     0     0          0        0     0          0     0
enc0     1536 <Link#6>                                         0     0     0          0        0     0          0     0
bridge0  1500 <Link#7>           58:9c:fc:10:ff:01          7777     0     0     777777     7777     0     777777     0
wg0      1420 <Link#8>                                         5     0     0        500        5     0        500     0
vlan01   1500 <Link#9>           52:54:00:aa:bb:01           100     0     0      10000      100     0      10000     0
ovpns1   1500 <Link#10>                                        1     0     0        100        1     0        100     0
igb0.10  1500 <Link#11>          00:1b:21:aa:bb:03           100     0     0      10000      100     0      10000     0
EOF
sed -e 's/   50000000 /   62500000 /' -e 's/   20000000 /   20250000 /' -e 's/      1000       10     0       1000 /      3000       10     0       1500 /' \
    -e 's/     777777     7777     0     777777 /    9777777     7777     0    9777777 /' "$F/netstat.1" >"$F/netstat.2"
printf '1000 0 500 100 8400\n' >"$F/cp_time.1"
printf '1200 0 600 100 8500\n' >"$F/cp_time.2"
cat >"$F/swapinfo" <<'EOF'
Device          1K-blocks     Used    Avail Capacity
/dev/gpt/swapfs   2097152    10240  2086912     0%
EOF
printf 'zroot\t5368709120\t96636764160\n' >"$F/zfs"
cat >"$F/df" <<'EOF'
Filesystem         1024-blocks    Used    Avail Capacity  Mounted on
zroot/ROOT/default    96500000 2128160 94371840     3%    /
devfs                        1       1        0   100%    /dev
zroot/var/log         94400000   28160 94371840     1%    /var/log
zroot/tmp             94372000     160 94371840     1%    /tmp
zroot                 94371936      96 94371840     1%    /zroot
devfs                        1       1        0   100%    /var/dhcpd/dev
devfs                        1       1        0   100%    /var/unbound/dev
fdescfs                      1       1        0   100%    /dev/fd
procfs                       8       8        0   100%    /proc
/dev/gpt/efiboot0       266176    1872   264304     1%    /boot/efi
tmpfs                  2097152    1200  2095952     1%    /var/run
/usr/local/lib/python3.13 96500000 2128160 94371840  3%    /var/unbound/usr/local/lib/python3.13
/lib                  96500000 2128160 94371840     3%    /var/unbound/lib
EOF
cat >"$F/ps" <<'EOF'
    0 root      0.0  0.0     0 kernel
   11 root    398.5  0.0    64 idle
    1 root      0.0  0.0  1200 init
  123 www       3.2  0.4 30000 php-cgi
  456 unbound   1.0  0.5 40000 unbound
EOF
cat >"$F/fake.sh" <<'EOF'
echo 1 >"$F/phase"
uname() { case $1 in -s) echo FreeBSD ;; -r) echo 15.1-RELEASE-p4 ;; -sr) echo FreeBSD 15.1-RELEASE-p4 ;; *) echo FreeBSD ;; esac; }
hostname() { echo opnsense.test; }
date() { echo 1760090000; }
sleep() { echo 2 >"$F/phase"; }
sysctl() {
    case $2 in
    kern.cp_time) cat "$F/cp_time.$(cat "$F/phase")" ;;
    kern.boottime) echo '{ sec = 1760000000, usec = 123456 } Thu Oct  9 08:53:20 2025' ;;
    vm.loadavg) echo '{ 0.12 0.20 0.25 }' ;;
    hw.ncpu) echo 4 ;;
    hw.pagesize) echo 4096 ;;
    hw.physmem) echo 8589934592 ;;
    vm.stats.vm.v_free_count) echo 1048576 ;;
    vm.stats.vm.v_inactive_count) echo 262144 ;;
    dev.vtnet.0.%driver) echo vtnet ;;
    dev.em.0.%driver) echo em ;;
    dev.igb.0.%driver) echo igb ;;
    *) echo "sysctl: unknown oid '$2'" >&2; return 1 ;;
    esac
}
netstat() { cat "$F/netstat.$(cat "$F/phase")"; }
swapinfo() { cat "$F/swapinfo"; }
zfs() { cat "$F/zfs"; }
df() { cat "$F/df"; }
ps() { case "$*" in *user=*) cat "$F/ps" ;; *) awk '{ print $1 }' "$F/ps" ;; esac; }
EOF
fbsd_run() { # shell
    "$1" -c 'F=$1; . "$F/fake.sh"; . "$2"' sh "$F" "$SC_ROOT/lib/remote/metrics.sh"
}
for shell in sh dash; do
    command -v "$shell" >/dev/null || continue
    fbsd_run "$shell" >"$F/out.$shell" 2>"$F/err.$shell"
    eq "$shell: exit status" 0 "$?"
    eq "$shell: no stderr output" "" "$(cat "$F/err.$shell")"
done
out=$(cat "$F/out.sh")
eq "same output from dash" "$out" "$(cat "$F/out.dash" 2>/dev/null || cat "$F/out.sh")"
eq "system lines" $'os=FreeBSD\nhostname=opnsense.test\nkernel=15.1-RELEASE-p4\ndistro=FreeBSD 15.1-RELEASE-p4\nuptime=90000\nload=0.12 0.20 0.25\ncores=4' \
    "$(sed -n 1,7p <<<"$out")"
eq "cpu from kern.cp_time over 1 s" $'cpu_busy=75.0\ncpu_user=50.0\ncpu_sys=25.0' "$(grep '^cpu_' <<<"$out")"
eq "network: only NICs with a dev.<driver>.<unit> node" $'netif=vtnet0|12500000|250000\nnetif=em0|2000|500' "$(grep '^netif=' <<<"$out")"
eq "no net_note when NICs are found" "" "$(grep '^net_note=' <<<"$out")"
eq "memory: free + inactive pages are available" $'mem_total=8388608\nmem_used=3145728' "$(grep '^mem_' <<<"$out")"
eq "swap from swapinfo -k" $'swap_total=2097152\nswap_used=10240' "$(grep '^swap_' <<<"$out")"
eq "disks: one line per ZFS pool, devfs/fdescfs/procfs/tmpfs and nullfs of the root dataset skipped" \
    $'disk=zroot (zfs)|99614720|5242880|6\ndisk=/boot/efi|266176|1872|1' "$(grep '^disk=' <<<"$out")"
eq "process count includes all processes" "proc_count=5" "$(grep '^proc_count=' <<<"$out")"
eq "idle process left out, busiest first" $'proc=123|www|3.2|0.4|30000|php-cgi\nproc=456|unbound|1.0|0.5|40000|unbound' \
    "$(grep '^proc=' <<<"$out" | head -n 2)"
eq "idle process not listed" "" "$(grep '|idle$' <<<"$out")"

fb() { # function args... (collector functions with the FreeBSD fakes)
    SCAT_METRICS_LIB=1 sh -c 'F=$1; shift; . "$F/fake.sh"; . "$1"; shift; "$@"' sh "$F" "$SC_ROOT/lib/remote/metrics.sh" "$@"
}
eq "physical interfaces" "vtnet0 em0 wlan0 " "$(fb bsd_phys_ifaces "vtnet0 em0 lo0 pflog0 pfsync0 enc0 bridge0 wg0 vlan01 ovpns1 ovpnc2 lagg0 tun0 tap1 gif0 gre0 vxlan0 epair0a igb0.10 igb1 wlan0")"
eq "link counters from the header columns" $'vtnet0 50000000 20000000\nem0 1000 1000\nlo0 25600 25600\npflog0 0 456789' \
    "$(fb netstat_link_counters <"$F/netstat.1" | head -n 4)"
eq "cp_time with 6 fields (OpenBSD) is ignored" "" "$(fb bsd_cpu_print '1 2 3 4 5 6' '2 3 4 5 6 7')"
printf 'Device          1K-blocks     Used    Avail Capacity\n/dev/ada0p3       1048576     1024  1047552     0%%\n/dev/ada1p3       1048576     2048  1046528     0%%\nTotal             2097152     3072  2094080     0%%\n' >"$F/swapinfo"
eq "swap: two devices summed, Total row ignored" $'swap_total=2097152\nswap_used=3072' "$(fb bsd_swap)"
printf 'Device          1K-blocks     Used    Avail Capacity\n' >"$F/swapinfo"
eq "swap: no device means no swap" $'swap_total=0\nswap_used=0' "$(fb bsd_swap)"
eq "UFS root without ZFS pools" "disk=/|20000000|3000000|17" \
    "$(printf 'Filesystem 1024-blocks Used Avail Capacity Mounted on\n/dev/gpt/rootfs 20000000 3000000 15400000 17%% /\ndevfs 1 1 0 100%% /dev\n' | fb print_disks '')"
eq "Linux df unchanged without pools" "disk=/srv/nfs|100|50|50" \
    "$(printf 'Filesystem 1024-blocks Used Avail Capacity Mounted on\nnas:/export 100 50 50 50%% /srv/nfs\n' | fb print_disks '')"
eq "same source mounted twice: only the first mount" $'disk=/var/unbound/usr/local/lib|94371840|1000|1\ndisk=/boot/efi|266176|1872|1' \
    "$(printf 'Filesystem 1024-blocks Used Avail Capacity Mounted on\n/usr/local/lib 94371840 1000 94370840 1%% /var/unbound/usr/local/lib\n/usr/local/lib 94371840 1000 94370840 1%% /var/unbound/usr/local/lib/python3.13\n/dev/gpt/efiboot0 266176 1872 264304 1%% /boot/efi\n' | fb print_disks '')"
df_head='Filesystem 1024-blocks Used Avail Capacity Mounted on'
eq "OPNsense nullfs (real df lines): first mount stays, same numbers dropped" "disk=/var/unbound/usr/local/lib/python3.13|457982620|4906812|1" \
    "$(printf '%s\n' "$df_head" \
        'devfs                               1       0         1     0%    /var/unbound/dev' \
        '/usr/local/lib/python3.13   457982620 4906812 453075808     1%    /var/unbound/usr/local/lib/python3.13' \
        '/lib                        457982620 4906812 453075808     1%    /var/unbound/lib' | fb print_disks '')"
eq "different numbers with a path source stay" 2 \
    "$(printf '%s\n' "$df_head" '/data/a 1000 10 990 1% /mnt/a' '/data/b 1000 20 980 2% /mnt/b' | fb print_disks '' | grep -c '^disk=')"
eq "Linux bind mount (same device, same numbers): first mount only" "disk=/|41000000|21000000|52" \
    "$(printf '%s\n' "$df_head" '/dev/sda1 41000000 21000000 18000000 52% /' '/dev/sda1 41000000 21000000 18000000 52% /srv/www' | fb print_disks '')"
eq "two devices with equal numbers (empty disks of one size) both stay" $'disk=/mnt/d1|960000000|28|1\ndisk=/mnt/d2|960000000|28|1' \
    "$(printf '%s\n' "$df_head" '/dev/sdb1 960000000 28 959999972 1% /mnt/d1' '/dev/sdc1 960000000 28 959999972 1% /mnt/d2' | fb print_disks '')"
eq "known limit: two shares of one NAS filesystem with equal numbers are merged" 1 \
    "$(printf '%s\n' "$df_head" 'nas:/export/a 5000 100 4900 2% /mnt/a' 'nas:/export/b 5000 100 4900 2% /mnt/b' | fb print_disks '' | grep -c '^disk=')"
eq "sources with spaces are compared in full" 2 \
    "$(printf 'Filesystem 1024-blocks Used Avail Capacity Mounted on\n//u@nas/My Share 100 50 50 50%% /mnt/a\n//u@nas/My Docs 200 60 140 30%% /mnt/b\n' | fb print_disks '' | grep -c '^disk=')"
eq "idle is only skipped on FreeBSD" "proc=11|root|98.0|0.0|64|idle" "$(echo '11 root 98.0 0.0 64 idle' | fb print_procs Linux)"

{ printf 'rc=0\nts=1760090000\n'; cat "$F/out.sh"; } >"$F/res"
sc_metrics_load opn "$F/res"
SC_SRV[opn|host]=opnsense.test
summary=$(sc_print_summary opn)
eq "--check: CPU" "  CPU       75.0%" "$(grep '^  CPU' <<<"$summary")"
eq "--check: ZFS pool as one disk" "  Disk      5.0G / 95.0G (6%) zroot (zfs)" "$(grep -m1 '^  Disk' <<<"$summary")"
eq "--check: vtnet0 rx 12.50, tx 0.25 MB/s" 1 "$(grep -c '^  Network   vtnet0 .*  rx  12.50  tx   0.25 MB/s$' <<<"$summary")"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=100; sc_draw_detail opn)
eq "detail: order on FreeBSD" ordered "$(order_of <<<"$detail")"
eq "detail: two interfaces, one row each" 2 "$(net_rows <<<"$detail" | grep -c .)"

# ------------------------------------------------------------------------------
section "ping column"
pp() { sc_ping_parse "$@"; printf '%s' "$REPLY"; }
eq "below 1 ms (macOS output)" "<1 ms" "$(pp 0 '64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.054 ms' '')"
eq "rounded to whole ms" "12 ms" "$(pp 0 '64 bytes from 192.0.2.1: icmp_seq=1 ttl=63 time=12.345 ms' '')"
eq "rounds half up" "13 ms" "$(pp 0 'time=12.5 ms' '')"
eq "0.5 ms shows as 1 ms" "1 ms" "$(pp 0 'time=0.5 ms' '')"
eq "Linux output" "24 ms" "$(pp 0 '64 bytes from 192.0.2.1 (192.0.2.1): icmp_seq=1 ttl=57 time=23.9 ms' '')"
eq "whole ms without decimals" "7 ms" "$(pp 0 'time=7 ms' '')"
eq "statistics line alone is no reply" "-" "$(pp 2 'round-trip min/avg/max/stddev = 1.0/1.0/1.0/0.0 ms' '')"
eq "no reply" "-" "$(pp 2 '1 packets transmitted, 0 packets received, 100.0% packet loss' '')"
eq "timeout" "-" "$(pp 124 '' '')"
eq "unknown host (macOS, FreeBSD)" "!" "$(pp 68 '' 'ping: cannot resolve no-such-host.invalid: Unknown host')"
eq "unknown host (Linux)" "!" "$(pp 2 '' 'ping: no-such-host.invalid: Name or service not known')"
eq "unknown host (Linux, no DNS server)" "!" "$(pp 2 '' 'ping: x.example: Temporary failure in name resolution')"

# A fake ping/ping6 in PATH: arguments are "-c 1 -- HOST".
mkdir -p "$TMP/fakeping"
cat >"$TMP/fakeping/ping" <<'EOF'
#!/bin/sh
[ -n "${FAKEPING_ARGS-}" ] && printf '%s\n' "$*" >"$FAKEPING_ARGS"
case $4 in
    slow*) sleep 5 ;;
    nxdomain*) echo "ping: cannot resolve $4: Unknown host" >&2; exit 68 ;;
    *) echo "64 bytes from $4: icmp_seq=0 ttl=64 time=3.2 ms" ;;
esac
EOF
sed 's/time=3.2/time=6.0/' "$TMP/fakeping/ping" >"$TMP/fakeping/ping6"
chmod +x "$TMP/fakeping/ping" "$TMP/fakeping/ping6"
sc_runtime_init
ph() { (PATH=$TMP/fakeping:$PATH; sc_ping_host "$1"; printf '%s' "$REPLY"); }
eq "reply from the host" "3 ms" "$(ph 192.0.2.5)"
eq "one packet, host after --" "-c 1 -- 192.0.2.5" "$(export FAKEPING_ARGS=$TMP/pingargs; ph 192.0.2.5 >/dev/null; cat "$TMP/pingargs")"
eq "IPv6 address uses ping6" "6 ms" "$(ph 2001:db8::1)"
eq "unknown host" "!" "$(ph nxdomain.invalid)"
start=$SECONDS
eq "no reply within the hard limit" "-" "$(ph slow.example)"
assert "hard limit of ${SC_PING_TIMEOUT}s respected (<= 4s)" test $((SECONDS - start)) -le 4
eq "a host starting with '-' never reaches ping" "!" "$(ph -f)"
eq "empty host" "!" "$(ph '')"

SC_SERVERS=() SC_SRV=() SC_M=() SC_PING=()
sc_server_upsert "" p1 192.0.2.5 "" "" "" "" "" >/dev/null
sc_server_upsert "" p2 10.0.0.5 "" "" "" p1 "" >/dev/null
sc_server_upsert "" p3 nxdomain.invalid "" "" "" "" "" >/dev/null
sc_server_upsert "" p4 192.0.2.6 "" "" "" "" "" >/dev/null
PATH=$TMP/fakeping:$PATH sc_ping_async p1
PATH=$TMP/fakeping:$PATH sc_ping_async p2
PATH=$TMP/fakeping:$PATH sc_ping_async p3
eq "behind a jump host: not pinged" jump "${SC_PING[p2]-}"
eq "behind a jump host: no background process" "" "${SC_PING_PID[p2]-}"
for _ in {1..40}; do
    sc_poll_results
    [[ -n ${SC_PING[p1]-} && -n ${SC_PING[p3]-} ]] && break
    sleep 0.1
done
eq "background result picked up" "3 ms" "${SC_PING[p1]-}"
eq "background unknown host" "!" "${SC_PING[p3]-}"
eq "no ping files left behind" 0 "$(ls -A "$SC_RUNTIME_DIR" | grep -c ping)"
printf '5 ms\n' >"$SC_RUNTIME_DIR/gone.ping"
sc_poll_results
eq "result of a deleted server is dropped" "|0" "${SC_PING[gone]-}|$(ls -A "$SC_RUNTIME_DIR" | grep -c ping)"
sc_runtime_cleanup

sc_list_build
pingcol() { cut -c 21-27 <<<"$1" | sed -n "$2"p; } # frame row -> PING cell
frame=$(list_frame 24 80 0 0)
eq "header: PING right-aligned after NAME" "   NAME                PING   CPU   MEM   LOAD   UPTIME STATUS" "$(sed -n 2p <<<"$frame" | sed 's/ *$//')"
eq "cell: reply time" "   3 ms" "$(pingcol "$frame" 3)"
eq "cell: behind a jump host" "   jump" "$(pingcol "$frame" 4)"
eq "cell: unknown host" "      !" "$(pingcol "$frame" 5)"
eq "cell: not measured yet" "      …" "$(pingcol "$frame" 6)"
eq "80 columns with PING: no row wider than 80" 0 "$(while IFS= read -r l; do ((${#l} > 80)) && echo x; done <<<"$frame" | grep -c x)"
eq "unknown host is shown in the error color" 1 "$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=24 SC_COLS=80; sc_draw_servers 0 0 | grep -cF "$C_CRIT      !")"
eq "TARGET column from 96 columns on (95: none)" "1 0" "$(list_frame 24 96 0 0 | sed -n 2p | grep -c TARGET) $(list_frame 24 95 0 0 | sed -n 2p | grep -c TARGET)"
frame=$(SC_SET[ping]=0; list_frame 24 80 0 0)
eq "ping = 0: no PING column" "   NAME               CPU   MEM   LOAD   UPTIME STATUS" "$(sed -n 2p <<<"$frame" | sed 's/ *$//')"

eq "ping defaults to 1" 1 "${SC_SET[ping]}"
printf '[settings]\nping = 0\ngroup_headings = 0\n' >"$TMP/ping.conf"
eq "ping and group_headings are read" "0 0" \
    "$(SC_SETTINGS_FILE=$TMP/ping.conf; SC_CONFIG_WARNINGS=(); sc_config_load_settings; printf '%s %s' "${SC_SET[ping]}" "${SC_SET[group_headings]}")"
printf '[settings]\nping = 2\ngroup_headings = yes\n' >"$TMP/ping.conf"
eq "invalid values: warnings, defaults kept" "1 1|settings.conf:2: ping must be a whole number between 0 and 1|settings.conf:3: group_headings must be a whole number between 0 and 1" \
    "$(SC_SETTINGS_FILE=$TMP/ping.conf; SC_CONFIG_WARNINGS=(); sc_config_load_settings; printf '%s %s|%s|%s' "${SC_SET[ping]}" "${SC_SET[group_headings]}" "${SC_CONFIG_WARNINGS[@]}")"
eq "settings.conf template documents both" 2 "$(sc_config_emit_default_settings | grep -cE '^# (ping|group_headings) = 1$')"

# ------------------------------------------------------------------------------
section "version consistency (scat, website, installer)"
site=$SC_ROOT/docs/index.html
eq "scat --version is SC_VERSION" "scat $SC_VERSION" "$("$SC_ROOT/scat" --version)"
eq "website hero names SC_VERSION" 1 "$(grep -c "<p class=\"tag\">scat $SC_VERSION " "$site")"
eq "website release link is v$SC_VERSION" 1 "$(grep -c "releases/tag/v$SC_VERSION\"" "$site")"
eq "website install note names SC_VERSION" 1 "$(grep -c "This installs scat $SC_VERSION " "$site")"
eq "website footer names SC_VERSION" 1 "$(grep -c "<p>scat $SC_VERSION · " "$site")"
eq "website: no other version anywhere" "$SC_VERSION" \
    "$(grep -oE '(scat |tag/v)[0-9]+\.[0-9]+\.[0-9]+' "$site" | sed -E 's/^(scat |tag\/v)//' | sort -u | tr '\n' ' ' | sed 's/ $//')"
eq "website: hero and install note share one date" 1 \
    "$(grep -E 'class="(tag|install-note)"' "$site" | grep -oE 'datetime="[0-9-]+"' | sort -u | grep -c .)"
# install.sh pins VERSION and the archive's SHA256. During release prep it
# lags behind on purpose (the archive does not exist yet), so a mismatch is
# only a note; SC_TEST_RELEASE=1 makes it a failure (run that after the
# release, before pushing the website).
inst=$(sed -nE 's/^VERSION=([0-9.]+)$/\1/p' "$SC_ROOT/install.sh")
if [[ $inst == "$SC_VERSION" || ${SC_TEST_RELEASE:-0} == 1 ]]; then
    eq "install.sh VERSION is SC_VERSION" "$SC_VERSION" "$inst"
else
    printf '  note  install.sh still installs %s, scat is %s: update VERSION and\n' "$inst" "$SC_VERSION"
    printf '        SHA256 after the release (check with SC_TEST_RELEASE=1)\n'
fi
eq "install.sh pins a SHA-256" 1 "$(grep -cE '^SHA256=[0-9a-f]{64}$' "$SC_ROOT/install.sh")"

# ------------------------------------------------------------------------------
if [[ ${SC_TEST_NETWORK:-1} == 1 ]]; then
    section "graceful failure against unreachable hosts (real ssh)"
    sc_runtime_init
    SC_SET[connect_timeout]=2 SC_SET[command_timeout]=10 SC_SET[multiplex]=1
    sc_server_upsert "" blackhole 192.0.2.1 "" "" "" "" "" >/dev/null
    sc_server_upsert "" nxdomain no-such-host.invalid "" "" "" "" "" >/dev/null
    start=$SECONDS
    sc_fetch_metrics blackhole "$SC_RUNTIME_DIR/blackhole.res"
    sc_metrics_load blackhole "$SC_RUNTIME_DIR/blackhole.res"
    refute "TEST-NET host reported offline" sc_metrics_online blackhole
    printf '        message: %s (%ss)\n' "${SC_M[blackhole|err]}" $((SECONDS - start))
    assert "respects timeouts (<= 12s)" test $((SECONDS - start)) -le 12
    sc_fetch_metrics nxdomain "$SC_RUNTIME_DIR/nxdomain.res"
    sc_metrics_load nxdomain "$SC_RUNTIME_DIR/nxdomain.res"
    eq "unresolvable host message" "cannot resolve hostname" "${SC_M[nxdomain|err]}"
    sc_fetch_async nxdomain
    for _ in {1..50}; do sc_poll_results && break; sleep 0.2; done
    eq "async fetch delivers result" "cannot resolve hostname" "${SC_M[nxdomain|err]-}"
    sc_runtime_cleanup
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
