# shellcheck shell=bash
# Docker module, read only: the containers of a server with status, health,
# CPU and memory. It appears only for servers whose collector reported
# docker=1: as a section in the detail view and as its own view under 'm'.
# Nothing here starts, stops or changes a container.
#
# lib/remote/docker.sh runs `docker ps -a` and `docker stats --no-stream`
# through sc_ssh_run_script, in the background and at most every
# MOD_DOCKER_REFRESH seconds; stats take 1-2 s on the server.
# Docker prints one JSON object per line. They are parsed here without jq;
# lines that are not JSON objects with a container name are skipped and
# counted. Every value is stripped of control characters before display.

MOD_DOCKER_REMOTE=${SC_ROOT:-.}/lib/remote/docker.sh
MOD_DOCKER_REFRESH=15
MOD_DOCKER_DETAIL_ROWS=5      # containers listed in the detail view
declare -gA MOD_DOCKER=()     # "<server>|<key>" -> value, see mod_docker_load
declare -gA MOD_DOCKER_PID=() # server -> pid of the running background query
declare -gA MOD_DOCKER_LAST=() # server -> EPOCHSECONDS of the last query start

# --- parsing ------------------------------------------------------------------

# Decodes the JSON string escapes of $1 into REPLY. \uXXXX outside printable
# ASCII becomes "?", \n, \t and the like a space.
mod_docker_unescape() {
    local s=$1 out= c hex
    while [[ $s == *\\* ]]; do
        out+=${s%%\\*}
        s=${s#*\\}
        c=${s:0:1} s=${s:1}
        case $c in
            u)
                hex=${s:0:4} s=${s:4}
                if [[ $hex =~ ^00[234567][0123456789abcdefABCDEF]$ ]]; then
                    printf -v c "\\x${hex:2}"
                    out+=$c
                else
                    out+='?'
                fi
                ;;
            b | f | n | r | t) out+=' ' ;;
            *) out+=$c ;;
        esac
    done
    REPLY=$out$s
}

# String field $2 of the JSON object $1 into REPLY, unescaped, sanitized,
# with "|" replaced (it separates the stored columns). Status 1 if missing.
# A key only counts after "{" or ",": inside a string value a quote is
# always escaped, so values cannot fake a field.
mod_docker_field() {
    local re="[{,]\"$2\":\"(([^\"\\\\]|\\\\.)*)\""
    [[ $1 =~ $re ]] || return 1
    mod_docker_unescape "${BASH_REMATCH[1]}"
    sc_sanitize "$REPLY"
    REPLY=${REPLY//|//}
}

# One `docker ps` JSON line $1 into REPLY as "id|name|image|state|status|health".
# Status 1 if it is not a JSON object with a Names field.
mod_docker_parse_ps() {
    local line=$1 id name image state status health=
    sc_trim "$line"
    line=$REPLY
    [[ $line == \{*\} ]] || return 1
    mod_docker_field "$line" Names && [[ -n $REPLY ]] || return 1
    name=$REPLY
    mod_docker_field "$line" ID && id=${REPLY:0:12} || id=
    mod_docker_field "$line" Image && image=$REPLY || image=
    mod_docker_field "$line" Status && status=$REPLY || status=
    if [[ $status =~ ^(.*)\ \((healthy|unhealthy|health:\ starting)\)(.*)$ ]]; then
        health=${BASH_REMATCH[2]#health: }
        status=${BASH_REMATCH[1]}${BASH_REMATCH[3]}
    fi
    # State is missing in old Docker versions; derive it from the status.
    if mod_docker_field "$line" State && [[ -n $REPLY ]]; then
        state=$REPLY
    else
        case $status in
            *"(Paused)"*) state=paused ;;
            Up*) state=running ;;
            Restarting*) state=restarting ;;
            Exited*) state=exited ;;
            Created*) state=created ;;
            Dead*) state=dead ;;
            *) state=unknown ;;
        esac
    fi
    REPLY="$id|$name|$image|$state|$status|$health"
}

# Percentage like "59.65%" as in the process list: one decimal, no "%"
# ("59.7"), rounded half up. Status 1 if $1 is not a percentage.
mod_docker_pct() {
    local frac t
    [[ $1 =~ ^([0-9]{1,9})(\.([0-9]*))?%$ ]] || return 1
    frac=${BASH_REMATCH[3]}00
    t=$(((10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2} + 5) / 10))
    REPLY="$((t / 10)).$((t % 10))"
}

