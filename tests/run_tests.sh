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
net_rx=12345
disk=/|41000000|21000000|52
disk=/data|100000000|10000000|10
proc=1|root|0.0|0.1|1200|systemd
proc=900|www-data|25.5|3.2|250000|nginx: worker process
bogus=ignored
EOF
printf 'hostname=\e]0;pwned\a-x\n' >>"$TMP/res"
sc_metrics_load web2 "$TMP/res"
assert "online" sc_metrics_online web2
eq "cpu" 31.2 "${SC_M[web2|cpu_busy]}"
eq "two disks" 2 "$(grep -c . <<<"${SC_M[web2|disks]}")"
eq "process with spaces kept" "900|www-data|25.5|3.2|250000|nginx: worker process" "$(sed -n 2p <<<"${SC_M[web2|procs]}")"
eq "unknown key ignored" "" "${SC_M[web2|bogus]-}"
eq "control chars stripped" "]0;pwned-x" "${SC_M[web2|hostname]}"
sc_sort_procs web2 cpu
eq "sort by cpu" 900 "${SC_PROC_ROWS[0]%%|*}"
sc_sort_procs web2 pid
eq "sort by pid" 1 "${SC_PROC_ROWS[0]%%|*}"
printf 'rc=255\nts=1\nerr=connection refused\n' >"$TMP/res"
sc_metrics_load web2 "$TMP/res"
refute "offline after error" sc_metrics_online web2
eq "old metrics cleared" "" "${SC_M[web2|cpu_busy]-}"

section "formatting"
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
