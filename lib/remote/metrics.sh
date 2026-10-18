# scat metrics collector. Sent to the remote host and run with `sh -s`,
# so it must stay POSIX sh and must not depend on the remote login shell.
# Prints key=value lines; netif=, disk= and proc= lines repeat. Linux is
# and FreeBSD (OPNsense) are fully supported, macOS on a best-effort basis.
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

# "name rx_bytes tx_bytes" from `netstat -ibn` output on stdin (macOS,
# FreeBSD), one line per interface from its <Link#n> row. The byte columns
# are located by their header and counted from the end of the line, because
# the Address column is empty for interfaces without a MAC address.
netstat_link_counters() {
    awk '$1 == "Name" {
            for (i = 1; i <= NF; i++) { if ($i == "Ibytes") ri = NF - i; if ($i == "Obytes") ro = NF - i }
            next
        }
        ri && $3 ~ /^<Link/ && !seen[$1]++ { print $1, $(NF - ri), $(NF - ro) }'
}

# Keeps the "name rx tx" lines of $2 whose name is in the space separated list $1.
pick_ifaces() {
    printf '%s\n' "$2" | awk -v want=" $1 " 'NF == 3 && index(want, " " $1 " ")'
}

# Physical interfaces on macOS are en0, en1, ...: "name rx_bytes tx_bytes".
darwin_net_sample() {
    netstat -ibn 2>/dev/null | netstat_link_counters | awk '$1 ~ /^en[0-9]+$/'
}

# kern.cp_time holds "user nice sys intr idle" ticks, summed over all CPUs.
bsd_cpu_sample() {
    sysctl -n kern.cp_time 2>/dev/null
}

bsd_cpu_print() {
    echo "$1 $2" | awk 'NF == 10 {
        t = 0; for (i = 1; i <= 5; i++) { d[i] = $(i + 5) - $i; t += d[i] }
        if (t <= 0) t = 1
        printf "cpu_busy=%.1f\ncpu_user=%.1f\ncpu_sys=%.1f\n",
            100 * (t - d[5]) / t, 100 * (d[1] + d[2]) / t, 100 * (d[3] + d[4]) / t
    }'
}

# Cloned FreeBSD interfaces (pf logging, IPsec, VLAN, lagg, OpenVPN, netgraph).
BSD_VIRTUAL_IF='^(pflog|pfsync|enc|lagg|epair|vlan|ovpn[cs]|ipsec|ng|pppoe|faith|ipfw|carp)[0-9]'

# Physical interfaces among the names in $1, space separated. A NIC driver
# instance (vtnet0, em0, igb0, ix0, re0, ue0) has a dev.<driver>.<unit> node
# in sysctl; cloned interfaces (lo, bridge, vlan, wg, tun, ...) have none.
# wlanN is a clone on top of the radio, but it carries the wireless traffic.
bsd_phys_ifaces() {
    for i in $1; do
        echo "$i" | grep -Eq "$VIRTUAL_IF|$BSD_VIRTUAL_IF" && continue
        case $i in
        wlan[0-9]*) ;;
        *[!A-Za-z0-9]*) continue ;;
        *)
            drv=$(echo "$i" | sed 's/[0-9]*$//')
            unit=${i#"$drv"}
            [ -n "$unit" ] && [ "$(sysctl -n "dev.$drv.$unit.%driver" 2>/dev/null)" = "$drv" ] || continue
            ;;
        esac
        printf '%s ' "$i"
    done
}

# Memory in KiB from the FreeBSD page counters; free and inactive pages count
# as available (ZFS ARC is wired memory and counts as used).
bsd_mem() {
    ps_bytes=$(sysctl -n hw.pagesize 2>/dev/null)
    total=$(sysctl -n hw.physmem 2>/dev/null)
    free=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null)
    inactive=$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null)
    if [ -n "$total" ] && [ -n "$free" ] && [ -n "$ps_bytes" ]; then
        echo "mem_total=$((total / 1024))"
        echo "mem_used=$(((total - (free + ${inactive:-0}) * ps_bytes) / 1024))"
    fi
}

# swapinfo -k: "Device 1K-blocks Used Avail Capacity", plus a Total row when
# there are several swap devices. No device rows means no swap.
bsd_swap() {
    out=$(swapinfo -k 2>/dev/null) || return 0
    printf '%s\n' "$out" | awk 'NR > 1 && $1 != "Total" { t += $2; u += $3 }
        END { printf "swap_total=%d\nswap_used=%d\n", t, u }'
}

# ZFS pools as "name used_bytes avail_bytes" (top-level dataset: used includes
# children and snapshots, used + avail is the usable size).
bsd_zfs_pools() {
    zfs list -Hp -d 0 -o name,used,avail 2>/dev/null
}

