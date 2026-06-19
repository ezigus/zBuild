#!/usr/bin/env bash
# acceptance-reachability.sh — Level-3 of the acceptance-contract gate (ADR-036, #956).
#
# Reachability check: proves the declared WIRING file is load-bearing in the
# live production call-path. For each WIRING target:
#   - Create a detached git worktree at the merge-base.
#   - Overlay ALL files changed between merge-base and HEAD from HEAD, EXCEPT
#     the WIRING target (which stays at merge-base).
#   - Run the declared TESTFILES.
#   - If ≥1 test flips pass→fail (rc_reverted!=0, rc_head==0), the wiring is
#     load-bearing: REACHABILITY PASS <target>.
#   - If no test flips: REACHABILITY FAIL inert_wiring <target> — gate hard-fails.
#
# WIRING: none → REACHABILITY EXEMPT none (pure-utility exemption, no revert runs).
# No WIRING section → no-op (composability invariant, caller skips Level-3).
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ACCEPTANCE_REACHABILITY_LOADED:-}" ]] && return 0
_ACCEPTANCE_REACHABILITY_LOADED=1

_ACCEPTANCE_REACHABILITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./acceptance-block.sh
source "$_ACCEPTANCE_REACHABILITY_DIR/acceptance-block.sh"
# shellcheck source=./merge-base.sh
source "$_ACCEPTANCE_REACHABILITY_DIR/merge-base.sh"

# _reachability_run <testfile_abs> <cwd>  → returns the test's rc.
_reachability_run() {
    local testfile="$1" cwd="$2"
    local timeout_s="${ZBUILD_NEGCTL_TIMEOUT:-60}"
    local -a runner=(bash "$testfile")
    if command -v timeout >/dev/null 2>&1; then
        runner=(timeout "$timeout_s" bash "$testfile")
    fi
    (
        cd "$cwd" || exit 2
        unset ZBUILD_TEST_QUIET
        "${runner[@]}" >/dev/null 2>&1
    )
}

