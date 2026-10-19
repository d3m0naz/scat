# scat Docker query, read only. Sent to the remote host after a first line
# MODE=ps or MODE=full and run with `sh -s`, so it must stay POSIX sh.
#
# Prints docker=0 when there is no docker client. Otherwise docker=1, then
# one ps=<json> line per container from `docker ps -a`, and with MODE=full
# one stats=<json> line per running container from `docker stats
# --no-stream`. A failing docker command prints ps_err= or stats_err= with
# the first line of its error message. Nothing here changes a container.

LC_ALL=C
export LC_ALL
PATH=$PATH:/usr/local/bin:/snap/bin:/usr/sbin:/sbin:/usr/bin:/bin
export PATH

# Runs `docker <args>` and prefixes each non-empty output line with "$1=";
# on failure prints "$1_err=<first line of stderr>" and returns 1.
query() {
    tag=$1
    shift
    if out=$(docker "$@" 2>"$errf"); then
        printf '%s\n' "$out" | sed -n "/./s/^/$tag=/p"
    else
        printf '%s_err=%s\n' "$tag" "$(sed -n '/./{p;q;}' "$errf" 2>/dev/null)"
        return 1
    fi
}

if ! command -v docker >/dev/null 2>&1; then
    echo docker=0
    exit 0
fi
echo docker=1
errf=$(mktemp 2>/dev/null) || errf=/dev/null
trap '[ "$errf" = /dev/null ] || rm -f "$errf"' EXIT

# {{json .}} gives the same lines as --format json and also works with
# Docker versions before 23.
query ps ps -a --format '{{json .}}' || exit 0
if [ "${MODE-}" = full ]; then
    query stats stats --no-stream --format '{{json .}}'
fi
exit 0
