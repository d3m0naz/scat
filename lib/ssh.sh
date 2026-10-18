# shellcheck shell=bash
# SSH layer: command construction, remote script execution with hard
# timeouts, background metric collection and parsing of its output.
#
# Every non-interactive call uses BatchMode=yes, so ssh never prompts for a
# password or passphrase; authentication must come from keys or ssh-agent.
# Modules should run remote commands through sc_ssh_run_script.

SC_REMOTE_METRICS=${SC_ROOT:-.}/lib/remote/metrics.sh
SC_RUNTIME_DIR=

declare -ga SC_SSH_OPTS=() SC_SSH_CMD=()
declare -gA SC_FETCH_PID=() # server name -> pid of the running background fetch
declare -gA SC_M=()         # "<name>|<metric>" -> value

# A short path under /tmp keeps ControlPath sockets below the 104-byte limit
# that $TMPDIR on macOS would exceed. The PID in the name lets later runs
# remove directories left behind by an instance that was SIGKILLed.
sc_runtime_init() {
    local d pid
    for d in /tmp/servercat."$UID".*.*; do
        [[ -d $d && -O $d ]] || continue
        pid=${d#/tmp/servercat."$UID".}
        pid=${pid%%.*}
        [[ $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null && rm -rf -- "$d"
    done
    SC_RUNTIME_DIR=$(mktemp -d "/tmp/servercat.$UID.$$.XXXXXX") || return 1
    chmod 700 "$SC_RUNTIME_DIR"
}

sc_runtime_cleanup() {
    local pid
    [[ -n $SC_RUNTIME_DIR && -d $SC_RUNTIME_DIR ]] || return 0
    for pid in "${SC_FETCH_PID[@]}"; do
        pkill -TERM -P "$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
    done
    sc_ssh_close_masters
    rm -rf -- "$SC_RUNTIME_DIR"
    SC_RUNTIME_DIR=
}

# Builds SC_SSH_OPTS and SC_SSH_CMD (ssh argv up to and including the host).
# Args: mode (batch|interactive) host port user identity jump
sc_ssh_build() {
    local mode=$1 host=$2 port=$3 user=$4 identity=$5 jump=$6
    sc_valid_host "$host" && sc_valid_port "$port" && sc_valid_user "$user" &&
        sc_valid_identity_syntax "$identity" && sc_valid_jump "$jump" || return 1
    SC_SSH_OPTS=(-o "ConnectTimeout=${SC_SET[connect_timeout]}"
        -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
    if [[ $mode == batch ]]; then
        SC_SSH_OPTS+=(-T -o BatchMode=yes)
        if [[ ${SC_SET[multiplex]} == 1 && -n $SC_RUNTIME_DIR ]]; then
            SC_SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=$SC_RUNTIME_DIR/cm-%C"
                -o ControlPersist=60)
        fi
    fi
    [[ -n $port ]] && SC_SSH_OPTS+=(-p "$port")
    [[ -n $user ]] && SC_SSH_OPTS+=(-l "$user")
    if [[ -n $identity ]]; then
        sc_expand_path "$identity"
        SC_SSH_OPTS+=(-i "$REPLY" -o IdentitiesOnly=yes)
    fi
    [[ -n $jump ]] && SC_SSH_OPTS+=(-J "$jump")
    SC_SSH_CMD=(ssh "${SC_SSH_OPTS[@]}" -- "$host")
}

sc_ssh_build_for() {
    local name=$1 mode=${2:-batch}
    if ! sc_server_exists "$name"; then
        SC_ERR="unknown server '$name'"
        return 1
    fi
    sc_ssh_build "$mode" "${SC_SRV[$name|host]}" "${SC_SRV[$name|port]}" \
        "${SC_SRV[$name|user]}" "${SC_SRV[$name|identity]}" "${SC_SRV[$name|jump]}"
}

sc_ssh_close_masters() {
    local name pids=()
    [[ ${SC_SET[multiplex]} == 1 ]] || return 0
    compgen -G "$SC_RUNTIME_DIR/cm-*" >/dev/null || return 0
    for name in "${SC_SERVERS[@]}"; do
        sc_ssh_build_for "$name" batch || continue
        ssh "${SC_SSH_OPTS[@]}" -O exit -- "${SC_SRV[$name|host]}" </dev/null >/dev/null 2>&1 &
        pids+=($!)
    done
    ((${#pids[@]})) && wait "${pids[@]}" 2>/dev/null
}

# Runs local script file $3 on server $1 via `sh -s`, killed after $2 seconds.
# stdout goes to $4, stderr to $5. Returns the ssh status, 124 on timeout and
# 125 if the server entry itself is invalid.
sc_ssh_run_script() {
    local name=$1 secs=$2 script=$3 out=$4 err=$5
    if ! sc_ssh_build_for "$name" batch; then
        printf '%s\n' "$SC_ERR" >"$err"
        : >"$out"
        return 125
    fi
    sc_run_timeout "$secs" "$script" "${SC_SSH_CMD[@]}" 'sh -s' >"$out" 2>"$err"
}

# Turns an ssh status and its stderr into a short message in REPLY.
sc_ssh_error_summary() {
    local rc=$1 err=$2 secs=$3 text= last
    [[ -r $err ]] && text=$(<"$err")
    sc_sanitize "${text##*$'\n'}"
    last=$REPLY
    case $rc in
        124) REPLY="timed out after ${secs}s"; return ;;
        125) REPLY=${last:-invalid server entry}; return ;;
        255) ;;
        *) REPLY="exit status $rc${last:+: $last}"; return ;;
    esac
    case $text in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
            REPLY="host key CHANGED - check ~/.ssh/known_hosts" ;;
        *"Host key verification failed"* | *"host key is known"*)
            REPLY="unknown host key - press 's' to connect once and verify it" ;;
        *"Permission denied"* | *"Too many authentication failures"*)
            REPLY="authentication failed - check key / ssh-agent (ssh-add -l)" ;;
        *"Could not resolve hostname"* | *"nodename nor servname"*)
            REPLY="cannot resolve hostname" ;;
        *"Connection refused"*) REPLY="connection refused" ;;
        *"timed out"*) REPLY="connection timed out" ;;
        *"No route to host"*) REPLY="no route to host" ;;
        *"Network is unreachable"*) REPLY="network unreachable" ;;
        *) REPLY="ssh failed${last:+: $last}" ;;
    esac
}

