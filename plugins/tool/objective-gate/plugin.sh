#!/usr/bin/env bash
# plugins/tool/objective-gate/plugin.sh — Objective Gate Stage (ADR-037 §1, issue #969)
#
# Kind: tool  Tier: T0  (NO LLM — ADR-037 §3 invariant)
# Runs the project test suite and lint/shellcheck. Hard-blocks (returns 1)
# on any non-zero exit. Writes verdict=fail|pass to objective-gate-result.json.
#
# Hook prefix: objective_gate_
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_OBJECTIVE_GATE_LOADED:-}" ]] && return 0
_ZBUILD_OBJECTIVE_GATE_LOADED=1

# shellcheck source=../../../scripts/lib/plugin-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/plugin-bootstrap.sh"
zbuild_plugin_bootstrap "${BASH_SOURCE[0]}"
_OG_ROOT="$_ZBUILD_PLUGIN_ROOT"

# shellcheck source=../../../core/event-bus/event-bus.sh
source "$_OG_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../../core/output/stage-io.sh
# ADR-015 §"command-kind capture is MANDATORY" (#1115): the suite + lint runs are
# the most expensive external commands in the pipeline; wrapping them in
# stage_io_begin/_end gives the operator the standard input/output banner pair
# instead of a silent ~13-min stall. No-op when the stage declares no io: dests.
source "$_OG_ROOT/core/output/stage-io.sh" 2>/dev/null || true
# shellcheck source=../../../scripts/lib/objective-ablation.sh
source "$_OG_ROOT/scripts/lib/objective-ablation.sh" 2>/dev/null || true

# Source locked_state_update for cross-run coverage baseline persistence.
if ! declare -F locked_state_update >/dev/null 2>&1; then
    # shellcheck source=../../../core/state/atomic.sh
    source "$_OG_ROOT/core/state/atomic.sh" 2>/dev/null || true
fi

# Resilient emit — no-op when event-bus is unavailable (unit-test isolation).
_og_emit() { declare -f eb_emit_event >/dev/null 2>&1 && eb_emit_event "$@" || true; }

# ─── objective_gate_init ──────────────────────────────────────────────────────
objective_gate_init() {
    export ZBUILD_PLUGIN="objective-gate"
    export ZBUILD_PLUGIN_KIND="tool"
    _og_emit "plugin.init.start" "plugin=objective-gate"
    _og_emit "plugin.init.complete" "plugin=objective-gate"
    return 0
}

