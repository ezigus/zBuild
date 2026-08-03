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

# A timeout leaves the run's true pass/fail unknown → INFRASTRUCTURE, never a
# flip (ADR-036 #1188): `timeout` exits 124 (TERM sent), 143 (child died of it),
# 137 when a -k kill-after SIGKILL lands or an external OOM kill (128+9).
_reachability_is_timeout_rc() { [[ "$1" -eq 124 || "$1" -eq 137 || "$1" -eq 143 ]]; }

# _reachability_run <testfile_abs> <cwd> [logfile]  → returns the test's rc.
# When <logfile> is given the combined output is appended for diagnosability.
_reachability_run() {
    local testfile="$1" cwd="$2" logfile="${3:-}"
    local timeout_s="${ZBUILD_NEGCTL_TIMEOUT:-60}"
    local template="${ZBUILD_ACCEPTANCE_RUN_CMD:-}"
    [[ -z "$template" || "$template" != *'{files}'* ]] && template="bash {files}"
    local -a runner=()
    while IFS= read -r -d '' _tok; do runner+=("$_tok"); done \
        < <(_acceptance_build_run_cmd "$template" "$testfile")
    _acceptance_timeout_prefix "$timeout_s"
    if [[ ${#_ACCEPTANCE_TOUT[@]} -gt 0 ]]; then
        runner=("${_ACCEPTANCE_TOUT[@]}" "${runner[@]}")
    fi
    (
        cd "$cwd" || exit 2
        unset ZBUILD_TEST_QUIET
        # #1211: same fd-3 escape as negctl (see _negctl_run) — the runner's
        # ZBUILD_STAGE_IO_FD=3 + duped-terminal fd 3 are inherited untouched, so
        # nested plugin banners leak to the operator terminal, repeated per WIRING
        # target × baseline/HEAD. Neutralize the channel and capture nested output
        # to the already-2>&1 diagnostic log instead. Sibling #1127 = general fix.
        unset ZBUILD_STAGE_IO_FD
        if [[ -n "$logfile" ]]; then
            "${runner[@]}" >>"$logfile" 2>&1 3>>"$logfile"
        else
            "${runner[@]}" >/dev/null 2>&1 3>&-
        fi
    )
}

# _reachability_bound_log <file> [max_bytes] — keep only the last max_bytes.
_reachability_bound_log() {
    local f="$1" cap="${2:-65536}"
    [[ -n "$f" && -f "$f" ]] || return 0
    local sz; sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
    if [[ "$sz" =~ ^[0-9]+$ && "$sz" -gt "$cap" ]]; then
        tail -c "$cap" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
    fi
}

# acceptance_reachability_check <design_md> <repo_root>
# Prints one verdict line per outcome:
#   REACHABILITY EXEMPT none          — WIRING: none declared; no revert runs
#   REACHABILITY PASS <target>        — ≥1 testfile flips pass→fail; wiring load-bearing
#   REACHABILITY FAIL inert_wiring <target>  — no testfile flips; wiring is inert
#   REACHABILITY ERROR <detail>       — infrastructure failure (worktree_failed,
#                                       empty_wiring_targets, timeout:<target>)
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

    # An empty diff with head != base means the git call failed (shallow clone,
    # unresolvable base). Fail closed: without it every target reads as off-diff.
    if [[ ${#changed_files[@]} -eq 0 ]]; then
        printf 'REACHABILITY ERROR diff_failed\n'
        return 1
    fi

    local rc=0

    for target in "${wiring_targets[@]}"; do
        # #1686: a target absent from this commit's diff was not changed here, so
        # reverting it is a no-op and no testfile can flip. Design named a file
        # unrelated to the change; only design can fix the declaration.
        # NOTE: this does NOT cover a target that IS in the diff but no test can
        # load (the #1664 CI-config shape) — that still reads as inert_wiring. No
        # static rule separates those two cases; see #1711.
        local _t_norm="${target#./}" _in_diff=0 _cf
        for _cf in "${changed_files[@]}"; do
            [[ "${_cf#./}" == "$_t_norm" ]] && _in_diff=1 && break
        done
        if [[ "$_in_diff" -eq 0 ]]; then
            printf 'REACHABILITY FAIL wiring_not_on_path %s\n' "$target"
            rc=1
            continue
        fi

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
        local found_flip=0 saw_timeout=0
        local logfile=""
        if [[ -n "${ZBUILD_NEGCTL_ARTIFACT_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_NEGCTL_ARTIFACT_DIR" 2>/dev/null || true
            # sanitize the target path into a flat log filename
            local _safe_target="${target//\//_}"
            logfile="$ZBUILD_NEGCTL_ARTIFACT_DIR/reachability-${_safe_target}.log"
            : > "$logfile" 2>/dev/null || logfile=""
        fi
        for tf in "${testfiles[@]:-}"; do
            [[ -z "$tf" ]] && continue
            [[ ! -f "$wt_dir/$tf" ]] && continue
            local rc_reverted=0 rc_head=0
            [[ -n "$logfile" ]] && printf '### %s reverted %s\n' "$target" "$tf" >> "$logfile"
            _reachability_run "$wt_dir/$tf" "$wt_dir" "$logfile" || rc_reverted=$?
            [[ -n "$logfile" ]] && printf '### %s head %s\n' "$target" "$tf" >> "$logfile"
            _reachability_run "$repo_root/$tf" "$repo_root" "$logfile" || rc_head=$?
            # A timeout on EITHER run leaves the flip verdict unknown → INFRA;
            # do not treat it as a flip or as inert wiring.
            if _reachability_is_timeout_rc "$rc_reverted" || _reachability_is_timeout_rc "$rc_head"; then
                saw_timeout=1; continue
            fi
            if [[ "$rc_reverted" -ne 0 && "$rc_head" -eq 0 ]]; then
                found_flip=1
                break
            fi
        done
        _reachability_bound_log "$logfile"

        # Remove worktree now (trap handles it but be explicit).
        git -C "$repo_root" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
        rm -rf "$wt_dir" 2>/dev/null || true

        if [[ "$found_flip" -eq 1 ]]; then
            printf 'REACHABILITY PASS %s\n' "$target"
        elif [[ "$saw_timeout" -eq 1 ]]; then
            # No flip observed, but a run timed out → cannot conclude inert; infra.
            printf 'REACHABILITY ERROR timeout:%s\n' "$target"
            rc=1
        else
            printf 'REACHABILITY FAIL inert_wiring %s\n' "$target"
            rc=1
        fi
    done

    return "$rc"
}
