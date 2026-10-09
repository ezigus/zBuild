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
# Only a code requirement (`[code]`, the old `[change]`, or no tag) is checked
# this way (#2304, ADR-069 §3). A done requirement (`[done]`, the old `[guard]`)
# and a no-code one (`[no-code]`) have nothing on the old code to fail, so they
# are not run (§4): NEGCTL SKIP <id> already_done | no_code.
#
# Granularity: each SPEC is judged by its own [spec_id]-tagged ✓/✗ lines in the
# file's output (#1969), falling back to the file rc where it printed none.
#
# Size: over 500 lines, deliberately. A sibling loaded as `source "$DIR/x.sh"`
# would join _runner_contract_lib_closure — the set that decides whether a run
# grades itself (ADR-057 gate 2) — and widen it for a cosmetic gain. It would
# not change what a self-grading run reads: that snapshot copies every
# top-level lib (#1752).
#
# Source-only; no `set -e` at top level (would mutate caller options).


# #2010: zbuild_engine_tmpdir names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmpdir >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)/helpers.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" helpers.sh"
fi

[[ -n "${_ACCEPTANCE_NEGCTL_LOADED:-}" ]] && return 0
_ACCEPTANCE_NEGCTL_LOADED=1

_ACCEPTANCE_NEGCTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./acceptance-block.sh
source "$_ACCEPTANCE_NEGCTL_DIR/acceptance-block.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-block.sh"
# shellcheck source=./acceptance-coverage.sh
source "$_ACCEPTANCE_NEGCTL_DIR/acceptance-coverage.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" acceptance-coverage.sh"
# shellcheck source=./merge-base.sh
source "$_ACCEPTANCE_NEGCTL_DIR/merge-base.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" merge-base.sh"
# #1644: the sandbox below scrubs runner state via the SAME contract the test
# stage uses, instead of a second, partial hand-list that keeps falling behind.
# shellcheck source=env-scrub.sh
source "$_ACCEPTANCE_NEGCTL_DIR/env-scrub.sh" || _ZBUILD_CONTRACT_LOAD_ERRORS+=" env-scrub.sh"

