# shellcheck shell=bash
# Configuration: INI-style files under ~/.config/scat for servers,
# snippets and settings. Files are parsed without eval and rewritten
# atomically with mode 600 (directory 700).

# Default config directory: $SC_CONFIG_DIR if set, else $XDG_CONFIG_HOME/scat
# (~/.config/scat). scat was called servercat before; when only the old
# servercat directory exists, it stays in use and SC_CONFIG_LEGACY names it.
sc_config_default_dir() {
    local base=${XDG_CONFIG_HOME:-$HOME/.config}
    SC_CONFIG_LEGACY=
    if [[ -n ${SC_CONFIG_DIR:-} ]]; then
        REPLY=$SC_CONFIG_DIR
    elif [[ ! -d $base/scat && -d $base/servercat ]]; then
        REPLY=$base/servercat SC_CONFIG_LEGACY=$base/servercat
    else
        REPLY=$base/scat
    fi
}

# Notice for the user when the old directory is in use (status 1 if not).
sc_config_legacy_note() {
    [[ -n $SC_CONFIG_LEGACY && $SC_CONFIG_DIR == "$SC_CONFIG_LEGACY" ]] || return 1
    REPLY="using the old config directory $SC_CONFIG_LEGACY; rename it to ${SC_CONFIG_LEGACY%/servercat}/scat"
    REPLY=${REPLY//"$HOME"/\~}
}

sc_config_default_dir
SC_CONFIG_DIR_DEFAULT=$REPLY
SC_CONFIG_DIR=$SC_CONFIG_DIR_DEFAULT
SC_SERVER_FIELDS=(host port user identity jump group)

declare -ga SC_SERVERS=() SC_SNIPPETS=() SC_CONFIG_WARNINGS=()
declare -gA SC_SRV=()  # "<name>|<field>" -> value
declare -gA SC_SNIP=() # snippet name -> command

declare -gA SC_SET=(
    [list_refresh]=15 [detail_refresh]=5 [connect_timeout]=5
    [command_timeout]=20 [snippet_timeout]=60 [multiplex]=1 [ascii]=0
)
declare -gA SC_SET_LIMITS=(
    [list_refresh]="5 3600" [detail_refresh]="2 3600" [connect_timeout]="1 60"
    [command_timeout]="5 600" [snippet_timeout]="5 3600" [multiplex]="0 1" [ascii]="0 1"
)
SC_SET_ORDER=(list_refresh detail_refresh connect_timeout command_timeout snippet_timeout multiplex ascii)

sc_config_paths() {
    SC_SERVERS_FILE=$SC_CONFIG_DIR/servers.conf
    SC_SNIPPETS_FILE=$SC_CONFIG_DIR/snippets.conf
    SC_SETTINGS_FILE=$SC_CONFIG_DIR/settings.conf
}

sc_config_warn() {
    SC_CONFIG_WARNINGS+=("$1")
}

# Creates the config directory and missing files, and tightens permissions.
sc_config_init() {
    local f
    sc_config_paths
    if [[ ! -d $SC_CONFIG_DIR ]]; then
        if ! (umask 077 && mkdir -p -- "$SC_CONFIG_DIR"); then
            SC_ERR="cannot create config directory $SC_CONFIG_DIR"
            return 1
        fi
    fi
    chmod 700 "$SC_CONFIG_DIR" 2>/dev/null
    if [[ ! -e $SC_SERVERS_FILE ]]; then
        sc_config_save_servers || return 1
    fi
    if [[ ! -e $SC_SNIPPETS_FILE ]]; then
        sc_snippets_seed_defaults
        sc_config_save_snippets || return 1
    fi
    if [[ ! -e $SC_SETTINGS_FILE ]]; then
        sc_config_write_atomic "$SC_SETTINGS_FILE" sc_config_emit_default_settings || return 1
    fi
    for f in "$SC_SERVERS_FILE" "$SC_SNIPPETS_FILE" "$SC_SETTINGS_FILE"; do
        chmod 600 "$f" 2>/dev/null
    done
    return 0
}

sc_config_load_all() {
    SC_CONFIG_WARNINGS=()
    sc_config_load_settings
    sc_config_load_servers
    sc_config_load_snippets
}

# Writes the output of function $2 to file $1 via a temp file + rename.
sc_config_write_atomic() {
    local file=$1 writer=$2 tmp
    if ! tmp=$(mktemp "${file%/*}/.${file##*/}.XXXXXX"); then
        SC_ERR="cannot write $file"
        return 1
    fi
    if "$writer" >"$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$file"; then
        return 0
    fi
    rm -f -- "$tmp"
    SC_ERR="cannot write $file"
    return 1
}

# Calls $2 <section> <line> for each [section] (non-zero return skips its keys)
# and $3 <section> <key> <value> <line> for each "key = value".
sc_ini_read() {
    local file=$1 on_section=$2 on_key=$3 line key val n=0 section= skip=1
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        ((n++))
        sc_trim "${line%$'\r'}"
        line=$REPLY
        [[ -z $line || $line == [\#\;]* ]] && continue
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            sc_trim "${BASH_REMATCH[1]}"
            section=$REPLY
            if "$on_section" "$section" "$n"; then skip=0; else skip=1; fi
        elif [[ $line == *=* ]]; then
            if [[ -z $section ]]; then
                sc_config_warn "${file##*/}:$n: key outside of a [section]"
                continue
            fi
            ((skip)) && continue
            sc_trim "${line%%=*}"
            key=${REPLY,,}
            sc_trim "${line#*=}"
            val=$REPLY
            "$on_key" "$section" "$key" "$val" "$n"
        else
            sc_config_warn "${file##*/}:$n: cannot parse line"
        fi
    done <"$file"
}

# --- servers ------------------------------------------------------------------

sc_config_load_servers() {
    SC_SERVERS=()
    SC_SRV=()
    sc_ini_read "$SC_SERVERS_FILE" _sc_server_section _sc_server_key
}

_sc_server_section() {
    local name=$1 f
    if ! sc_valid_name "$name"; then
        sc_config_warn "servers.conf:$2: skipping [$name]: $SC_ERR"
        return 1
    fi
    if [[ -n ${SC_SRV[$name|host]+x} ]]; then
        sc_config_warn "servers.conf:$2: duplicate server [$name] ignored"
        return 1
    fi
    SC_SERVERS+=("$name")
    for f in "${SC_SERVER_FIELDS[@]}"; do SC_SRV[$name|$f]=; done
}

_sc_server_key() {
    local name=$1 key=$2 val=$3 ok
    case $key in
        host) sc_valid_host "$val" ;;
        port) sc_valid_port "$val" ;;
        user) sc_valid_user "$val" ;;
        identity) sc_valid_identity_syntax "$val" ;;
        jump) sc_valid_jump "$val" ;;
        group) sc_valid_group "$val" ;;
        *)
            sc_config_warn "servers.conf:$4: unknown key '$key' ignored"
            return 0
            ;;
    esac
    ok=$?
    if ((ok != 0)); then
        sc_config_warn "servers.conf:$4: [$name] $key ignored: $SC_ERR"
        return 0
    fi
    SC_SRV[$name|$key]=$val
}

