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
# Granularity: [change] SPECs use per-TESTFILE rc (file-level exit code), not
# per-assertion. [guard] SPECs additionally consult the guard's own
# [spec_id]-tagged output line, so a sibling [change] assertion failing at
# baseline does not condemn the guard (#1737) — but only under the default bash
# runner, and only when that line carries an explicit ✓/✗ marker; every other
# case keeps the file-rc verdict. Author one SPEC per test file (or one tagged
# assertion per file) for precise attribution; a file mixing a load-bearing and a
# tautological [change] SPEC is judged load-bearing.
#
# Size (CLAUDE.md "under 500 lines unless there is a strong reason"): this file
# is over, and stays over deliberately. The guard helpers below are shared by the
# acceptance gate and the design-gate pre-check (#1777); splitting them into a
# sibling under scripts/lib would add that file to _runner_contract_lib_closure —
# runner.sh derives the hot-reloaded contract-reader set by following
# same-directory `source` lines — which widens ADR-057 gate 2 and changes which
# future issues must be built by hand. That is a real architectural cost for a
# cosmetic gain.
#
# Source-only; no `set -e` at top level (would mutate caller options).


# #2010: zbuild_engine_tmp names where engine code writes temp files.
# Lazy-sourced, same pattern lifecycle.sh uses for stage-scratch.sh: this
# file is sourced from several entry points and cannot assume helpers.sh
# arrived first. helpers.sh sources only compat.sh, so there is no cycle.
if ! declare -F zbuild_engine_tmp >/dev/null 2>&1; then
    # shellcheck source=./helpers.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)/helpers.sh" 2>/dev/null || true
fi

[[ -n "${_ACCEPTANCE_NEGCTL_LOADED:-}" ]] && return 0
_ACCEPTANCE_NEGCTL_LOADED=1

_ACCEPTANCE_NEGCTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./acceptance-block.sh
source "$_ACCEPTANCE_NEGCTL_DIR/acceptance-block.sh"
# shellcheck source=./acceptance-coverage.sh
source "$_ACCEPTANCE_NEGCTL_DIR/acceptance-coverage.sh"
# shellcheck source=./merge-base.sh
source "$_ACCEPTANCE_NEGCTL_DIR/merge-base.sh"
# #1644: the sandbox below scrubs runner state via the SAME contract the test
# stage uses, instead of a second, partial hand-list that keeps falling behind.
# shellcheck source=env-scrub.sh
source "$_ACCEPTANCE_NEGCTL_DIR/env-scrub.sh"

# A timeout leaves the run's true pass/fail unknown, so it is an INFRASTRUCTURE
# signal, never a control/violation (ADR-036 #1188): `timeout` exits 124 when it
# TERMs the child, 143 when the child dies from that SIGTERM, 137 when a
# -k kill-after SIGKILL lands or an external OOM kill reaches the child (128+9).
_negctl_is_timeout_rc() { [[ "$1" -eq 124 || "$1" -eq 137 || "$1" -eq 143 ]]; }

# #1670: rc classes meaning "the runner could not execute the file" rather than
# "an assertion failed" — 126 (found, not executable) and 127 (command not
# found). These are POSIX shell conventions, so the discrimination holds for any
# {files} runner configured via ZBUILD_ACCEPTANCE_RUN_CMD (#1478), not just bash.
_negctl_is_harness_rc() { [[ "$1" -eq 126 || "$1" -eq 127 ]]; }

# #1670: a baseline copy that does not PARSE never reached an assertion, so its
# non-zero rc says nothing about the invariant. Only the default bash runner can
# be parse-checked; a custom ZBUILD_ACCEPTANCE_RUN_CMD reports "parses" so its
# behaviour is unchanged.
_negctl_baseline_parses() {
    local f="$1"
    [[ -n "${ZBUILD_ACCEPTANCE_RUN_CMD:-}" ]] && return 0
    [[ -f "$f" ]] || return 1
    bash -n "$f" 2>/dev/null
}

