# ServerCat metrics collector. Sent to the remote host and run with `sh -s`,
# so it must stay POSIX sh and must not depend on the remote login shell.
# Prints key=value lines; netif=, disk= and proc= lines repeat. Linux is
# fully supported, macOS and FreeBSD on a best-effort basis.
#
# Rates (CPU, network) come from two samples taken 1 second apart.
# Network rates are per physical interface: netif=name|rx_bytes_per_s|tx_bytes_per_s.
# Hosts where that is not available print net_note= instead of numbers.

LC_ALL=C
export LC_ALL
PATH=$PATH:/usr/sbin:/sbin:/usr/bin:/bin
export PATH

NET_DEV=/proc/net/dev
SYS_NET=/sys/class/net

linux_cpu_sample() {
    awk '/^cpu /{print $2, $3, $4, $5, $6, $7, $8, $9; exit}' /proc/stat
}

# Name patterns of virtual interfaces; never shown even if they look physical.
VIRTUAL_IF='^(lo|veth|docker|br-|bridge|virbr|vnet|tun|tap|wg|ppp|vxlan|flannel|cni|cali|cilium|kube|tailscale|zt|dummy|bond|team|ifb|sit|gre|ip6|ipip|macvlan|macvtap|lxc|lxd|utun|awdl|llw|anpi|ap|gif|stf)'

# Physical interfaces on Linux, space separated. A real NIC has a "device"
# link in sysfs (PCI, USB, SDIO or platform bus); bridges, veth, tunnels and
# docker interfaces do not. Without sysfs, fall back to the usual NIC names.
linux_phys_ifaces() {
    for i in $(awk 'NR > 2 { sub(/^[ \t]+/, ""); sub(/:.*/, ""); print }' "$NET_DEV"); do
        echo "$i" | grep -Eq "$VIRTUAL_IF" && continue
        if [ -d "$SYS_NET" ]; then
            [ -e "$SYS_NET/$i/device" ] || continue
        else
            echo "$i" | grep -Eq '^(eth|en|wl|ww|em|ib)[a-z0-9]*$' || continue
        fi
        printf '%s ' "$i"
    done
}

# "name rx_bytes tx_bytes" for each interface listed in $1.
linux_net_sample() {
    awk -v want=" $1 " 'NR > 2 {
        line = $0; sub(/^[ \t]+/, "", line)
        i = index(line, ":"); name = substr(line, 1, i - 1)
        if (index(want, " " name " ") == 0) next
        split(substr(line, i + 1), f, " "); print name, f[1], f[9]
    }' "$NET_DEV"
}

# Prints netif= lines from two samples ("name rx tx" lines) taken $3 seconds
# apart, in the order of the second sample; net_note= if there are none.
print_netifs() {
    { printf '%s\n' "$1" | sed 's/^/1 /'; printf '%s\n' "$2" | sed 's/^/2 /'; } | awk -v s="$3" '
        NF == 4 && $2 ~ /^[A-Za-z0-9._@-]+$/ {
            if ($1 == 1) { rx[$2] = $3; tx[$2] = $4; next }
            if (!($2 in rx)) next
            if (s <= 0) s = 1
            r = ($3 - rx[$2]) / s; t = ($4 - tx[$2]) / s
            if (r < 0) r = 0; if (t < 0) t = 0
            printf "netif=%s|%.0f|%.0f\n", $2, r, t; n++
        }
        END { if (!n) print "net_note=no physical network interface found" }'
}

# Physical interfaces on macOS are en0, en1, ...: "name rx_bytes tx_bytes".
darwin_net_sample() {
    netstat -ibn 2>/dev/null | awk '$3 ~ /^<Link/ && $1 ~ /^en[0-9]+$/ && !seen[$1]++ {
        if (NF >= 11) print $1, $7, $10; else print $1, $6, $9
    }'
}

# Only collect when run as the script, not when sourced by the tests.
[ -n "${SERVERCAT_METRICS_LIB-}" ] && return 0

os=$(uname -s 2>/dev/null)
echo "os=$os"
echo "hostname=$(hostname 2>/dev/null || uname -n)"
echo "kernel=$(uname -r 2>/dev/null)"

bsd_common() {
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\).*/\1/p')
    [ -n "$boot" ] && echo "uptime=$(($(date +%s) - boot))"
    echo "load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2, $3, $4}')"
    echo "cores=$(sysctl -n hw.ncpu 2>/dev/null)"
}

