# shellcheck shell=bash
# Screens. Each view runs its own loop: poll background results, redraw only
# when something changed (key, data, resize), and return on Esc/q.

declare -ga SC_PAGER_LINES=() SC_PROC_ROWS=() SC_FORM_KEYS=()
declare -gA SC_FORM_LABEL=() SC_FORM_HINT=() SC_FORM_VAL=()
SC_FORM_ORIG= SC_FORM_RESULT= SC_FORM_ERRKEY=

# --- server list --------------------------------------------------------------

# Rows of the server list: SC_LIST_KIND[i] is "h" (group heading, not
# selectable) or "s" (server), SC_LIST_VAL[i] the group or server name.
# Without any group the rows are the servers in config order. With groups:
# named groups A-Z, servers A-Z within a group, then "ungrouped".
declare -ga SC_LIST_KIND=() SC_LIST_VAL=()
SC_LIST_GROUPED=0

sc_list_build() {
    local name g last=$'\1' line
    SC_LIST_KIND=() SC_LIST_VAL=() SC_LIST_GROUPED=0
    for name in "${SC_SERVERS[@]}"; do
        [[ -n ${SC_SRV[$name|group]} ]] && { SC_LIST_GROUPED=1; break; }
    done
    if ((!SC_LIST_GROUPED)); then
        for name in "${SC_SERVERS[@]}"; do SC_LIST_KIND+=(s) SC_LIST_VAL+=("$name"); done
        return 0
    fi
    # "0group<TAB>name" for named groups, "1<TAB>name" for the rest, so that
    # ungrouped servers sort last. Names and groups contain no control chars.
    while IFS=$'\t' read -r g name; do
        if [[ $g != "$last" ]]; then
            last=$g
            SC_LIST_KIND+=(h)
            if [[ $g == 1 ]]; then SC_LIST_VAL+=(ungrouped); else SC_LIST_VAL+=("${g#0}"); fi
        fi
        SC_LIST_KIND+=(s) SC_LIST_VAL+=("$name")
    done < <(for name in "${SC_SERVERS[@]}"; do
        g=${SC_SRV[$name|group]}
        if [[ -n $g ]]; then line="0$g"; else line=1; fi
        printf '%s\t%s\n' "$line" "$name"
    done | LC_ALL=C sort -f -t $'\t' -k1,1 -k2,2)
}

# Row index of server $1 (REPLY=-1 and status 1 if not listed).
sc_list_row() {
    local i
    for i in "${!SC_LIST_VAL[@]}"; do
        [[ ${SC_LIST_KIND[i]} == s && ${SC_LIST_VAL[i]} == "$1" ]] && { REPLY=$i; return 0; }
    done
    REPLY=-1
    return 1
}

# Moves a row index off headings: towards $2 (1 down, -1 up), and the other
# way if there is no server in that direction. REPLY=row (-1: no servers).
sc_list_fix() {
    local r=$1 d=${2:-1} n=${#SC_LIST_KIND[@]}
    ((r >= n)) && r=$((n - 1))
    ((r < 0)) && r=0
    while ((r >= 0 && r < n)) && [[ ${SC_LIST_KIND[r]} != s ]]; do ((r += d)); done
    if ((r < 0 || r >= n)); then
        r=$1 d=$((-d))
        ((r >= n)) && r=$((n - 1))
        ((r < 0)) && r=0
        while ((r >= 0 && r < n)) && [[ ${SC_LIST_KIND[r]} != s ]]; do ((r += d)); done
        ((r < 0 || r >= n)) && r=-1
    fi
    REPLY=$r
}

# Navigation keys over the list rows; headings are skipped. REPLY=new row.
sc_list_nav() {
    local sel=$1 d=1
    case $SC_KEY in
        UP | k | PGUP | HOME | g) d=-1 ;;
    esac
    sc_ui_nav "$sel" "${#SC_LIST_KIND[@]}" || return 1
    case $SC_KEY in
        HOME | g) d=1 ;;
        END | G) d=-1 ;;
    esac
    sc_list_fix "$REPLY" "$d"
    ((REPLY < 0)) && REPLY=$sel
    return 0
}

