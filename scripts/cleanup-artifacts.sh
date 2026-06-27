#!/usr/bin/env bash
# Operator CLI to prune the plan-context cache and per-run state dirs (#1052, Pillar F).
# Both stores grow unbounded: the cross-run plan-context cache
# ($ZBUILD_PLAN_CONTEXT_DIR) introduced by this issue, and the per-run state dirs
# ($HOME/.zbuild/state/runs/<run_id>). This prunes both, default-safe (dry-run
# unless --force), path-sanitized (refuses anything outside the two roots), and
# never touches the currently-active $ZBUILD_RUN_ID.
#
# Usage: bash scripts/cleanup-artifacts.sh [flags]   (see --help)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Roots we are allowed to touch. Resolve to absolute (canonical) paths so the
# containment guard below can never be fooled by .. or a symlink escape.
PLAN_CONTEXT_DIR="${ZBUILD_PLAN_CONTEXT_DIR:-$HOME/.zbuild/plan-context}"
STATE_ROOT="$HOME/.zbuild/state"

# Source plan-context.sh if a sibling agent has written it (for plan_context_gc
# parity), but DEGRADE GRACEFULLY — this CLI implements its own pruning so the
# unit test does not hard-depend on that file existing.
if [[ -f "$REPO_ROOT/scripts/lib/plan-context.sh" ]]; then
    # shellcheck source=lib/plan-context.sh disable=SC1091
    source "$REPO_ROOT/scripts/lib/plan-context.sh" 2>/dev/null || true
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
OLDER_THAN="14d"
STATUS_FILTER="complete"   # complete | scope_too_large | all
REPO_FILTER=""
ISSUE_FILTER=""
MAX_ENTRIES=""
DRY_RUN=true               # default-safe: list only
FORCE=false
WIPE_ALL=false

# ── Running totals (summary) ─────────────────────────────────────────────────
REMOVED_COUNT=0
BYTES_FREED=0

usage() {
    cat <<'EOF'
Usage: cleanup-artifacts.sh [flags]

Prune the plan-context cache ($ZBUILD_PLAN_CONTEXT_DIR, default ~/.zbuild/plan-context)
and per-run state dirs ($HOME/.zbuild/state/runs/<run_id>).

Flags:
  --older-than <Nd|Nh>   Prune entries older than N days/hours by mtime
                         (and .created_at for context JSON when present). Default: 14d.
  --status <s>           Which context statuses to prune: complete | scope_too_large | all.
                         Default: complete (keeps resumable scope_too_large entries).
  --repo <repo_id>       Restrict to one repo namespace subtree.
  --issue <scope_key>    Restrict to one issue/scope namespace subtree.
  --max-entries <n>      Keep newest N entries per <repo_id>/<scope_key> (LRU by mtime),
                         delete older.
  --dry-run              Print what WOULD be removed; delete nothing (DEFAULT-SAFE).
  --force                Actually delete (required for any deletion).
  --all                  Full wipe of the plan-context cache dir (still requires --force).
  -h, --help             Show this help.

Safety:
  Refuses to delete anything outside $ZBUILD_PLAN_CONTEXT_DIR or $HOME/.zbuild/state.
  Never deletes the directory of the currently-active $ZBUILD_RUN_ID.
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --older-than)
            OLDER_THAN="${2:?--older-than needs a value}"; shift 2 ;;
        --status)
            STATUS_FILTER="${2:?--status needs a value}"; shift 2 ;;
        --repo)
            REPO_FILTER="${2:?--repo needs a value}"; shift 2 ;;
        --issue)
            ISSUE_FILTER="${2:?--issue needs a value}"; shift 2 ;;
        --max-entries)
            MAX_ENTRIES="${2:?--max-entries needs a value}"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --force)
            FORCE=true; DRY_RUN=false; shift ;;
        --all)
            WIPE_ALL=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "cleanup-artifacts.sh: unknown argument: $1" >&2
            usage >&2
            exit 2 ;;
    esac
done

case "$STATUS_FILTER" in
    complete|scope_too_large|all) ;;
    *) echo "cleanup-artifacts.sh: invalid --status '$STATUS_FILTER' (complete|scope_too_large|all)" >&2; exit 2 ;;
esac

# ── Helpers ──────────────────────────────────────────────────────────────────

# Resolve a path to its canonical absolute form without requiring realpath -m.
_canonical() {
    local p="$1"
    if [[ -e "$p" ]]; then
        # cd into the dir and re-attach the basename so symlinks in the path are
        # resolved; refuse silently (empty) on failure.
        local dir base
        dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 0
        base="$(basename "$p")"
        printf '%s/%s\n' "${dir%/}" "$base"
    else
        printf '%s\n' "$p"
    fi
}

