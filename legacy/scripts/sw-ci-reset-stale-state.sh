#!/usr/bin/env bash
# sw-ci-reset-stale-state.sh — Rewrite stale blocking statuses to `failed`.
#
# Purpose: when a CI pipeline run crashes mid-stage, .claude/pipeline-state.md
# is left with status `running`, `paused`, or `interrupted`. The next CI run's
# in-shell guard at sw-pipeline.sh:3189-3198 then refuses to start with
# "A pipeline is already in progress". This script rewrites those blocking
# statuses to `failed` so the next CI run is unblocked. `failed` is a valid
# persisted status (daemon-poll.sh:1145 already writes it, the resume guard at
# sw-pipeline.sh:3293 accepts it, the start-block list at :3193 excludes it).
#
# Usage: scripts/sw-ci-reset-stale-state.sh [path-to-state-file]
#   default state file: .claude/pipeline-state.md
#
# Output (stdout): the previous status value when a rewrite occurs; empty
# otherwise. Always exits 0 except for write errors.
#
# Idempotent: a state file with `failed`, `complete`, or `stuck_cycling` is
# untouched. A missing file is a no-op.
set -euo pipefail

state_file="${1:-.claude/pipeline-state.md}"

if [[ ! -f "$state_file" ]]; then
    exit 0
fi

status=$(sed -n 's/^status: *//p' "$state_file" | head -1 | tr -d '[:space:]')

case "$status" in
    running|paused|interrupted) ;;
    *) exit 0 ;;
esac

tmp=$(mktemp "${state_file}.tmp.XXXXXX")
if ! sed -E 's/^status:[[:space:]]*(running|paused|interrupted)[[:space:]]*$/status: failed/' \
        "$state_file" > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR: sed rewrite failed for $state_file" >&2
    exit 1
fi
mv "$tmp" "$state_file"

new_status=$(sed -n 's/^status: *//p' "$state_file" | head -1 | tr -d '[:space:]')
if [[ "$new_status" != "failed" ]]; then
    echo "ERROR: rewrite did not produce 'failed' (got '$new_status')" >&2
    exit 1
fi

echo "$status"