# First visible row for selection $1 in a window of $3 rows, from the
# previous top $2. With groups the first line always shows a group heading:
# if the top row is a server, its heading is drawn in place of it ("sticky")
# and SC_LIST_STICKY names the group. REPLY=top.
sc_list_scroll() {
    local sel=$1 top=$2 h=$3 n=${#SC_LIST_KIND[@]} i
    SC_LIST_STICKY=
    sc_ui_scroll "$sel" "$top" "$h" "$n"
    top=$REPLY
    # Keep the heading of the selected server's group in view when there is room.
    if ((top == sel && sel > 0)) && [[ ${SC_LIST_KIND[sel - 1]} == h ]] && ((h > 1)); then
        top=$((sel - 1))
    fi
    if ((SC_LIST_GROUPED && n > 0 && h > 1)) && [[ ${SC_LIST_KIND[top]} == s ]]; then
        sc_ui_scroll "$sel" "$top" $((h - 1)) "$n"
        top=$REPLY
        if [[ ${SC_LIST_KIND[top]} == s ]]; then
            for ((i = top; i >= 0; i--)); do
                [[ ${SC_LIST_KIND[i]} == h ]] && { SC_LIST_STICKY=${SC_LIST_VAL[i]}; break; }
            done
        fi
    fi
    REPLY=$top
}

sc_view_servers() {
    local sel=0 top=0 dirty=1 last_fetch=0 n name
    sc_list_build
    sc_list_fix 0 1; sel=$REPLY
    while :; do
        n=${#SC_LIST_KIND[@]}
        ((sel >= n)) && sel=$((n - 1))
        ((sel < 0)) && sel=0
        sc_ui_check_resize && dirty=1
        if ((EPOCHSECONDS - last_fetch >= SC_SET[list_refresh])); then
            sc_fetch_all
            last_fetch=$EPOCHSECONDS
            dirty=1
        fi
        sc_poll_results && dirty=1
        if ((dirty)); then
            sc_list_scroll "$sel" "$top" $((SC_ROWS - 4))
            top=$REPLY
            sc_draw_servers "$sel" "$top"
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        if sc_list_nav "$sel"; then
            sel=$REPLY
            continue
        fi
        name=
        [[ ${SC_LIST_KIND[sel]-} == s ]] && name=${SC_LIST_VAL[sel]}
        case $SC_KEY in
            ENTER | RIGHT | l) [[ -n $name ]] && sc_view_detail "$name" ;;
            a)
                if sc_form_server ""; then
                    sc_list_build
                    sc_list_row "$SC_FORM_RESULT" && sel=$REPLY
                    sc_fetch_async "$SC_FORM_RESULT"
                fi
                ;;
            e)
                if [[ -n $name ]] && sc_form_server "$name"; then
                    sc_list_build
                    sc_list_row "$SC_FORM_RESULT" && sel=$REPLY
                    sc_fetch_async "$SC_FORM_RESULT"
                fi
                ;;
            d)
                [[ -n $name ]] || continue
                if sc_ui_confirm "Delete server '$name'?"; then
                    if sc_server_delete "$name"; then
                        sc_metrics_clear "$name"
                        sc_msg info "Deleted '$name'"
                        sc_list_build
                        sc_list_fix "$sel" 1; sel=$REPLY
                    else
                        sc_msg error "$SC_ERR"
                    fi
                fi
                ;;
            J | K)
                [[ -n $name ]] || continue
                if ((SC_LIST_GROUPED)); then
                    sc_msg info "Grouped lists are sorted by name; J/K reorders only without groups"
                elif [[ $SC_KEY == J ]]; then
                    sc_server_move "$name" 1 && { ((sel++)); sc_list_build; }
                else
                    sc_server_move "$name" -1 && { ((sel--)); sc_list_build; }
                fi
                ;;
            s) [[ -n $name ]] && { sc_ssh_interactive "$name" || sc_msg error "$SC_ERR"; } ;;
            r)
                last_fetch=0
                sc_msg info "Refreshing all servers${SC_G_ELL}"
                ;;
            '?') sc_view_help ;;
            q | ESC) return 0 ;;
        esac
    done
}

# Fills CELL_* with the display values of one server row.
sc_server_cells() {
    local name=$1 rc=${SC_M[$1|rc]-}
    CELL_CPU=- CELL_MEM=- CELL_LOAD=- CELL_UP=- CELL_CPU_C= CELL_MEM_C= CELL_INFO_C=$C_DIM
    if [[ -z $rc ]]; then
        CELL_G=$SC_G_HOLLOW
        if [[ -n ${SC_M[$name|loading]-} ]]; then
            CELL_G_C=$C_YELLOW CELL_INFO="connecting$SC_G_ELL"
        else
            CELL_G_C=$C_DIM CELL_INFO="not checked yet"
        fi
    elif ((rc != 0)); then
        CELL_G=$SC_G_DOT CELL_G_C=$C_RED CELL_INFO=${SC_M[$name|err]:-error} CELL_INFO_C=$C_RED
    else
        CELL_G=$SC_G_DOT CELL_G_C=$C_GREEN
        if sc_int "${SC_M[$name|cpu_busy]-}"; then
            CELL_CPU="$REPLY%"
            sc_level_color "$REPLY"
            CELL_CPU_C=$SC_LEVEL
        fi
        if sc_pct "${SC_M[$name|mem_used]-}" "${SC_M[$name|mem_total]-}"; then
            CELL_MEM="$REPLY%"
            sc_level_color "$REPLY"
            CELL_MEM_C=$SC_LEVEL
        fi
        CELL_LOAD=${SC_M[$name|load]%% *}
        [[ -n $CELL_LOAD ]] || CELL_LOAD=-
        sc_fmt_duration "${SC_M[$name|uptime]-}"
        CELL_UP=$REPLY
        CELL_INFO=${SC_M[$name|distro]:-${SC_M[$name|os]-}}
    fi
}

# One group heading row: "── production ──" in the accent color.
sc_list_heading() {
    sc_fit "$SC_G_HLINE$SC_G_HLINE $1 $SC_G_HLINE$SC_G_HLINE" $((SC_COLS - 1))
    REPLY=" $C_BOLD$C_CYAN$REPLY$C_RESET"
}

