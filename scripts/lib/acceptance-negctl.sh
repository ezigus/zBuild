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

# A timeout leaves the run's true pass/fail unknown, so it is an INFRASTRUCTURE
# signal, never a control/violation (ADR-036 #1188): `timeout` exits 124 when it
# TERMs the child, 143 when the child dies from that SIGTERM.
_negctl_is_timeout_rc() { [[ "$1" -eq 124 || "$1" -eq 143 ]]; }

# _negctl_run <testfile_abs> <cwd> [logfile]  → echoes nothing, returns the rc.
# Runs with ZBUILD_TEST_QUIET unset (so labeled output is produced) under an
# optional timeout (ZBUILD_NEGCTL_TIMEOUT, default 60s). When <logfile> is given
# the combined stdout+stderr is appended there (size-bounded by the caller) so a
# failed control is diagnosable; otherwise output is discarded.
_negctl_run() {
    local testfile="$1" cwd="$2" logfile="${3:-}"
    local timeout_s="${ZBUILD_NEGCTL_TIMEOUT:-60}"
    local template="${ZBUILD_ACCEPTANCE_RUN_CMD:-}"
    [[ -z "$template" || "$template" != *'{files}'* ]] && template="bash {files}"
    local -a runner=()
    while IFS= read -r -d '' _tok; do runner+=("$_tok"); done \
        < <(_acceptance_build_run_cmd "$template" "$testfile")
    if command -v timeout >/dev/null 2>&1; then
        runner=(timeout "$timeout_s" "${runner[@]}")
    fi
    (
        cd "$cwd" || exit 2
        unset ZBUILD_TEST_QUIET
        # #983: the negctl sandbox must never inherit test-runner parallelism from
        # the pipeline env. A tagged TESTFILE that invokes run-tests.sh could
        # otherwise fan a non-parallel-safe tier out and deadlock — the #983
        # fork-bomb hit BOTH the test-stage AND this sandbox. The test stage scrubs
        # via _zbuild_make_fresh_shell (plugins/tool/test/plugin.sh); _negctl_run
        # does not, so scrub the parallelism knobs explicitly here.
        unset ZBUILD_TEST_PARALLEL_JOBS ZBUILD_PARALLEL_SAFE_TIERS
        # #1211: the runner dups fd 3 to the operator terminal and exports
        # ZBUILD_STAGE_IO_FD=3 so stage-io banners survive `2>/dev/null`. A nested
        # TESTFILE drives real plugins whose banners would then escape to the
        # terminal via the inherited fd 3, bypassing this sandbox's stdout/stderr
        # capture. Neutralize the channel: unset ZBUILD_STAGE_IO_FD so nested
        # banners fall back to fd 2 (captured below), and redirect/close fd 3 so
        # nothing reaches the terminal. Sibling #1127 = the general isolation.
        unset ZBUILD_STAGE_IO_FD
        if [[ -n "$logfile" ]]; then
            "${runner[@]}" >>"$logfile" 2>&1 3>>"$logfile"
        else
            "${runner[@]}" >/dev/null 2>&1 3>&-
        fi
    )
}

# _negctl_bound_log <file> [max_bytes] — keep only the last max_bytes of a log so
# a runaway test cannot blow up the state dir. Default cap 64 KiB.
_negctl_bound_log() {
    local f="$1" cap="${2:-65536}"
    [[ -n "$f" && -f "$f" ]] || return 0
    local sz; sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
    if [[ "$sz" =~ ^[0-9]+$ && "$sz" -gt "$cap" ]]; then
        tail -c "$cap" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
    fi
}

