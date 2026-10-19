# shellcheck shell=bash
# Drives module, read only: temperature and SMART health of the disks of a
# server, as a "Drives" section after Disks in the detail view; a problem
# (WARN/FAIL) replaces the OS text in the STATUS column of the server list.
# It has no entry under 'm'.
#
# lib/remote/drives.sh runs `smartctl -n standby -A` per disk (as root, or
# through `sudo -n`) in the background, at most every drives_refresh seconds
# (default 300): reading SMART data wakes a sleeping hard disk, -n standby
# avoids that. Health comes from the -A output alone, so a sudo rule for
# `smartctl -A` is enough (-H is not needed). Every value is stripped of
# control characters.

MOD_DRIVES_REMOTE=${SC_ROOT:-.}/lib/remote/drives.sh
declare -gA MOD_DRIVES=()      # "<server>|<key>" -> value, see mod_drives_load
declare -gA MOD_DRIVES_PID=()  # server -> pid of the running background query
declare -gA MOD_DRIVES_LAST=() # server -> EPOCHSECONDS of the last query start
declare -gA MOD_DRIVES_NOSTANDBY=() # server -> 1 once sudo refused -n standby

# --- parsing ------------------------------------------------------------------

# Parses the `smartctl -A` lines $2 of a drive of kind $1 (HDD|SSD|NVMe|-).
# Sets P_TEMP (degrees C or empty), P_HEALTH (OK|WARN|FAIL|?), P_DETAIL
# (short counters) and P_SHORT (the problem for the server list, if any).
mod_drives_parse() {
    local kind=$1 line id name when raw v realloc= pend= uncorr= past=0 failing=0 attrs=0
    local crit= spare= spare_thr= used= media= defects= details=()
    P_TEMP= P_HEALTH='?' P_DETAIL= P_SHORT=
    while IFS= read -r line; do
        if [[ $line =~ ^\ *([0-9]{1,3})\ +([A-Za-z0-9_-]+)\ +0x[0-9a-fA-F]+\ +[0-9]+\ +[0-9]+\ +[0-9-]+\ +[A-Za-z_-]+\ +[A-Za-z_]+\ +([A-Za-z_-]+)\ +(.*)$ ]]; then
            id=$((10#${BASH_REMATCH[1]})) when=${BASH_REMATCH[3]} raw=${BASH_REMATCH[4]}
            ((attrs++))
            [[ $raw =~ ^([0-9]+) ]] && v=$((10#${BASH_REMATCH[1]})) || v=
            case $when in
                FAILING_NOW) failing=1 ;;
                In_the_past) past=1 ;;
            esac
            case $id in
                5) realloc=$v ;;
                197) pend=$v ;;
                198) uncorr=$v ;;
                194) [[ -n $v ]] && P_TEMP=$v ;;
                190) [[ -z $P_TEMP && -n $v ]] && P_TEMP=$v ;;
            esac
        elif [[ $line =~ ^Critical\ Warning:\ +(0x[0-9a-fA-F]+) ]]; then
            crit=${BASH_REMATCH[1]}
        elif [[ $line =~ ^Temperature:\ +([0-9]+)\ Celsius ]]; then
            P_TEMP=${BASH_REMATCH[1]}
        elif [[ $line =~ ^Available\ Spare:\ +([0-9]+)% ]]; then
            spare=${BASH_REMATCH[1]}
        elif [[ $line =~ ^Available\ Spare\ Threshold:\ +([0-9]+)% ]]; then
            spare_thr=${BASH_REMATCH[1]}
        elif [[ $line =~ ^Percentage\ Used:\ +([0-9]+)% ]]; then
            used=${BASH_REMATCH[1]}
        elif [[ $line =~ ^Media\ and\ Data\ Integrity\ Errors:\ +([0-9,]+) ]]; then
            media=${BASH_REMATCH[1]//,/}
        elif [[ $line =~ ^Current\ Drive\ Temperature:\ +([0-9]+)\ C ]]; then
            P_TEMP=${BASH_REMATCH[1]}
        elif [[ $line =~ ^Elements\ in\ grown\ defect\ list:\ +([0-9]+) ]]; then
            defects=${BASH_REMATCH[1]}
        fi
    done <<<"$2"
    if ((attrs)); then
        # ATA: a failing attribute, or sectors that were or will be remapped.
        P_HEALTH=OK
        if ((failing)); then
            P_HEALTH=FAIL P_SHORT=FAILING
        elif ((${uncorr:-0} || ${pend:-0} || ${realloc:-0} || past)); then
            P_HEALTH=WARN
            if ((${uncorr:-0})); then P_SHORT="$uncorr uncorr"
            elif ((${pend:-0})); then P_SHORT="$pend pending"
            elif ((${realloc:-0})); then P_SHORT="$realloc realloc"
            else P_SHORT="past failure"; fi
        fi
        # Most serious first, so a narrow DETAIL column keeps what matters.
        ((${uncorr:-0})) && details+=("uncorr $uncorr")
        [[ -n $pend ]] && details+=("pend $pend")
        [[ -n $realloc ]] && details+=("realloc $realloc")
        ((failing)) && details=("attribute failing" "${details[@]}")
    elif [[ -n $crit || -n $used || -n $spare ]]; then
        # NVMe: the controller's critical warning bits and the spare blocks;
        # wear and media errors only warn.
        P_HEALTH=OK
        if [[ -n $crit && $((crit)) != 0 ]]; then
            P_HEALTH=FAIL P_SHORT=critical
        elif [[ -n $spare && -n $spare_thr ]] && ((spare < spare_thr)); then
            P_HEALTH=FAIL P_SHORT="spare low"
        elif ((${used:-0} >= 90)); then
            P_HEALTH=WARN P_SHORT="$used% used"
        elif ((${media:-0})); then
            P_HEALTH=WARN P_SHORT="media err"
        fi
        ((${media:-0})) && details+=("media err $media")
        [[ -n $used ]] && details+=("used $used%")
        [[ -n $spare ]] && details+=("spare $spare%")
    elif [[ -n $P_TEMP || -n $defects ]]; then
        # SAS/SCSI: grown defects.
        P_HEALTH=OK
        if ((${defects:-0})); then P_HEALTH=WARN P_SHORT="$defects defects"; fi
        [[ -n $defects ]] && details+=("defects $defects")
    fi
    local IFS=$'\x1f'
    P_DETAIL=${details[*]}
    P_DETAIL=${P_DETAIL//$'\x1f'/ $SC_G_SEP }
}

# Parses result file $2 of server $1 into MOD_DRIVES:
#   rc ts err        query status (err: ssh message)
#   drives           1 or 0 (no smartctl) as reported by lib/remote/drives.sh
#   rows             "dev|model|kind|bytes|access|temp|health|detail|short"
#   n warn fail sleep denied wakes   counts
mod_drives_load() {
    local name=$1 file=$2 line key v dev rows=() order=() i
    local -A text=() meta=()
    for key in rc ts err drives rows n warn fail sleep denied wakes; do
        unset "MOD_DRIVES[$name|$key]"
    done
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        key=${line%%=*} v=${line#*=}
        sc_sanitize "$v"
        v=$REPLY
        case $key in
            rc | ts | err | drives) MOD_DRIVES[$name|$key]=$v ;;
            drive)
                dev=${v%%|*}
                [[ $dev =~ ^/dev/[A-Za-z0-9]+$ ]] || continue
                [[ -n ${meta[$dev]+x} ]] || order+=("$dev")
                meta[$dev]=${v#*|}
                ;;
            smart)
                dev=${v%%|*}
                [[ -n ${meta[$dev]+x} ]] && text[$dev]+="${v#*|}"$'\n'
                ;;
        esac
    done <"$file"
    local model kind bytes access n=0 warn=0 fail=0 sleep=0 denied=0 wakes=0
    for dev in "${order[@]}"; do
        IFS='|' read -r model kind bytes access <<<"${meta[$dev]}"
        ((n++))
        P_TEMP= P_HEALTH='?' P_DETAIL= P_SHORT=
        case $access in
            standby) P_HEALTH=SLEEP P_DETAIL="standby, not woken"; ((sleep++)) ;;
            denied) P_HEALTH='-' P_DETAIL="not allowed"; ((denied++)) ;;
            *)
                [[ $access == wakes ]] && ((wakes++))
                mod_drives_parse "$kind" "${text[$dev]-}"
                [[ $P_HEALTH == '?' ]] && P_DETAIL="not readable"
                ;;
        esac
        case $P_HEALTH in WARN) ((warn++)) ;; FAIL) ((fail++)) ;; esac
        rows+=("${dev#/dev/}|${model//|//}|$kind|$bytes|$access|$P_TEMP|$P_HEALTH|$P_DETAIL|$P_SHORT")
    done
    MOD_DRIVES[$name|n]=$n MOD_DRIVES[$name|warn]=$warn MOD_DRIVES[$name|fail]=$fail
    MOD_DRIVES[$name|sleep]=$sleep MOD_DRIVES[$name|denied]=$denied MOD_DRIVES[$name|wakes]=$wakes
    if ((n)); then
        local IFS=$'\n'
        MOD_DRIVES[$name|rows]="${rows[*]}"
    fi
    # Remember a refused -n standby, so later runs do not ask sudo again.
    ((wakes)) && MOD_DRIVES_NOSTANDBY[$name]=1
    return 0
}

