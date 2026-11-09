# scat drive query (SMART), read only. Sent to the remote host, optionally
# after a first line NOSTANDBY=1, and run with `sh -s`; POSIX sh.
#
# Prints drives=0 without smartctl. Otherwise drives=1, then per whole disk
#   drive=<device>|<model>|<HDD|SSD|NVMe|->|<size in bytes>|<access>
#   smart=<device>|<one line of `smartctl -A` output>   (repeated)
# access: ok (asked with -n standby, sleeping disks are not woken),
# wakes (-n standby not allowed, asked without it), standby (asleep, not
# woken), denied (sudo does not allow smartctl -A).
#
# Without root, smartctl runs through `sudo -n`, which fails instead of
# asking for a password. A form that sudo refused is not tried again in the
# same run, so a missing rule causes one refusal per run, not one per disk.

LC_ALL=C
export LC_ALL
PATH=$PATH:/usr/sbin:/sbin:/usr/local/sbin:/usr/bin:/bin
export PATH
SYS_BLOCK=${SYS_BLOCK:-/sys/block}
DEV_DIR=${DEV_DIR:-/dev}

if ! command -v smartctl >/dev/null 2>&1; then
    echo drives=0
    exit 0
fi
echo drives=1
os=${DRIVES_OS:-$(uname -s 2>/dev/null)}
errf=$(mktemp 2>/dev/null) || errf=/dev/null
trap '[ "$errf" = /dev/null ] || rm -f "$errf"' EXIT
if [ "$(id -u)" = 0 ]; then SUDO=; else SUDO="sudo -n"; fi

# Whole disks: what `smartctl --scan` finds (no root needed) plus the usual
# names. Output is one "device<TAB>type" line per disk; type is the -d
# argument from the scan (megaraid,0, sat, cciss,0 ...) or empty. Linux NVMe
# controllers (/dev/nvme0) become their namespace (/dev/nvme0n1), the form
# smartctl and sudo rules use.
list_devs() {
    {
        smartctl --scan 2>/dev/null | awk '$1 ~ /^\/dev\// { t = ""; if ($2 == "-d") t = $3; print $1 "\t" t }'
        for d in "$DEV_DIR"/*; do
            [ -e "$d" ] || continue
            n=${d##*/}
            case $n in
            sd[a-z] | sd[a-z][a-z] | ada[0-9] | ada[0-9][0-9] | nvd[0-9] | nvd[0-9][0-9] | \
                nda[0-9] | nda[0-9][0-9] | da[0-9] | da[0-9][0-9] | \
                nvme[0-9] | nvme[0-9][0-9] | nvme[0-9]n[0-9] | nvme[0-9]n[0-9][0-9] | \
                nvme[0-9][0-9]n[0-9] | nvme[0-9][0-9]n[0-9][0-9])
                printf '/dev/%s\t\n' "$n" ;;
            esac
        done
    } | awk -F '\t' -v OFS='\t' -v linux="$([ "$os" = Linux ] && echo 1 || echo 0)" '
        linux == 1 && $1 ~ /^\/dev\/nvme[0-9][0-9]*$/ { $1 = $1 "n1" }
        !seen[$1]++
    '
}

# "model|kind|bytes" of disk $1 (a name like sda), without root.
disk_info() {
    case $os in
    FreeBSD)
        geom disk list "$1" 2>/dev/null | awk -v n="$1" '
            /^ *descr:/ { sub(/^ *descr: */, ""); m = $0 }
            /^ *rotationrate:/ { r = $2 }
            /^ *Mediasize:/ { s = $2 }
            END {
                k = "-"
                if (n ~ /^(nvd|nda)/) k = "NVMe"; else if (r == "0") k = "SSD"; else if (r ~ /^[0-9]+$/) k = "HDD"
                gsub(/\|/, "/", m); printf "%s|%s|%s\n", m, k, s
            }'
        ;;
    *)
        model=$(cat "$SYS_BLOCK/$1/device/model" 2>/dev/null | sed 's/^ *//; s/ *$//; s/|/\//g')
        rot=$(cat "$SYS_BLOCK/$1/queue/rotational" 2>/dev/null)
        sectors=$(cat "$SYS_BLOCK/$1/size" 2>/dev/null)
        case $1 in
        nvme*) kind=NVMe ;;
        *) case $rot in 1) kind=HDD ;; 0) kind=SSD ;; *) kind=- ;; esac ;;
        esac
        printf '%s|%s|%s\n' "$model" "$kind" "$(echo "$sectors" | awk '/^[0-9]+$/ { printf "%.0f", $1 * 512 }')"
        ;;
    esac
}

# True if the last smartctl call failed because sudo refused it (no rule,
# password needed, or no sudo at all).
refused() {
    [ -n "$SUDO" ] && grep -qi 'sudo' "$errf" 2>/dev/null
}

standby_ok=1
[ "${NOSTANDBY-}" = 1 ] && standby_ok=0
denied=0
tab=$(printf '\t')
devs=$(list_devs)
# The list is read from fd 3, so smartctl and sudo cannot eat it.
while IFS=$tab read -r dev dtype <&3; do
    [ -n "$dev" ] || continue
    info=$(disk_info "${dev##*/}")
    dopt=
    [ -n "$dtype" ] && dopt="-d $dtype"
    access=ok out=
    if [ "$denied" = 1 ]; then
        access=denied
    else
        if [ "$standby_ok" = 1 ]; then
            out=$($SUDO smartctl -n standby -A $dopt "$dev" 2>"$errf")
            if refused; then standby_ok=0; fi
        fi
        if [ "$standby_ok" = 0 ]; then
            out=$($SUDO smartctl -A $dopt "$dev" 2>"$errf")
            access=wakes
            if refused; then access=denied denied=1 out=; fi
        fi
        case $out in *"STANDBY mode"* | *"SLEEP mode"*) access=standby out= ;; esac
    fi
    printf 'drive=%s|%s|%s\n' "$dev" "$info" "$access"
    [ -n "$out" ] && printf '%s\n' "$out" | sed -n "/./s|^|smart=$dev\||p"
done 3<<EOF
$devs
EOF
exit 0