sc_draw_servers() {
    local sel=$1 top=$2 n=${#SC_SERVERS[@]} rows=${#SC_LIST_KIND[@]} h=$((SC_ROWS - 4)) i name line style mark plural=s
    local nw=16 hw=0 cw=5 mw=5 lw=6 uw=8 fixed iw
    ((n == 1)) && plural=
    printf -v line '%(%H:%M:%S)T' -1
    sc_ui_begin_frame "Servers" "$n server$plural $SC_G_SEP $line" || return
    fixed=$((3 + nw + 1 + cw + 1 + mw + 1 + lw + 1 + uw + 1))
    if ((SC_COLS - fixed >= 40)); then
        hw=$(((SC_COLS - fixed) / 2))
        ((hw > 32)) && hw=32
    fi
    iw=$((SC_COLS - fixed - (hw ? hw + 1 : 0)))

    sc_fit "NAME" "$nw"; line="   $REPLY "
    if ((hw)); then sc_fit "TARGET" "$hw"; line+="$REPLY "; fi
    sc_fit_right "CPU" "$cw"; line+="$REPLY "
    sc_fit_right "MEM" "$mw"; line+="$REPLY "
    sc_fit_right "LOAD" "$lw"; line+="$REPLY "
    sc_fit_right "UPTIME" "$uw"; line+="$REPLY "
    sc_fit "STATUS" "$iw"; line+=$REPLY
    sc_frame_add "$C_DIM$line$C_RESET"

    if ((n == 0)); then
        sc_frame_add ""
        sc_frame_text "" "   No servers yet. Press 'a' to add one."
        sc_frame_text "$C_DIM" "   Authentication uses your SSH keys / ssh-agent; passwords are never stored."
    fi
    if [[ -n ${SC_LIST_STICKY-} ]]; then
        sc_list_heading "$SC_LIST_STICKY"
        sc_frame_add "$REPLY"
        ((h--))
    fi
    for ((i = top; i < rows && i < top + h; i++)); do
        name=${SC_LIST_VAL[i]}
        if [[ ${SC_LIST_KIND[i]} == h ]]; then
            sc_list_heading "$name"
            sc_frame_add "$REPLY"
            continue
        fi
        sc_server_cells "$name"
        style= mark=' '
        ((i == sel)) && style=$C_SEL mark=$SC_G_SEL
        line="$style$mark$CELL_G_C$CELL_G$C_NORM "
        sc_fit "$name" "$nw"; line+="$C_BOLD$REPLY$C_NORM "
        if ((hw)); then
            sc_server_target "$name"
            sc_fit "$REPLY" "$hw"; line+="$REPLY "
        fi
        sc_fit_right "$CELL_CPU" "$cw"; line+="$CELL_CPU_C$REPLY$C_NORM "
        sc_fit_right "$CELL_MEM" "$mw"; line+="$CELL_MEM_C$REPLY$C_NORM "
        sc_fit_right "$CELL_LOAD" "$lw"; line+="$REPLY "
        sc_fit_right "$CELL_UP" "$uw"; line+="$REPLY "
        sc_fit "$CELL_INFO" "$iw"; line+="$CELL_INFO_C$REPLY$C_NORM"
        sc_frame_add "$line$C_RESET"
    done
    # J/K (reorder) is listed in the help screen; the footer has to fit 80 columns.
    sc_ui_end_frame "$SC_G_UPDOWN" move "$SC_G_ENTER" details a add e edit d delete \
        s ssh r refresh '?' help q quit
}

# --- server detail ------------------------------------------------------------

SC_DET_SCROLL=0 SC_DET_SCROLL_MAX=0 SC_DET_MIN_PROCS=3

sc_view_detail() {
    local name=$1 dirty=1 last=0
    SC_DET_SCROLL=0
    while :; do
        sc_ui_check_resize && dirty=1
        if ((EPOCHSECONDS - last >= SC_SET[detail_refresh])); then
            sc_fetch_async "$name"
            last=$EPOCHSECONDS
        fi
        sc_poll_results && dirty=1
        if ((dirty)); then
            sc_draw_detail "$name"
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        sc_detail_scroll_key && continue
        case $SC_KEY in
            ESC | q | LEFT | h) return 0 ;;
            r)
                last=0
                sc_msg info "Refreshing$SC_G_ELL"
                ;;
            p | ENTER) sc_view_processes "$name" ;;
            s) sc_ssh_interactive "$name" || sc_msg error "$SC_ERR" ;;
            x) sc_view_snippets "$name" ;;
            e)
                if sc_form_server "$name"; then
                    name=$SC_FORM_RESULT
                    last=0
                fi
                ;;
            m) sc_view_modules "$name" ;;
            '?') sc_view_help ;;
        esac
    done
}

# Split rate bar of one interface, $3 cells wide: rx (green) in the left
# half, a gap, tx (muted red) in the right half; each half has its own
# 100 MB/s scale.
sc_netif_bar() {
    local w=$(($3 - 1)) h rx
    h=$((w / 2))
    sc_rate_bar "$1" "$h"
    rx="$C_RX$REPLY$C_NORM$C_DIM$SC_BAR_REST$C_NORM"
    sc_rate_bar "$2" $((w - h))
    REPLY="$rx $C_TX$REPLY$C_NORM$C_DIM$SC_BAR_REST$C_NORM"
}

# "rx  12.50  tx   0.25 MB/s" (25 characters up to 999.99 MB/s).
sc_netif_values() {
    local rx
    sc_fmt_mbs "$1"; rx=${REPLY% MB/s}
    sc_fmt_mbs "$2"
    printf -v REPLY 'rx %6s  tx %6s MB/s' "$rx" "${REPLY% MB/s}"
}

# One "label [bar] pct  detail" row of the detail view.
sc_detail_bar_line() {
    local label=$1 pct=$2 text=$3 bar pt
    if [[ -n $pct ]]; then
        sc_ui_bar "$pct" "$SC_DET_BW"
        bar=$REPLY
        sc_fit_right "$pct%" 5
        pt=$REPLY
    else
        sc_repeat "$SC_G_EMPTY" "$SC_DET_BW"
        bar=$C_DIM$REPLY$C_NORM
        pt="  n/a"
    fi
    sc_fit "$label" "$SC_DET_LW"
    label=$REPLY
    sc_fit "$text" $((SC_COLS - 2 - SC_DET_LW - SC_DET_BW - 8))
    SC_FRAME+=("  $C_BOLD$label$C_NORM$bar $pt  $C_DIM$REPLY$C_RESET")
}

