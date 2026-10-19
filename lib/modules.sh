# shellcheck shell=bash
# Extension point for feature modules (Docker; planned: Kubernetes pods).
#
# A module is a file lib/modules/<id>.sh. It keeps all of its functions in
# its own namespace (mod_<id>_*) and registers itself when sourced:
#
#     sc_module_register <id> <label> <view-function>
#
# With an empty view function the module has no entry under 'm' and only
# works through the hooks below.
#
# The view function is called with the server name from the server detail
# view (key 'm'). It runs its own key loop with the ui helpers and should
# run remote commands via sc_ssh_run_script so they share BatchMode,
# timeouts and connection multiplexing. See lib/modules/README.md.
#
# Optional functions a module may define (NAME is the server name):
#   mod_<id>_available NAME   status 0 if the module applies to that server,
#                             otherwise a short reason in REPLY; without it
#                             the module is always offered under 'm'
#   mod_<id>_detail_tick NAME called on every pass of the detail view loop
#                             (start background queries, load results);
#                             status 0 means the view needs a redraw
#   mod_<id>_detail_draw NAME appends rows below the processes of the detail
#                             view; the processes shrink to SC_DET_MOD_PROCS
#                             rows when a module adds any
#   mod_<id>_detail_after_disks NAME  appends a section (with its trailing
#                             blank row) right after Disks in the detail view
#   mod_<id>_detail_refresh NAME  'r' in the detail view
#   mod_<id>_list_tick        called on every pass of the server list loop;
#                             status 0 means the list needs a redraw
#   mod_<id>_list_status NAME status 0 if the STATUS cell of the server list
#                             should show REPLY instead of the OS, in colour
#                             SC_MOD_STATUS_C (first module wins)
#   mod_<id>_cleanup          on exit: stop background jobs

declare -ga SC_MODULES=() SC_MODULES_AVAIL=()
declare -gA SC_MODULE_LABEL=() SC_MODULE_VIEW=()

sc_module_register() {
    local id=$1 label=$2 view=$3
    if [[ ! $id =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
        sc_warn "module id '$id' is invalid"
        return 1
    fi
    # An empty view: the module only uses hooks and has no entry under 'm'.
    if [[ -n $view ]] && ! declare -F "$view" >/dev/null; then
        sc_warn "module '$id': view function '$view' is not defined"
        return 1
    fi
    [[ -n ${SC_MODULE_VIEW[$id]+x} ]] || SC_MODULES+=("$id")
    SC_MODULE_LABEL[$id]=$label
    SC_MODULE_VIEW[$id]=$view
}

sc_modules_load() {
    local f
    for f in "$SC_ROOT"/lib/modules/*.sh; do
        [[ -f $f ]] || continue
        # shellcheck source=/dev/null
        source "$f" || sc_warn "failed to load module $f"
    done
}

# Fills SC_MODULES_AVAIL with the modules that apply to server $1; REPLY
# holds the reasons of the others, separated by "; ".
sc_modules_for() {
    local name=$1 id reasons=()
    SC_MODULES_AVAIL=()
    for id in "${SC_MODULES[@]}"; do
        [[ -n ${SC_MODULE_VIEW[$id]} ]] || continue
        if ! declare -F "mod_${id}_available" >/dev/null || "mod_${id}_available" "$name"; then
            SC_MODULES_AVAIL+=("$id")
        else
            reasons+=("$REPLY")
        fi
    done
    local IFS=';'
    REPLY=${reasons[*]}
    REPLY=${REPLY//;/; }
}

# Calls mod_<id>_<hook> NAME for every module that defines it; status 0 if
# any of them returned 0.
sc_modules_hook() {
    local hook=$1 name=${2-} id rc=1
    for id in "${SC_MODULES[@]}"; do
        declare -F "mod_${id}_$hook" >/dev/null || continue
        "mod_${id}_$hook" "$name" && rc=0
    done
    return "$rc"
}

# STATUS text of server $1 in the list from the first module that has one;
# REPLY and SC_MOD_STATUS_C as set by that module.
sc_modules_list_status() {
    local id
    for id in "${SC_MODULES[@]}"; do
        declare -F "mod_${id}_list_status" >/dev/null || continue
        "mod_${id}_list_status" "$1" && return 0
    done
    return 1
}