# Convert --older-than (Nd|Nh|N) to seconds.
_duration_to_secs() {
    local d="$1" n unit
    if [[ "$d" =~ ^([0-9]+)([dh]?)$ ]]; then
        n="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            h) printf '%s\n' "$(( n * 3600 ))" ;;
            d|"") printf '%s\n' "$(( n * 86400 ))" ;;
        esac
    else
        echo "cleanup-artifacts.sh: invalid --older-than '$d' (expect Nd or Nh)" >&2
        exit 2
    fi
}

# Portable mtime in epoch seconds.
_mtime() {
    local p="$1"
    stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo 0
}

# Size in bytes of a file or directory tree.
_size_bytes() {
    local p="$1" total
    if [[ -d "$p" ]]; then
        total="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
        printf '%s\n' "$(( ${total:-0} * 1024 ))"
    elif [[ -f "$p" ]]; then
        stat -f %z "$p" 2>/dev/null || stat -c %s "$p" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# MANDATORY safety gate: a path is deletable only if its canonical form is
# strictly *inside* one of the allowed roots (never equal to a root, never
# outside it, no .. escape, no symlink escape). Returns 0 if safe to delete.
_is_within_roots() {
    local target canon root_pc root_st
    target="$1"
    canon="$(_canonical "$target")"
    root_pc="$(_canonical "$PLAN_CONTEXT_DIR")"
    root_st="$(_canonical "$STATE_ROOT")"
    local r
    for r in "$root_pc" "$root_st"; do
        [[ -z "$r" ]] && continue
        # Must be strictly under the root (root + '/' prefix), not the root itself.
        if [[ "$canon" == "$r"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Delete (or in dry-run, just report) a path after the safety gate.
_remove_path() {
    local p="$1" reason="${2:-}" bytes
    if ! _is_within_roots "$p"; then
        echo "REFUSE (outside allowed roots): $p" >&2
        return 1
    fi
    if [[ -n "${ZBUILD_RUN_ID:-}" && "$p" == *"/$ZBUILD_RUN_ID" ]]; then
        echo "SKIP (active run): $p" >&2
        return 0
    fi
    bytes="$(_size_bytes "$p")"
    if [[ "$DRY_RUN" == true ]]; then
        echo "WOULD REMOVE${reason:+ ($reason)}: $p"
    else
        rm -rf "$p"
        echo "REMOVED${reason:+ ($reason)}: $p"
        REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
        BYTES_FREED=$(( BYTES_FREED + bytes ))
    fi
}

# Read .status (and .created_at) from a context JSON, tolerant of missing jq.
_ctx_status() {
    local json="$1"
    [[ -f "$json" ]] || { echo ""; return; }
    if command -v jq >/dev/null 2>&1; then
        jq -r '.status // ""' "$json" 2>/dev/null || echo ""
    else
        echo ""
    fi
}
_ctx_created_epoch() {
    local json="$1" iso
    [[ -f "$json" ]] || { echo ""; return; }
    if command -v jq >/dev/null 2>&1; then
        iso="$(jq -r '.created_at // ""' "$json" 2>/dev/null)" || iso=""
    fi
    [[ -z "$iso" ]] && { echo ""; return; }
    # ISO8601 → epoch (GNU then BSD).
    date -d "$iso" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${iso%%.*}Z" +%s 2>/dev/null \
        || echo ""
}

# Decide whether a context status passes the --status filter.
_status_selected() {
    local st="$1"
    case "$STATUS_FILTER" in
        all) return 0 ;;
        complete) [[ "$st" == "complete" ]] ;;
        scope_too_large) [[ "$st" == "scope_too_large" ]] ;;
    esac
}

# ── --all full wipe ──────────────────────────────────────────────────────────
prune_wipe_all() {
    local root="$PLAN_CONTEXT_DIR"
    [[ -d "$root" ]] || { echo "plan-context cache absent: $root"; return 0; }
    if [[ "$FORCE" != true ]]; then
        echo "--all requires --force; refusing to wipe $root" >&2
        # Still list (dry behaviour) so the operator sees scope.
        local entry
        for entry in "$root"/*/*/*.json; do
            [[ -e "$entry" ]] || continue
            echo "WOULD REMOVE (--all): $entry"
        done
        return 0
    fi
    local entry
    for entry in "$root"/*/*; do
        [[ -d "$entry" ]] || continue
        _remove_path "$entry" "--all"
    done
}

# ── plan-context cache prune ─────────────────────────────────────────────────
prune_plan_context() {
    local root="$PLAN_CONTEXT_DIR"
    [[ -d "$root" ]] || { echo "plan-context cache absent: $root"; return 0; }

    local max_age now cutoff
    max_age="$(_duration_to_secs "$OLDER_THAN")"
    now="$(date +%s)"
    cutoff=$(( now - max_age ))

    local repo_dir issue_dir
    for repo_dir in "$root"/*; do
        [[ -d "$repo_dir" ]] || continue
        local repo_id; repo_id="$(basename "$repo_dir")"
        [[ -n "$REPO_FILTER" && "$repo_id" != "$REPO_FILTER" ]] && continue

        for issue_dir in "$repo_dir"/*; do
            [[ -d "$issue_dir" ]] || continue
            local scope_key; scope_key="$(basename "$issue_dir")"
            [[ -n "$ISSUE_FILTER" && "$scope_key" != "$ISSUE_FILTER" ]] && continue

            _prune_namespace "$issue_dir" "$cutoff"
        done
    done
}

# Prune one <repo_id>/<scope_key> namespace: apply --max-entries (LRU) first,
# then age + status filters on the survivors.
_prune_namespace() {
    local ns_dir="$1" cutoff="$2"

    # Gather context JSON leaves with their mtime.
    local -a entries=()
    local json
    for json in "$ns_dir"/*.json; do
        [[ -f "$json" ]] || continue
        entries+=("$(_mtime "$json")|$json")
    done
    [[ ${#entries[@]} -eq 0 ]] && return 0

    # Sort newest-first by mtime.
    local sorted
    sorted="$(printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1nr)"

    local -a kept_for_lru=()
    local i=0 line mtime path
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        mtime="${line%%|*}"
        path="${line#*|}"
        i=$(( i + 1 ))

        # --max-entries: delete anything beyond the newest N (LRU by mtime).
        if [[ -n "$MAX_ENTRIES" && "$i" -gt "$MAX_ENTRIES" ]]; then
            _remove_context_leaf "$path" "lru>$MAX_ENTRIES"
            continue
        fi
        kept_for_lru+=("$mtime|$path")
    done <<<"$sorted"

    # Age + status prune on survivors of the LRU pass.
    for line in "${kept_for_lru[@]}"; do
        mtime="${line%%|*}"
        path="${line#*|}"

        local st; st="$(_ctx_status "$path")"
        _status_selected "$st" || continue

        # Age check: prefer .created_at, fall back to mtime.
        local age_epoch; age_epoch="$(_ctx_created_epoch "$path")"
        [[ -z "$age_epoch" ]] && age_epoch="$mtime"
        if [[ "$age_epoch" -le "$cutoff" ]]; then
            _remove_context_leaf "$path" "older-than=$OLDER_THAN${st:+,status=$st}"
        fi
    done
}

# Remove a context leaf and its sibling .md (same stem).
_remove_context_leaf() {
    local json="$1" reason="$2"
    _remove_path "$json" "$reason"
    local md="${json%.json}.md"
    [[ -f "$md" ]] && _remove_path "$md" "$reason"
}

# ── per-run state dir prune ──────────────────────────────────────────────────
prune_state_runs() {
    local runs_dir="$STATE_ROOT/runs"
    [[ -d "$runs_dir" ]] || return 0

    local max_age now cutoff
    max_age="$(_duration_to_secs "$OLDER_THAN")"
    now="$(date +%s)"
    cutoff=$(( now - max_age ))

    local run_dir
    for run_dir in "$runs_dir"/*; do
        [[ -d "$run_dir" ]] || continue
        local run_id; run_id="$(basename "$run_dir")"
        # Never delete the active run (also guarded in _remove_path).
        [[ -n "${ZBUILD_RUN_ID:-}" && "$run_id" == "$ZBUILD_RUN_ID" ]] && continue
        local mtime; mtime="$(_mtime "$run_dir")"
        if [[ "$mtime" -le "$cutoff" ]]; then
            _remove_path "$run_dir" "older-than=$OLDER_THAN"
        fi
    done
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "── DRY-RUN: nothing deleted (re-run with --force to apply) ──"
    else
        echo "── Removed ${REMOVED_COUNT} entries, freed ${BYTES_FREED} bytes ──"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    if [[ "$WIPE_ALL" == true ]]; then
        prune_wipe_all
    else
        prune_plan_context
        prune_state_runs
    fi
    print_summary
}

main