sc_config_emit_servers() {
    local name f
    printf '# scat servers. Rewritten by scat; comments are not preserved.\n'
    printf '# Authentication uses SSH keys or ssh-agent only - never put passwords here.\n'
    printf '# Keys: host (required), port, user, identity, jump, group\n'
    for name in "${SC_SERVERS[@]}"; do
        printf '\n[%s]\n' "$name"
        for f in "${SC_SERVER_FIELDS[@]}"; do
            [[ -n ${SC_SRV[$name|$f]} ]] && printf '%s = %s\n' "$f" "${SC_SRV[$name|$f]}"
        done
    done
    return 0
}

sc_config_save_servers() {
    sc_config_write_atomic "$SC_SERVERS_FILE" sc_config_emit_servers
}

sc_server_exists() {
    [[ -n ${SC_SRV[$1|host]+x} ]]
}

sc_server_index() {
    local i
    for i in "${!SC_SERVERS[@]}"; do
        [[ ${SC_SERVERS[i]} == "$1" ]] && { REPLY=$i; return 0; }
    done
    REPLY=-1
    return 1
}

# Validates all fields (syntax level) and returns the first error.
sc_server_validate() {
    local name=$1 host=$2 port=$3 user=$4 identity=$5 jump=$6 group=$7
    sc_valid_name "$name" || { SC_ERR="Name: $SC_ERR"; return 1; }
    sc_valid_host "$host" || { SC_ERR="Host: $SC_ERR"; return 1; }
    sc_valid_port "$port" || { SC_ERR="Port: $SC_ERR"; return 1; }
    sc_valid_user "$user" || { SC_ERR="User: $SC_ERR"; return 1; }
    sc_valid_identity_syntax "$identity" || { SC_ERR="Identity: $SC_ERR"; return 1; }
    sc_valid_jump "$jump" || { SC_ERR="Jump host: $SC_ERR"; return 1; }
    sc_valid_group "$group" || { SC_ERR="Group: $SC_ERR"; return 1; }
}

