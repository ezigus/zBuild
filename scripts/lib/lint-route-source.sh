#!/usr/bin/env bash
# scripts/lib/lint-route-source.sh — route_to_model callers must load route.sh
# (#2063). This is a tree guard, not a runtime dependency resolver (#2065).
set -euo pipefail

plugins_root="${1:-}"
if [[ -z "$plugins_root" || ! -d "$plugins_root" ]]; then
    printf 'usage: %s <plugins-root>\n' "${BASH_SOURCE[0]}" >&2
    exit 2
fi

violations=0
while IFS= read -r -d '' plugin_sh; do
    # Ignore full-line comments, but keep inline references: a live command
    # followed by a comment is still a non-comment route_to_model reference.
    if ! awk '
        {
            line = $0
            sub(/^[[:space:]]*#.*/, "", line)
            if (line ~ /route_to_model/) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$plugin_sh"; then
        continue
    fi

    if ! awk '
        {
            line = $0
            sub(/^[[:space:]]*#.*/, "", line)
            if (line ~ /(^|[[:space:];])(source|\.)[[:space:]]+.*core\/router\/route\.sh/) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$plugin_sh"; then
        relative="${plugin_sh#"$plugins_root"/}"
        printf 'route-source violation: %s calls route_to_model but does not source core/router/route.sh\n' \
            "$relative" >&2
        violations=$((violations + 1))
    fi
done < <(find "$plugins_root" -type f -name plugin.sh -print0)

exit "$violations"