# _negctl_guard_log_check <logfile> <spec_id>
# Scans ONE TESTFILE's captured baseline output for [spec_id]-tagged assertion
# lines, after stripping ANSI escapes (LC_ALL=C sed, as test-output-sanitize.sh).
# Returns:
#   0 — a ✗-marked line tagged [spec_id] → the guard's own assertion failed
#   1 — a ✓-marked line tagged [spec_id] and no ✗ → a sibling caused the exit
#   2 — inconclusive: no marked [spec_id] line, empty capture, or a custom
#       runner. The caller falls back to the file rc, which is pre-#1737
#       behaviour — the safe direction.
#
# #1737: BOTH markers must be looked for, not just ✗. A bare `grep -v ✗` would
# read "tag mentioned anywhere" as "the guard held", so a tag appearing only in a
# comment, a header, or an unrelated stale assertion from an earlier issue would
# clear a guard that asserted nothing. Requiring an explicit ✓ makes the evidence
# an assertion result rather than a string match.
#
# #1691/#1740: gated on the default bash runner. A repo pointing
# ZBUILD_ACCEPTANCE_RUN_CMD (#1478) at pytest/jest/cargo emits nothing like ✓/✗,
# so parsing its output would be guesswork; those targets keep the file-rc
# verdict they have today. Same precedent as _negctl_baseline_parses.
_negctl_guard_log_check() {
    local logfile="$1" spec_id="$2"
    [[ -n "${ZBUILD_ACCEPTANCE_RUN_CMD:-}" ]] && return 2
    [[ -f "$logfile" ]] || return 2
    local clean tagged
    clean="$(LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g' "$logfile" 2>/dev/null)" || true
    [[ -z "$clean" ]] && return 2
    # grep exits non-zero on no-match, which is the only way $tagged can be
    # empty — a matched line always contains the tag.
    tagged="$(printf '%s\n' "$clean" | LC_ALL=C grep -F "[$spec_id]" 2>/dev/null)" || return 2
    # ✗ wins over ✓: a guard with one failing and one passing tagged assertion
    # has regressed.
    LC_ALL=C grep -qF '✗' <<< "$tagged" 2>/dev/null && return 0
    LC_ALL=C grep -qF '✓' <<< "$tagged" 2>/dev/null && return 1
    return 2
}

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
    _acceptance_timeout_prefix "$timeout_s"
    if [[ ${#_ACCEPTANCE_TOUT[@]} -gt 0 ]]; then
        runner=("${_ACCEPTANCE_TOUT[@]}" "${runner[@]}")
    fi
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

# _negctl_guard_resolve_tfs <design_md> <repo_root> <spec_id> [<pool>...]
# Echoes the TESTFILEs a [guard] SPEC is measured against, one per line, keeping
# only those present on disk under <repo_root>. Per-SPEC binding wins (#1480, no
# sibling-riding); with no binding, fall back to scanning the declared <pool> for
# the [spec_id] tag.
#
# #1777: extracted so the design-gate pre-check and this file's own guard arm
# resolve the SAME set. Two copies of "which files does this guard own" is how
# the pre-check and the gate would come to disagree about the same design.
_negctl_guard_resolve_tfs() {
    local design_md="$1" repo_root="$2" spec_id="$3"; shift 3
    local _tf
    if acceptance_spec_has_binding "$design_md" "$spec_id"; then
        while IFS= read -r _tf; do
            [[ -n "$_tf" && -f "$repo_root/$_tf" ]] && printf '%s\n' "$_tf"
        done < <(acceptance_list_testfiles_for_spec "$design_md" "$spec_id")
    else
        for _tf in "$@"; do
            [[ -z "$_tf" ]] && continue
            grep -qF "[$spec_id]" "$repo_root/$_tf" 2>/dev/null || continue
            printf '%s\n' "$_tf"
        done
    fi
    return 0
}

# _negctl_guard_verdict <wt_dir> <spec_id> <logfile> <testfile>...
# Runs a [guard] SPEC's TESTFILEs inside the baseline worktree and echoes ONE of:
#   held       — every tagged assertion holds at the merge-base (a real guard)
#   regressed  — the guard's own assertion FAILS there, so it is not an invariant
#   timeout    — a run was killed; pass/fail unknown (infrastructure)
#   harness    — unparseable at baseline, or the runner could not execute it
# <logfile> may be empty to discard the per-TESTFILE capture.
#
# #1777: extracted verbatim from acceptance_negctl_check's guard arm so the
# design-gate can apply the identical rule one stage earlier. The #1737 ✓/✗
# discrimination lives here and therefore cannot drift between the two callers.
_negctl_guard_verdict() {
    local wt_dir="$1" spec_id="$2" logfile="$3"; shift 3
    local _g_tf _g_rc _g_capfile _g_lv
    for _g_tf in "$@"; do
        # A baseline run that never reached an assertion (unparseable at the
        # merge-base, or a runner that could not execute it) proves nothing
        # either way — warn, never block. Distinguishing this from a real
        # assertion failure is what keeps a guard whose test depends on code
        # this change introduces from being unlandable.
        if ! _negctl_baseline_parses "$wt_dir/$_g_tf"; then printf 'harness'; return 0; fi
        _g_rc=0
        # #1737: capture PER TESTFILE, never into the shared per-SPEC log.
        # $logfile accumulates every TESTFILE bound to this SPEC, so scanning it
        # would let file A's passing ✓ clear file B's failure.
        _g_capfile="$(mktemp "$(zbuild_engine_tmp)/zb-negctl-guard.XXXXXX")" || _g_capfile=""
        _negctl_run "$wt_dir/$_g_tf" "$wt_dir" "$_g_capfile" || _g_rc=$?
        # Fold the capture into the per-SPEC diagnostic log, preserving the
        # pre-#1737 artifact shape operators read.
        if [[ -n "$logfile" ]]; then
            printf '### %s baseline %s\n' "$spec_id" "$_g_tf" >> "$logfile"
            [[ -n "$_g_capfile" ]] && cat "$_g_capfile" >> "$logfile" 2>/dev/null
        fi
        if _negctl_is_timeout_rc "$_g_rc"; then
            [[ -n "$_g_capfile" ]] && rm -f "$_g_capfile"
            printf 'timeout'; return 0
        fi
        if _negctl_is_harness_rc "$_g_rc"; then
            [[ -n "$_g_capfile" ]] && rm -f "$_g_capfile"
            printf 'harness'; return 0
        fi
        # lv=1 (a ✓-marked [spec_id] line, no ✗) is the ONLY outcome that clears
        # a non-zero file rc: a sibling [change] assertion reddened the file
        # while the guard's own assertion held. Everything else — ✗ found,
        # nothing marked, custom runner — keeps the file-rc verdict.
        _g_lv=1
        if [[ "$_g_rc" -ne 0 ]]; then
            _negctl_guard_log_check "$_g_capfile" "$spec_id" && _g_lv=0 || _g_lv=$?
        fi
        [[ -n "$_g_capfile" ]] && rm -f "$_g_capfile"
        if [[ "$_g_rc" -ne 0 && "$_g_lv" -ne 1 ]]; then printf 'regressed'; return 0; fi
    done
    printf 'held'
    return 0
}


# acceptance_negctl_check <design_md> <repo_root>
# Prints one verdict line per SPEC-n:
#   NEGCTL PASS <spec_id>      — ≥1 tagged testfile fails at baseline, passes at HEAD
#   NEGCTL PASS <spec_id> guard_spec — [guard]: the invariant holds at baseline
#   NEGCTL FAIL <spec_id> <reason>   reason ∈ {tautology, not_passing_at_head,
#                                no_testfile, guard_regressed}
#   NEGCTL ERROR <detail>      — infrastructure (baseline_resolve_failed,
#                                worktree_failed, timeout:<spec_id>,
#                                harness:<spec_id>)
#   NEGCTL SKIP <spec_id> <detail> — no negative control possible for that SPEC
#                                (no_impl_delta, no_prod_delta). #1715: the
#                                reason is run-wide but the roster is not, so
#                                these emit once per declared SPEC.
#   NEGCTL SKIP <detail>       — same, when the SPEC roster is unavailable
#   NEGCTL SKIP <spec_id> guard_untested — [guard] with no tagged assertion (#1255)
#
# #1670 — [change] vs [guard] at the merge-base. A [change] SPEC's assertion must
# FAIL there (it describes behaviour that does not exist yet); a [guard] SPEC's
# must PASS there (an invariant holds at the baseline by definition). A guard
# assertion that fails at baseline is therefore not a guard: it is a mislabelled
# [change], or an assertion inverted relative to its own SPEC text.
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
            _negctl_emit_whole_run_skip "$design_md" no_prod_delta
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
    local wt_dir; wt_dir="$(mktemp -d "$(zbuild_engine_tmp)/zb-negctl.XXXXXX")"
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
        # Guard SPECs are invariants: run only the baseline check.
        # rc=0 at baseline → invariant holds (PASS); rc≠0 → already regressed (FAIL).
        if acceptance_spec_is_guard "$design_md" "$spec_id"; then
            local _g_logfile=""
            if [[ -n "${ZBUILD_NEGCTL_ARTIFACT_DIR:-}" ]]; then
                mkdir -p "$ZBUILD_NEGCTL_ARTIFACT_DIR" 2>/dev/null || true
                _g_logfile="$ZBUILD_NEGCTL_ARTIFACT_DIR/negctl-${spec_id}.log"
                : > "$_g_logfile" 2>/dev/null || _g_logfile=""
            fi
            local -a _g_tfs=()
            local _g_tf
            while IFS= read -r _g_tf; do
                [[ -n "$_g_tf" ]] && _g_tfs+=("$_g_tf")
            done < <(_negctl_guard_resolve_tfs "$design_md" "$repo_root" "$spec_id" \
                        ${testfiles[@]+"${testfiles[@]}"})
            # #1255 exempts [guard] SPECs from the design-gate's tag-coverage
            # rule, so an untagged guard is LEGAL input here. Failing it would
            # deadlock the pipeline: design-gate admits the design, this gate
            # halts the cycle, and no rewind edge exists for the class. Nothing
            # tagged → nothing to measure → skip, exactly as before #1670.
            if [[ ${#_g_tfs[@]} -eq 0 ]]; then
                printf 'NEGCTL SKIP %s guard_untested\n' "$spec_id"; continue
            fi
            local _g_out
            _g_out="$(_negctl_guard_verdict "$wt_dir" "$spec_id" "$_g_logfile" "${_g_tfs[@]}")"
            _negctl_bound_log "$_g_logfile"
            # SPEC id leads every token, as on the [change] lines: the #1684
            # summary enrichment and the plugin's generic FAIL parser both key
            # off that position, so guard verdicts need no special-casing.
            case "$_g_out" in
                timeout)   printf 'NEGCTL ERROR timeout:%s\n' "$spec_id"; rc=1 ;;
                harness)   printf 'NEGCTL ERROR harness:%s\n' "$spec_id"; rc=1 ;;
                regressed) printf 'NEGCTL FAIL %s guard_regressed\n' "$spec_id"; rc=1 ;;
                *)         printf 'NEGCTL PASS %s guard_spec\n' "$spec_id" ;;
            esac
            continue
        fi
        local found_control=0 saw_tautology=0 saw_tagged=0 only_head_fail=0 saw_timeout=0 saw_harness=0
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
            # #1969: capture each run separately so the per-assertion scan can
            # tell the baseline's evidence from HEAD's. Appending both to the
            # shared per-SPEC log (pre-#1969) made that impossible — a ✓ from
            # the HEAD run would clear a ✗ from the baseline run and vice
            # versa. The scratch files are folded into $logfile afterwards, so
            # the artifact shape operators read is unchanged.
            local _cap_base _cap_head
            _cap_base="$(mktemp "$(zbuild_engine_tmp)/zb-negctl-base.XXXXXX")" || _cap_base=""
            _cap_head="$(mktemp "$(zbuild_engine_tmp)/zb-negctl-head.XXXXXX")" || _cap_head=""
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
            _negctl_guard_log_check "$_cap_base" "$spec_id" && _lv_base=0 || _lv_base=$?
            _negctl_guard_log_check "$_cap_head" "$spec_id" && _lv_head=0 || _lv_head=$?
            [[ -n "$_cap_base" ]] && rm -f "$_cap_base"
            [[ -n "$_cap_head" ]] && rm -f "$_cap_head"
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
            # never "the assertion failed" — the [guard] path has classified it
            # as infrastructure since #1670 and the [change] path did not, so a
            # baseline that died on a function the change introduces was
            # silently accepted as a valid negative control. Only consulted
            # where the log gave no verdict: a SPEC that printed its own ✗
            # before the abort has real evidence and keeps it.
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
        elif [[ "$saw_timeout" -eq 1 ]]; then
            # Only-signal was a timeout: infra, not a genuine violation.
            printf 'NEGCTL ERROR timeout:%s\n' "$spec_id"; rc=1
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

# acceptance_negctl_guard_precheck <design_md> <repo_root>
# #1777 — the same [guard] rule as acceptance_negctl_check, applied ONE STAGE
# EARLIER so a mislabelled SPEC costs a design turn instead of a build cycle.
#
# A [guard] SPEC claims an invariant: its assertion must hold at the merge-base
# by definition. An assertion that FAILS there is not a guard — it is a
# mislabelled [change], or an assertion inverted relative to its own SPEC text.
# The acceptance gate already catches this, but only after build has spent its
# entire iteration budget: #1789 lost 5 iterations and 2h06m, #1809 lost 2 more
# and was aborted, and both needed the same two-word fix.
#
# Prints one line per [guard] SPEC:
#   GUARD PASS <spec_id>
#   GUARD FAIL <spec_id> guard_regressed
#   GUARD SKIP <spec_id> <reason>
# Returns 0 when nothing FAILed, 1 otherwise.
#
# FAIL-OPEN on every infrastructure signal — no baseline, no git, no worktree, a
# timeout, an unparseable file. This runs in a T0 structural gate that must not
# become a new way for a correct design to be rejected; the acceptance gate is
# still the authority, this is only an earlier net (ADR-036).
#
# Design-time note: on the FIRST pass of a fresh branch the merge-base IS HEAD,
# so every guard skips `no_impl_delta` and the gate costs nothing. The check
# earns its keep on the REWIND — after build has committed, `route_design` sent
# the run back here, and the same mislabel would otherwise consume another full
# build cycle before being caught again.
acceptance_negctl_guard_precheck() {
    local design_md="${1:-}" repo_root="${2:-}"
    [[ -z "$design_md" || -z "$repo_root" || ! -f "$design_md" ]] && return 0

    # Roster first: with no [guard] SPEC declared there is nothing to measure,
    # and no worktree is created.
    local -a guards=()
    local spec_id
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        acceptance_spec_is_guard "$design_md" "$spec_id" && guards+=("$spec_id")
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
    [[ ${#guards[@]} -eq 0 ]] && return 0

    local base_sha; base_sha="$(zbuild_resolve_merge_base "$repo_root")"
    if [[ -z "$base_sha" ]]; then
        printf 'GUARD SKIP %s no_baseline\n' "${guards[@]}"; return 0
    fi
    local head_sha; head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$head_sha" || "$base_sha" == "$head_sha" ]]; then
        printf 'GUARD SKIP %s no_impl_delta\n' "${guards[@]}"; return 0
    fi

    # The declared pool, for guards that carry no per-SPEC binding.
    local -a testfiles=()
    local tf
    while IFS= read -r tf; do
        [[ -n "$tf" && -f "$repo_root/$tf" ]] && testfiles+=("$tf")
    done < <(acceptance_list_testfiles "$design_md" 2>/dev/null || true)

    local wt_dir; wt_dir="$(mktemp -d "$(zbuild_engine_tmp)/zb-guardpre.XXXXXX")"
    # shellcheck disable=SC2064
    trap "git -C '$repo_root' worktree remove --force '$wt_dir' >/dev/null 2>&1 || true; rm -rf '$wt_dir' 2>/dev/null || true" RETURN
    if ! git -C "$repo_root" worktree add --detach "$wt_dir" "$base_sha" >/dev/null 2>&1; then
        printf 'GUARD SKIP %s worktree_failed\n' "${guards[@]}"; return 0
    fi
    # Overlay each declared TESTFILE from HEAD: impl reverted, assertion current.
    for tf in ${testfiles[@]+"${testfiles[@]}"}; do
        [[ -z "$tf" ]] && continue
        mkdir -p "$wt_dir/$(dirname "$tf")"
        git -C "$repo_root" show "HEAD:$tf" > "$wt_dir/$tf" 2>/dev/null || true
        chmod +x "$wt_dir/$tf" 2>/dev/null || true
    done

    local rc=0 out
    for spec_id in "${guards[@]}"; do
        local -a _tfs=()
        while IFS= read -r tf; do
            [[ -n "$tf" ]] && _tfs+=("$tf")
        done < <(_negctl_guard_resolve_tfs "$design_md" "$repo_root" "$spec_id" \
                    ${testfiles[@]+"${testfiles[@]}"})
        # #1255: an untagged [guard] is legal input — the design-gate exempts it
        # from tag-coverage. Nothing tagged → nothing to measure → skip.
        if [[ ${#_tfs[@]} -eq 0 ]]; then
            printf 'GUARD SKIP %s guard_untested\n' "$spec_id"; continue
        fi
        out="$(_negctl_guard_verdict "$wt_dir" "$spec_id" "" "${_tfs[@]}")"
        case "$out" in
            regressed)       printf 'GUARD FAIL %s guard_regressed\n' "$spec_id"; rc=1 ;;
            timeout|harness) printf 'GUARD SKIP %s %s\n' "$spec_id" "$out" ;;
            *)               printf 'GUARD PASS %s\n' "$spec_id" ;;
        esac
    done
    return "$rc"
}
