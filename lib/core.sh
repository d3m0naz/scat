# shellcheck shell=bash
# Core helpers shared by all other files: messages, dependency check, string
# and number formatting, input validation and a timeout runner (macOS has no
# coreutils `timeout`).

SC_VERSION="0.2.0"
SC_ERR=

sc_die() {
    printf 'scat: %s\n' "$*" >&2
    exit 1
}

sc_warn() {
    printf 'scat: warning: %s\n' "$*" >&2
}

sc_error() {
    printf 'scat: error: %s\n' "$*" >&2
}

# Homebrew formula that provides a command, for install hints.
declare -gA SC_BREW_FORMULA=(
    [ssh]=openssh [tput]=ncurses [stty]=coreutils [awk]=gawk [sed]=gnu-sed
    [sort]=coreutils [mktemp]=coreutils [grep]=grep [pkill]=proctools
)

sc_check_deps() {
    local cmd missing=() formulas=()
    for cmd in ssh tput stty awk sed sort mktemp grep pkill; do
        command -v "$cmd" >/dev/null 2>&1 && continue
        missing+=("$cmd")
        formulas+=("${SC_BREW_FORMULA[$cmd]:-$cmd}")
    done
    ((${#missing[@]} == 0)) && return 0
    printf 'scat: missing required commands: %s\n' "${missing[*]}" >&2
    printf 'They normally ship with macOS. To install them with Homebrew:\n  brew install %s\n' \
        "${formulas[*]}" >&2
    return 1
}

# --- glyphs -------------------------------------------------------------------

sc_glyphs_init() {
    local charmap
    charmap=$(locale charmap 2>/dev/null)
    if [[ ${SC_SET[ascii]:-0} == 1 || $charmap != UTF-8 ]]; then
        SC_G_FULL='#' SC_G_EMPTY='.' SC_G_DOT='*' SC_G_HOLLOW='o' SC_G_ELL='~'
        SC_G_SEP='|' SC_G_SEL='>' SC_G_UPDOWN='^v' SC_G_RX='rx' SC_G_TX='tx' SC_G_ENTER='Enter' SC_G_HLINE='-' SC_G_TIMES='x'
        SC_G_EIGHTHS=()
    else
        SC_G_FULL='█' SC_G_EMPTY='░' SC_G_DOT='●' SC_G_HOLLOW='○' SC_G_ELL='…'
        SC_G_SEP='·' SC_G_SEL='▶' SC_G_UPDOWN='↑↓' SC_G_RX='↓' SC_G_TX='↑' SC_G_ENTER='⏎' SC_G_HLINE='─' SC_G_TIMES='×'
        # Partial cells for 1/8 .. 7/8 of a cell, indexed by eighths.
        SC_G_EIGHTHS=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')
    fi
}

# --- strings ------------------------------------------------------------------
# Helpers return their result in REPLY to avoid a subshell per call.

sc_trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    REPLY=$s
}

# Removes control characters (ESC included) so text from remote hosts cannot
# inject terminal escape sequences.
sc_sanitize() {
    local s=${1//$'\t'/    }
    REPLY=${s//[[:cntrl:]]/}
}

sc_repeat() {
    local s
    (($2 > 0)) || { REPLY=; return; }
    printf -v s '%*s' "$2" ''
    REPLY=${s// /"$1"}
}

# Pads or truncates to exactly $2 characters (character-aware in UTF-8).
sc_fit() {
    local s=$1 w=$2
    if ((w <= 0)); then
        REPLY=
    elif ((${#s} > w)); then
        REPLY="${s:0:w-1}${SC_G_ELL:-~}"
    else
        sc_repeat ' ' $((w - ${#s}))
        REPLY=$s$REPLY
    fi
}

sc_fit_right() {
    local s=$1 w=$2
    if ((${#s} >= w)); then
        sc_fit "$s" "$w"
    else
        sc_repeat ' ' $((w - ${#s}))
        REPLY=$REPLY$s
    fi
}

sc_expand_path() {
    if [[ $1 == "~" || $1 == "~/"* ]]; then
        REPLY=$HOME${1:1}
    else
        REPLY=$1
    fi
}

# --- numbers and formatting ---------------------------------------------------

# Truncates a decimal like "12.7" to an integer; fails on non-numbers.
sc_int() {
    [[ $1 =~ ^([0-9]+)(\.[0-9]+)?$ ]] || return 1
    REPLY=$((10#${BASH_REMATCH[1]}))
}

sc_pct() {
    [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] && (($2 > 0)) || return 1
    REPLY=$(($1 * 100 / $2))
    ((REPLY > 100)) && REPLY=100
    return 0
}

sc_fmt_duration() {
    local s=$1 d h m
    [[ $s =~ ^[0-9]+$ ]] || { REPLY=-; return; }
    d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
    if ((d)); then
        REPLY="${d}d ${h}h"
    elif ((h)); then
        REPLY="${h}h ${m}m"
    elif ((m)); then
        REPLY="${m}m"
    else
        REPLY="${s}s"
    fi
}

# KiB -> "512K", "1.5M", "12G" (binary units, one decimal below 100).
sc_fmt_kib() {
    local units=(K M G T P) i=0 t
    [[ $1 =~ ^[0-9]+$ ]] || { REPLY=-; return; }
    t=$((10#$1 * 10))
    while ((t >= 10240 && i < 4)); do
        t=$((t / 1024))
        ((i++))
    done
    if ((t >= 1000)); then
        REPLY="$((t / 10))${units[i]}"
    else
        REPLY="$((t / 10)).$((t % 10))${units[i]}"
    fi
}

# Bytes per second as megabytes per second (1 MB = 1,000,000 bytes), two
# decimals, rounded: 523000 -> "0.52 MB/s".
sc_fmt_mbs() {
    local h
    [[ $1 =~ ^[0-9]+$ ]] || { REPLY=-; return; }
    h=$(((10#$1 + 5000) / 10000))
    printf -v REPLY '%d.%02d MB/s' $((h / 100)) $((h % 100))
}

sc_fmt_bytes() {
    [[ $1 =~ ^[0-9]+$ ]] || { REPLY=-; return; }
    if (($1 < 1024)); then
        REPLY="${1}B"
    else
        sc_fmt_kib $(($1 / 1024))
    fi
}

# --- validation ---------------------------------------------------------------
# Each validator returns 1 and sets SC_ERR on invalid input.

sc_valid_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] && return 0
    SC_ERR="name must be 1-32 characters: letters, digits, '.', '_' or '-', starting with a letter or digit"
    return 1
}

sc_valid_host() {
    if [[ -z $1 ]]; then
        SC_ERR="host is required"
        return 1
    fi
    [[ $1 =~ ^[A-Za-z0-9_:%][A-Za-z0-9._:%-]{0,252}$ ]] && return 0
    SC_ERR="host must be a hostname, IP address or ~/.ssh/config alias"
    return 1
}

sc_valid_port() {
    [[ -z $1 ]] && return 0
    [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) && return 0
    SC_ERR="port must be a number between 1 and 65535"
    return 1
}

sc_valid_user() {
    [[ -z $1 || $1 =~ ^[A-Za-z_][A-Za-z0-9._@-]{0,63}$ ]] && return 0
    SC_ERR="user may contain letters, digits, '.', '_', '-' and '@'"
    return 1
}

# Syntax only; used when loading the config (the key may live on a volume
# that is not mounted right now).
sc_valid_identity_syntax() {
    [[ -z $1 ]] && return 0
    if [[ $1 == *[[:cntrl:]]* || ${#1} -gt 1024 ]]; then
        SC_ERR="identity file path is invalid"
        return 1
    fi
    if [[ $1 == *.pub ]]; then
        SC_ERR="identity must be the private key, not the .pub file"
        return 1
    fi
    return 0
}

sc_valid_identity() {
    sc_valid_identity_syntax "$1" || return 1
    [[ -z $1 ]] && return 0
    sc_expand_path "$1"
    [[ -f $REPLY && -r $REPLY ]] && return 0
    SC_ERR="identity file not found or not readable: $1"
    return 1
}

sc_valid_jump() {
    [[ -z $1 || $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._@:%,-]{0,252}$ ]] && return 0
    SC_ERR="jump host must look like [user@]host[:port], comma-separated for chains"
    return 1
}

sc_valid_group() {
    [[ $1 != *[[:cntrl:]]* ]] && ((${#1} <= 32)) && return 0
    SC_ERR="group must be at most 32 printable characters"
    return 1
}

sc_valid_command() {
    if [[ -z $1 ]]; then
        SC_ERR="command is required"
        return 1
    fi
    [[ $1 != *[[:cntrl:]]* ]] && ((${#1} <= 2000)) && return 0
    SC_ERR="command must be a single line of at most 2000 characters"
    return 1
}

sc_valid_int() {
    [[ $1 =~ ^[0-9]{1,6}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)) && return 0
    SC_ERR="must be a whole number between $2 and $3"
    return 1
}

# --- processes ----------------------------------------------------------------

# Runs "$@" with stdin from file $2 and kills it after $1 seconds.
# Returns the command's status, or 124 on timeout (like coreutils timeout).
sc_run_timeout() {
    local secs=$1 input=$2 pid wd rc
    shift 2
    "$@" <"$input" &
    pid=$!
    (
        trap 'kill "$sp" 2>/dev/null; exit 0' TERM
        sleep "$secs" &
        sp=$!
        wait "$sp"
        kill -TERM "$pid" 2>/dev/null
        exit 1
    ) </dev/null >/dev/null 2>&1 &
    wd=$!
    wait "$pid"
    rc=$?
    kill -TERM "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    (($? == 1)) && rc=124
    return "$rc"
}