# --- metrics ------------------------------------------------------------------

# Collects metrics for $1 synchronously and writes a result file $2:
# rc=, ts=, optional err=, then the collector's key=value lines.
sc_fetch_metrics() {
    local name=$1 res=$2 rc msg=
    sc_ssh_run_script "$name" "${SC_SET[command_timeout]}" "$SC_REMOTE_METRICS" "$res.body" "$res.err"
    rc=$?
    if ((rc != 0)); then
        sc_ssh_error_summary "$rc" "$res.err" "${SC_SET[command_timeout]}"
        msg=$REPLY
    fi
    {
        printf 'rc=%d\n' "$rc"
        printf 'ts=%(%s)T\n' -1
        if ((rc == 0)); then
            cat -- "$res.body"
        else
            printf 'err=%s\n' "$msg"
        fi
    } >"$res.tmp" && mv -f -- "$res.tmp" "$res"
    rm -f -- "$res.body" "$res.err"
}

# Starts a background fetch unless one is already running for that server.
# Completion is signalled by a "<name>.new" marker picked up by sc_poll_results.
sc_fetch_async() {
    local name=$1 pid=${SC_FETCH_PID[$1]-}
    [[ -n $SC_RUNTIME_DIR ]] || return 1
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    (
        trap 'pkill -TERM -P "$BASHPID" 2>/dev/null; exit 143' TERM
        sc_fetch_metrics "$name" "$SC_RUNTIME_DIR/$name.res"
        : >"$SC_RUNTIME_DIR/$name.new"
    ) </dev/null >/dev/null 2>&1 &
    SC_FETCH_PID[$name]=$!
    SC_M[$name|loading]=1
}

sc_fetch_all() {
    local name
    for name in "${SC_SERVERS[@]}"; do sc_fetch_async "$name"; done
}

# Loads finished background results; returns 0 if anything changed.
sc_poll_results() {
    local f name changed=1
    for f in "$SC_RUNTIME_DIR"/*.new; do
        [[ -e $f ]] || continue
        name=${f##*/}
        name=${name%.new}
        rm -f -- "$f"
        unset "SC_FETCH_PID[$name]"
        sc_server_exists "$name" || continue
        sc_metrics_load "$name" "$SC_RUNTIME_DIR/$name.res"
        changed=0
    done
    return "$changed"
}