# Creates ($1 empty) or updates/renames server $1 and saves the file.
# Remaining args: name host port user identity jump group.
sc_server_upsert() {
    local orig=$1 name=$2 i f vals
    shift
    sc_server_validate "$@" || return 1
    shift
    vals=("$@")
    if [[ $name != "$orig" ]] && sc_server_exists "$name"; then
        SC_ERR="a server named '$name' already exists"
        return 1
    fi
    if [[ -z $orig ]]; then
        SC_SERVERS+=("$name")
    elif [[ $name != "$orig" ]]; then
        sc_server_index "$orig" || { SC_ERR="unknown server '$orig'"; return 1; }
        SC_SERVERS[REPLY]=$name
        for f in "${SC_SERVER_FIELDS[@]}"; do unset "SC_SRV[$orig|$f]"; done
    fi
    for i in "${!SC_SERVER_FIELDS[@]}"; do
        SC_SRV[$name|${SC_SERVER_FIELDS[i]}]=${vals[i]-}
    done
    sc_config_save_servers
}

sc_server_delete() {
    local name=$1 f
    sc_server_index "$name" || { SC_ERR="unknown server '$name'"; return 1; }
    SC_SERVERS=("${SC_SERVERS[@]:0:REPLY}" "${SC_SERVERS[@]:REPLY+1}")
    for f in "${SC_SERVER_FIELDS[@]}"; do unset "SC_SRV[$name|$f]"; done
    sc_config_save_servers
}

