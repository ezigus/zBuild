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
# shellcheck source=env-scrub.sh
source "$_ACCEPTANCE_REACHABILITY_DIR/env-scrub.sh"
# #2109: the per-[SPEC-n] log scan is negctl's (#1969); one rule, two callers.
if ! declare -F _negctl_guard_log_check >/dev/null 2>&1; then
    # shellcheck source=acceptance-negctl.sh
    source "$_ACCEPTANCE_REACHABILITY_DIR/acceptance-negctl.sh"
fi
# shellcheck source=./merge-base.sh
source "$_ACCEPTANCE_REACHABILITY_DIR/merge-base.sh"

# #2010: zbuild_engine_tmpdir names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)/helpers.sh" 2>/dev/null || true
fi


# A timeout leaves the run's true pass/fail unknown → INFRASTRUCTURE, never a
# flip (ADR-036 #1188): `timeout` exits 124 (TERM sent), 143 (child died of it),
# 137 when a -k kill-after SIGKILL lands or an external OOM kill (128+9).
_reachability_is_timeout_rc() { [[ "$1" -eq 124 || "$1" -eq 137 || "$1" -eq 143 ]]; }
# #2109: 126/127 = the runner could not execute the file at all — pass/fail
# unknown (negctl has classified this as infrastructure since #1670).
_reachability_is_harness_rc() { [[ "$1" -eq 126 || "$1" -eq 127 ]]; }