# ─── _og_run_coverage_floor ──────────────────────────────────────────────────
# Invokes ZBUILD_COVERAGE_CMD or scripts/check-coverage.sh. Parses coverage %.
# Hard-blocks if below floor (exit 1); warns on instrumentation failure (exit 2).
# Sets caller's coverage_pct and appends to fail_reason when appropriate.
_og_run_coverage_floor() {
    local _og_root="$1"
    local _artifacts_dir="${2:-}"
    local coverage_cmd="${ZBUILD_COVERAGE_CMD:-}"
    local coverage_floor="${ZBUILD_COVERAGE_FLOOR:-29}"
    local cov_rc=0
    local cov_out=""
    local _map_out=""
    coverage_ran=0
    coverage_map_path=""

    if [[ -n "$coverage_cmd" ]]; then
        cov_out="$(bash -c "$coverage_cmd" 2>&1)" || cov_rc=$?
    else
        local cov_script="$_og_root/scripts/check-coverage.sh"
        if [[ -f "$cov_script" ]]; then
            [[ -n "$_artifacts_dir" ]] && _map_out="$_artifacts_dir/coverage-map.json"
            cov_out="$(COVERAGE_FLOOR="$coverage_floor" ZBUILD_COVERAGE_MAP_OUT="$_map_out" bash "$cov_script" 2>&1)" || cov_rc=$?
        else
            # No coverage script available — skip gate (composability).
            coverage_pct=0
            return 0
        fi
    fi

    # Parse the OVERALL coverage % from check-coverage.sh's "Total: ... (NN.N%)"
    # summary line — never the first % token, which is a per-file table row.
    # Fall back to the LAST % seen (the summary is last) when no Total: line.
    coverage_pct="$(printf '%s\n' "$cov_out" | grep -iE '^Total:' | grep -o '[0-9][0-9]*\.[0-9]*%' | tail -1 | tr -d '%')"
    [[ -z "$coverage_pct" ]] && coverage_pct="$(printf '%s\n' "$cov_out" | grep -o '[0-9][0-9]*\.[0-9]*%' | tail -1 | tr -d '%')"
    [[ -z "$coverage_pct" ]] && coverage_pct=0

    if [[ $cov_rc -eq 2 ]]; then
        # Instrumentation failure — warn but don't hard-block.
        _og_emit "objective_gate.coverage.fail" "exit_code=$cov_rc" "instrumentation=failed"
        return 0
    fi

    if [[ $cov_rc -ne 0 ]]; then
        _og_emit "objective_gate.coverage.fail" "exit_code=$cov_rc" "coverage_pct=$coverage_pct"
        fail_reason="coverage_fail"
        return 0
    fi

    # Mark coverage as "ran" only when a real percentage was parsed (parsed
    # values carry a decimal, e.g. "31.6"; the fallback above is the literal
    # "0"). This keeps an empty/garbled coverage output from overwriting the
    # persisted baseline with 0 (#1012 review).
    [[ "$coverage_pct" != "0" ]] && coverage_ran=1
    _og_emit "objective_gate.coverage.pass" "coverage_pct=$coverage_pct"

    if [[ -n "$_map_out" && -s "$_map_out" ]]; then
        coverage_map_path="$_map_out"
        _og_emit "objective_gate.coverage_map.written" "path=$coverage_map_path"
    fi
}