# --- background queries -------------------------------------------------------

mod_drives_fetch() { # name result-file
    local name=$1 res=$2 rc msg=
    {
        [[ -n ${MOD_DRIVES_NOSTANDBY[$name]-} ]] && printf 'NOSTANDBY=1\n'
        cat -- "$MOD_DRIVES_REMOTE"
    } >"$res.sh"
    sc_ssh_run_script "$name" "${SC_SET[command_timeout]}" "$res.sh" "$res.out" "$res.err"
    rc=$?
    if ((rc != 0)); then
        sc_ssh_error_summary "$rc" "$res.err" "${SC_SET[command_timeout]}"
        msg=$REPLY
    fi
    {
        printf 'rc=%d\nts=%(%s)T\n' "$rc" -1
        if ((rc == 0)); then cat -- "$res.out"; else printf 'err=%s\n' "$msg"; fi
    } >"$res.tmp" && mv -f -- "$res.tmp" "$res"
    rm -f -- "$res.sh" "$res.out" "$res.err"
}

# Starts a background query of server $1 unless one is running (status 1).
# The result arrives as "<name>.drives".
mod_drives_async() {
    local name=$1 pid=${MOD_DRIVES_PID[$1]-}
    [[ -n $SC_RUNTIME_DIR ]] || return 1
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    (
        trap 'pkill -TERM -P "$BASHPID" 2>/dev/null; exit 143' TERM
        mod_drives_fetch "$name" "$SC_RUNTIME_DIR/$name.dr"
        mv -f -- "$SC_RUNTIME_DIR/$name.dr" "$SC_RUNTIME_DIR/$name.drives"
    ) </dev/null >/dev/null 2>&1 &
    MOD_DRIVES_PID[$name]=$!
    MOD_DRIVES_LAST[$name]=$EPOCHSECONDS
}