# _reachability_run <testfile_abs> <cwd> [logfile]  → returns the test's rc.
# When <logfile> is given the combined output is appended for diagnosability.
_reachability_run() {
    local testfile="$1" cwd="$2" logfile="${3:-}"
    local timeout_s="${ZBUILD_NEGCTL_TIMEOUT:-60}"
    # #2110: raise to the file's measured time; the HEAD run is memoised across
    # WIRING targets (the reverted runs differ per target and are not).
    timeout_s="$(_acceptance_file_timeout "${testfile#"$cwd"/}" "$timeout_s")"
    local template="${ZBUILD_ACCEPTANCE_RUN_CMD:-}"
    [[ -z "$template" || "$template" != *'{files}'* ]] && template="bash {files}"
    local -a runner=()
    while IFS= read -r -d '' _tok; do runner+=("$_tok"); done \
        < <(_acceptance_build_run_cmd "$template" "$testfile")
    _acceptance_timeout_prefix "$timeout_s"
    if [[ ${#_ACCEPTANCE_TOUT[@]} -gt 0 ]]; then
        runner=("${_ACCEPTANCE_TOUT[@]}" "${runner[@]}")
    fi
    _acceptance_run_cached "$testfile" "$logfile" _reachability_run_once "$cwd" "${runner[@]}"
}

# _reachability_run_once <cwd> <runner...> — the un-memoised execution (#2110).
_reachability_run_once() {
    local cwd="$1"; shift
    local -a runner=("$@")
    (
        cd "$cwd" || exit 2
        # #2108 (closes #1782): the same scrub negctl has taken since #1644 —
        # every ZBUILD_*/_TPL_* name, fd 3, and stdin. A TESTFILE that fails
        # only because ZBUILD_RUN_ID leaked into it read as rc_head≠0 →
        # `inert_wiring`; the two gate runners must execute a file in ONE
        # environment or their verdicts cannot be compared (and, later, shared).
        _zbuild_make_fresh_shell
        "${runner[@]}"
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
    # #2110: memoise the HEAD run across targets (see _acceptance_run_cached).
    _acceptance_run_cache_begin
    local _rc_owner="${_ACCEPTANCE_RUN_CACHE_OWNED:-0}"

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
        local wt_dir; wt_dir="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-reach.XXXXXX")"
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
        # #2109: judged per [SPEC-n] line (the #1969 rule negctl already has),
        # file rc only where the captures carry no verdict; a file that is red
        # at HEAD, a run the harness could not execute, and a roster with no
        # file on disk are each named for what they are — "inert_wiring" used
        # to swallow all three, and at iter≥2 it routes to DESIGN.
        local found_flip=0 saw_timeout=0 saw_harness="" red_at_head="" ran_any=0
        local logfile=""
        if [[ -n "${ZBUILD_NEGCTL_ARTIFACT_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_NEGCTL_ARTIFACT_DIR" 2>/dev/null || true
            # sanitize the target path into a flat log filename
            local _safe_target="${target//\//_}"
            logfile="$ZBUILD_NEGCTL_ARTIFACT_DIR/reachability-${_safe_target}.log"
            : > "$logfile" 2>/dev/null || logfile=""
        fi
        local -a _spec_ids=()
        local _sid
        while IFS= read -r _sid; do
            [[ -n "$_sid" ]] && _spec_ids+=("$_sid")
        done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
        for tf in "${testfiles[@]:-}"; do
            [[ -z "$tf" ]] && continue
            [[ ! -f "$wt_dir/$tf" ]] && continue
            ran_any=1
            local rc_reverted=0 rc_head=0 _cap_rev _cap_head
            _cap_rev="$(mktemp "$(zbuild_engine_tmpdir)/zb-reach-rev.XXXXXX")" || _cap_rev=""
            _cap_head="$(mktemp "$(zbuild_engine_tmpdir)/zb-reach-head.XXXXXX")" || _cap_head=""
            _reachability_run "$wt_dir/$tf" "$wt_dir" "$_cap_rev" || rc_reverted=$?
            _reachability_run "$repo_root/$tf" "$repo_root" "$_cap_head" || rc_head=$?
            if [[ -n "$logfile" ]]; then
                printf '### %s reverted %s\n' "$target" "$tf" >> "$logfile"
                [[ -n "$_cap_rev" ]] && cat "$_cap_rev" >> "$logfile" 2>/dev/null
                printf '### %s head %s\n' "$target" "$tf" >> "$logfile"
                [[ -n "$_cap_head" ]] && cat "$_cap_head" >> "$logfile" 2>/dev/null
            fi
            # A timeout on EITHER run leaves the flip verdict unknown → INFRA;
            # do not treat it as a flip or as inert wiring.
            if _reachability_is_timeout_rc "$rc_reverted" || _reachability_is_timeout_rc "$rc_head"; then
                rm -f "$_cap_rev" "$_cap_head" 2>/dev/null; saw_timeout=1; continue
            fi
            if _reachability_is_harness_rc "$rc_reverted" || _reachability_is_harness_rc "$rc_head"; then
                rm -f "$_cap_rev" "$_cap_head" 2>/dev/null
                [[ -z "$saw_harness" ]] && saw_harness="$tf"; continue
            fi
            # Per-SPEC evidence: 0 = a ✗ line for the id, 1 = ✓ and no ✗, 2 = none.
            local _any_verdict=0 _lv_h _lv_r
            for _sid in ${_spec_ids[@]+"${_spec_ids[@]}"}; do
                _negctl_guard_log_check "$_cap_head" "$_sid" && _lv_h=0 || _lv_h=$?
                _negctl_guard_log_check "$_cap_rev" "$_sid" && _lv_r=0 || _lv_r=$?
                [[ "$_lv_h" -ne 2 || "$_lv_r" -ne 2 ]] && _any_verdict=1
                if [[ "$_lv_h" -eq 1 && "$_lv_r" -eq 0 ]]; then found_flip=1; break; fi
                [[ "$_lv_h" -eq 0 && -z "$red_at_head" ]] && red_at_head="$tf"
            done
            rm -f "$_cap_rev" "$_cap_head" 2>/dev/null
            [[ "$found_flip" -eq 1 ]] && break
            # No tagged evidence at all (custom runner, untagged file): file rc.
            if [[ "$_any_verdict" -eq 0 ]]; then
                if [[ "$rc_reverted" -ne 0 && "$rc_head" -eq 0 ]]; then found_flip=1; break; fi
                [[ "$rc_head" -ne 0 && -z "$red_at_head" ]] && red_at_head="$tf"
            fi
        done
        _reachability_bound_log "$logfile"

        # Remove worktree now (trap handles it but be explicit).
        git -C "$repo_root" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
        rm -rf "$wt_dir" 2>/dev/null || true

        if [[ "$found_flip" -eq 1 ]]; then
            printf 'REACHABILITY PASS %s\n' "$target"
        elif [[ "$ran_any" -eq 0 ]]; then
            # No declared TESTFILE exists on disk: nothing could flip. Not a
            # wiring verdict — a roster the next iteration can still create.
            printf 'REACHABILITY FAIL no_testfiles %s\n' "$target"
            rc=1
        elif [[ "$saw_timeout" -eq 1 ]]; then
            # No flip observed, but a run timed out → cannot conclude inert; infra.
            printf 'REACHABILITY ERROR timeout:%s\n' "$target"
            rc=1
        elif [[ -n "$saw_harness" ]]; then
            printf 'REACHABILITY ERROR harness:%s %s\n' "$target" "$saw_harness"
            rc=1
        elif [[ -n "$red_at_head" ]]; then
            # The file is red at HEAD: no revert can flip a failing test. That is
            # the build's defect (or the assertion's), never the wiring's.
            printf 'REACHABILITY FAIL not_passing_at_head %s %s\n' "$target" "$red_at_head"
            rc=1
        else
            printf 'REACHABILITY FAIL inert_wiring %s\n' "$target"
            rc=1
        fi
    done

    if [[ "$_rc_owner" -eq 1 ]]; then
        rm -rf "${_ACCEPTANCE_RUN_CACHE_DIR:-}" 2>/dev/null || true
        unset _ACCEPTANCE_RUN_CACHE_DIR
    fi
    return "$rc"
}