# Scroll keys of the detail view: one row, one page (the visible content
# rows), top, bottom. Status 1 for other keys. sc_draw_detail clamps.
sc_detail_scroll_key() {
    local page=$((SC_ROWS - 3))
    ((page < 1)) && page=1
    case $SC_KEY in
        UP | k) ((SC_DET_SCROLL > 0)) && ((SC_DET_SCROLL--)) ;;
        DOWN | j) ((SC_DET_SCROLL < SC_DET_SCROLL_MAX)) && ((SC_DET_SCROLL++)) ;;
        PGUP) ((SC_DET_SCROLL -= page)) ;;
        PGDN) ((SC_DET_SCROLL += page)) ;;
        HOME | g) SC_DET_SCROLL=0 ;;
        END | G) SC_DET_SCROLL=$SC_DET_SCROLL_MAX ;;
        *) return 1 ;;
    esac
    return 0
}

# Detail view of server $1. The content below the title row scrolls:
# SC_DET_SCROLL is the first content row shown; it is clamped here to
# 0..SC_DET_SCROLL_MAX (content rows minus visible rows), so key handlers
# and resizes only need to change it.
sc_draw_detail() {
    local name=$1 rc=${SC_M[$1|rc]-} status line v used total pct mnt size room n=0 row
    local iface rxv txv h total_rows
    h=$((SC_ROWS - 3))
    if [[ -z $rc ]]; then
        status="connecting$SC_G_ELL"
    elif ((rc == 0)); then
        printf -v status 'online %s %(%H:%M:%S)T' "$SC_G_SEP" "${SC_M[$name|ts]:-0}"
    else
        status=offline
    fi
    sc_ui_begin_frame "$name" "$status" || return
    sc_server_target "$name"
    line=" $REPLY"
    [[ -n ${SC_SRV[$name|group]} ]] && line+="  [${SC_SRV[$name|group]}]"
    sc_frame_text "$C_BOLD" "$line"
    if [[ $rc == 0 ]]; then
        sc_fmt_duration "${SC_M[$name|uptime]-}"
        sc_frame_text "$C_DIM" " ${SC_M[$name|distro]:-${SC_M[$name|os]}} $SC_G_SEP kernel ${SC_M[$name|kernel]} $SC_G_SEP host ${SC_M[$name|hostname]} $SC_G_SEP up $REPLY"
    else
        sc_frame_add ""
    fi
    sc_frame_add ""
    if [[ -z $rc ]]; then
        sc_frame_text "$C_YELLOW" "  Connecting to ${SC_SRV[$name|host]}$SC_G_ELL"
    elif ((rc != 0)); then
        sc_frame_text "$C_RED$C_BOLD" "  ${SC_M[$name|err]:-connection failed}"
        sc_frame_add ""
        sc_frame_text "$C_DIM" "  Monitoring uses BatchMode (no prompts). Press 's' to connect interactively,"
        sc_frame_text "$C_DIM" "  e.g. to accept a new host key; check 'ssh-add -l' or set an identity file with 'e'."
    else
        SC_DET_LW=12
        SC_DET_BW=$((SC_COLS / 3))
        ((SC_DET_BW > 40)) && SC_DET_BW=40
        ((SC_DET_BW < 10)) && SC_DET_BW=10

        sc_int "${SC_M[$name|cpu_busy]-}" && pct=$REPLY || pct=
        line="${SC_M[$name|cores]:-?} cores"
        [[ -n ${SC_M[$name|cpu_user]-} ]] && line+="  usr ${SC_M[$name|cpu_user]} sys ${SC_M[$name|cpu_sys]}"
        [[ -n ${SC_M[$name|cpu_iowait]-} ]] && line+=" io ${SC_M[$name|cpu_iowait]}"
        sc_detail_bar_line CPU "$pct" "$line"

        sc_pct "${SC_M[$name|mem_used]-}" "${SC_M[$name|mem_total]-}" && pct=$REPLY || pct=
        sc_fmt_kib "${SC_M[$name|mem_used]-}"; used=$REPLY
        sc_fmt_kib "${SC_M[$name|mem_total]-}"; total=$REPLY
        sc_detail_bar_line Memory "$pct" "$used / $total"

        v=${SC_M[$name|swap_total]:-0}
        if [[ $v =~ ^[0-9]+$ ]] && ((v > 0)); then
            sc_pct "${SC_M[$name|swap_used]-}" "${SC_M[$name|swap_total]}" && pct=$REPLY || pct=
            sc_fmt_kib "${SC_M[$name|swap_used]-}"; used=$REPLY
            sc_fmt_kib "${SC_M[$name|swap_total]}"
            sc_detail_bar_line Swap "$pct" "$used / $REPLY"
        else
            sc_detail_bar_line Swap 0 "no swap"
        fi

        sc_fit Load "$SC_DET_LW"
        sc_frame_text "" "  $REPLY${SC_M[$name|load]:--}   ${SC_M[$name|proc_count]:-?} processes"
        sc_frame_add ""

        if [[ -n ${SC_M[$name|disks]-} ]]; then
            sc_frame_text "$C_BOLD" "  Disks"
            while IFS='|' read -r mnt size used pct; do
                [[ -n $mnt ]] || continue
                ((n++ < 6)) || break
                sc_fmt_kib "$used"; v=$REPLY
                sc_fmt_kib "$size"
                sc_detail_bar_line "$mnt" "$pct" "$v / $REPLY"
            done <<<"${SC_M[$name|disks]}"
            sc_frame_add ""
        fi

        sc_frame_text "$C_BOLD" "  Network"
        if [[ -n ${SC_M[$name|netifs]-} ]]; then
            n=0
            # Same columns as the Disks rows: name, bar, then the values
            # where the disks show percentage and size.
            while IFS='|' read -r iface rxv txv; do
                ((n++ < 6)) || break
                sc_fit "$iface" "$SC_DET_LW"; line="  $C_BOLD$REPLY$C_NORM"
                sc_netif_bar "$rxv" "$txv" "$SC_DET_BW"; line+=$REPLY
                sc_netif_values "$rxv" "$txv"
                sc_fit "$REPLY" $((SC_COLS - 2 - SC_DET_LW - SC_DET_BW - 1))
                SC_FRAME+=("$line $C_DIM$REPLY$C_RESET")
            done <<<"${SC_M[$name|netifs]}"
        else
            sc_frame_text "$C_DIM" "  ${SC_M[$name|net_note]:-no network data}"
        fi
        sc_frame_add ""

        # Processes fill the rest of the screen, but at least SC_DET_MIN_PROCS
        # rows (reachable by scrolling); 'p' shows the full list.
        room=$((h - (${#SC_FRAME[@]} - 1) - 1))
        ((room < SC_DET_MIN_PROCS)) && room=$SC_DET_MIN_PROCS
        sc_proc_header
        sc_frame_text "$C_BOLD" "  $REPLY"
        n=0
        while IFS= read -r row && ((n++ < room)); do
            [[ -n $row ]] || continue
            sc_proc_line "$row"
            sc_frame_text "" "  $REPLY"
        done <<<"${SC_M[$name|procs]}"
    fi

    total_rows=$((${#SC_FRAME[@]} - 1))
    SC_DET_SCROLL_MAX=$((total_rows > h ? total_rows - h : 0))
    ((SC_DET_SCROLL > SC_DET_SCROLL_MAX)) && SC_DET_SCROLL=$SC_DET_SCROLL_MAX
    ((SC_DET_SCROLL < 0)) && SC_DET_SCROLL=0
    if ((SC_DET_SCROLL_MAX > 0)); then
        SC_FRAME=("${SC_FRAME[0]}" "${SC_FRAME[@]:1+SC_DET_SCROLL:h}")
        # Visible content rows and total, e.g. "1-21/33".
        SC_FRAME_STATUS="$((SC_DET_SCROLL + 1))-$((SC_DET_SCROLL + h))/$total_rows"
    fi
    sc_ui_end_frame p processes s ssh x snippets e edit m modules r refresh esc back
}

# --- processes ----------------------------------------------------------------

sc_proc_header() {
    local out
    sc_fit_right PID 7; out="$REPLY "
    sc_fit USER 10; out+="$REPLY "
    sc_fit_right CPU% 6; out+="$REPLY "
    sc_fit_right MEM% 6; out+="$REPLY "
    sc_fit_right RSS 7; out+="$REPLY "
    REPLY="${out}COMMAND"
}

# Formats one process row to width $2 (default: screen width minus indent).
sc_proc_line() {
    local pid user cpu mem rss cmd out width=${2:-$((SC_COLS - 2))}
    IFS='|' read -r pid user cpu mem rss cmd <<<"$1"
    sc_fit_right "$pid" 7; out="$REPLY "
    sc_fit "$user" 10; out+="$REPLY "
    sc_fit_right "$cpu" 6; out+="$REPLY "
    sc_fit_right "$mem" 6; out+="$REPLY "
    sc_fmt_kib "$rss"; sc_fit_right "$REPLY" 7; out+="$REPLY "
    sc_fit "$cmd" $((width - ${#out}))
    REPLY=$out$REPLY
}

# Sorts the process rows of server $1 by $2 (cpu|mem|pid|name) into SC_PROC_ROWS.
sc_sort_procs() {
    local keys
    case $2 in
        mem) keys=(-k4,4rn) ;;
        pid) keys=(-k1,1n) ;;
        name) keys=(-k6,6f) ;;
        *) keys=(-k3,3rn) ;;
    esac
    SC_PROC_ROWS=()
    [[ -n ${SC_M[$1|procs]-} ]] || return 0
    mapfile -t SC_PROC_ROWS < <(sort -t'|' "${keys[@]}" <<<"${SC_M[$1|procs]}")
}

sc_view_processes() {
    local name=$1 sel=0 top=0 dirty=1 last=0 sort=cpu seen= pid cmd i
    while :; do
        sc_ui_check_resize && dirty=1
        if ((EPOCHSECONDS - last >= SC_SET[detail_refresh])); then
            sc_fetch_async "$name"
            last=$EPOCHSECONDS
        fi
        sc_poll_results && dirty=1
        if [[ "${SC_M[$name|ts]-}/$sort" != "$seen" ]]; then
            pid=${SC_PROC_ROWS[sel]%%|*}
            sc_sort_procs "$name" "$sort"
            seen="${SC_M[$name|ts]-}/$sort"
            for i in "${!SC_PROC_ROWS[@]}"; do
                [[ ${SC_PROC_ROWS[i]%%|*} == "$pid" ]] && { sel=$i; break; }
            done
            dirty=1
        fi
        ((sel >= ${#SC_PROC_ROWS[@]})) && sel=$((${#SC_PROC_ROWS[@]} - 1))
        ((sel < 0)) && sel=0
        if ((dirty)); then
            sc_ui_scroll "$sel" "$top" $((SC_ROWS - 4)) "${#SC_PROC_ROWS[@]}"
            top=$REPLY
            sc_draw_processes "$name" "$sel" "$top" "$sort"
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        if sc_ui_nav "$sel" "${#SC_PROC_ROWS[@]}"; then
            sel=$REPLY
            continue
        fi
        case $SC_KEY in
            c) sort=cpu ;;
            m) sort=mem ;;
            p) sort=pid ;;
            n) sort=name ;;
            r) last=0 ;;
            K)
                [[ -n ${SC_PROC_ROWS[sel]-} ]] || continue
                IFS='|' read -r pid _ _ _ _ cmd <<<"${SC_PROC_ROWS[sel]}"
                sc_ui_confirm "Send SIGTERM to PID $pid ($cmd) on $name?" || continue
                sc_ui_flash "Sending SIGTERM to $pid$SC_G_ELL"
                if sc_ssh_kill "$name" "$pid"; then
                    sc_msg info "SIGTERM sent to PID $pid"
                    last=0
                else
                    sc_msg error "kill failed: $REPLY"
                fi
                ;;
            ESC | q | LEFT | h) return 0 ;;
        esac
    done
}

sc_draw_processes() {
    local name=$1 sel=$2 top=$3 sort=$4 i n=${#SC_PROC_ROWS[@]}
    sc_ui_begin_frame "$name $SC_G_SEP processes" "sorted by $sort $SC_G_SEP $n shown" || return
    sc_proc_header
    sc_frame_text "$C_BOLD" "  $REPLY"
    if ((n == 0)); then
        if sc_metrics_online "$name"; then
            sc_frame_text "$C_DIM" "  No process data (ps not available?)"
        else
            sc_frame_text "$C_DIM" "  ${SC_M[$name|err]:-Waiting for data$SC_G_ELL}"
        fi
    fi
    for ((i = top; i < n && i < top + SC_ROWS - 4; i++)); do
        sc_proc_line "${SC_PROC_ROWS[i]}"
        if ((i == sel)); then
            sc_frame_text "$C_SEL" "$SC_G_SEL $REPLY"
        else
            sc_frame_text "" "  $REPLY"
        fi
    done
    sc_ui_end_frame "$SC_G_UPDOWN" move c "sort cpu" m "sort mem" p "sort pid" n "sort name" \
        K "SIGTERM" r refresh esc back
}

# --- snippets -----------------------------------------------------------------

sc_view_snippets() {
    local name=$1 sel=0 top=0 dirty=1 n snip out rc
    while :; do
        n=${#SC_SNIPPETS[@]}
        ((sel >= n)) && sel=$((n - 1))
        ((sel < 0)) && sel=0
        sc_ui_check_resize && dirty=1
        if ((dirty)); then
            sc_ui_scroll "$sel" "$top" $((SC_ROWS - 4)) "$n"
            top=$REPLY
            sc_draw_snippets "$name" "$sel" "$top"
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        if sc_ui_nav "$sel" "$n"; then
            sel=$REPLY
            continue
        fi
        snip=${SC_SNIPPETS[sel]-}
        case $SC_KEY in
            ENTER)
                [[ -n $snip ]] || continue
                sc_ui_confirm "Run '${SC_SNIP[$snip]}' on $name?" || continue
                sc_ui_flash "Running '$snip' on $name (timeout ${SC_SET[snippet_timeout]}s)$SC_G_ELL"
                out=$SC_RUNTIME_DIR/snippet.out
                sc_ssh_run_snippet "$name" "${SC_SNIP[$snip]}" "$out"
                rc=$?
                sc_pager_load "$out" "\$ ${SC_SNIP[$snip]}" ""
                ((rc == 0)) || SC_PAGER_LINES+=("" "[$REPLY]")
                rm -f -- "$out"
                sc_view_pager "$snip @ $name $SC_G_SEP exit $rc"
                ;;
            a) sc_form_snippet "" && { sc_snippet_index "$SC_FORM_RESULT"; sel=$REPLY; } ;;
            e) [[ -n $snip ]] && sc_form_snippet "$snip" ;;
            d)
                [[ -n $snip ]] || continue
                if sc_ui_confirm "Delete snippet '$snip'?"; then
                    sc_snippet_delete "$snip" || sc_msg error "$SC_ERR"
                fi
                ;;
            ESC | q | LEFT | h) return 0 ;;
        esac
    done
}