# acceptance_reachability_check <design_md> <repo_root>
# Prints one verdict line per outcome:
#   REACHABILITY EXEMPT none          — WIRING: none declared; no revert runs
#   REACHABILITY PASS <target>        — ≥1 testfile flips pass→fail; wiring load-bearing
#   REACHABILITY FAIL inert_wiring <target>  — no testfile flips; wiring is inert
#   REACHABILITY ERROR <detail>       — infrastructure failure
#   REACHABILITY SKIP no_impl_delta   — HEAD == merge-base; nothing to check
# Returns 0 when every target passes (or exempt/skip), 1 otherwise.
acceptance_reachability_check() {
    local design_md="${1:-}" repo_root="${2:-}"
    [[ -z "$design_md" || -z "$repo_root" ]] && { printf 'REACHABILITY ERROR bad_args\n'; return 1; }

    # Resolve baseline = merge-base with default branch.
    local base_sha; base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    if [[ -z "$base_sha" ]]; then
        printf 'REACHABILITY ERROR baseline_resolve_failed\n'
        return 1
    fi
    local head_sha; head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$head_sha" && "$base_sha" == "$head_sha" ]]; then
        printf 'REACHABILITY SKIP no_impl_delta\n'
        return 0
    fi

    # Was a WIRING section declared at all? (rc=0 even if every path is filtered)
    local wiring_declared=1
    acceptance_list_wiring "$design_md" >/dev/null 2>&1 || wiring_declared=0

    # Collect WIRING targets (path-traversal-unsafe paths are filtered out upstream).
    local -a wiring_targets=()
    local wt
    while IFS= read -r wt; do
        [[ -n "$wt" ]] && wiring_targets+=("$wt")
    done < <(acceptance_list_wiring "$design_md" 2>/dev/null || true)

    if [[ ${#wiring_targets[@]} -eq 0 ]]; then
        # No WIRING section → genuine no-op (caller normally guards on this too).
        [[ "$wiring_declared" -eq 0 ]] && return 0
        # WIRING declared but every target was rejected (unsafe/empty) → FAIL CLOSED.
        # A gate must never silently skip because the author gave only bad paths.
        printf 'REACHABILITY ERROR empty_wiring_targets\n'
        return 1
    fi

    # WIRING: none → exempt.
    if [[ ${#wiring_targets[@]} -eq 1 && "${wiring_targets[0]}" == "none" ]]; then
        printf 'REACHABILITY EXEMPT none\n'
        return 0
    fi

    # Collect declared TESTFILES (existing on disk).
    local -a testfiles=()
    local tf
    while IFS= read -r tf; do
        [[ -n "$tf" && -f "$repo_root/$tf" ]] && testfiles+=("$tf")
    done < <(acceptance_list_testfiles "$design_md")

    # Get all files changed between merge-base and HEAD.
    local -a changed_files=()
    local cf
    while IFS= read -r cf; do
        [[ -n "$cf" ]] && changed_files+=("$cf")
    done < <(git -C "$repo_root" diff --name-only "$base_sha" HEAD 2>/dev/null || true)

    local rc=0

    for target in "${wiring_targets[@]}"; do
        # Create detached worktree at baseline.
        local wt_dir; wt_dir="$(mktemp -d "${TMPDIR:-/tmp}/zb-reach.XXXXXX")"
        # shellcheck disable=SC2064
        trap "git -C '$repo_root' worktree remove --force '$wt_dir' >/dev/null 2>&1 || true; rm -rf '$wt_dir' 2>/dev/null || true" RETURN
        if ! git -C "$repo_root" worktree add --detach "$wt_dir" "$base_sha" >/dev/null 2>&1; then
            printf 'REACHABILITY ERROR worktree_failed %s\n' "$target"
            rc=1
            rm -rf "$wt_dir" 2>/dev/null || true  # don't leak the mktemp dir (trap is per-return)
            continue
        fi

        # Overlay ALL changed files from HEAD, EXCEPT the WIRING target.
        for cf in "${changed_files[@]:-}"; do
            [[ -z "$cf" ]] && continue
            [[ "$cf" == "$target" ]] && continue  # leave WIRING file at merge-base
            mkdir -p "$wt_dir/$(dirname "$cf")"
            # Overlay HEAD version; if the file was DELETED at HEAD, git show fails —
            # remove it from the baseline overlay rather than leaving a truncated empty
            # file (which would corrupt the flip detection).
            if git -C "$repo_root" show "HEAD:$cf" > "$wt_dir/$cf.zbtmp" 2>/dev/null; then
                mv "$wt_dir/$cf.zbtmp" "$wt_dir/$cf"
                chmod +x "$wt_dir/$cf" 2>/dev/null || true
            else
                rm -f "$wt_dir/$cf.zbtmp" "$wt_dir/$cf" 2>/dev/null || true
            fi
        done

        # Ensure testfiles are overlaid from HEAD (may not be in changed_files if unchanged).
        for tf in "${testfiles[@]:-}"; do
            [[ -z "$tf" ]] && continue
            mkdir -p "$wt_dir/$(dirname "$tf")"
            git -C "$repo_root" show "HEAD:$tf" > "$wt_dir/$tf" 2>/dev/null || true
            chmod +x "$wt_dir/$tf" 2>/dev/null || true
        done

        # Check if any testfile flips pass→fail when WIRING is at merge-base.
        local found_flip=0
        for tf in "${testfiles[@]:-}"; do
            [[ -z "$tf" ]] && continue
            [[ ! -f "$wt_dir/$tf" ]] && continue
            local rc_reverted=0 rc_head=0
            _reachability_run "$wt_dir/$tf" "$wt_dir" || rc_reverted=$?
            _reachability_run "$repo_root/$tf" "$repo_root" || rc_head=$?
            if [[ "$rc_reverted" -ne 0 && "$rc_head" -eq 0 ]]; then
                found_flip=1
                break
            fi
        done

        # Remove worktree now (trap handles it but be explicit).
        git -C "$repo_root" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
        rm -rf "$wt_dir" 2>/dev/null || true

        if [[ "$found_flip" -eq 1 ]]; then
            printf 'REACHABILITY PASS %s\n' "$target"
        else
            printf 'REACHABILITY FAIL inert_wiring %s\n' "$target"
            rc=1
        fi
    done

    return "$rc"
}
