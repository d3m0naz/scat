#!/usr/bin/env bash
# Tests for the non-interactive parts: config read/write, validation, ssh
# command construction, error classification, metric parsing, formatting,
# the timeout runner and the local run of the remote collector.
# Usage: tests/run_tests.sh   (set SC_TEST_NETWORK=0 to skip ssh failure tests)

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
eq "unknown server is an error" "servercat: error: unknown server 'nope' (see --list)" "$(sc_cli_check nope 2>&1)"
sc_cli_check nope 2>/dev/null; eq "unknown server exit 2" 2 "$?"
eq "help names the default config dir" 1 "$("$SC_ROOT/servercat" --config-dir "$TMP/other" --help | grep -c "instead of ${SC_CONFIG_DIR_DEFAULT/#$HOME/\~}\$")"

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
r32=$(printf '░%.0s' {1..32}) r33=$(printf '░%.0s' {1..33})
pad=$(printf '%14s' '')
eq "detail: rx row above tx row, name only on rx (100 cols: 33-cell bars)" "  eth0        rx   0.52 MB/s  ▏$r32
${pad}tx   0.01 MB/s  ▏$r32
  wlan0       rx   0.00 MB/s  $r33
${pad}tx   0.00 MB/s  $r33" "$(net_rows <<<"$detail")"
eq "detail: 2 rows per interface" 4 "$(net_rows <<<"$detail" | grep -c .)"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=60; sc_draw_detail web2)
eq "detail at 60 columns: rows 50 wide (20-cell bars)" "50 50 50 50" "$(net_rows <<<"$detail" | while IFS= read -r l; do printf '%s ' "${#l}"; done | sed 's/ $//')"
eq "detail order at 60 columns" ordered "$(order_of <<<"$detail")"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=110; sc_draw_detail web2)
eq "detail at 110 columns: rows 66 wide (36-cell bars)" "66 66 66 66" "$(net_rows <<<"$detail" | while IFS= read -r l; do printf '%s ' "${#l}"; done | sed 's/ $//')"
eq "network section height: heading + 2 per interface + blank" 6 "$(awk '/^  Network/ { on = 1 } on { n++ } on && /^ *$/ { exit } END { print n }' <<<"$detail")"
summary=$(sc_print_summary web2)
eq "--check order" ordered "$(order_of <<<"$summary")"
r9=$(printf '░%.0s' {1..9}) r10=$(printf '░%.0s' {1..10})
eq "--check: rx above tx, 10-cell bars" "  Network   eth0       rx   0.52 MB/s  ▏$r9
                       tx   0.01 MB/s  ▏$r9
  Network   wlan0      rx   0.00 MB/s  $r10
                       tx   0.00 MB/s  $r10" "$(grep -E '^  Network|^ {23}tx' <<<"$summary")"
printf 'rc=0\nts=1\nos=FreeBSD\nnet_note=per-interface rates are not collected on FreeBSD\n' >"$TMP/res3"
sc_metrics_load web2 "$TMP/res3"
eq "--check shows the limitation" "  Network   per-interface rates are not collected on FreeBSD" "$(sc_print_summary web2 | grep Network)"
detail=$(sc_ui_render() { printf '%s\n' "${SC_FRAME[@]}"; }; SC_ROWS=40 SC_COLS=100; sc_draw_detail web2)
eq "detail shows the limitation" 1 "$(grep -c '^  per-interface rates are not collected on FreeBSD' <<<"$detail")"

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
SC_DET_LW=12 SC_DET_BW=20 SC_COLS=60; sc_netif_bar_width; eq "bar width at 60 columns (capped at SC_DET_BW)" 20 "$REPLY"
SC_DET_BW=40 SC_COLS=200; sc_netif_bar_width; eq "bar width capped like other bars" 40 "$REPLY"
SC_DET_BW=40 SC_COLS=50; sc_netif_bar_width; eq "bar width fills what is left" 20 "$REPLY"
SC_DET_BW=10 SC_COLS=30; sc_netif_bar_width; eq "bar width minimum" 4 "$REPLY"
SC_COLS=80
SC_SET[ascii]=1; sc_glyphs_init
eq "ascii: no eighth cells" 0 "${#SC_G_EIGHTHS[@]}"
eq "ascii: 0 MB/s" "|..........|0" "$(bar 0 10)"
eq "ascii: 50 MB/s" "#####|.....|5" "$(bar 50000000 10)"
eq "ascii: 150 MB/s clamped" "##########||10" "$(bar 150000000 10)"
eq "ascii: 12.5 MB/s rounds to whole cells" "#|.........|1" "$(bar 12500000 10)"
eq "ascii: tiny rate still visible" "#|.........|1" "$(bar 1 10)"
sc_metrics_load web2 "$TMP/res.full"
eq "ascii: --check rows" "  Network   eth0       rx   0.52 MB/s  #.........
                       tx   0.01 MB/s  #........." "$(sc_print_summary web2 | grep -A1 'Network   eth0')"
SC_SET[ascii]=0 SC_G_FULL='█' SC_G_EMPTY='░' SC_G_EIGHTHS=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
eq "colors: rx green, tx muted red" $'\e[32m|\e[38;5;131m' "$(TERM=xterm-256color; unset NO_COLOR; sc_ui_colors; printf '%s|%s' "$C_RX" "$C_TX")"
eq "colors: 8-color tx falls back to palette red" $'\e[31m' "$(TERM=xterm; unset NO_COLOR; sc_ui_colors; printf '%s' "$C_TX")"
eq "colors: NO_COLOR disables bar colors" "|" "$(TERM=xterm-256color NO_COLOR=1; sc_ui_colors; printf '%s|%s' "$C_RX" "$C_TX")"

eq "renderer clears a row before writing it (keeps the last column)" $'\e[1;1H\e[0m\e[Kabc\e[0m' \
    "$(SC_ROWS=1 SC_FULL_REDRAW=0 SC_SCREEN=() SC_FRAME=(abc); sc_ui_render)"

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
    SERVERCAT_METRICS_LIB=1 sh -c '. "$1"; NET_DEV=$2 SYS_NET=$3; shift 3; "$@"' sh \
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
