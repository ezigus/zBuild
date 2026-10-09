#!/usr/bin/env bash
# ci-reconcile-state.sh — Reconcile a WIP pipeline-state.md after a killed CI job.
#
# Scope: rewrites `running` and `paused` → `interrupted`. These are always
# stale in CI (a graceful exit would have set `interrupted` itself).
# `failed`, `interrupted`, `complete`, `stuck_cycling` are NOT rewritten.
#
# Outputs to stdout: comma-separated list of stages that completed, read from
# the YAML `stages:` block only. The `## Log` section is intentionally ignored:
# it is human-readable and can contain transient failed-attempt entries from
# interrupted runs. The YAML block is written atomically by write_state() on
# each mark_stage_complete() call and is the single authoritative source.
# pipeline-state.md is the authoritative record — written atomically by
# mark_stage_complete() on each successful stage exit. Returns completed stages
# for any resumable status so that a pipeline resumed from any state correctly
# skips already-completed work.
#
# Returns empty string only when:
#   - the file does not exist
#   - status is `complete` (re-run should start fresh)
#   - no completed stages are found in the YAML block
#
# Side effect: rewrites `status:` line atomically via tmp+mv when running/paused.
set -euo pipefail

ci_reconcile_state() {
    local state_file="${1:?usage: ci_reconcile_state <state_file>}"
    [[ -f "$state_file" ]] || { echo ""; return 0; }

    local status
    status="$(sed -n 's/^status: *//p' "$state_file" | head -1 | tr -d '[:space:]')"

    # Rewrite running/paused → interrupted (always stale in CI).
    case "$status" in
        running|paused)
            local tmp
            tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
            sed -E 's/^status:[[:space:]]*(running|paused)[[:space:]]*$/status: interrupted/' \
                "$state_file" > "$tmp" && mv "$tmp" "$state_file"
            ;;
        complete)
            # Pipeline completed — do not emit stages; a re-run should start fresh.
            echo ""; return 0
            ;;
    esac

    # Extract completed stages from the YAML `stages:` block only.
    # The `## Log` section is intentionally not read: it can contain transient
    # failed-attempt lines from interrupted runs. The YAML block is written
    # atomically by write_state() and is the single authoritative source.
    # POSIX awk only — no gawk extensions.
    awk '
        /^stages:[[:space:]]*$/ { in_stages=1; next }

        # YAML stages block ends at the first non-indented non-empty line
        in_stages && /^[^[:space:]]/ { in_stages=0 }

        # YAML source: "  <stage>: complete"
        in_stages && /^[[:space:]]+[A-Za-z0-9_]+:[[:space:]]+complete/ {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/:[[:space:]]+complete.*$/, "", line)
            if (!(line in seen)) { seen[line]=1; out = (out=="" ? line : out","line) }
        }

        END { print out }
    ' "$state_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0:-}" ]]; then
    ci_reconcile_state "$@"
fi