# ─── _og_run_diff_scope_leak_check ──────────────────────────────────────────
# Reads plan.json steps[].files[] (the SAME declared-scope source as
# _og_run_scope_adherence) as the allow-set, then flags every diff path the
# plan did NOT declare into scope_leak_files[]. Sets fail_reason=scope_leak
# when non-empty. plan.json — not the redaction scope-manifest — is the source
# of truth: the redaction manifest emits '+ ./' (allow-all) for the generic
# platform, which made an earlier manifest-based gate inert for the common case.
# No-op when plan.json is absent or declares no files (composability).
_og_run_diff_scope_leak_check() {
    local artifacts_dir="$1"
    local plan_json="$artifacts_dir/plan.json"

    if [[ ! -f "$plan_json" ]]; then
        return 0
    fi

    local plan_files=""
    plan_files="$(jq -r '.steps[]?.files[]? // empty' "$plan_json" 2>/dev/null || true)"
    # No declared files → no scope to enforce; skip rather than flag everything.
    [[ -z "$plan_files" ]] && return 0

    local diff_cmd="${ZBUILD_DIFF_CMD:-git diff --name-only "${ZBUILD_BASELINE_SHA:-HEAD~1}"..HEAD}"
    local diff_files=""
    diff_files="$(bash -c "$diff_cmd" 2>/dev/null || true)"

    scope_leak_files=()
    local df
    while IFS= read -r df; do
        [[ -z "$df" ]] && continue
        # A diff path is in-scope only if the plan declared it (exact match,
        # same idiom as _og_run_scope_adherence). Anything else is a leak.
        if ! printf '%s\n' "$plan_files" | grep -qxF "$df"; then
            scope_leak_files+=("$df")
        fi
    done <<< "$diff_files"

    if [[ ${#scope_leak_files[@]} -gt 0 ]]; then
        _og_emit "objective_gate.scope_leak.fail" "leak_count=${#scope_leak_files[@]}"
        [[ -z "$fail_reason" ]] && fail_reason="scope_leak"
    fi
}

# ─── _og_run_scope_adherence ─────────────────────────────────────────────────
# Reads plan.json from artifacts_dir, extracts steps[].files[], diffs against
# git diff --name-only. Files in plan but not in diff → scope_gaps[].
# Any gap → fail_reason=scope_fail. No-op when plan.json absent.
_og_run_scope_adherence() {
    local artifacts_dir="$1"
    local plan_json="$artifacts_dir/plan.json"

    if [[ ! -f "$plan_json" ]]; then
        # No plan.json — composability: skip silently (same as absent acceptance block).
        return 0
    fi

    local diff_cmd="${ZBUILD_DIFF_CMD:-git diff --name-only "${ZBUILD_BASELINE_SHA:-HEAD~1}"..HEAD}"
    local diff_files=""
    diff_files="$(bash -c "$diff_cmd" 2>/dev/null || true)"

    local plan_files=""
    plan_files="$(jq -r '.steps[]?.files[]? // empty' "$plan_json" 2>/dev/null || true)"

    scope_gaps=()
    local pf
    while IFS= read -r pf; do
        [[ -z "$pf" ]] && continue
        if ! printf '%s\n' "$diff_files" | grep -qxF "$pf"; then
            scope_gaps+=("$pf")
        fi
    done <<< "$plan_files"

    if [[ ${#scope_gaps[@]} -gt 0 ]]; then
        _og_emit "objective_gate.scope.fail" "gap_count=${#scope_gaps[@]}"
        [[ -z "$fail_reason" ]] && fail_reason="scope_fail"
    else
        _og_emit "objective_gate.scope.pass"
    fi
}

# ─── _og_emit_report_signals ─────────────────────────────────────────────────
# Computes coverage-delta vs last_coverage_pct in state and quality-score.
# Emits advisory events — never sets fail_reason.
_og_emit_report_signals() {
    local state_file="$1"
    local cov_pct="$2"
    local scope_ok="$3"

    local last_pct=0
    if [[ -n "$state_file" && -f "$state_file" ]]; then
        last_pct="$(grep -o '"last_coverage_pct":[0-9.]*' "$state_file" | grep -o '[0-9.]*$' || echo 0)"
    fi

    local delta=0
    # Simple integer delta (truncate decimals for portability).
    delta=$(( ${cov_pct%%.*} - ${last_pct%%.*} ))

    # quality_score is bare (no `local`) so it propagates to the caller's frame
    # (dynamic scoping) for inclusion in the result JSON — see objective_gate_run.
    if [[ "$scope_ok" == "1" ]]; then
        quality_score="${cov_pct%%.*}"
    else
        quality_score=$(( ${cov_pct%%.*} / 2 ))
    fi

    coverage_delta="$delta"
    _og_emit "objective_gate.coverage_delta" "delta=$delta"
    _og_emit "objective_gate.quality_score" "score=$quality_score"
}

# ─── _og_run_negctl ──────────────────────────────────────────────────────────
# Calls _og_ablation_negctl and parses the ABLATION_NEGCTL verdict.
# Sets caller's negctl_verdict (skip|pass|fail) and negctl_detail via dynamic scoping.
# Sets fail_reason=negctl_fail on FAIL (if not already set).
_og_run_negctl() {
    local repo_root="$1"
    local _negctl_out=""
    if declare -f _og_ablation_negctl >/dev/null 2>&1; then
        _negctl_out="$(_og_ablation_negctl "$repo_root")"
    fi
    negctl_detail="$_negctl_out"
    case "$_negctl_out" in
        *"ABLATION_NEGCTL PASS"*)
            negctl_verdict="pass"
            _og_emit "objective_gate.negctl.pass"
            ;;
        *"ABLATION_NEGCTL FAIL"*)
            negctl_verdict="fail"
            [[ -z "$fail_reason" ]] && fail_reason="negctl_fail"
            _og_emit "objective_gate.negctl.fail" "detail=${_negctl_out##*ABLATION_NEGCTL FAIL }"
            ;;
        *)
            negctl_verdict="skip"
            _og_emit "objective_gate.negctl.skip"
            ;;
    esac
}

# ─── _og_run_reachability ─────────────────────────────────────────────────────
# Calls _og_ablation_reachability and parses the ABLATION_REACH verdict.
# Sets caller's reachability_verdict (skip|pass|fail) and reachability_detail via dynamic scoping.
_og_run_reachability() {
    local repo_root="$1"
    local _reach_out=""
    if declare -f _og_ablation_reachability >/dev/null 2>&1; then
        _reach_out="$(_og_ablation_reachability "$repo_root")"
    fi
    reachability_detail="$_reach_out"
    case "$_reach_out" in
        *"ABLATION_REACH PASS"*)
            reachability_verdict="pass"
            _og_emit "objective_gate.reachability.pass"
            ;;
        *"ABLATION_REACH FAIL"*)
            reachability_verdict="fail"
            [[ -z "$fail_reason" ]] && fail_reason="reachability_fail"
            _og_emit "objective_gate.reachability.fail" "detail=${_reach_out##*ABLATION_REACH FAIL }"
            ;;
        *)
            reachability_verdict="skip"
            _og_emit "objective_gate.reachability.skip"
            ;;
    esac
}