sc_snippet_index() {
    local i
    for i in "${!SC_SNIPPETS[@]}"; do
        [[ ${SC_SNIPPETS[i]} == "$1" ]] && { REPLY=$i; return 0; }
    done
    REPLY=0
    return 1
}

sc_draw_snippets() {
    local name=$1 sel=$2 top=$3 i n=${#SC_SNIPPETS[@]} snip line
    sc_ui_begin_frame "$name $SC_G_SEP snippets" "$n saved" || return
    sc_frame_text "$C_DIM" "  Saved commands run with 'sh' on the server (non-interactive: no sudo password prompts)."
    if ((n == 0)); then
        sc_frame_text "" "  No snippets yet. Press 'a' to add one."
    fi
    for ((i = top; i < n && i < top + SC_ROWS - 4; i++)); do
        snip=${SC_SNIPPETS[i]}
        sc_fit "$snip" 20
        line="$REPLY  ${SC_SNIP[$snip]}"
        if ((i == sel)); then
            sc_frame_text "$C_SEL" "$SC_G_SEL $line"
        else
            sc_frame_text "" "  $line"
        fi
    done
    sc_ui_end_frame "$SC_G_UPDOWN" move "$SC_G_ENTER" run a add e edit d delete esc back
}

# --- pager --------------------------------------------------------------------

# Loads file $1 into SC_PAGER_LINES (sanitized, capped), after header lines $2...
sc_pager_load() {
    local file=$1 line n=0
    shift
    SC_PAGER_LINES=("$@")
    while IFS= read -r line || [[ -n $line ]]; do
        if ((++n > 5000)); then
            SC_PAGER_LINES+=("[output truncated after 5000 lines]")
            break
        fi
        sc_sanitize "$line"
        SC_PAGER_LINES+=("$REPLY")
    done <"$file"
}

sc_view_pager() {
    local title=$1 top=0 dirty=1 h max i n
    while :; do
        sc_ui_check_resize && dirty=1
        n=${#SC_PAGER_LINES[@]}
        h=$((SC_ROWS - 3))
        max=$((n - h))
        ((max < 0)) && max=0
        ((top > max)) && top=$max
        if ((dirty)); then
            if sc_ui_begin_frame "$title" "$((n ? top + 1 : 0))-$((top + h < n ? top + h : n))/$n"; then
                for ((i = top; i < n && i < top + h; i++)); do
                    sc_frame_text "" " ${SC_PAGER_LINES[i]}"
                done
                sc_ui_end_frame "$SC_G_UPDOWN" scroll PgUp/PgDn page g/G top/bottom esc back
            fi
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        case $SC_KEY in
            UP | k) ((top > 0)) && ((top--)) ;;
            DOWN | j) ((top < max)) && ((top++)) ;;
            PGUP) top=$((top - h < 0 ? 0 : top - h)) ;;
            PGDN | ' ') top=$((top + h > max ? max : top + h)) ;;
            HOME | g) top=0 ;;
            END | G) top=$max ;;
            ESC | q | LEFT | h) return 0 ;;
        esac
    done
}