# Loads finished results; status 0 if anything changed.
mod_drives_poll() {
    local f name changed=1
    for f in "$SC_RUNTIME_DIR"/*.drives; do
        [[ -e $f ]] || continue
        name=${f##*/}
        name=${name%.drives}
        unset "MOD_DRIVES_PID[$name]"
        if sc_server_exists "$name"; then
            mod_drives_load "$name" "$f"
            changed=0
        fi
        rm -f -- "$f"
    done
    return "$changed"
}

# Starts a query of server $1 if it is online and the last one is older
# than drives_refresh.
mod_drives_due() {
    ((${SC_SET[drives]:-1})) && sc_metrics_online "$1" &&
        ((EPOCHSECONDS - ${MOD_DRIVES_LAST[$1]:-0} >= ${SC_SET[drives_refresh]:-300})) &&
        mod_drives_async "$1"
}

# --- module hooks -------------------------------------------------------------

mod_drives_list_tick() {
    local name changed=1
    mod_drives_poll && changed=0
    for name in "${SC_SERVERS[@]}"; do mod_drives_due "$name"; done
    return "$changed"
}

mod_drives_detail_tick() {
    local changed=1
    mod_drives_poll && changed=0
    mod_drives_due "$1"
    return "$changed"
}

# 'r' in the detail view: query now, and try -n standby again.
mod_drives_detail_refresh() {
    MOD_DRIVES_LAST[$1]=0
    unset "MOD_DRIVES_NOSTANDBY[$1]"
}