# ─── _og_run_shape_floor ──────────────────────────────────────────────────────
# Calls _og_ablation_shape_floor and parses the ABLATION_SHAPE verdict.
# Sets caller's shape_floor_verdict (skip|pass|fail) via dynamic scoping.
_og_run_shape_floor() {
    local repo_root="$1"
    local _shape_out=""
    if declare -f _og_ablation_shape_floor >/dev/null 2>&1; then
        _shape_out="$(_og_ablation_shape_floor "$repo_root")"
    fi
    case "$_shape_out" in
        *"ABLATION_SHAPE PASS"*)
            shape_floor_verdict="pass"
            _og_emit "objective_gate.shape_floor.pass"
            ;;
        *"ABLATION_SHAPE FAIL"*)
            shape_floor_verdict="fail"
            [[ -z "$fail_reason" ]] && fail_reason="shape_floor_fail"
            _og_emit "objective_gate.shape_floor.fail" "detail=${_shape_out##*ABLATION_SHAPE FAIL }"
            ;;
        *)
            shape_floor_verdict="skip"
            _og_emit "objective_gate.shape_floor.skip"
            ;;
    esac
}

# ─── _og_persist_coverage_pct ────────────────────────────────────────────────
# jq transformer for locked_state_update: writes last_coverage_pct into state and
# bumps updated_at (parity with set_state_field). Caller sets _og_persist_pct
# first. MUST stay compact (`-c`): _og_emit_report_signals reads the field with a
# grep that assumes `"key":value` (no space), so a pretty `"key": value` reads empty.
_og_persist_coverage_pct() {
    jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson p "${_og_persist_pct:-0}" \
       '. + {"last_coverage_pct": $p, "updated_at": $now}'
}