# acceptance_negctl_check <design_md> <repo_root>
# Prints one verdict line per SPEC-n:
#   NEGCTL PASS <spec_id>      — ≥1 tagged testfile fails at baseline, passes at HEAD
#   NEGCTL FAIL <spec_id> <reason>   reason ∈ {tautology, not_passing_at_head, no_testfile}
#   NEGCTL ERROR <detail>      — infrastructure (baseline_resolve_failed,
#                                worktree_failed, timeout:<spec_id>)
#   NEGCTL SKIP <detail>       — no negative control possible (no_impl_delta,
#                                no_prod_delta)
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

    # Test-only diff: every changed path is under tests/ → no production code to
    # revert, so the baseline worktree would be byte-identical for all impl paths.
    # Tautology-fail would be a false positive; skip instead.
    local -a _nd_paths=()
    local _nd_p
    while IFS= read -r _nd_p; do
        [[ -n "$_nd_p" ]] && _nd_paths+=("$_nd_p")
    done < <(git -C "$repo_root" diff --name-only "$base_sha" HEAD 2>/dev/null || true)
    if [[ "${#_nd_paths[@]}" -gt 0 ]]; then
        local _nd_all_test=1
        for _nd_p in "${_nd_paths[@]}"; do
            if [[ "$_nd_p" != tests/* ]]; then
                _nd_all_test=0; break
            fi
        done
        if [[ "$_nd_all_test" -eq 1 ]]; then
            printf 'NEGCTL SKIP no_prod_delta\n'
            return 0
        fi
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
        # Guard SPECs are invariants, not expected to fail at baseline; skip negctl.
        if acceptance_spec_is_guard "$design_md" "$spec_id"; then
            printf 'NEGCTL SKIP guard_spec %s\n' "$spec_id"
            continue
        fi
        local found_control=0 saw_tautology=0 saw_tagged=0 only_head_fail=0 saw_timeout=0
        # Per-SPEC diagnostic log (opt-in via ZBUILD_NEGCTL_ARTIFACT_DIR, set by
        # the plugin from the pipeline state dir). Empty → output discarded.
        local logfile=""
        if [[ -n "${ZBUILD_NEGCTL_ARTIFACT_DIR:-}" ]]; then
            mkdir -p "$ZBUILD_NEGCTL_ARTIFACT_DIR" 2>/dev/null || true
            logfile="$ZBUILD_NEGCTL_ARTIFACT_DIR/negctl-${spec_id}.log"
            : > "$logfile" 2>/dev/null || logfile=""
        fi
        # Build the candidate testfile set for this SPEC.
        # When per-SPEC binding is declared for this SPEC, use only its bound files
        # directly (no tag-scan), eliminating the sibling-riding defect (#1480).
        # When no per-SPEC binding exists for this SPEC, fall back to scanning all
        # declared testfiles for the [SPEC-n] tag (backward-compat).
        local -a _cand_tfs=()
        local _ctf
        if acceptance_spec_has_binding "$design_md" "$spec_id"; then
            while IFS= read -r _ctf; do
                [[ -n "$_ctf" && -f "$repo_root/$_ctf" ]] && { _cand_tfs+=("$_ctf"); saw_tagged=1; }
            done < <(acceptance_list_testfiles_for_spec "$design_md" "$spec_id")
        else
            for _ctf in "${testfiles[@]:-}"; do
                [[ -z "$_ctf" ]] && continue
                grep -qF "[$spec_id]" "$repo_root/$_ctf" 2>/dev/null || continue
                saw_tagged=1; _cand_tfs+=("$_ctf")
            done
        fi
        for tf in "${_cand_tfs[@]:-}"; do
            [[ -z "$tf" ]] && continue
            # The baseline run is EXPECTED to fail; capture rc via `|| rc=$?`
            # so a non-zero exit never aborts the caller under `set -e`.
            local rc_base=0 rc_head=0
            [[ -n "$logfile" ]] && printf '### %s baseline %s\n' "$spec_id" "$tf" >> "$logfile"
            _negctl_run "$wt_dir/$tf" "$wt_dir" "$logfile" || rc_base=$?
            [[ -n "$logfile" ]] && printf '### %s head %s\n' "$spec_id" "$tf" >> "$logfile"
            _negctl_run "$repo_root/$tf" "$repo_root" "$logfile" || rc_head=$?
            # A timeout on EITHER run leaves pass/fail unknown → INFRA, not a
            # control or a not_passing_at_head violation. Skip this testfile.
            if _negctl_is_timeout_rc "$rc_base" || _negctl_is_timeout_rc "$rc_head"; then
                saw_timeout=1; continue
            fi
            if [[ "$rc_base" -ne 0 && "$rc_head" -eq 0 ]]; then
                found_control=1; break
            elif [[ "$rc_base" -eq 0 ]]; then
                saw_tautology=1
            elif [[ "$rc_head" -ne 0 ]]; then
                only_head_fail=1
            fi
        done
        _negctl_bound_log "$logfile"
        if [[ "$found_control" -eq 1 ]]; then
            printf 'NEGCTL PASS %s\n' "$spec_id"
        elif [[ "$saw_tagged" -eq 0 ]]; then
            printf 'NEGCTL FAIL %s no_testfile\n' "$spec_id"; rc=1
        elif [[ "$saw_tautology" -eq 1 ]]; then
            printf 'NEGCTL FAIL %s tautology\n' "$spec_id"; rc=1
        elif [[ "$only_head_fail" -eq 1 ]]; then
            printf 'NEGCTL FAIL %s not_passing_at_head\n' "$spec_id"; rc=1
        elif [[ "$saw_timeout" -eq 1 ]]; then
            # Only-signal was a timeout: infra, not a genuine violation.
            printf 'NEGCTL ERROR timeout:%s\n' "$spec_id"; rc=1
        else
            printf 'NEGCTL FAIL %s tautology\n' "$spec_id"; rc=1
        fi
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)

    return "$rc"
}
