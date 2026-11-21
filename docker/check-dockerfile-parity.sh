#!/usr/bin/env bash
# Fails when docker/Dockerfile (UAT) and docker/prod/Dockerfile clone different components or build
# different component jars. The two files have no shared include, and twice a component landed in one
# only: database-darpan (prod lacked it until 1.5.0) and moqui-rules (DAR-BE-318). Refs may differ
# (UAT floats, prod pins); the component set and the extra jar tasks may not.
# Run from anywhere: docker/check-dockerfile-parity.sh
set -euo pipefail
cd "$(dirname "$0")/.."

components() { grep -oE '/moqui-framework/runtime/component/[A-Za-z0-9_-]+' "$1" | sed 's#.*/##' | sort -u; }
jar_tasks()  { grep -oE ':runtime:component:[A-Za-z0-9_-]+:jar' "$1" | sort -u; }

status=0
for kind in components jar_tasks; do
    if ! out=$(diff <("$kind" docker/Dockerfile) <("$kind" docker/prod/Dockerfile)); then
        echo "Dockerfile parity: $kind differ (< docker/Dockerfile, > docker/prod/Dockerfile):" >&2
        echo "$out" >&2
        status=1
    fi
done
[ "$status" -eq 0 ] && echo "Dockerfile parity: UAT and prod clone and build the same components."
exit "$status"