# ─── _og_can_reuse_suite ─────────────────────────────────────────────────────
# #1058 Phase B / #1116: decide whether the gate may REUSE the test stage's
# full-suite result (test-results.json) instead of re-running `npm test` on the
# identical committed work-tree. Returns 0 (reuse) ONLY when ALL hold:
#   • ZBUILD_OBJECTIVE_GATE_NO_REUSE is unset/empty (escape hatch forces re-run)
#   • test-results.json exists and parses
#   • its .run_mode == "full"      (targeted runs are NOT authoritative)
#   • its .verdict  ∈ {pass, fail}  (a DEFINITIVE verdict — #1116). A cached FAIL
#     on a provably identical tree is just as authoritative as a PASS: re-running
#     a deterministic suite cannot change it, and the caller propagates the cached
#     exit_code so a reused fail still HARD-BLOCKS the gate. verdict == "error"
#     (interrupted / unparseable) is NOT authoritative and forces a re-run.
#   • its .tree_sha is non-empty and EQUALS the current committed work-tree SHA
# Any other condition (missing field, mismatch, unreadable git tree, verdict=error)
# returns 1 (fail closed → caller runs the suite). Repo root is derived exactly as
# the test plugin does so both compute the same tree.
# Usage: _og_can_reuse_suite <artifacts_dir>
_og_can_reuse_suite() {
    local artifacts_dir="$1"

    # Escape hatch: any non-empty value forces a full re-run.
    [[ -n "${ZBUILD_OBJECTIVE_GATE_NO_REUSE:-}" ]] && return 1

    local results_json="$artifacts_dir/test-results.json"
    [[ -f "$results_json" ]] || return 1

    # Single jq read of the three relevant fields; bail closed if jq can't parse.
    local _parsed
    _parsed="$(jq -r '[(.tree_sha // ""), (.verdict // ""), (.run_mode // "")] | @tsv' \
        "$results_json" 2>/dev/null)" || return 1
    local _art_tree _art_verdict _art_mode
    IFS=$'\t' read -r _art_tree _art_verdict _art_mode <<< "$_parsed"

    [[ "$_art_mode" == "full" ]] || return 1
    # #1116: a DEFINITIVE verdict (pass OR fail) is authoritative on an identical
    # tree; only an `error` (interrupted/unparseable) verdict forces a re-run.
    case "$_art_verdict" in
        pass | fail) ;;
        *) return 1 ;;
    esac
    [[ -n "$_art_tree" ]] || return 1

    local repo_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo)}"
    [[ -n "$repo_root" ]] || return 1
    local _cur_sha
    _cur_sha="$(git -C "$repo_root" rev-parse 'HEAD^{tree}' 2>/dev/null || echo)"
    [[ -n "$_cur_sha" ]] || return 1

    [[ "$_art_tree" == "$_cur_sha" ]] || return 1
    return 0
}

# ─── _og_io_output_summary ────────────────────────────────────────────────────
# Build the OUTPUT-banner body for a command-kind capture: the verdict + exit
# code, plus a short recognizable summary line lifted from the raw output (e.g.
# `unit: 12/12 passed`, `mutation 20/22`). The FULL raw output is kept in an
# artifact by the caller — only this truncated summary reaches the banner. When
# the suite result was REUSED (no command ran) the body is a one-line cache note.
# Usage: _og_io_output_summary <verdict> <exit_code> <raw_output> <reused>
_og_io_output_summary() {
    local verdict="$1" exit_code="$2" raw="$3" reused="$4"
    if [[ "$reused" == "1" ]]; then
        printf 'verdict=%s [reused] cached full-suite result\n' "$verdict"
        return 0
    fi
    printf 'verdict=%s exit_code=%s\n' "$verdict" "$exit_code"
    # Lift the last few tier/mutation/pass-fail summary lines so the banner shows
    # signal, not the whole log. Best-effort: empty when nothing matches.
    local summary_line
    summary_line="$(printf '%s\n' "$raw" \
        | grep -iE '([0-9]+/[0-9]+|[0-9]+ (passed|failed)|mutation|Tests:|shellcheck)' \
        | tail -n 3 || true)"
    [[ -n "$summary_line" ]] && printf '%s\n' "$summary_line"
    return 0
}