sc_metrics_clear() {
    local key
    for key in "${!SC_M[@]}"; do
        [[ $key == "$1|"* ]] && unset "SC_M[$key]"
    done
}

# Parses a result file. Unknown keys are ignored and all values are stripped
# of control characters.
sc_metrics_load() {
    local name=$1 file=$2 line key disks=() procs=() netifs=()
    sc_metrics_clear "$name"
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        key=${line%%=*}
        sc_sanitize "${line#*=}"
        case $key in
            disk) disks+=("$REPLY") ;;
            netif) [[ $REPLY =~ ^[A-Za-z0-9._@-]+\|[0-9]+\|[0-9]+$ ]] && netifs+=("$REPLY") ;;
            proc) procs+=("$REPLY") ;;
            rc | ts | err | os | hostname | kernel | distro | uptime | load | cores | proc_count | \
                cpu_* | mem_* | swap_* | net_*)
                SC_M[$name|$key]=$REPLY ;;
        esac
    done <"$file"
    local IFS=$'\n'
    SC_M[$name|disks]="${disks[*]}"
    SC_M[$name|netifs]="${netifs[*]}"
    SC_M[$name|procs]="${procs[*]}"
}

sc_metrics_online() {
    [[ ${SC_M[$1|rc]-} == 0 ]]
}

# --- actions ------------------------------------------------------------------

# Opens an interactive shell; BatchMode is off so ssh may ask to confirm a
# host key or for a key passphrase. Nothing typed here is stored.
sc_ssh_interactive() {
    local name=$1 rc
    sc_ssh_build_for "$name" interactive || return 1
    sc_ui_leave
    printf '\nConnecting to %s - exit the remote shell to return to ServerCat.\n\n' "$name"
    "${SC_SSH_CMD[@]}"
    rc=$?
    if ((rc != 0)); then
        printf '\nssh exited with status %d. Press any key to return to ServerCat.' "$rc"
        IFS= read -rsn1 -d '' _ </dev/tty
    fi
    sc_ui_enter
    sc_fetch_async "$name"
    return 0
}

# Quick connectivity check with explicit (possibly unsaved) values.
# Args: host port user identity jump. Sets REPLY to a message.
sc_ssh_test() {
    local err=$SC_RUNTIME_DIR/test.err rc
    if ! sc_ssh_build batch "$@"; then
        REPLY=$SC_ERR
        return 1
    fi
    sc_run_timeout $((SC_SET[connect_timeout] + 10)) /dev/null "${SC_SSH_CMD[@]}" true >/dev/null 2>"$err"
    rc=$?
    if ((rc == 0)); then
        REPLY="connection OK"
    else
        sc_ssh_error_summary "$rc" "$err" $((SC_SET[connect_timeout] + 10))
    fi
    rm -f -- "$err"
    return "$rc"
}

sc_ssh_kill() {
    local name=$1 pid=$2 script=$SC_RUNTIME_DIR/kill.sh out=$SC_RUNTIME_DIR/kill.out err=$SC_RUNTIME_DIR/kill.err rc
    if [[ ! $pid =~ ^[0-9]+$ ]] || ((pid <= 1)); then
        REPLY="invalid PID"
        return 1
    fi
    printf 'kill -TERM %d\n' "$pid" >"$script"
    sc_ssh_run_script "$name" $((SC_SET[connect_timeout] + 10)) "$script" "$out" "$err"
    rc=$?
    ((rc == 0)) || sc_ssh_error_summary "$rc" "$err" $((SC_SET[connect_timeout] + 10))
    rm -f -- "$script" "$out" "$err"
    return "$rc"
}

# Runs snippet command $2 on server $1; combined output goes to file $3.
sc_ssh_run_snippet() {
    local name=$1 cmd=$2 out=$3 script=$SC_RUNTIME_DIR/snippet.sh err=$SC_RUNTIME_DIR/snippet.err rc
    printf '%s\n' "$cmd" >"$script"
    sc_ssh_run_script "$name" "${SC_SET[snippet_timeout]}" "$script" "$out" "$err"
    rc=$?
    REPLY=
    ((rc == 0)) || sc_ssh_error_summary "$rc" "$err" "${SC_SET[snippet_timeout]}"
    if [[ -s $err ]]; then
        printf -- '--- stderr ---\n' >>"$out"
        cat -- "$err" >>"$out"
    fi
    rm -f -- "$script" "$err"
    return "$rc"
}