case $os in
Linux)
    [ -r /etc/os-release ] &&
        echo "distro=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | sed 's/^"//; s/"$//' | head -n 1)"
    read -r up _ </proc/uptime && echo "uptime=${up%.*}"
    read -r l1 l2 l3 _ </proc/loadavg && echo "load=$l1 $l2 $l3"
    echo "cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || nproc 2>/dev/null)"

    phys=$(linux_phys_ifaces)
    c1=$(linux_cpu_sample)
    n1=$(linux_net_sample "$phys")
    sleep 1
    c2=$(linux_cpu_sample)
    n2=$(linux_net_sample "$phys")
    echo "$c1 $c2" | awk '{
        t = 0; for (i = 1; i <= 8; i++) { d[i] = $(i + 8) - $i; t += d[i] }
        if (t <= 0) t = 1
        printf "cpu_busy=%.1f\ncpu_user=%.1f\ncpu_sys=%.1f\ncpu_iowait=%.1f\ncpu_steal=%.1f\n",
            100 * (t - d[4] - d[5]) / t, 100 * (d[1] + d[2]) / t,
            100 * (d[3] + d[6] + d[7]) / t, 100 * d[5] / t, 100 * d[8] / t
    }'
    print_netifs "$n1" "$n2" 1

    awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2; has = 1}
        /^MemFree:/ {f = $2} /^Buffers:/ {b = $2} /^Cached:/ {c = $2}
        /^SwapTotal:/ {st = $2} /^SwapFree:/ {sf = $2}
        END {
            if (!has) a = f + b + c
            printf "mem_total=%d\nmem_used=%d\nswap_total=%d\nswap_used=%d\n", t, t - a, st, st - sf
        }' /proc/meminfo
    ;;
Darwin)
    echo "distro=$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
    bsd_common
    # A separate 1 s window: the top run below takes an unknown time, and
    # date +%s is too coarse to measure it.
    n1=$(darwin_net_sample)
    sleep 1
    n2=$(darwin_net_sample)
    print_netifs "$n1" "$n2" 1
    top -l 2 -n 0 -s 1 2>/dev/null | awk '/^CPU usage/ {u = $3; s = $5; i = $7}
        END { gsub(/%/, "", u); gsub(/%/, "", s); gsub(/%/, "", i)
              if (i != "") printf "cpu_busy=%.1f\ncpu_user=%.1f\ncpu_sys=%.1f\n", 100 - i, u, s }'

    pagesize=$(sysctl -n hw.pagesize 2>/dev/null)
    total=$(sysctl -n hw.memsize 2>/dev/null)
    vm_stat 2>/dev/null | awk -v ps="$pagesize" -v total="$total" '
        /^Pages active/ {a = $NF} /^Pages wired down/ {w = $NF}
        /^Pages occupied by compressor/ {c = $NF}
        END { gsub(/\./, "", a); gsub(/\./, "", w); gsub(/\./, "", c)
              printf "mem_total=%d\nmem_used=%d\n", total / 1024, (a + w + c) * ps / 1024 }'
    sysctl -n vm.swapusage 2>/dev/null | awk '{
        t = $3; u = $6
        mult = (t ~ /G$/) ? 1048576 : 1024; sub(/[MG]$/, "", t); t *= mult
        mult = (u ~ /G$/) ? 1048576 : 1024; sub(/[MG]$/, "", u); u *= mult
        printf "swap_total=%d\nswap_used=%d\n", t, u
    }'
    ;;
*BSD | DragonFly)
    echo "distro=$(uname -sr)"
    bsd_common
    ps_bytes=$(sysctl -n hw.pagesize 2>/dev/null)
    total=$(sysctl -n hw.physmem 2>/dev/null)
    free=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null)
    inactive=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null)
    if [ -n "$total" ] && [ -n "$free" ]; then
        echo "mem_total=$((total / 1024))"
        echo "mem_used=$(((total - (free + ${inactive:-0}) * ps_bytes) / 1024))"
    fi
    echo "net_note=per-interface rates are not collected on $os"
    ;;
*)
    echo "net_note=network rates are not collected on ${os:-this system}"
    ;;
esac

# Locates the "NN%" column so filesystem names with spaces still parse.
df -P -k 2>/dev/null | awk 'NR > 1 {
    p = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { p = i; break }
    if (p < 5 || $(p - 3) == 0) next
    mnt = $(p + 1); for (i = p + 2; i <= NF; i++) mnt = mnt " " $i
    if ($1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|none|squashfs|devfs|map|proc|sysfs|efivarfs)$/) next
    if (mnt ~ /^\/(dev|proc|sys|run)(\/|$)/ || mnt ~ /^\/snap\// || mnt ~ /^\/private\/var\/(vm|folders)\//) next
    if (mnt ~ /^\/Volumes\/\.timemachine\//) next
    if (mnt ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/) next
    v = $p; sub(/%/, "", v)
    printf "disk=%s|%s|%s|%s\n", mnt, $(p - 3), $(p - 2), v
}' | head -n 20

echo "proc_count=$(ps -A -o pid= 2>/dev/null | wc -l | tr -d ' ')"
ps -A -o pid= -o user= -o pcpu= -o pmem= -o rss= -o comm= 2>/dev/null | awk '{
    c = $6; for (i = 7; i <= NF; i++) c = c " " $i
    printf "proc=%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, c
}' | sort -t'|' -k3,3 -rn | head -n 100

exit 0