mod_drives_cleanup() {
    local pid
    for pid in "${MOD_DRIVES_PID[@]}"; do
        pkill -TERM -P "$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
    done
    MOD_DRIVES_PID=()
}

# The worst drive problem of server $1 for the STATUS column: "sdb: 8
# pending" (WARN, yellow) or "sda: FAILING" (FAIL, red), "+N" if more drives
# have one.
mod_drives_list_status() {
    local name=$1 dev model kind bytes access temp health detail short best= level= more=-1
    ((${SC_SET[drives]:-1})) || return 1
    ((${MOD_DRIVES[$name|warn]:-0} + ${MOD_DRIVES[$name|fail]:-0})) || return 1
    while IFS='|' read -r dev model kind bytes access temp health detail short; do
        case $health in
            FAIL) ((more++)); [[ $level == FAIL ]] || best="$dev: $short" level=FAIL ;;
            WARN) ((more++)); [[ -n $level ]] || best="$dev: $short" level=WARN ;;
        esac
    done <<<"${MOD_DRIVES[$name|rows]}"
    ((more > 0)) && best+=" +$more"
    REPLY=$best
    if [[ $level == FAIL ]]; then SC_MOD_STATUS_C=$C_CRIT; else SC_MOD_STATUS_C=$C_WARN; fi
    return 0
}

# Temperature cell of a drive: unit as in the list (temp_unit / f), colour
# by kind: hard disks warn from 50 C and are critical from 60 C, SSDs and
# NVMe from 70 / 80 C.
mod_drives_temp() { # temp kind
    local warn=70 crit=80
    [[ $2 == HDD ]] && warn=50 crit=60
    MOD_DRIVES_TEMP_C=
    sc_fmt_temp "$1" "${SC_SET[temp_unit]:-c}" || { MOD_DRIVES_TEMP_C=$C_DIM; return; }
    if (($1 >= crit)); then MOD_DRIVES_TEMP_C=$C_CRIT
    elif (($1 >= warn)); then MOD_DRIVES_TEMP_C=$C_WARN
    fi
}

# Size in bytes as in the Disks rows (sc_fmt_kib).
mod_drives_size() {
    if [[ $1 =~ ^[0-9]+$ ]]; then sc_fmt_kib $(($1 / 1024)); else REPLY=-; fi
}