# disk= lines from `df -P -k` on stdin. Pseudo filesystems are skipped. ZFS
# datasets of the pools in $1 ("name used avail" lines, bytes) all share the
# pool's free space, so each pool is shown once as "<pool> (zfs)" instead.
#
# Repeated mounts of an already listed filesystem are left out, the first
# mount stays:
# - same source (Linux bind mounts, a share mounted twice);
# - same size, used and avail as an earlier row, for sources that are not
#   devices (/dev/...). That catches FreeBSD nullfs mounts, whose source is a
#   directory (/lib mounted at /var/unbound/lib), including nullfs mounts of a
#   ZFS dataset that is shown as its pool. Two different block devices are
#   never merged, even with equal numbers (e.g. two empty disks of one size).
print_disks() {
    awk -v zfs="$1" 'BEGIN {
        n = split(zfs, L, "\n")
        for (i = 1; i <= n; i++) {
            if (split(L[i], f, /[ \t]+/) != 3 || f[2] !~ /^[0-9]+$/ || f[3] !~ /^[0-9]+$/) continue
            pool[f[1]] = 1; size = int((f[2] + f[3]) / 1024); used = int(f[2] / 1024)
            if (size > 0) printf "disk=%s (zfs)|%d|%d|%d\n", f[1], size, used, int((used * 100 + size - 1) / size)
        }
    }
    NR > 1 {
        p = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { p = i; break }
        if (p < 5 || $(p - 3) == 0) next
        mnt = $(p + 1); for (i = p + 2; i <= NF; i++) mnt = mnt " " $i
        nums = $(p - 3) " " $(p - 2) " " $(p - 1)
        ds = $1; sub(/\/.*/, "", ds); if (ds in pool) { sizes[nums] = 1; next }
        if ($1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|none|squashfs|devfs|fdescfs|procfs|map|proc|sysfs|efivarfs)$/) next
        if (mnt ~ /^\/(dev|proc|sys|run)(\/|$)/ || mnt ~ /^\/snap\// || mnt ~ /^\/private\/var\/(vm|folders)\//) next
        if (mnt ~ /^\/Volumes\/\.timemachine\//) next
        if (mnt ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/) next
        src = $1; for (i = 2; i < p - 3; i++) src = src " " $i
        if (src in seen) next
        if (src !~ /^\/dev\// && nums in sizes) next
        seen[src] = 1; sizes[nums] = 1
        v = $p; sub(/%/, "", v)
        printf "disk=%s|%s|%s|%s\n", mnt, $(p - 3), $(p - 2), v
    }' | head -n 20
}

# proc= lines from `ps -o pid,user,pcpu,pmem,rss,comm` on stdin, busiest first.
# FreeBSD's "idle" kernel process accounts idle time as CPU (up to 100% per
# core), so it is left out there.
print_procs() {
    awk -v os="$1" '{
        if (os == "FreeBSD" && $2 == "root" && $6 == "idle" && NF == 6) next
        c = $6; for (i = 7; i <= NF; i++) c = c " " $i
        printf "proc=%s|%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5, c
    }' | sort -t'|' -k3,3 -rn | head -n 100
}

# Only collect when run as the script, not when sourced by the tests.
[ -n "${SCAT_METRICS_LIB-}" ] && return 0

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
FreeBSD)
    echo "distro=$(uname -sr)"
    bsd_common
    # -W: do not truncate long interface names.
    phys=$(bsd_phys_ifaces "$(netstat -ibnW 2>/dev/null | netstat_link_counters | awk '{ print $1 }')")
    c1=$(bsd_cpu_sample)
    n1=$(netstat -ibnW 2>/dev/null | netstat_link_counters)
    sleep 1
    c2=$(bsd_cpu_sample)
    n2=$(netstat -ibnW 2>/dev/null | netstat_link_counters)
    bsd_cpu_print "$c1" "$c2"
    print_netifs "$(pick_ifaces "$phys" "$n1")" "$(pick_ifaces "$phys" "$n2")" 1
    bsd_mem
    bsd_swap
    zfs_pools=$(bsd_zfs_pools)
    ;;
*BSD | DragonFly)
    echo "distro=$(uname -sr)"
    bsd_common
    bsd_mem
    echo "net_note=per-interface rates are not collected on $os"
    ;;
*)
    echo "net_note=network rates are not collected on ${os:-this system}"
    ;;
esac

# The disk filter locates the "NN%" column so names with spaces still parse.
df -P -k 2>/dev/null | print_disks "${zfs_pools-}"

echo "proc_count=$(ps -A -o pid= 2>/dev/null | wc -l | tr -d ' ')"
ps -A -o pid= -o user= -o pcpu= -o pmem= -o rss= -o comm= 2>/dev/null | print_procs "$os"

exit 0