sc_view_help() {
    mapfile -t SC_PAGER_LINES <<EOF
scat $SC_VERSION - keyboard reference

Everywhere
  Up/Down, j/k        move selection        PgUp/PgDn, g/G   page, top/bottom
  Enter               open / confirm        Esc, q           back / quit
  Ctrl-C              quit immediately      Ctrl-Z           suspend (fg)

Server list
  a  add server       e  edit       d  delete      J/K  move down/up
  s  interactive ssh  r  refresh    ?  this help
  With groups: sorted by group and name; J/K reorders only without groups.

Server detail
  p  processes        s  ssh        x  snippets    e  edit server
  m  modules          r  refresh
  Up/Down, j/k        scroll one row        PgUp/PgDn        scroll one page
  Home/End, g/G       top / bottom          position shown at bottom right

Processes
  c/m/p/n  sort by cpu / memory / pid / name       K  send SIGTERM (asks first)

Snippets
  Enter  run on this server (asks first)   a/e/d  add / edit / delete

Forms
  Enter  edit field (Enter accepts, Esc cancels)   s  save   t  test connection
  Esc  cancel the form
  Line editor: Left/Right, Home/End (Ctrl-A/E), Backspace/Del, Ctrl-U/Ctrl-K

Config: $SC_CONFIG_DIR
EOF
    sc_view_pager "Help"
}

