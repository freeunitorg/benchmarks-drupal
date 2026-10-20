#!/bin/sh
# Remove what killed runs leave behind: exited bench containers, containers of a run that
# is no longer current, and per-run networks with nothing attached. Only the names this
# suite creates are touched, so a neighbour's containers are never at risk.
#
#   prune-bench.sh [CURRENT_RUN_ID]
set -u
tab=$(printf '\t')
docker ps -a --format "{{.Names}}${tab}{{.Status}}${tab}{{.Label \"bench-run\"}}" | while IFS="$tab" read -r name status label; do
    case "$name" in
        rt-*|perf-*|recrec-*|db-bench-*|py-*|val-*|cnt|db-*-bench-*) ;;
        *) continue ;;
    esac
    case "$status" in
        Exited*|Created*|Dead*)
            docker rm -f "$name" >/dev/null 2>&1 && echo "rm container $name ($status)"
            continue
            ;;
    esac
    if [ $# -ge 1 ] && [ -n "${1:-}" ] && [ "$label" != "${1:-}" ]; then
        docker rm -f "$name" >/dev/null 2>&1 && echo "rm orphan $name (run $label)"
    fi
done
docker network ls --format '{{.Name}}' | grep -E '^dbnet-[0-9]+-(a|b)$' | while read -r n; do
    n_attached=$(docker network inspect -f '{{len .Containers}}' "$n" 2>/dev/null || echo 0)
    [ "$n_attached" = 0 ] && docker network rm "$n" >/dev/null 2>&1 && echo "rm network $n"
done
exit 0
