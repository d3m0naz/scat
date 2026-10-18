# shellcheck shell=bash
# Extension point for feature modules (planned: Docker, Kubernetes pods).
#
# A module is a file lib/modules/<id>.sh. It keeps all of its functions in
# its own namespace (mod_<id>_*) and registers itself when sourced:
#
#     sc_module_register <id> <label> <view-function>
#
# The view function is called with the server name from the server detail
# view (key 'm'). It runs its own key loop with the ui helpers and should
# run remote commands via sc_ssh_run_script so they share BatchMode,
# timeouts and connection multiplexing. See lib/modules/README.md.

declare -ga SC_MODULES=()
declare -gA SC_MODULE_LABEL=() SC_MODULE_VIEW=()

sc_module_register() {
    local id=$1 label=$2 view=$3
    if [[ ! $id =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
        sc_warn "module id '$id' is invalid"
        return 1
    fi
    if ! declare -F "$view" >/dev/null; then
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