# --- modules ------------------------------------------------------------------

sc_view_modules() {
    local name=$1 sel=0 dirty=1 n=${#SC_MODULES[@]} i
    if ((n == 0)); then
        sc_msg info "No modules installed. Docker and Kubernetes support are planned (lib/modules/)."
        return 0
    fi
    while :; do
        sc_ui_check_resize && dirty=1
        if ((dirty)); then
            if sc_ui_begin_frame "$name $SC_G_SEP modules" "$n available"; then
                for ((i = 0; i < n; i++)); do
                    if ((i == sel)); then
                        sc_frame_text "$C_SEL" "$SC_G_SEL ${SC_MODULE_LABEL[${SC_MODULES[i]}]}"
                    else
                        sc_frame_text "" "  ${SC_MODULE_LABEL[${SC_MODULES[i]}]}"
                    fi
                done
                sc_ui_end_frame "$SC_G_UPDOWN" move "$SC_G_ENTER" open esc back
            fi
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        if sc_ui_nav "$sel" "$n"; then
            sel=$REPLY
            continue
        fi
        case $SC_KEY in
            ENTER) "${SC_MODULE_VIEW[${SC_MODULES[sel]}]}" "$name" ;;
            ESC | q | LEFT | h) return 0 ;;
        esac
    done
}

# --- forms --------------------------------------------------------------------

# Generic form over SC_FORM_KEYS / SC_FORM_LABEL / SC_FORM_HINT / SC_FORM_VAL.
# Args: title, validator (key value), submit function, optional handler for
# extra keys, then extra footer hint pairs. Returns 0 when saved.
sc_form_run() {
    local title=$1 validate=$2 submit=$3 extra=$4 sel=0 dirty=1 changed=0 n key v i
    shift 4
    n=${#SC_FORM_KEYS[@]}
    while :; do
        sc_ui_check_resize && dirty=1
        if ((dirty)); then
            sc_draw_form "$title" "$sel" "$@"
            dirty=0
        fi
        sc_read_key 0.5 || continue
        dirty=1
        SC_MSG=
        case $SC_KEY in
            UP | k) ((sel > 0)) && ((sel--)) ;;
            DOWN | j | TAB) ((sel < n - 1)) && ((sel++)) ;;
            ENTER)
                ((SC_ROWS >= SC_MIN_ROWS && SC_COLS >= SC_MIN_COLS)) || continue
                key=${SC_FORM_KEYS[sel]}
                sc_ui_edit_line $((2 + sel)) 20 $((SC_COLS - 21)) "${SC_FORM_VAL[$key]}" || continue
                sc_trim "$REPLY"
                v=$REPLY
                [[ $v != "${SC_FORM_VAL[$key]}" ]] && changed=1
                SC_FORM_VAL[$key]=$v
                if "$validate" "$key" "$v"; then
                    ((sel < n - 1)) && ((sel++))
                else
                    sc_msg error "${SC_FORM_LABEL[$key]}: $SC_ERR"
                fi
                ;;
            s | $'\x13')
                SC_FORM_ERRKEY=
                if "$submit"; then
                    return 0
                fi
                sc_msg error "$SC_ERR"
                for i in "${!SC_FORM_KEYS[@]}"; do
                    [[ ${SC_FORM_KEYS[i]} == "$SC_FORM_ERRKEY" ]] && sel=$i
                done
                ;;
            ESC | q)
                if ((changed)) && ! sc_ui_confirm "Discard changes?"; then
                    continue
                fi
                return 1
                ;;
            *) [[ -n $extra ]] && "$extra" "$SC_KEY" ;;
        esac
    done
}