# Moves server $1 by $2 positions (-1 up, 1 down) in the list.
sc_server_move() {
    local i j tmp
    sc_server_index "$1" || return 1
    i=$REPLY j=$((REPLY + $2))
    ((j >= 0 && j < ${#SC_SERVERS[@]})) || return 1
    tmp=${SC_SERVERS[i]}
    SC_SERVERS[i]=${SC_SERVERS[j]}
    SC_SERVERS[j]=$tmp
    sc_config_save_servers
}

# --- snippets -----------------------------------------------------------------

sc_snippets_seed_defaults() {
    SC_SNIPPETS=(disk-usage memory top-memory listening-ports failed-units recent-errors)
    SC_SNIP=(
        [disk-usage]="df -h"
        [memory]="free -h 2>/dev/null || vm_stat"
        [top-memory]="ps aux | sort -rnk 4 | head -n 15"
        [listening-ports]="ss -tulpn 2>/dev/null || netstat -an | grep -i listen"
        [failed-units]="systemctl --failed --no-pager"
        [recent-errors]="journalctl -p err -n 50 --no-pager"
    )
}

sc_config_load_snippets() {
    SC_SNIPPETS=()
    SC_SNIP=()
    sc_ini_read "$SC_SNIPPETS_FILE" _sc_snippet_section _sc_snippet_key
}

_sc_snippet_section() {
    if ! sc_valid_name "$1"; then
        sc_config_warn "snippets.conf:$2: skipping [$1]: $SC_ERR"
        return 1
    fi
    if [[ -n ${SC_SNIP[$1]+x} ]]; then
        sc_config_warn "snippets.conf:$2: duplicate snippet [$1] ignored"
        return 1
    fi
    SC_SNIPPETS+=("$1")
    SC_SNIP[$1]=
}

_sc_snippet_key() {
    if [[ $2 != command ]]; then
        sc_config_warn "snippets.conf:$4: unknown key '$2' ignored"
    elif sc_valid_command "$3"; then
        SC_SNIP[$1]=$3
    else
        sc_config_warn "snippets.conf:$4: [$1] command ignored: $SC_ERR"
    fi
}

sc_config_emit_snippets() {
    local name
    printf '# scat snippets: saved shell commands, run via `sh` on the remote host.\n'
    printf '# Rewritten by scat; comments are not preserved.\n'
    for name in "${SC_SNIPPETS[@]}"; do
        printf '\n[%s]\ncommand = %s\n' "$name" "${SC_SNIP[$name]}"
    done
}

sc_config_save_snippets() {
    sc_config_write_atomic "$SC_SNIPPETS_FILE" sc_config_emit_snippets
}

sc_snippet_upsert() {
    local orig=$1 name=$2 cmd=$3 i
    sc_valid_name "$name" || { SC_ERR="Name: $SC_ERR"; return 1; }
    sc_valid_command "$cmd" || { SC_ERR="Command: $SC_ERR"; return 1; }
    if [[ $name != "$orig" && -n ${SC_SNIP[$name]+x} ]]; then
        SC_ERR="a snippet named '$name' already exists"
        return 1
    fi
    if [[ -z $orig ]]; then
        SC_SNIPPETS+=("$name")
    elif [[ $name != "$orig" ]]; then
        for i in "${!SC_SNIPPETS[@]}"; do
            [[ ${SC_SNIPPETS[i]} == "$orig" ]] && SC_SNIPPETS[i]=$name
        done
        unset "SC_SNIP[$orig]"
    fi
    SC_SNIP[$name]=$cmd
    sc_config_save_snippets
}

sc_snippet_delete() {
    local name=$1 i keep=()
    for i in "${SC_SNIPPETS[@]}"; do
        [[ $i == "$name" ]] || keep+=("$i")
    done
    SC_SNIPPETS=("${keep[@]}")
    unset "SC_SNIP[$name]"
    sc_config_save_snippets
}

# --- settings -----------------------------------------------------------------

sc_config_emit_default_settings() {
    cat <<'EOF'
# scat settings. Remove the leading '#' to change a value.
[settings]
# Seconds between automatic refreshes of the server list (5-3600)
# list_refresh = 15
# Seconds between refreshes of the detail and process views (2-3600)
# detail_refresh = 5
# ssh ConnectTimeout in seconds (1-60)
# connect_timeout = 5
# Hard limit for one metrics collection in seconds (5-600)
# command_timeout = 20
# Hard limit for running a snippet in seconds (5-3600)
# snippet_timeout = 60
# Reuse ssh connections between refreshes via ControlMaster (0/1)
# multiplex = 1
# Use plain ASCII instead of Unicode glyphs (0/1)
# ascii = 0
EOF
}

sc_config_load_settings() {
    sc_ini_read "$SC_SETTINGS_FILE" _sc_settings_section _sc_settings_key
}

_sc_settings_section() {
    [[ $1 == settings ]] && return 0
    sc_config_warn "settings.conf:$2: unknown section [$1] ignored"
    return 1
}

_sc_settings_key() {
    local limits=${SC_SET_LIMITS[$2]-}
    if [[ -z $limits ]]; then
        sc_config_warn "settings.conf:$4: unknown setting '$2' ignored"
    elif sc_valid_int "$3" ${limits}; then
        SC_SET[$2]=$((10#$3))
    else
        sc_config_warn "settings.conf:$4: $2 $SC_ERR"
    fi
}
