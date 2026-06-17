#!/usr/bin/env bash
# acceptance-negctl.sh — Level-2 of the acceptance-contract gate (ADR-036, #922).
#
# Negative control: a SPEC-n's tagged test must FAIL when the implementation is
# reverted to the merge-base with the default branch, and PASS at HEAD. A test
# that passes at baseline is tautological (it does not depend on the change) and
# is rejected — this is what catches the #844-class "green but inert" defect.
#
# Mechanism (per SPEC-n tagged TESTFILE):
#   baseline run — a detached `git worktree` at the merge-base, with the TESTFILE
#                  overlaid from HEAD (impl reverted, test current). rc_base.
#   head run     — the TESTFILE run in repo_root (everything at HEAD). rc_head.
#   valid control ⇔ rc_base != 0 AND rc_head == 0.
# A SPEC-n is load-bearing iff ≥1 of its tagged TESTFILEs is a valid control.
#
# Granularity is per-TESTFILE (file-level rc), not per-assertion. Author one
# SPEC per test file (or one tagged assertion per file) for precise attribution;
# a file mixing a load-bearing and a tautological SPEC is judged load-bearing.
#
# Source-only; no `set -e` at top level (would mutate caller options).

[[ -n "${_ACCEPTANCE_NEGCTL_LOADED:-}" ]] && return 0
_ACCEPTANCE_NEGCTL_LOADED=1

_ACCEPTANCE_NEGCTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./acceptance-block.sh
source "$_ACCEPTANCE_NEGCTL_DIR/acceptance-block.sh"
# shellcheck source=./acceptance-coverage.sh
source "$_ACCEPTANCE_NEGCTL_DIR/acceptance-coverage.sh"
# shellcheck source=./merge-base.sh
source "$_ACCEPTANCE_NEGCTL_DIR/merge-base.sh"

# _negctl_run <testfile_abs> <cwd>  → echoes nothing, returns the test's rc.
# Runs with ZBUILD_TEST_QUIET unset (so labeled output is produced) under an
# optional timeout. A timeout (rc 124) counts as a non-zero/failed run.
_negctl_run() {
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

# acceptance_negctl_check <design_md> <repo_root>
# Prints one verdict line per SPEC-n:
#   NEGCTL PASS <spec_id>      — ≥1 tagged testfile fails at baseline, passes at HEAD
#   NEGCTL FAIL <spec_id> <reason>   reason ∈ {tautology, not_passing_at_head, no_testfile}
#   NEGCTL ERROR <detail>      — infrastructure (baseline_resolve_failed, worktree_failed)
#   NEGCTL SKIP <detail>       — no negative control possible (no_impl_delta)
# Returns 0 when every SPEC-n passes (or is legitimately skipped), 1 otherwise.
acceptance_negctl_check() {
    local design_md="${1:-}" repo_root="${2:-}"
    [[ -z "$design_md" || -z "$repo_root" ]] && { printf 'NEGCTL ERROR bad_args\n'; return 1; }

    # Resolve baseline = merge-base with default branch.
    local base_sha; base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    if [[ -z "$base_sha" ]]; then
        printf 'NEGCTL ERROR baseline_resolve_failed\n'
        return 1
    fi
    local head_sha; head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$head_sha" && "$base_sha" == "$head_sha" ]]; then
        # No commits ahead of the default branch → no implementation delta to
        # control against. Skip (not a failure): cannot prove load-bearing.
        printf 'NEGCTL SKIP no_impl_delta\n'
        return 0
    fi

    # Collect declared TESTFILES (existing on disk) once.
    local -a testfiles=()
    local tf
    while IFS= read -r tf; do
        [[ -n "$tf" && -f "$repo_root/$tf" ]] && testfiles+=("$tf")
    done < <(acceptance_list_testfiles "$design_md")

    # Detached worktree at baseline; overlay each TESTFILE from HEAD.
    local wt_dir; wt_dir="$(mktemp -d "${TMPDIR:-/tmp}/zb-negctl.XXXXXX")"
    # shellcheck disable=SC2064
    trap "git -C '$repo_root' worktree remove --force '$wt_dir' >/dev/null 2>&1 || true; rm -rf '$wt_dir' 2>/dev/null || true" RETURN
    if ! git -C "$repo_root" worktree add --detach "$wt_dir" "$base_sha" >/dev/null 2>&1; then
        printf 'NEGCTL ERROR worktree_failed\n'
        return 1
    fi
    for tf in "${testfiles[@]:-}"; do
        [[ -z "$tf" ]] && continue
        mkdir -p "$wt_dir/$(dirname "$tf")"
        git -C "$repo_root" show "HEAD:$tf" > "$wt_dir/$tf" 2>/dev/null || true
        chmod +x "$wt_dir/$tf" 2>/dev/null || true
    done

    # Per SPEC-n: is ≥1 tagged testfile a valid negative control?
    local spec_id rc=0
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        local found_control=0 saw_tautology=0 saw_tagged=0 only_head_fail=0
        for tf in "${testfiles[@]:-}"; do
            [[ -z "$tf" ]] && continue
            grep -qF "[$spec_id]" "$repo_root/$tf" 2>/dev/null || continue
            saw_tagged=1
            local rc_base=0 rc_head=0
            _negctl_run "$wt_dir/$tf" "$wt_dir"; rc_base=$?
            _negctl_run "$repo_root/$tf" "$repo_root"; rc_head=$?
            if [[ "$rc_base" -ne 0 && "$rc_head" -eq 0 ]]; then
                found_control=1; break
            elif [[ "$rc_base" -eq 0 ]]; then
                saw_tautology=1
            elif [[ "$rc_head" -ne 0 ]]; then
                only_head_fail=1
            fi
        done
        if [[ "$found_control" -eq 1 ]]; then
            printf 'NEGCTL PASS %s\n' "$spec_id"
        elif [[ "$saw_tagged" -eq 0 ]]; then
            printf 'NEGCTL FAIL %s no_testfile\n' "$spec_id"; rc=1
        elif [[ "$saw_tautology" -eq 1 ]]; then
            printf 'NEGCTL FAIL %s tautology\n' "$spec_id"; rc=1
        elif [[ "$only_head_fail" -eq 1 ]]; then
            printf 'NEGCTL FAIL %s not_passing_at_head\n' "$spec_id"; rc=1
        else
            printf 'NEGCTL FAIL %s tautology\n' "$spec_id"; rc=1
        fi
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)

    return "$rc"
}