sc_draw_form() {
    local title=$1 sel=$2 i key val style
    shift 2
    sc_ui_begin_frame "$title" "" || return
    sc_frame_add ""
    for i in "${!SC_FORM_KEYS[@]}"; do
        key=${SC_FORM_KEYS[i]}
        sc_fit "${SC_FORM_LABEL[$key]}" 16
        val=${SC_FORM_VAL[$key]}
        if ((i == sel)); then
            sc_fit "$SC_G_SEL $REPLY  ${val:-(empty)}" "$SC_COLS"
            SC_FRAME+=("$C_SEL$REPLY$C_RESET")
        elif [[ -z $val ]]; then
            SC_FRAME+=("  $REPLY  $C_DIM(empty)$C_RESET")
        else
            sc_frame_text "" "  $REPLY  $val"
        fi
    done
    sc_frame_add ""
    sc_frame_text "$C_DIM" "  ${SC_FORM_HINT[${SC_FORM_KEYS[sel]}]}"
    sc_ui_end_frame "$SC_G_UPDOWN" move "$SC_G_ENTER" "edit field" s save "$@" esc cancel
}

sc_form_server() {
    local orig=$1 f
    SC_FORM_ORIG=$orig SC_FORM_RESULT=
    SC_FORM_KEYS=(name "${SC_SERVER_FIELDS[@]}")
    SC_FORM_LABEL=([name]=Name [host]=Host [port]=Port [user]=User [identity]="Identity file"
        [jump]="Jump host" [group]=Group)
    SC_FORM_HINT=(
        [name]="Short unique label, e.g. web1 (letters, digits, . _ -)"
        [host]="Hostname, IP address or Host alias from ~/.ssh/config (required)"
        [port]="Optional. Default: 22 or the value from ~/.ssh/config"
        [user]="Optional. Default: from ~/.ssh/config or your local user name"
        [identity]="Optional private key, e.g. ~/.ssh/id_ed25519. Passwords are never stored - use keys/ssh-agent."
        [jump]="Optional ProxyJump host, e.g. admin@bastion.example.com:22"
        [group]="Optional; the list shows servers under group headings"
    )
    SC_FORM_VAL=([name]=$orig)
    for f in "${SC_SERVER_FIELDS[@]}"; do
        SC_FORM_VAL[$f]=${SC_SRV[$orig|$f]-}
    done
    [[ -n $orig ]] || SC_FORM_VAL[port]=
    if [[ -n $orig ]]; then
        sc_form_run "Edit $orig" sc_form_server_validate sc_form_server_submit sc_form_server_extra t test
    else
        sc_form_run "Add server" sc_form_server_validate sc_form_server_submit sc_form_server_extra t test
    fi
}

sc_form_server_validate() {
    case $1 in
        name) sc_valid_name "$2" ;;
        host) sc_valid_host "$2" ;;
        port) sc_valid_port "$2" ;;
        user) sc_valid_user "$2" ;;
        identity) sc_valid_identity "$2" ;;
        jump) sc_valid_jump "$2" ;;
        group) sc_valid_group "$2" ;;
    esac
}

sc_form_server_submit() {
    local k old=$SC_FORM_ORIG new=${SC_FORM_VAL[name]}
    for k in "${SC_FORM_KEYS[@]}"; do
        if ! sc_form_server_validate "$k" "${SC_FORM_VAL[$k]}"; then
            SC_FORM_ERRKEY=$k
            SC_ERR="${SC_FORM_LABEL[$k]}: $SC_ERR"
            return 1
        fi
    done
    if ! sc_server_upsert "$old" "$new" "${SC_FORM_VAL[host]}" "${SC_FORM_VAL[port]}" \
        "${SC_FORM_VAL[user]}" "${SC_FORM_VAL[identity]}" "${SC_FORM_VAL[jump]}" "${SC_FORM_VAL[group]}"; then
        SC_FORM_ERRKEY=name
        return 1
    fi
    if [[ -n $old && $old != "$new" ]]; then
        sc_metrics_clear "$old"
    fi
    sc_metrics_clear "$new"
    SC_FORM_RESULT=$new
    sc_msg info "Saved '$new'"
}

sc_form_server_extra() {
    [[ $1 == t ]] || return 0
    sc_ui_flash "Testing connection to ${SC_FORM_VAL[host]:-?}$SC_G_ELL"
    if sc_ssh_test "${SC_FORM_VAL[host]}" "${SC_FORM_VAL[port]}" "${SC_FORM_VAL[user]}" \
        "${SC_FORM_VAL[identity]}" "${SC_FORM_VAL[jump]}"; then
        sc_msg info "Test: $REPLY"
    else
        sc_msg error "Test: $REPLY"
    fi
}

sc_form_snippet() {
    local orig=$1
    SC_FORM_ORIG=$orig SC_FORM_RESULT=
    SC_FORM_KEYS=(name command)
    SC_FORM_LABEL=([name]=Name [command]=Command)
    SC_FORM_HINT=(
        [name]="Short unique label, e.g. disk-usage"
        [command]="Shell command run with 'sh' on the server, e.g. df -h"
    )
    SC_FORM_VAL=([name]=$orig [command]=${SC_SNIP[$orig]-})
    local title="Add snippet"
    [[ -n $orig ]] && title="Edit snippet $orig"
    sc_form_run "$title" sc_form_snippet_validate sc_form_snippet_submit ""
}

sc_form_snippet_validate() {
    case $1 in
        name) sc_valid_name "$2" ;;
        command) sc_valid_command "$2" ;;
    esac
}

sc_form_snippet_submit() {
    if ! sc_snippet_upsert "$SC_FORM_ORIG" "${SC_FORM_VAL[name]}" "${SC_FORM_VAL[command]}"; then
        [[ $SC_ERR == Command* ]] && SC_FORM_ERRKEY=command || SC_FORM_ERRKEY=name
        return 1
    fi
    SC_FORM_RESULT=${SC_FORM_VAL[name]}
    sc_msg info "Saved snippet '$SC_FORM_RESULT'"
}
