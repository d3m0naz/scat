# shellcheck shell=bash
# Non-interactive commands: --list and --check, usable from scripts.

sc_print_warnings() {
    local w
    [[ -n ${SC_CONFIG_NOTE-} ]] && printf 'scat: %s\n' "$SC_CONFIG_NOTE" >&2
    for w in "${SC_CONFIG_WARNINGS[@]}"; do sc_warn "$w"; done
}

sc_server_target() {
    local name=$1 t=${SC_SRV[$1|host]}
    [[ -n ${SC_SRV[$name|user]} ]] && t=${SC_SRV[$name|user]}@$t
    [[ -n ${SC_SRV[$name|port]} ]] && t+=:${SC_SRV[$name|port]}
    [[ -n ${SC_SRV[$name|jump]} ]] && t+=" via ${SC_SRV[$name|jump]}"
    REPLY=$t
}

sc_cli_list() {
    local name
    if ((${#SC_SERVERS[@]} == 0)); then
        printf 'No servers configured (%s).\n' "$SC_SERVERS_FILE"
        return 0
    fi
    printf '%-20s %-40s %s\n' NAME TARGET GROUP
    for name in "${SC_SERVERS[@]}"; do
        sc_server_target "$name"
        printf '%-20s %-40s %s\n' "$name" "$REPLY" "${SC_SRV[$name|group]}"
    done
}

sc_print_summary() {
    local name=$1 d mnt size used total pct n=0 p iface rxv txv line
    sc_server_target "$name"
    if ! sc_metrics_online "$name"; then
        printf '%s (%s): OFFLINE - %s\n' "$name" "$REPLY" "${SC_M[$name|err]:-unknown error}"
        return
    fi
    printf '%s (%s): online\n' "$name" "$REPLY"
    sc_fmt_duration "${SC_M[$name|uptime]-}"
    printf '  %-9s %s (%s, kernel %s)\n' System "${SC_M[$name|distro]:-${SC_M[$name|os]}}" \
        "${SC_M[$name|hostname]}" "${SC_M[$name|kernel]}"
    printf '  %-9s %s\n' Uptime "$REPLY"
    printf '  %-9s %s (%s cores)\n' Load "${SC_M[$name|load]:--}" "${SC_M[$name|cores]:-?}"
    printf '  %-9s %s%%\n' CPU "${SC_M[$name|cpu_busy]:--}"
    sc_fmt_kib "${SC_M[$name|mem_used]-}"; used=$REPLY
    sc_fmt_kib "${SC_M[$name|mem_total]-}"; total=$REPLY
    sc_pct "${SC_M[$name|mem_used]-}" "${SC_M[$name|mem_total]-}" && pct=$REPLY || pct=-
    printf '  %-9s %s / %s (%s%%)\n' Memory "$used" "$total" "$pct"
    while IFS='|' read -r mnt size used pct; do
        [[ -n $mnt ]] || continue
        sc_fmt_kib "$used"; d=$REPLY
        sc_fmt_kib "$size"
        printf '  %-9s %s / %s (%s%%) %s\n' Disk "$d" "$REPLY" "$pct" "$mnt"
    done <<<"${SC_M[$name|disks]}"
    if [[ -n ${SC_M[$name|netifs]-} ]]; then
        while IFS='|' read -r iface rxv txv; do
            sc_netif_bar "$rxv" "$txv" 21
            line=$REPLY
            sc_netif_values "$rxv" "$txv"
            printf '  %-9s %-10s %s  %s\n' Network "$iface" "$line" "$REPLY"
        done <<<"${SC_M[$name|netifs]}"
    else
        printf '  %-9s %s\n' Network "${SC_M[$name|net_note]:-no network data}"
    fi
    printf '  Top processes (%s total):\n' "${SC_M[$name|proc_count]:-?}"
    sc_proc_header
    printf '    %s\n' "$REPLY"
    while IFS= read -r p && ((n++ < 5)); do
        [[ -n $p ]] || continue
        sc_proc_line "$p" 76
        printf '    %s\n' "${REPLY%"${REPLY##*[! ]}"}"
    done <<<"${SC_M[$name|procs]}"
}

sc_cli_check() {
    local name=$1
    if ! sc_server_exists "$name"; then
        sc_error "unknown server '$name' (see --list)"
        return 2
    fi
    sc_runtime_init || sc_die "cannot create runtime directory"
    trap 'sc_runtime_cleanup' EXIT
    sc_fetch_metrics "$name" "$SC_RUNTIME_DIR/$name.res"
    sc_metrics_load "$name" "$SC_RUNTIME_DIR/$name.res"
    sc_print_summary "$name"
    sc_metrics_online "$name"
}