# _acceptance_is_test_path <path> — a test file: under tests/, or under a
# plugin's own plugins/<kind>/<id>/tests/ (#2300).
_acceptance_is_test_path() {
    [[ "${1:-}" == tests/* || "${1:-}" =~ ^plugins/[^/]+/[^/]+/tests/ ]]
}

# _acceptance_is_production_path <path> — production code (ADR-069 §5): any
# path except tests (above), docs/ and Markdown files.
_acceptance_is_production_path() {
    local p="${1:-}"
    [[ -n "$p" ]] || return 1
    _acceptance_is_test_path "$p" && return 1
    [[ "$p" == docs/* || "$p" == *.md ]] && return 1
    return 0
}

# acceptance_unclaimed_code_check <design_md> <repo_root>  (#2304, ADR-069 §5)
# A requirement marked no-code or done is never run against the old code, so
# a change could ship code under those labels with nothing showing its tests
# fail without it. When the branch (merge-base..HEAD) changes production code
# and the block declares requirements but none of them is code, print one line
# per production path:
#   UNCLAIMED_CODE <path>
# and return 1. Otherwise print nothing and return 0. An untagged requirement
# counts as code: the negative control checks it as one (design-gate C3 rejects
# it before it gets here). A block with no requirement ids has no status to
# read, and a baseline that does not resolve has no diff to judge — both are
# silent here (the gate's preconditions and Level 1 own those cases).
acceptance_unclaimed_code_check() {
    local design_md="${1:-}" repo_root="${2:-}"
    [[ -n "$design_md" && -n "$repo_root" && -f "$design_md" ]] || return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    local line any_id=0
    while IFS= read -r line; do
        [[ "$line" == "TESTFILES:" ]] && break
        [[ "$line" =~ $_ACCEPTANCE_SPEC_RE ]] || continue
        any_id=1
        case "${BASH_REMATCH[3]}" in
            ""|code|change) return 0 ;;
        esac
    done <<< "$block_output"
    [[ "$any_id" -eq 1 ]] || return 0
    local base_sha; base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    [[ -n "$base_sha" ]] || return 0
    local p found=0
    while IFS= read -r p; do
        if _acceptance_is_production_path "$p"; then
            printf 'UNCLAIMED_CODE %s\n' "$p"
            found=1
        fi
    done < <(git -C "$repo_root" diff --name-only "$base_sha" HEAD 2>/dev/null || true)
    [[ "$found" -eq 0 ]]
}

# A timeout leaves the run's true pass/fail unknown, so it is an INFRASTRUCTURE
# signal, never a control/violation (ADR-036 #1188). Only the TIMER's own exit
# codes mean that: GNU `timeout` exits 124 when its timer fires (whatever signal
# then ended the child — it does not pass 143 through without --preserve-status),
# and 137 when its -k kill-after SIGKILL lands. These are OS conventions, the
# same in every repository and test runner.
#
# 143 (128+15) is NOT on the list: it means "a SIGTERM killed it", from anyone.
# #1847 run 20260928144733-57620: a TESTFILE stubbed the model call as
# `kill -TERM "$$"`, died at the merge-base after ~1s, and every SPEC after that
# point was reported `timeout:` — infra, owned by nobody — under a 60s timer
# that never fired. See _negctl_is_signal_rc.
_negctl_is_timeout_rc() {
    [[ "$1" -eq 124 ]] && return 0
    [[ "$1" -eq 137 && "${_ACCEPTANCE_TIMEOUT_KILL_OK:-}" == "yes" ]]
}

# rc 0 when the run was ended by a signal (128+N) and the timer did not send it:
# the test process was killed — often by itself. That is the test file's defect,
# not infrastructure, and the finding names the class so its author can act.
_negctl_is_signal_rc() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 128 && $1 <= 192 )) \
        && ! _negctl_is_timeout_rc "$1" && ! _negctl_is_sigkill_rc "$1"
}

# rc 0 for a SIGKILL (137) the timer did not send. Nothing inside a test
# normally sends SIGKILL; the usual sender is the OOM killer or an operator, so
# it is INFRASTRUCTURE (`NEGCTL ERROR sigkill:`), not the test's defect — and
# "signal a child instead" would be the wrong advice (review #2220). Before
# #1847's fix it read `timeout`, which was also infra; only the word changed.
_negctl_is_sigkill_rc() {
    [[ "$1" == "137" ]] && ! _negctl_is_timeout_rc "$1"
}

# #1670: rc classes meaning "the runner could not execute the file" rather than
# "an assertion failed" — 126 (found, not executable) and 127 (command not
# found). These are POSIX shell conventions, so the discrimination holds for any
# {files} runner configured via ZBUILD_ACCEPTANCE_RUN_CMD (#1478), not just bash.
_negctl_is_harness_rc() { [[ "$1" -eq 126 || "$1" -eq 127 ]]; }

# _negctl_spec_log_check <logfile> <spec_id>
# Scans ONE TESTFILE's captured output for [spec_id]-tagged assertion lines,
# after stripping ANSI escapes (LC_ALL=C sed, as test-output-sanitize.sh).
# Returns:
#   0 — a ✗-marked line tagged [spec_id] → this SPEC's own assertion failed
#   1 — a ✓-marked line tagged [spec_id] and no ✗ → a sibling caused the exit
#   2 — inconclusive: no marked [spec_id] line, empty capture, or a custom
#       runner. The caller falls back to the file rc — the safe direction.
#
# #1737: BOTH markers must be looked for, not just ✗. A bare `grep -v ✗` would
# read "tag mentioned anywhere" as "it held", so a tag appearing only in a
# comment or a stale assertion from an earlier issue would count as a result.
#
# #1691/#1740: gated on the default bash runner. A repo pointing
# ZBUILD_ACCEPTANCE_RUN_CMD (#1478) at pytest/jest/cargo emits nothing like ✓/✗,
# so parsing its output would be guesswork; those targets keep the file-rc
# verdict.
_negctl_spec_log_check() {
    local logfile="$1" spec_id="$2"
    [[ -n "${ZBUILD_ACCEPTANCE_RUN_CMD:-}" ]] && return 2
    [[ -f "$logfile" ]] || return 2
    local clean tagged
    clean="$(LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g' "$logfile" 2>/dev/null)" || true
    [[ -z "$clean" ]] && return 2
    # grep exits non-zero on no-match, which is the only way $tagged can be
    # empty — a matched line always contains the tag.
    tagged="$(LC_ALL=C grep -F "$(acceptance_spec_tag "$spec_id")" <<< "$clean" 2>/dev/null)" || return 2
    # ✗ wins over ✓: one failing tagged assertion fails the SPEC.
    LC_ALL=C grep -qF '✗' <<< "$tagged" 2>/dev/null && return 0
    LC_ALL=C grep -qF '✓' <<< "$tagged" 2>/dev/null && return 1
    return 2
}

# _negctl_last_other_verdict <logfile> <spec_id> → prints the id of the LAST
# other SPEC of this contract that printed a ✓/✗ verdict, rc 0; rc 1 when none
# did. A file that printed verdicts for its other SPECs and none for this one
# stopped before this assertion ran (#1835): what it says about this SPEC is
# nothing. Keyed on the contract's own tag shape, so it holds for any language;
# a bare test (#1658, no verdict lines at all) finds nothing here.
_negctl_last_other_verdict() {
    local logfile="$1" spec_id="$2" tag prefix line rest id last=""
    [[ -n "${ZBUILD_ACCEPTANCE_RUN_CMD:-}" || ! -f "$logfile" ]] && return 1
    tag="$(acceptance_spec_tag "$spec_id")"
    prefix="${tag%"$spec_id"]}SPEC-"
    while IFS= read -r line; do
        [[ "$line" == *"$prefix"* && ( "$line" == *✓* || "$line" == *✗* ) ]] || continue
        rest="${line#*"$prefix"}"
        id="SPEC-${rest%%]*}"
        [[ "$id" =~ ^SPEC-[0-9]+$ && "$id" != "$spec_id" ]] && last="$id"
    done < <(LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g' "$logfile" 2>/dev/null)
    [[ -n "$last" ]] || return 1
    printf '%s' "$last"
}

# _negctl_run <testfile_abs> <cwd> [logfile]  → echoes nothing, returns the rc.
# Runs with ZBUILD_TEST_QUIET unset (so labeled output is produced) under an
# optional timeout (ZBUILD_NEGCTL_TIMEOUT, default 60s). When <logfile> is given
# the combined stdout+stderr is appended there (size-bounded by the caller) so a
# failed control is diagnosable; otherwise output is discarded.
_negctl_run() {
    local testfile="$1" cwd="$2" logfile="${3:-}"
    local timeout_s="${ZBUILD_NEGCTL_TIMEOUT:-60}"
    # #2110: raise to the file's measured time; one execution per file per pass.
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
    _acceptance_run_cached "$testfile" "$logfile" _negctl_run_once "$cwd" "${runner[@]}"
}

# _negctl_run_once <cwd> <runner...> — the un-memoised execution (#2110).
_negctl_run_once() {
    local cwd="$1"; shift
    local -a runner=("$@")
    (
        cd "$cwd" || exit 2
        # #1644: scrub ALL runner state, not a hand-picked subset. This list grew
        # once per outage — #983 (test-runner parallelism, a fork-bomb), #1211
        # (ZBUILD_STAGE_IO_FD escaping via inherited fd 3), #1567 (banner labels)
        # — and each time the NEXT leaked variable was found the same way: a
        # correct change rejected with a false not_passing_at_head. #1644 was the
        # fourth, ZBUILD_RUN_ID, which flips the router into its in-a-run branch
        # and fails 21 unrelated assertions in any TESTFILE that calls it.
        #
        # env-scrub.sh already settled this argument for the test stage: "per-var
        # scrub doesn't generalize" (#645/Wave 11A missed ZBUILD_RUN_ID for the
        # same reason). Using the same contract here means a new runner variable
        # cannot leak into a TESTFILE without someone deliberately exempting it.
        _zbuild_make_fresh_shell
        "${runner[@]}"
    )
}

# _negctl_bound_log <file> [max_bytes] — keep only the last max_bytes of a log so
# a runaway test cannot blow up the state dir. Default cap 64 KiB.
_negctl_bound_log() {
    local f="$1" cap="${2:-65536}"
    [[ -n "$f" && -f "$f" ]] || return 0
    local sz; sz="$(wc -c 2>/dev/null < "$f" || echo 0)"
    if [[ "$sz" =~ ^[0-9]+$ && "$sz" -gt "$cap" ]]; then
        tail -c "$cap" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
    fi
}

# _negctl_emit_whole_run_skip <design_md> <reason> — #1715: a whole-run skip's
# reason is run-wide but the roster of unverified SPECs is not, so emit one line
# per declared SPEC. Falls back to the pre-#1715 bare line when the roster cannot
# be read: emitting nothing would turn "we verified nothing, here is what" into
# silence, which reads identically to the check never having run.
_negctl_emit_whole_run_skip() {
    local design_md="$1" reason="$2" spec_id emitted=0
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        printf 'NEGCTL SKIP %s %s\n' "$spec_id" "$reason"
        emitted=1
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
    [[ "$emitted" -eq 0 ]] && printf 'NEGCTL SKIP %s\n' "$reason"
    return 0
}

# acceptance_negctl_check <design_md> <repo_root>
# Prints one verdict line per SPEC-n:
#   NEGCTL PASS <spec_id>      — ≥1 tagged testfile fails at baseline, passes at HEAD
#   NEGCTL FAIL <spec_id> <reason>   reason ∈ {tautology, not_passing_at_head,
#                                no_testfile, unreached_at_base,
#                                unreached_at_head, killed_by_signal}
#   NEGCTL ERROR <detail>      — infrastructure (baseline_resolve_failed,
#                                worktree_failed, timeout:<spec_id>,
#                                harness:<spec_id>, sigkill:<spec_id>)
#   NEGCTL SKIP <spec_id> <detail> — no negative control possible for that SPEC
#                                (no_impl_delta, no_prod_delta). #1715: the
#                                reason is run-wide but the roster is not, so
#                                these emit once per declared SPEC.
#   NEGCTL SKIP <detail>       — same, when the SPEC roster is unavailable
#   NEGCTL SKIP <spec_id> already_done — a done requirement: not run (ADR-069 §4)
#   NEGCTL SKIP <spec_id> no_code      — a no-code requirement: not run (ADR-069 §4)
#
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
        _negctl_emit_whole_run_skip "$design_md" no_impl_delta
        return 0
    fi

    # Test-only diff: every changed path is under tests/ or a plugin's own
    # plugins/<kind>/<id>/tests/ (#2300) → no production code to revert, so the
    # baseline worktree would be byte-identical for all impl paths.
    # Tautology-fail would be a false positive; skip instead.
    local -a _nd_paths=()
    local _nd_p
    while IFS= read -r _nd_p; do
        [[ -n "$_nd_p" ]] && _nd_paths+=("$_nd_p")
    done < <(git -C "$repo_root" diff --name-only "$base_sha" HEAD 2>/dev/null || true)
    if [[ "${#_nd_paths[@]}" -gt 0 ]]; then
        local _nd_all_test=1
        for _nd_p in "${_nd_paths[@]}"; do
            if ! _acceptance_is_test_path "$_nd_p"; then
                _nd_all_test=0; break
            fi
        done
        if [[ "$_nd_all_test" -eq 1 ]]; then
            _negctl_emit_whole_run_skip "$design_md" no_prod_delta
            return 0
        fi
    fi

    # Each SPEC's status, read once (ADR-069 §1). With no code requirement
    # there is nothing to run, and no worktree is made.
    local -A _statuses=()
    local -a _sid_order=()
    local _blk _sid _any_code=0
    _blk="$(extract_acceptance_block "$design_md" 2>/dev/null || true)"
    while IFS= read -r _sid; do
        [[ -n "$_sid" ]] || continue
        _acceptance_spec_line "$_blk" "$_sid" || _ACC_SPEC_STATUS=""
        _statuses[$_sid]="$_ACC_SPEC_STATUS"
        _sid_order+=("$_sid")
        [[ "$_ACC_SPEC_STATUS" == "done" || "$_ACC_SPEC_STATUS" == "no-code" ]] || _any_code=1
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
    if [[ "$_any_code" -eq 0 && ${#_sid_order[@]} -gt 0 ]]; then
        for _sid in "${_sid_order[@]}"; do
            [[ "${_statuses[$_sid]}" == "done" ]] && printf 'NEGCTL SKIP %s already_done\n' "$_sid" \
                || printf 'NEGCTL SKIP %s no_code\n' "$_sid"
        done
        return 0
    fi

    # Collect declared TESTFILES (existing on disk) once.
    local -a testfiles=()
    local tf
    while IFS= read -r tf; do
        [[ -n "$tf" && -f "$repo_root/$tf" ]] && testfiles+=("$tf")
    done < <(acceptance_list_testfiles "$design_md")

    # Detached worktree at baseline; overlay each TESTFILE from HEAD.
    local wt_dir; wt_dir="$(mktemp -d "$(zbuild_engine_tmpdir)/zb-negctl.XXXXXX")"
    # #2110: one execution per file per pass — the memo lives for this check
    # (or for the plugin's whole gate pass when it created the directory).
    _acceptance_run_cache_begin
    local _rc_rm=""; [[ "${_ACCEPTANCE_RUN_CACHE_OWNED:-0}" -eq 1 ]] && _rc_rm="rm -rf '${_ACCEPTANCE_RUN_CACHE_DIR:-}' 2>/dev/null; unset _ACCEPTANCE_RUN_CACHE_DIR;"
    # shellcheck disable=SC2064
    trap "git -C '$repo_root' worktree remove --force '$wt_dir' >/dev/null 2>&1 || true; rm -rf '$wt_dir' 2>/dev/null || true; $_rc_rm" RETURN
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
        # #2304 (ADR-069 §4): only a code requirement has something on the old
        # code to fail. A done or no-code one is not run.
        case "${_statuses[$spec_id]:-}" in
            done)    printf 'NEGCTL SKIP %s already_done\n' "$spec_id"; continue ;;
            no-code) printf 'NEGCTL SKIP %s no_code\n' "$spec_id"; continue ;;
        esac
        local found_control=0 saw_tautology=0 saw_tagged=0 only_head_fail=0 saw_timeout=0 saw_harness=0 saw_signal=0 saw_sigkill=0
        local ub_after="" uh_after=""
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
                grep -qF "$(acceptance_spec_tag "$spec_id")" "$repo_root/$_ctf" 2>/dev/null || continue
                saw_tagged=1; _cand_tfs+=("$_ctf")
            done
        fi
        for tf in "${_cand_tfs[@]:-}"; do
            [[ -z "$tf" ]] && continue
            # The baseline run is EXPECTED to fail; capture rc via `|| rc=$?`
            # so a non-zero exit never aborts the caller under `set -e`.
            local rc_base=0 rc_head=0
            # #1969: capture each run separately so the per-assertion scan can
            # tell the baseline's evidence from HEAD's. Appending both to the
            # shared per-SPEC log (pre-#1969) made that impossible — a ✓ from
            # the HEAD run would clear a ✗ from the baseline run and vice
            # versa. The scratch files are folded into $logfile afterwards, so
            # the artifact shape operators read is unchanged.
            local _cap_base _cap_head
            _cap_base="$(mktemp "$(zbuild_engine_tmpdir)/zb-negctl-base.XXXXXX")" || _cap_base=""
            _cap_head="$(mktemp "$(zbuild_engine_tmpdir)/zb-negctl-head.XXXXXX")" || _cap_head=""
            _negctl_run "$wt_dir/$tf" "$wt_dir" "$_cap_base" || rc_base=$?
            _negctl_run "$repo_root/$tf" "$repo_root" "$_cap_head" || rc_head=$?
            if [[ -n "$logfile" ]]; then
                printf '### %s baseline %s\n' "$spec_id" "$tf" >> "$logfile"
                [[ -n "$_cap_base" ]] && cat "$_cap_base" >> "$logfile" 2>/dev/null
                printf '### %s head %s\n' "$spec_id" "$tf" >> "$logfile"
                [[ -n "$_cap_head" ]] && cat "$_cap_head" >> "$logfile" 2>/dev/null
            fi
            # A timeout on EITHER run leaves pass/fail unknown → INFRA, not a
            # control or a not_passing_at_head violation. Skip this testfile.
            if _negctl_is_timeout_rc "$rc_base" || _negctl_is_timeout_rc "$rc_head"; then
                [[ -n "$_cap_base" ]] && rm -f "$_cap_base"
                [[ -n "$_cap_head" ]] && rm -f "$_cap_head"
                saw_timeout=1; continue
            fi
            # #1969: judge THIS SPEC by its own [spec_id]-tagged assertions, not
            # by the file's exit code. A file mixes many assertions; before this
            # a single unrelated red one condemned every SPEC bound to the file.
            # Run 32886585375 lost 4h to exactly that: SPEC-1..SPEC-8 were each
            # ✓ at HEAD and all eight were reported not_passing_at_head because
            # a ninth, untagged assertion had a `grep -c … || echo 0` typo.
            # 0 = a ✗ line for this SPEC, 1 = a ✓ line and no ✗, 2 = no verdict.
            local _lv_base=2 _lv_head=2
            _negctl_spec_log_check "$_cap_base" "$spec_id" && _lv_base=0 || _lv_base=$?
            _negctl_spec_log_check "$_cap_head" "$spec_id" && _lv_head=0 || _lv_head=$?
            # #1835: this SPEC printed nothing of its own while others did — the
            # file stopped before its assertion ran, on that side.
            local _ub="" _uh=""
            [[ "$_lv_base" -eq 2 && "$rc_base" -ne 0 ]] && _ub="$(_negctl_last_other_verdict "$_cap_base" "$spec_id")"
            [[ "$_lv_head" -eq 2 && "$rc_head" -ne 0 ]] && _uh="$(_negctl_last_other_verdict "$_cap_head" "$spec_id")"
            [[ -n "$_cap_base" ]] && rm -f "$_cap_base"
            [[ -n "$_cap_head" ]] && rm -f "$_cap_head"
            # A run that died on a signal without printing this SPEC's verdict
            # never reached its assertion — no evidence either way, and not a
            # timeout. A ✗/✓ printed before the death is real evidence and is
            # used as it stands (#1847).
            if { [[ "$_lv_base" -eq 2 ]] && _negctl_is_signal_rc "$rc_base"; } \
               || { [[ "$_lv_head" -eq 2 ]] && _negctl_is_signal_rc "$rc_head"; }; then
                saw_signal=1; continue
            fi
            if { [[ "$_lv_base" -eq 2 ]] && _negctl_is_sigkill_rc "$rc_base"; } \
               || { [[ "$_lv_head" -eq 2 ]] && _negctl_is_sigkill_rc "$rc_head"; }; then
                saw_sigkill=1; continue
            fi
            # Unreached is "not measured", never "failed": at the merge-base it
            # proves no negative control; on the new code it hides the SPEC
            # from the check. Both are the file's or the code's, never design's.
            if [[ -n "$_ub" ]]; then ub_after="$_ub"; continue; fi
            if [[ -n "$_uh" ]]; then uh_after="$_uh"; continue; fi
            # Fall back to the file rc only where the log carries no verdict for
            # this SPEC — a custom runner, an empty capture, or a run that died
            # before reaching the assertion. That is pre-#1969 behaviour, i.e.
            # the safe direction, and it is the same fallback #1737 chose.
            local _base_failed _head_failed
            case "$_lv_base" in
                0) _base_failed=1 ;;
                1) _base_failed=0 ;;
                *) [[ "$rc_base" -ne 0 ]] && _base_failed=1 || _base_failed=0 ;;
            esac
            case "$_lv_head" in
                0) _head_failed=1 ;;
                1) _head_failed=0 ;;
                *) [[ "$rc_head" -ne 0 ]] && _head_failed=1 || _head_failed=0 ;;
            esac
            # #1969: 126/127 means "the runner could not execute this file",
            # never "the assertion failed". Before #1969 a baseline that died on
            # a function the change introduces was silently accepted as a valid
            # negative control. Only consulted where the log gave no verdict: a
            # SPEC that printed its own ✗ before the abort keeps that evidence.
            if [[ "$_lv_base" -eq 2 ]] && _negctl_is_harness_rc "$rc_base"; then
                saw_harness=1; continue
            fi
            if [[ "$_lv_head" -eq 2 ]] && _negctl_is_harness_rc "$rc_head"; then
                saw_harness=1; continue
            fi
            if [[ "$_base_failed" -eq 1 && "$_head_failed" -eq 0 ]]; then
                found_control=1; break
            elif [[ "$_base_failed" -eq 0 ]]; then
                saw_tautology=1
            elif [[ "$_head_failed" -eq 1 ]]; then
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
        # Unreached ranks BELOW tautology and not_passing_at_head on purpose:
        # those are what a file that DID reach the assertion showed — evidence —
        # and unreached is only the absence of it in another file. Evidence
        # outranks absence; the unreached file is still named when it is all
        # there is (review #2235).
        elif [[ -n "$ub_after" ]]; then
            printf 'NEGCTL FAIL %s unreached_at_base after=%s\n' "$spec_id" "$ub_after"; rc=1
        elif [[ -n "$uh_after" ]]; then
            printf 'NEGCTL FAIL %s unreached_at_head after=%s\n' "$spec_id" "$uh_after"; rc=1
        elif [[ "$saw_signal" -eq 1 ]]; then
            # The file died on a signal before this SPEC's assertion ran. The
            # test's defect, so it is its author's to fix — not infrastructure.
            printf 'NEGCTL FAIL %s killed_by_signal\n' "$spec_id"; rc=1
        elif [[ "$saw_timeout" -eq 1 ]]; then
            # Nothing but timer stops for this SPEC: infra, not a violation.
            printf 'NEGCTL ERROR timeout:%s\n' "$spec_id"; rc=1
        elif [[ "$saw_sigkill" -eq 1 ]]; then
            # A SIGKILL from outside (OOM, operator): infra, not the test's defect.
            printf 'NEGCTL ERROR sigkill:%s\n' "$spec_id"; rc=1
        elif [[ "$saw_harness" -eq 1 ]]; then
            # Only-signal was 126/127: the runner could not execute the file, so
            # pass/fail is unknown (#1969). Infra, like a timeout — never a
            # control and never a violation.
            printf 'NEGCTL ERROR harness:%s\n' "$spec_id"; rc=1
        else
            printf 'NEGCTL FAIL %s tautology\n' "$spec_id"; rc=1
        fi
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)

    return "$rc"
}