# The "Drives" section: heading with counts, column header, one row per
# drive. Columns: DEVICE 11 (the model starts in the bar column of the
# rows above), MODEL 18, TYPE 4, SIZE 6, TEMP 5, HEALTH 6, DETAIL the rest.
mod_drives_detail_after_disks() {
    local name=$1 info dev model kind bytes access temp health detail short cell hc row t tc
    ((${SC_SET[drives]:-1})) && sc_metrics_online "$name" || return 1
    if [[ -z ${MOD_DRIVES[$name|rc]-} ]]; then
        [[ -n ${MOD_DRIVES_LAST[$name]-} ]] || return 1
        sc_detail_heading Drives "loading$SC_G_ELL"
        sc_frame_add ""
        return 0
    fi
    if [[ ${MOD_DRIVES[$name|rc]} != 0 ]]; then
        sc_detail_heading Drives "${MOD_DRIVES[$name|err]:-no answer}"
        sc_frame_add ""
        return 0
    fi
    # No smartctl or no disk found: no section.
    [[ ${MOD_DRIVES[$name|drives]-} == 1 && -n ${MOD_DRIVES[$name|rows]-} ]] || return 1
    if ((MOD_DRIVES[$name|denied] == MOD_DRIVES[$name|n])); then
        sc_detail_heading Drives "sudo smartctl -A not allowed (see README)"
        sc_frame_add ""
        return 0
    fi
    info="${MOD_DRIVES[$name|n]} drive"
    ((MOD_DRIVES[$name|n] == 1)) || info+=s
    if ((MOD_DRIVES[$name|fail] + MOD_DRIVES[$name|warn] == 0)); then
        info+=" $SC_G_SEP all OK"
    else
        ((MOD_DRIVES[$name|fail])) && info+=" $SC_G_SEP ${MOD_DRIVES[$name|fail]} failing"
        if ((MOD_DRIVES[$name|warn])); then
            info+=" $SC_G_SEP ${MOD_DRIVES[$name|warn]} warning"
            ((MOD_DRIVES[$name|warn] == 1)) || info+=s
        fi
    fi
    ((MOD_DRIVES[$name|sleep])) && info+=" $SC_G_SEP ${MOD_DRIVES[$name|sleep]} asleep"
    printf -v info '%s %s as of %(%H:%M)T' "$info" "$SC_G_SEP" "${MOD_DRIVES[$name|ts]:-0}"
    sc_detail_heading Drives "$info"
    ((MOD_DRIVES[$name|wakes])) &&
        sc_frame_text "$C_DIM" "  sudo does not allow -n standby: sleeping disks are woken (see README)"
    mod_drives_cols DEVICE MODEL TYPE SIZE TEMP HEALTH DETAIL
    sc_frame_text "$C_DIM" "  $REPLY"
    while IFS='|' read -r dev model kind bytes access temp health detail short; do
        [[ -n $dev ]] || continue
        mod_drives_temp "$temp" "$kind"
        t=$REPLY tc=$MOD_DRIVES_TEMP_C
        [[ -n $temp ]] || t=- tc=$C_DIM
        sc_fit "$dev" 11; row="  $REPLY "
        sc_fit "${model:--}" 18; row+="$REPLY "
        sc_fit "$kind" 4; row+="$REPLY "
        mod_drives_size "$bytes"; sc_fit_right "$REPLY" 6; row+="$REPLY "
        sc_fit_right "$t" 5; cell=$REPLY
        sc_fit "$health" 6; hc=$REPLY
        sc_fit "$detail" $((SC_COLS - ${#row} - 5 - 1 - 6 - 1))
        case $health in
            FAIL) health=$C_CRIT ;;
            WARN) health=$C_WARN ;;
            SLEEP | '?' | -) health=$C_DIM ;;
            *) health=$C_OK ;;
        esac
        if [[ $access == standby ]]; then
            SC_FRAME+=("$C_DIM$row$cell $hc $REPLY$C_RESET")
        else
            SC_FRAME+=("$row$tc$cell$C_NORM $health$hc$C_NORM $C_DIM$REPLY$C_RESET")
        fi
    done <<<"${MOD_DRIVES[$name|rows]}"
    sc_frame_add ""
    return 0
}

mod_drives_cols() { # header cells
    local out
    sc_fit "$1" 11; out="$REPLY "
    sc_fit "$2" 18; out+="$REPLY "
    sc_fit "$3" 4; out+="$REPLY "
    sc_fit_right "$4" 6; out+="$REPLY "
    sc_fit_right "$5" 5; out+="$REPLY "
    sc_fit "$6" 6; out+="$REPLY "
    REPLY=$out$7
}

sc_module_register drives "Drives (SMART)" ""
