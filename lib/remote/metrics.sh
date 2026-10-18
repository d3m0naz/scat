# ServerCat metrics collector. Sent to the remote host and run with `sh -s`,
# so it must stay POSIX sh and must not depend on the remote login shell.
# Prints key=value lines; disk= and proc= lines repeat. Linux is fully
# supported, macOS and FreeBSD on a best-effort basis.

LC_ALL=C
export LC_ALL
PATH=$PATH:/usr/sbin:/sbin:/usr/bin:/bin
export PATH

os=$(uname -s 2>/dev/null)
echo "os=$os"
echo "hostname=$(hostname 2>/dev/null || uname -n)"
echo "kernel=$(uname -r 2>/dev/null)"

linux_cpu_sample() {
    awk '/^cpu /{print $2, $3, $4, $5, $6, $7, $8, $9; exit}' /proc/stat
}

linux_net_sample() {
    awk 'NR > 2 {
        line = $0; sub(/^[ \t]+/, "", line)
        split(line, a, ":"); iface = a[1]
        if (iface == "lo" || iface ~ /^(veth|docker|br-|virbr)/) next
        split(a[2], f, " "); rx += f[1]; tx += f[9]
    } END { printf "%.0f %.0f\n", rx, tx }' /proc/net/dev
}

# Prints net_* lines from two "rx tx" samples taken $3 seconds apart.
print_net() {
    echo "$1 $2 $3" | awk '{
        s = ($5 > 0) ? $5 : 1
        rx = ($3 - $1) / s; tx = ($4 - $2) / s
        if (rx < 0) rx = 0; if (tx < 0) tx = 0
        printf "net_rx=%.0f\nnet_tx=%.0f\nnet_rx_total=%.0f\nnet_tx_total=%.0f\n", rx, tx, $3, $4
    }'
}

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

    c1=$(linux_cpu_sample)
    n1=$(linux_net_sample)
    sleep 1
    c2=$(linux_cpu_sample)
    n2=$(linux_net_sample)
    echo "$c1 $c2" | awk '{
        t = 0; for (i = 1; i <= 8; i++) { d[i] = $(i + 8) - $i; t += d[i] }
        if (t <= 0) t = 1
        printf "cpu_busy=%.1f\ncpu_user=%.1f\ncpu_sys=%.1f\ncpu_iowait=%.1f\ncpu_steal=%.1f\n",
            100 * (t - d[4] - d[5]) / t, 100 * (d[1] + d[2]) / t,
            100 * (d[3] + d[6] + d[7]) / t, 100 * d[5] / t, 100 * d[8] / t
    }'
    print_net "$n1" "$n2" 1

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
    netsample() {
        netstat -ibn 2>/dev/null | awk '$3 ~ /^<Link/ && $1 !~ /^(lo|utun|awdl|llw|bridge|anpi|ap)/ {
            if (NF >= 11) { rx += $7; tx += $10 } else { rx += $6; tx += $9 }
        } END { printf "%.0f %.0f\n", rx, tx }'
    }
    t1=$(date +%s)
    n1=$(netsample)
    top -l 2 -n 0 -s 1 2>/dev/null | awk '/^CPU usage/ {u = $3; s = $5; i = $7}
        END { gsub(/%/, "", u); gsub(/%/, "", s); gsub(/%/, "", i)
              if (i != "") printf "cpu_busy=%.1f\ncpu_user=%.1f\ncpu_sys=%.1f\n", 100 - i, u, s }'
    n2=$(netsample)
    print_net "$n1" "$n2" $(($(date +%s) - t1))

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