# Docker size like "159.6MiB", "1.2GB" or "512kB" in KiB, formatted like the
# RSS column (sc_fmt_kib: "159.6M"). Status 1 if $1 is not a size.
mod_docker_size() {
    local frac f
    [[ $1 =~ ^([0-9]{1,6})(\.([0-9]*))?([KkMGT]i?B|B)$ ]] || return 1
    case ${BASH_REMATCH[4]} in
        B) f=1 ;;
        KiB) f=1024 ;;
        kB | KB) f=1000 ;;
        MiB) f=1048576 ;;
        MB) f=1000000 ;;
        GiB) f=1073741824 ;;
        GB) f=1000000000 ;;
        TiB) f=1099511627776 ;;
        TB) f=1000000000000 ;;
        *) return 1 ;;
    esac
    frac=${BASH_REMATCH[3]}000
    # Thousandths of the unit, times bytes per unit, to KiB.
    sc_fmt_kib $(((10#${BASH_REMATCH[1]} * 1000 + 10#${frac:0:3}) * f / 1000 / 1024))
}

# One `docker stats` JSON line $1 into REPLY as "key|cpu|memp|mem", key being
# the short ID (or the name without one); values in the format of the process
# list ("59.7", "4.1", "159.6M"), "-" if missing. Status 1 if not usable.
mod_docker_parse_stats() {
    local line=$1 key cpu=- memp=- mem=-
    sc_trim "$line"
    line=$REPLY
    [[ $line == \{*\} ]] || return 1
    if mod_docker_field "$line" ID && [[ -n $REPLY ]]; then
        key=${REPLY:0:12}
    elif mod_docker_field "$line" Name && [[ -n $REPLY ]]; then
        key=$REPLY
    else
        return 1
    fi
    mod_docker_field "$line" CPUPerc && mod_docker_pct "$REPLY" && cpu=$REPLY
    mod_docker_field "$line" MemPerc && mod_docker_pct "$REPLY" && memp=$REPLY
    mod_docker_field "$line" MemUsage && mod_docker_size "${REPLY%% / *}" && mem=$REPLY
    REPLY="$key|$cpu|$memp|$mem"
}

# Parses a result file $2 of server $1 into MOD_DOCKER:
#   rc ts mode err   query status (err: ssh or docker message)
#   docker           1 or 0 as reported by lib/remote/docker.sh
#   rows             "name|image|state|status|health|cpu|memp|mem" lines,
#                    running containers first, then by name; cpu, memp
#                    (memory %) and mem as in the process list, "-" if unknown
#   rows_cpu         the same rows for the detail view: running containers
#                    by CPU % (highest first, equal CPU by name), then
#                    running ones without stats by name, then the others
#                    by name
#   running total    container counts
#   bad              lines skipped because they were not valid JSON
#   stats            1 if the result included docker stats
mod_docker_load() {
    local name=$1 file=$2 line key v bad=0 running=0 rows=() by_cpu=() ps=() ps_ok=1 rank c
    local id cname image state status health
    local -A cpu=() memp=() mem=()
    for key in rc ts mode err docker rows rows_cpu running total bad stats; do
        unset "MOD_DOCKER[$name|$key]"
    done
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        key=${line%%=*} v=${line#*=}
        case $key in
            rc | ts | mode | docker)
                sc_sanitize "$v"
                MOD_DOCKER[$name|$key]=$REPLY
                ;;
            err | ps_err | stats_err)
                sc_sanitize "$v"
                [[ $key == stats_err ]] && REPLY="docker stats: ${REPLY:-failed}"
                [[ $key == ps_err ]] && REPLY=${REPLY:-docker ps failed} ps_ok=0
                MOD_DOCKER[$name|err]=${MOD_DOCKER[$name|err]:-$REPLY}
                ;;
            ps) ps+=("$v") ;;
            stats)
                MOD_DOCKER[$name|stats]=1
                # Direct assignments: the key comes from the server and must
                # not pass through read or printf -v as an array subscript.
                if mod_docker_parse_stats "$v"; then
                    id=${REPLY%%|*} v=${REPLY#*|}
                    cpu[$id]=${v%%|*} v=${v#*|}
                    memp[$id]=${v%%|*} mem[$id]=${v#*|}
                else
                    ((bad++))
                fi
                ;;
        esac
    done <"$file"
    for line in "${ps[@]}"; do
        if ! mod_docker_parse_ps "$line"; then
            ((bad++))
            continue
        fi
        IFS='|' read -r id cname image state status health <<<"$REPLY"
        key=$id
        [[ -n $key && -n ${cpu[$key]+x} ]] || key=$cname
        rank=1
        [[ $state == running ]] && rank=0 && ((running++))
        rows+=("$rank|$cname|$image|$state|$status|$health|${cpu[$key]:--}|${memp[$key]:--}|${mem[$key]:--}")
        c=${cpu[$key]:--}
        if ((rank == 0)) && [[ $c != - ]]; then rank="0|$c"; else rank="$((rank ? 2 : 1))|0"; fi
        by_cpu+=("$rank|${rows[-1]#*|}")
    done
    MOD_DOCKER[$name|bad]=$bad
    # Counts only from a complete docker ps answer.
    if [[ ${MOD_DOCKER[$name|rc]-} == 0 && ${MOD_DOCKER[$name|docker]-} == 1 ]] && ((ps_ok)); then
        MOD_DOCKER[$name|running]=$running
        MOD_DOCKER[$name|total]=${#rows[@]}
    fi
    if ((${#rows[@]})); then
        MOD_DOCKER[$name|rows]=$(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1 -k2,2f | cut -d'|' -f2-)
        MOD_DOCKER[$name|rows_cpu]=$(printf '%s\n' "${by_cpu[@]}" |
            LC_ALL=C sort -t'|' -k1,1n -k2,2nr -k3,3f | cut -d'|' -f3-)
    fi
    return 0
}

# --- background queries -------------------------------------------------------

# Runs the query for server $1 in mode $2 (ps|full) and writes result file $3.
mod_docker_fetch() {
    local name=$1 mode=$2 res=$3 rc msg=
    { printf 'MODE=%s\n' "$mode"; cat -- "$MOD_DOCKER_REMOTE"; } >"$res.sh"
    sc_ssh_run_script "$name" "${SC_SET[command_timeout]}" "$res.sh" "$res.out" "$res.err"
    rc=$?
    if ((rc != 0)); then
        sc_ssh_error_summary "$rc" "$res.err" "${SC_SET[command_timeout]}"
        msg=$REPLY
    fi
    {
        printf 'rc=%d\nts=%(%s)T\nmode=%s\n' "$rc" -1 "$mode"
        if ((rc == 0)); then
            cat -- "$res.out"
        else
            printf 'err=%s\n' "$msg"
        fi
    } >"$res.tmp" && mv -f -- "$res.tmp" "$res"
    rm -f -- "$res.sh" "$res.out" "$res.err"
}

# Starts a background query of server $1 in mode $2 (ps|full). Status 1 if
# one is still running. The result arrives as "<name>.docker".
mod_docker_async() {
    local name=$1 mode=$2 pid=${MOD_DOCKER_PID[$1]-}
    [[ -n $SC_RUNTIME_DIR && $mode =~ ^(ps|full)$ ]] || return 1
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    (
        trap 'pkill -TERM -P "$BASHPID" 2>/dev/null; exit 143' TERM
        mod_docker_fetch "$name" "$mode" "$SC_RUNTIME_DIR/$name.dk"
        mv -f -- "$SC_RUNTIME_DIR/$name.dk" "$SC_RUNTIME_DIR/$name.docker"
    ) </dev/null >/dev/null 2>&1 &
    MOD_DOCKER_PID[$name]=$!
    MOD_DOCKER_LAST[$name]=$EPOCHSECONDS
}

# Loads finished results; status 0 if anything changed.
mod_docker_poll() {
    local f name changed=1
    for f in "$SC_RUNTIME_DIR"/*.docker; do
        [[ -e $f ]] || continue
        name=${f##*/}
        name=${name%.docker}
        unset "MOD_DOCKER_PID[$name]"
        if sc_server_exists "$name"; then
            mod_docker_load "$name" "$f"
            changed=0
        fi
        rm -f -- "$f"
    done
    return "$changed"
}

mod_docker_busy() {
    [[ -n ${MOD_DOCKER_PID[$1]-} ]] && kill -0 "${MOD_DOCKER_PID[$1]}" 2>/dev/null
}

# --- module hooks -------------------------------------------------------------

mod_docker_available() {
    if [[ ${SC_M[$1|docker]-} == 1 ]] && sc_metrics_online "$1"; then
        return 0
    elif sc_metrics_online "$1"; then
        REPLY="Docker: no docker command on $1"
    else
        REPLY="Docker: $1 is not online"
    fi
    return 1
}

mod_docker_detail_tick() {
    local name=$1 changed=1
    mod_docker_poll && changed=0
    if [[ ${SC_M[$name|docker]-} == 1 ]] && sc_metrics_online "$name" &&
        ((EPOCHSECONDS - ${MOD_DOCKER_LAST[$name]:-0} >= MOD_DOCKER_REFRESH)); then
        mod_docker_async "$name" full
    fi
    return "$changed"
}

mod_docker_detail_refresh() {
    MOD_DOCKER_LAST[$1]=0
}

mod_docker_cleanup() {
    local pid
    for pid in "${MOD_DOCKER_PID[@]}"; do
        pkill -TERM -P "$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
    done
    MOD_DOCKER_PID=()
}

# "4 running / 6 total" plus notes about errors and skipped lines, in REPLY.
mod_docker_summary() {
    local name=$1
    if [[ -z ${MOD_DOCKER[$name|rc]-} ]]; then
        REPLY="loading$SC_G_ELL"
        return
    fi
    if [[ -z ${MOD_DOCKER[$name|total]-} ]]; then
        if [[ ${MOD_DOCKER[$name|docker]-} == 0 ]]; then
            REPLY="no docker command on the server"
        else
            REPLY=${MOD_DOCKER[$name|err]:-no answer}
        fi
        return
    fi
    REPLY="${MOD_DOCKER[$name|running]} running / ${MOD_DOCKER[$name|total]} total"
    ((MOD_DOCKER[$name|bad])) && REPLY+=" $SC_G_SEP ${MOD_DOCKER[$name|bad]} unreadable line(s) skipped"
}

# Colours as in the rest of the detail view: numbers plain, containers that
# are not running dimmed (whole row); health colours only its own cell:
# unhealthy red, starting yellow. Sets MOD_DOCKER_ROW_STYLE and
# MOD_DOCKER_CELL_STYLE.
mod_docker_style() { # state health
    MOD_DOCKER_ROW_STYLE= MOD_DOCKER_CELL_STYLE=
    [[ $1 == running ]] || MOD_DOCKER_ROW_STYLE=$C_DIM
    case $2 in
        unhealthy) MOD_DOCKER_CELL_STYLE=$C_CRIT ;;
        starting) MOD_DOCKER_CELL_STYLE=$C_WARN ;;
    esac
}

# Adds a row of fitted plain parts: $1 before the cell, cell $2, $3 after it;
# the row is padded to the screen width and styled with MOD_DOCKER_ROW_STYLE,
# the cell with MOD_DOCKER_CELL_STYLE.
mod_docker_frame_row() {
    local base=$MOD_DOCKER_ROW_STYLE cell=$MOD_DOCKER_CELL_STYLE
    sc_fit "$3" $((SC_COLS - ${#1} - ${#2}))
    if [[ -n $cell ]]; then
        SC_FRAME+=("$base$1$cell$2$C_NORM$base$REPLY$C_RESET")
    else
        SC_FRAME+=("$base$1$2$REPLY$C_RESET")
    fi
}

# The Docker rows of the detail view share the grid of the process rows:
# NAME is as wide as PID + USER (18), then CPU% (6), MEM% (6) and MEM (7,
# where the processes have RSS), then STATUS where COMMAND starts. From 84
# columns on the image follows in its own column (the width is fixed so it
# does not come and go when status texts change). Sets MOD_DOCKER_PRE
# (everything up to the status).
mod_docker_detail_cols() { # name cpu memp mem
    local out
    sc_fit "$1" 18; out="  $REPLY "
    sc_fit_right "$2" 6; out+="$REPLY "
    sc_fit_right "$3" 6; out+="$REPLY "
    sc_fit_right "$4" 7; out+="$REPLY "
    MOD_DOCKER_PRE=$out
}

# Count line, column header and the first MOD_DOCKER_DETAIL_ROWS containers
# in the columns of the Docker view, busiest first (rows_cpu); the rest are
# under 'm'.
mod_docker_detail_draw() {
    local name=$1 n=0 cname image state status health cpu memp mem err rest sw=0
    [[ ${SC_M[$name|docker]-} == 1 ]] && sc_metrics_online "$name" || return 1
    mod_docker_summary "$name"
    sc_detail_heading Docker "$REPLY"
    err=${MOD_DOCKER[$name|err]-}
    [[ -n ${MOD_DOCKER[$name|rows]-} && -n $err ]] && sc_frame_text "$C_WARN" "  $err"
    [[ -n ${MOD_DOCKER[$name|rows]-} ]] || return 0
    # With the image: STATUS as wide as the longest status shown (6 to 24
    # characters), then 2 spaces, so the image stays close to the status.
    if ((SC_COLS >= 84)); then
        sw=6
        while IFS='|' read -r cname image state status health _; do
            ((n++ < MOD_DOCKER_DETAIL_ROWS)) || break
            [[ -n $health ]] && status+=" ($health)"
            ((${#status} > sw)) && sw=${#status}
        done <<<"${MOD_DOCKER[$name|rows_cpu]}"
        ((sw > 24)) && sw=24
        n=0
    fi
    mod_docker_detail_cols NAME CPU% MEM% MEM
    rest=STATUS
    if ((sw)); then
        sc_fit STATUS "$sw"
        rest="$REPLY  IMAGE"
    fi
    sc_frame_text "$C_DIM" "$MOD_DOCKER_PRE$rest"
    while IFS='|' read -r cname image state status health cpu memp mem; do
        [[ -n $cname ]] || continue
        if ((n++ >= MOD_DOCKER_DETAIL_ROWS)); then
            sc_frame_text "$C_DIM" "  $SC_G_ELL $((MOD_DOCKER[$name|total] - MOD_DOCKER_DETAIL_ROWS)) more: m for the Docker view"
            break
        fi
        [[ -n $health ]] && status+=" ($health)"
        # Before the first answer with stats (e.g. a ps-only result).
        [[ ${MOD_DOCKER[$name|stats]-} == 1 || $state != running ]] || cpu=$SC_G_ELL memp=$SC_G_ELL mem=$SC_G_ELL
        mod_docker_detail_cols "$cname" "$cpu" "$memp" "$mem"
        rest=
        if ((sw)); then
            sc_fit "$status" "$sw"
            status=$REPLY rest="  $image"
        fi
        mod_docker_style "$state" "$health"
        mod_docker_frame_row "$MOD_DOCKER_PRE" "$status" "$rest"
    done <<<"${MOD_DOCKER[$name|rows_cpu]}"
    return 0
}

# --- module view --------------------------------------------------------------

# Column widths for $SC_COLS: name and image share what the fixed columns
# leave. Sets MOD_DOCKER_W=(name image status health cpu mem).
mod_docker_widths() {
    local fixed=$((2 + 16 + 9 + 6 + 7 + 5)) rest nw
    rest=$((SC_COLS - fixed))
    nw=$((rest / 2))
    ((nw > 30)) && nw=30
    MOD_DOCKER_W=("$nw" $((rest - nw)) 16 9 6 7)
}

mod_docker_row() { # name image status health cpu mem
    local out= v i=0
    for v in "$1" "$2" "$3" "$4"; do
        sc_fit "$v" "${MOD_DOCKER_W[i++]}"
        out+="$REPLY "
    done
    sc_fit_right "$5" "${MOD_DOCKER_W[4]}"
    out+="$REPLY "
    sc_fit_right "$6" "${MOD_DOCKER_W[5]}"
    REPLY=$out$REPLY
}

mod_docker_draw() {
    local name=$1 sel=$2 top=$3 n=${#MOD_DOCKER_ROWS[@]} i cname image state status health cpu memp mem
    local summary note= msg=$SC_MSG right row pre
    mod_docker_summary "$name"
    summary=$REPLY right=$REPLY
    [[ -n ${MOD_DOCKER[$name|total]-} ]] &&
        right="${MOD_DOCKER[$name|running]}/${MOD_DOCKER[$name|total]} running"
    sc_ui_begin_frame "$name $SC_G_SEP docker" "$right" || return
    mod_docker_widths
    mod_docker_row NAME IMAGE STATUS HEALTH CPU% MEM
    sc_frame_text "$C_DIM" "  $REPLY"
    if ((n == 0)); then
        [[ ${MOD_DOCKER[$name|total]-} == 0 ]] && summary="No containers on this server."
        sc_frame_text "$C_DIM" "  $summary"
    fi
    for ((i = top; i < n && i < top + SC_ROWS - 4; i++)); do
        IFS='|' read -r cname image state status health cpu memp mem <<<"${MOD_DOCKER_ROWS[i]}"
        [[ ${MOD_DOCKER[$name|stats]-} == 1 || $state != running ]] || cpu=$SC_G_ELL mem=$SC_G_ELL
        mod_docker_row "$cname" "$image" "$status" "${health:--}" "$cpu" "$mem"
        row=$REPLY
        if ((i == sel)); then
            sc_frame_text "$C_SEL" "$SC_G_SEL $row"
        else
            # Same colours as in the detail view; the cell is HEALTH here.
            pre=$((MOD_DOCKER_W[0] + MOD_DOCKER_W[1] + MOD_DOCKER_W[2] + 3))
            mod_docker_style "$state" "$health"
            mod_docker_frame_row "  ${row:0:pre}" "${row:pre:MOD_DOCKER_W[3]}" "${row:pre+MOD_DOCKER_W[3]}"
        fi
    done
    # A docker error next to existing rows (e.g. stats failed) and skipped
    # lines go to the status line unless a message is already shown there.
    ((n)) && [[ -n ${MOD_DOCKER[$name|err]-} ]] && note=${MOD_DOCKER[$name|err]}
    ((${MOD_DOCKER[$name|bad]:-0})) && note+="${note:+ $SC_G_SEP }${MOD_DOCKER[$name|bad]} unreadable line(s) skipped"
    [[ -z $SC_MSG && -n $note ]] && sc_msg warn "$note"
    if mod_docker_busy "$name"; then
        SC_FRAME_STATUS="updating$SC_G_ELL"
    elif [[ -n ${MOD_DOCKER[$name|ts]-} ]]; then
        printf -v SC_FRAME_STATUS 'as of %(%H:%M:%S)T' "${MOD_DOCKER[$name|ts]}"
    fi
    sc_ui_end_frame "$SC_G_UPDOWN" move r refresh esc back
    SC_MSG=$msg
}

mod_docker_view() {
    local name=$1 sel=0 top=0 dirty=1 last=0 seen=
    sc_msg info "Read only: no container is changed from here."
    while :; do
        sc_ui_check_resize && dirty=1
        if ((EPOCHSECONDS - last >= MOD_DOCKER_REFRESH)) && mod_docker_async "$name" full; then
            last=$EPOCHSECONDS
            dirty=1
        fi
        mod_docker_poll && dirty=1
        if [[ ${MOD_DOCKER[$name|ts]-}/${MOD_DOCKER[$name|mode]-} != "$seen" ]]; then
            MOD_DOCKER_ROWS=()
            [[ -n ${MOD_DOCKER[$name|rows]-} ]] && mapfile -t MOD_DOCKER_ROWS <<<"${MOD_DOCKER[$name|rows]}"
            seen=${MOD_DOCKER[$name|ts]-}/${MOD_DOCKER[$name|mode]-}
            dirty=1
        fi
        ((sel >= ${#MOD_DOCKER_ROWS[@]})) && sel=$((${#MOD_DOCKER_ROWS[@]} - 1))
        ((sel < 0)) && sel=0
        if ((dirty)); then
            sc_ui_scroll "$sel" "$top" $((SC_ROWS - 4)) "${#MOD_DOCKER_ROWS[@]}"
            top=$REPLY
            mod_docker_draw "$name" "$sel" "$top"
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        if sc_ui_nav "$sel" "${#MOD_DOCKER_ROWS[@]}"; then
            sel=$REPLY
            continue
        fi
        case $SC_KEY in
            r) last=0 ;;
            ESC | q | LEFT | h) return 0 ;;
        esac
    done
}

sc_module_register docker "Docker containers (read only)" mod_docker_view