# ─── _og_emit_io_end ──────────────────────────────────────────────────────────
# Close a command-kind stage-io banner pair opened by stage_io_begin. Computes
# wall duration from $t0_us and calls stage_io_end. Best-effort — failures are
# swallowed so they can never affect the gate verdict. No-op when seq is empty
# (begin suppressed because the stage declares no io: destinations). Mirrors the
# test plugin's _test_emit_io_end (#497).
# Usage: _og_emit_io_end <seq> <t0_us> <verdict> <exit_code> <output>
_og_emit_io_end() {
    local seq="$1" t0_us="$2" verdict="$3" exit_code="$4" output="$5"
    [[ -z "$seq" ]] && return 0
    local t1_us="${EPOCHREALTIME/./}"
    local dur_ms=$(( (10#${t1_us} - 10#${t0_us}) / 1000 ))
    (( dur_ms < 0 )) && dur_ms=0
    stage_io_end --stage objective-gate --kind command --seq "$seq" \
        --output "$output" \
        --exit-code "$exit_code" \
        --duration-ms "$dur_ms" \
        --metadata "verdict=$verdict" 2>/dev/null || true
    return 0
}

# ─── objective_gate_run ───────────────────────────────────────────────────────
# Hard-blocks on test suite, lint, coverage-floor, or scope-adherence failure.
# Writes enriched artifact with coverage_pct, coverage_delta, scope_ok, quality_score.
# Args: $1 = stage_id, $2 = state_file
objective_gate_run() {
    local stage_id="${1:-objective-gate}"; : "$stage_id"
    local state_file="${2:-}"

    local artifacts_dir
    if [[ -n "$state_file" && -d "$(dirname "$state_file")" ]]; then
        artifacts_dir="$(dirname "$state_file")/artifacts"
    else
        artifacts_dir="${ZBUILD_ARTIFACT_DIR:-${TMPDIR:-/tmp}/zbuild-og-artifacts}"
    fi
    mkdir -p "$artifacts_dir"

    local result_path="$artifacts_dir/objective-gate-result.json"
    local test_cmd="${ZBUILD_TEST_CMD:-npm test}"
    local lint_cmd="${ZBUILD_LINT_CMD:-npm run lint}"

    _og_emit "plugin.run.start" "plugin=objective-gate"

    local test_rc=0 lint_rc=0 fail_reason=""
    local coverage_pct=0 coverage_delta=0 quality_score=0 coverage_ran=0 coverage_map_path=""
    local scope_gaps=()
    local scope_leak_files=()
    local negctl_verdict="skip" reachability_verdict="skip" shape_floor_verdict="skip"
    local negctl_detail="" reachability_detail=""

    # Run test suite — T0 hard gate: any non-zero exit blocks merge.
    # #1058 Phase B: attempt to REUSE the test stage's full-suite result instead
    # of re-running the identical suite on the same committed work-tree. This is
    # SAFETY-CRITICAL: reuse must NEVER let a broken build pass the gate, so it
    # fails closed (runs the suite) on ANY doubt — missing artifact, missing or
    # mismatched tree_sha, non-pass verdict, a targeted (non-authoritative) run,
    # an unreadable git tree, or the ZBUILD_OBJECTIVE_GATE_NO_REUSE escape hatch.
    local _suite_reused=0 _reuse_verdict="pass"
    if _og_can_reuse_suite "$artifacts_dir"; then
        _suite_reused=1
        # #1116: a reused FAIL must still HARD-BLOCK, so propagate the cached
        # exit_code into test_rc (a reused PASS keeps 0). Read verdict+exit_code
        # at the reuse decision; default to a passing posture if jq can't parse.
        local _reuse_parsed _reuse_ec=0
        _reuse_parsed="$(jq -r '[(.verdict // "pass"), (.exit_code // 0)] | @tsv' \
            "$artifacts_dir/test-results.json" 2>/dev/null)" || _reuse_parsed=$'pass\t0'
        IFS=$'\t' read -r _reuse_verdict _reuse_ec <<< "$_reuse_parsed"
        if [[ "$_reuse_verdict" == "fail" ]]; then
            # SAFETY-CRITICAL: never let a reused fail pass the gate — force a
            # non-zero test_rc even if the cached exit_code is bogusly 0/empty.
            [[ "$_reuse_ec" =~ ^-?[0-9]+$ ]] && test_rc="$_reuse_ec" || test_rc=1
            [[ "$test_rc" -eq 0 ]] && test_rc=1
        else
            test_rc=0
        fi
    fi

    # ── ADR-015 (#1115): stage-io banner pair around the suite run ─────────────
    # INPUT banner shows the command (or a [reused] cache note); OUTPUT banner
    # shows the verdict + a short summary. Capture stdout+stderr (NOT >/dev/null)
    # so the banner + artifact carry it. Begin is suppressed (seq empty) when the
    # stage declares no io: destinations — the gate then behaves as before.
    local _suite_raw="" _suite_input _suite_seq="" _suite_t0_us="${EPOCHREALTIME/./}"
    if [[ $_suite_reused -eq 1 ]]; then
        local _reuse_root _reuse_tree
        _reuse_root="${ZBUILD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo)}"
        _reuse_tree="$(git -C "$_reuse_root" rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
        _suite_input="$(printf '%q' "[reused] cached full-suite result tree=$_reuse_tree")"
    else
        _suite_input="$(printf '%q' "$test_cmd")"
    fi
    if stage_io_begin --stage objective-gate --kind command \
            --input "$_suite_input" >/dev/null 2>&1; then
        _suite_seq="$_STAGE_IO_LAST_SEQ"
    fi

    if [[ $_suite_reused -ne 1 ]]; then
        _suite_raw="$(bash -c "$test_cmd" 2>&1)" || test_rc=$?
        # Keep the full raw suite output as an artifact; only the banner truncates.
        printf '%s\n' "$_suite_raw" > "$artifacts_dir/objective-gate-suite-output.log" 2>/dev/null || true
    fi

    if [[ $test_rc -ne 0 ]]; then
        fail_reason="suite_fail"
        # #1116: emit reused=1 for BOTH verdicts so reuse is observable on a fail too.
        if [[ $_suite_reused -eq 1 ]]; then
            _og_emit "objective_gate.suite.fail" "exit_code=$test_rc" "reused=1"
        else
            _og_emit "objective_gate.suite.fail" "exit_code=$test_rc"
        fi
    elif [[ $_suite_reused -eq 1 ]]; then
        _og_emit "objective_gate.suite.pass" "exit_code=0" "reused=1"
    else
        _og_emit "objective_gate.suite.pass" "exit_code=0"
    fi

    local _suite_verdict="pass"; [[ $test_rc -ne 0 ]] && _suite_verdict="fail"
    _og_emit_io_end "$_suite_seq" "$_suite_t0_us" "$_suite_verdict" "$test_rc" \
        "$(_og_io_output_summary "$_suite_verdict" "$test_rc" "$_suite_raw" "$_suite_reused")"

    # ── Run lint / shellcheck — always run even when suite failed so both ──────
    # results are captured in the artifact for operator visibility. Wrapped in a
    # second stage-io banner pair (ADR-015 #1115); output captured, not discarded.
    local _lint_raw="" _lint_input _lint_seq="" _lint_t0_us="${EPOCHREALTIME/./}"
    _lint_input="$(printf '%q' "$lint_cmd")"
    if stage_io_begin --stage objective-gate --kind command \
            --input "$_lint_input" >/dev/null 2>&1; then
        _lint_seq="$_STAGE_IO_LAST_SEQ"
    fi
    _lint_raw="$(bash -c "$lint_cmd" 2>&1)" || lint_rc=$?
    printf '%s\n' "$_lint_raw" > "$artifacts_dir/objective-gate-lint-output.log" 2>/dev/null || true
    if [[ $lint_rc -ne 0 ]]; then
        [[ -z "$fail_reason" ]] && fail_reason="lint_fail"
        _og_emit "objective_gate.lint.fail" "exit_code=$lint_rc"
    else
        _og_emit "objective_gate.lint.pass" "exit_code=0"
    fi
    local _lint_verdict="pass"; [[ $lint_rc -ne 0 ]] && _lint_verdict="fail"
    _og_emit_io_end "$_lint_seq" "$_lint_t0_us" "$_lint_verdict" "$lint_rc" \
        "$(_og_io_output_summary "$_lint_verdict" "$lint_rc" "$_lint_raw" "0")"

    # Coverage floor gate (I4 — requires post-build artifacts).
    _og_run_coverage_floor "$_OG_ROOT" "$artifacts_dir"

    # Scope-adherence gate (I4 — requires plan.json in artifacts_dir).
    _og_run_scope_adherence "$artifacts_dir"

    # Diff scope-leak gate — reject diff paths the plan didn't declare
    # (plan.json files[] in artifacts_dir; same source as scope-adherence).
    _og_run_diff_scope_leak_check "$artifacts_dir"

    # Ablation gates (I5 — de-ceremonied negctl, reachability, shape floor).
    _og_run_negctl "$_OG_ROOT"
    _og_run_reachability "$_OG_ROOT"
    _og_run_shape_floor "$_OG_ROOT"

    # Persist full ablation output unconditionally (even on skip) so review-report
    # can always find a candidate to register for the design-conformance lens.
    jq -n \
        --arg nv "$negctl_verdict" \
        --arg nd "$negctl_detail" \
        --arg rv "$reachability_verdict" \
        --arg rd "$reachability_detail" \
        '{"negctl_verdict":$nv,"negctl_detail":$nd,"reachability_verdict":$rv,"reachability_detail":$rd}' \
        | atomic_write "$artifacts_dir/reachability-ablation.json"

    # Scope ok = no gaps found (after scope check).
    local scope_ok=0
    [[ ${#scope_gaps[@]} -eq 0 ]] && scope_ok=1

    # Emit advisory report signals (coverage-delta, quality-score).
    _og_emit_report_signals "$state_file" "$coverage_pct" "$scope_ok"

    # Persist coverage baseline for next-run delta computation (both paths).
    if [[ -n "$state_file" && -f "$state_file" && "$coverage_ran" == "1" ]]; then
        if declare -F locked_state_update >/dev/null 2>&1; then
            _og_persist_pct="$coverage_pct"
            locked_state_update "$state_file" "_og_persist_coverage_pct" || true
        fi
    fi

    if [[ -n "$fail_reason" ]]; then
        # JSON-escape each gap/leak (paths may contain quotes/backslashes) via jq.
        local gaps_json="[]"
        if [[ ${#scope_gaps[@]} -gt 0 ]]; then
            gaps_json="$(printf '%s\n' "${scope_gaps[@]}" | jq -R . | jq -sc .)"
        fi
        local scope_leak_files_json="[]"
        if [[ ${#scope_leak_files[@]} -gt 0 ]]; then
            scope_leak_files_json="$(printf '%s\n' "${scope_leak_files[@]}" | jq -R . | jq -sc .)"
        fi
        printf '{"verdict":"fail","reason":"%s","test_rc":%d,"lint_rc":%d,"coverage_pct":%s,"coverage_delta":%d,"scope_ok":%d,"quality_score":%d,"scope_gaps":%s,"scope_leak_files":%s,"negctl_verdict":"%s","reachability_verdict":"%s","shape_floor_verdict":"%s"}\n' \
            "$fail_reason" "$test_rc" "$lint_rc" "$coverage_pct" "$coverage_delta" "$scope_ok" "$quality_score" "$gaps_json" "$scope_leak_files_json" \
            "$negctl_verdict" "$reachability_verdict" "$shape_floor_verdict" \
            | atomic_write "$result_path"
        _og_emit "plugin.run.complete" "plugin=objective-gate" "verdict=fail"
        return 1
    fi

    printf '{"verdict":"pass","test_rc":0,"lint_rc":0,"coverage_pct":%s,"coverage_delta":%d,"scope_ok":%d,"quality_score":%d,"scope_gaps":[],"scope_leak_files":[],"negctl_verdict":"%s","reachability_verdict":"%s","shape_floor_verdict":"%s"}\n' \
        "$coverage_pct" "$coverage_delta" "$scope_ok" "$quality_score" \
        "$negctl_verdict" "$reachability_verdict" "$shape_floor_verdict" | atomic_write "$result_path"
    _og_emit "plugin.run.complete" "plugin=objective-gate" "verdict=pass"
    return 0
}

# ─── objective_gate_finalize ──────────────────────────────────────────────────
objective_gate_finalize() {
    _og_emit "plugin.finalize.start" "plugin=objective-gate"
    _og_emit "plugin.finalize.complete" "plugin=objective-gate"
    return 0
}

# ─── objective_gate_cleanup ───────────────────────────────────────────────────
objective_gate_cleanup() {
    _og_emit "plugin.cleanup.start" "plugin=objective-gate"
    _og_emit "plugin.cleanup.complete" "plugin=objective-gate"
    return 0
}
