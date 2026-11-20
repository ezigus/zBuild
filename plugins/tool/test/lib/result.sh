#!/usr/bin/env bash
# plugins/tool/test/lib/result.sh — test's result: the verdict, its reason and the file (moved from plugin.sh, #2565:
# plugin.sh under 500 lines).
#
# Sourced by plugin.sh after its bootstrap. Sourced library: no set -euo.

[[ -n "${_ZBUILD_TEST_RESULT_LOADED:-}" ]] && return 0
_ZBUILD_TEST_RESULT_LOADED=1

# ─── _test_framework_enabled (ADR-040 / #1133) ───────────────────────────────
# The shared framework result (lint/coverage/mutation blocks) is OPT-IN so the
# default test behavior stays byte-unchanged. It activates when
# ZBUILD_FRAMEWORK_RESULT is truthy OR when any framework command is explicitly
# configured (a generic target wiring ZBUILD_LINT_CMD/ZBUILD_COVERAGE_CMD).
_test_framework_enabled() {
    case "${ZBUILD_FRAMEWORK_RESULT:-}" in
        1|true|yes|on) return 0 ;;
    esac
    [[ -n "${ZBUILD_LINT_CMD+x}" || -n "${ZBUILD_COVERAGE_CMD+x}" ]] && return 0
    return 1
}

# #626: sanitize a numeric slot — accept "null", integers, or fall back to "null".
# Anything else (whitespace, "abc", embedded quotes) becomes JSON null so jq
# --argjson never barfs and the writer stays fail-CLOSED.
_test_sanitize_numeric() {
    local v="$1"
    if [[ "$v" == "null" ]] || [[ "$v" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$v"
    else
        printf 'null'
    fi
}

# #626: sanitize a boolean slot — only literal true/false survive; everything
# else becomes false. Mirrors the numeric sanitizer's fail-closed posture.
_test_sanitize_bool() {
    local v="$1"
    if [[ "$v" == "true" || "$v" == "false" ]]; then
        printf '%s' "$v"
    else
        printf 'false'
    fi
}

# ─── _test_disposition_from_rc (#1836, ADR-054 §5) ───────────────────────────
# Maps (rc, verdict) → ADR-054 disposition token:
#   pass|fail (test ran to completion)   → complete
#   rc=130/137/143 (signal death)        → interrupted  (recoverable retry)
#   rc=124 (timeout, ADR-054 §6 table)   → interrupted  (recoverable retry)
#   everything else                      → broken
# #1747: only a signalled death or a true timeout is recoverable. An rc=0 exit
# with unrecognised output is a real config bug and stays `broken` — it falls
# through to the default precisely because it is NOT in this set.
# Called once per run, AFTER verdict is finalized.
# Usage: _test_disposition_from_rc <rc> <verdict>
_test_disposition_from_rc() {
    local rc="$1" verdict="$2"
    case "$verdict" in
        pass|fail) printf 'complete'; return 0 ;;
    esac
    # verdict=error — distinguish signal deaths and timeouts (interrupted) from
    # config bugs (broken). ADR-054 §6: 124 is the timeout row; the router
    # absorbs it today, so this arm is contract conformance, not a live path.
    case "$rc" in
        124|130|137|143) printf 'interrupted'; return 0 ;;
    esac
    printf 'broken'
}

# ─── _test_default_reason <verdict> <passed> <failed> <exit_code> ────────────
# #2050: `reason` is MANDATORY in a v2 result, and the reader enforces presence
# AND non-emptiness (core/pipeline/verdict.sh:382-388). Most runs have no
# special-case reason to report, so without a derived default the ordinary
# pass/fail paths ship a result the reader rejects as structurally broken.
# The counts go in the string rather than a fixed token: ADR-054 §5 asks a
# result to explain itself to an operator, and "fail" alone does not.
# Args are the SANITIZED values, so each is an integer or the "null" token.
_test_default_reason() {
    local verdict="$1" passed="$2" failed="$3" exit_code="$4"
    if [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]]; then
        local total=$(( passed + failed ))
        case "$verdict" in
            pass) printf '%d of %d tests passed' "$passed" "$total"; return 0 ;;
            fail) printf '%d of %d tests failed' "$failed" "$total"; return 0 ;;
        esac
    fi
    # No usable counts (parser fail-safe passes the "null" token) or a verdict
    # outside pass/fail. The exit code is the only fact left that is certainly true.
    if [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        printf 'test command exited %d' "$exit_code"
    else
        printf 'test command exited with no recorded status'
    fi
}

# ─── _test_write_result ───────────────────────────────────────────────────────
# Writes test-results.json atomically via a temp file (v2 result contract,
# ADR-054 §5, #1836). Top-level: result_contract, verdict, disposition, reason.
# Plugin-specific detail lives under data:{}.
# Usage: _test_write_result <path> <verdict> <disposition> <exit_code> <passed> <failed>
#                            <test_output> <diff_applied> <test_cmd> [reason]
#                            [run_mode] [timing_json] [tree_sha]
#                            [lint_json] [coverage_json] [mutation_json]
#                            [targeted_json]
# #584: passed/failed may be the literal token "null" to record that the
# parser did not recognize this runner's output (honest fail-safe — never
# fabricate counts). `reason` and `disposition` are always emitted (mandatory v2
# top-level fields). A caller may name the reason — `summary_unavailable` (#584
# fail-safe), `silent_failure` (#485 no-op guard) — and
# otherwise _test_default_reason derives one from the counts (#2050). Wave 12-C
# (#662) removed `diff_apply_failed` — no caller writes it anymore.
# #626: numeric and boolean slots pass through the sanitizers above, so jq
# --argjson never barfs and the writer stays fail-CLOSED.
_test_write_result() {
    local path="$1"
    local verdict="$2"
    local disposition="$3"
    local exit_code="$4"
    local passed="$5"
    local failed="$6"
    local test_output="$7"
    local diff_applied="$8"
    local test_cmd="$9"
    local reason="${10:-}"
    # ADR-034 / #846: run_mode field (full|targeted|targeted+full). Defaults to "full" so
    # callers that do not pass the arg (e.g. the missing-diff guard path) get
    # the safe default that does not suppress cycle convergence.
    local run_mode="${11:-full}"
    # #1058 Phase A: optional pre-rendered `timing` JSON object. Empty string →
    # field omitted. That contract is this field's alone since #2050 — `reason`
    # used to share it and is now always written, being mandatory in v2. A
    # malformed value is dropped by the jq fromjson guard below — never crashes.
    local timing_json="${12:-}"
    # #1058 Phase B: optional committed work-tree SHA. Written ONLY for an
    # authoritative full-suite run (caller passes empty otherwise). Empty string
    # → field omitted, so a consumer (objective gate) that requires a matching
    # tree_sha fails closed and re-runs. Never written for targeted runs.
    local tree_sha="${13:-}"
    # ADR-040 / #1133: optional pre-rendered framework-result blocks. Each is a
    # JSON object string or "" — empty → field omitted (mirrors timing's
    # omit-when-empty contract) so the default test path stays byte-unchanged.
    # A malformed value is dropped by the jq fromjson guard below — never crashes.
    local lint_json="${14:-}"
    local coverage_json="${15:-}"
    local mutation_json="${16:-}"
    # #2144: optional pre-rendered result of the targeted subset that this run
    # confirmed (run_mode=targeted+full). Empty → field omitted.
    local targeted_json="${17:-}"
    # lib/findings.sh: [{file, reason, points_at}] for a failing run. Non-empty →
    # data.failures, and the union of points_at → top-level `about` (#2180).
    local findings_json="${18:-[]}"
    [[ -n "$findings_json" ]] || findings_json="[]"

    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir"

    # #2271: each failing file is a numbered finding. #2569 (ADR-071 §1): a
    # failing file is the code's to make pass, whoever's test it is, so each goes
    # to test's code output; a test that is wrong reaches test-author as build's
    # answer (build-tests-result.json, test-findings).
    local _numbered="[]"
    if [[ "$findings_json" != "[]" ]]; then
        _numbered="$(jq -r '.[]? | "\(.file) fails: \(.reason)"' <<< "$findings_json" 2>/dev/null \
            | stage_findings_route "$dir" test code-findings)"
        [[ -n "$_numbered" ]] || _numbered="[]"
    else
        stage_findings_route "$dir" test code-findings < /dev/null >/dev/null
    fi

    # #2366 (ADR-054 §6): one outcome — pass/fail when the suite ran to the end,
    # otherwise how the stage stopped (the disposition word).
    local outcome="$verdict"
    case "$verdict" in pass|fail) ;; *) outcome="$disposition" ;; esac

    # #584: pass through "null" literal so --argjson treats it as JSON null;
    # numeric values pass through unchanged.
    # #626: defensive sanitizers — adversarial input (whitespace, control
    # chars, embedded quotes) must never crash jq. Anything that is not a
    # bare integer or the "null" token becomes JSON null; anything that is
    # not true/false becomes false.
    local exit_code_json passed_json failed_json diff_applied_json
    exit_code_json="$(_test_sanitize_numeric "$exit_code")"
    passed_json="$(_test_sanitize_numeric "$passed")"
    failed_json="$(_test_sanitize_numeric "$failed")"
    diff_applied_json="$(_test_sanitize_bool "$diff_applied")"

    # #2050: derive only when the caller supplied nothing — silent_failure,
    # summary_unavailable stay verbatim.
    if [[ -z "$reason" ]]; then
        reason="$(_test_default_reason "$verdict" "$passed_json" "$failed_json" \
                                       "$exit_code_json")"
    fi

    # #507: write via atomic_write (helpers.sh) so the manifest-declared
    # primary output `test-results.json` passes the atomicity guard test.
    # #626 + Copilot P2 on #640: stream jq → atomic_write directly with a
    # subshell-scoped pipefail so large test_output never buffers in a
    # bash variable. Check the jq-side exit via PIPESTATUS[0]; on failure
    # write a degenerate-but-valid fallback so the primary artifact always
    # exists and emit test.result_write.fallback. All jq stderr is
    # suppressed so internal sanitization failures never leak.
    jq -n \
        --argjson exit_code "$exit_code_json" \
        --argjson passed "$passed_json" \
        --argjson failed "$failed_json" \
        --arg test_output "$test_output" \
        --argjson diff_applied "$diff_applied_json" \
        --arg test_cmd "$test_cmd" \
        --arg run_mode "$run_mode" \
        --arg timing "$timing_json" \
        --arg tree_sha "$tree_sha" \
        --arg lint "$lint_json" \
        --arg coverage "$coverage_json" \
        --arg mutation "$mutation_json" \
        --arg targeted "$targeted_json" \
        --arg findings "$findings_json" \
        --argjson numbered "$_numbered" \
        '($findings | try fromjson catch []) as $fnd
        | {
            test_output: $test_output,
            run_mode: $run_mode,
            exit_code: $exit_code
        }
        + {
            data: (
                {
                    exit_code: $exit_code,
                    passed: $passed,
                    failed: $failed,
                    test_output: $test_output,
                    diff_applied: $diff_applied,
                    test_cmd: $test_cmd,
                    run_mode: $run_mode
                }
                + (if $timing != "" then (try {timing: ($timing | fromjson)} catch {}) else {} end)
                + (if $tree_sha != "" then {tree_sha: $tree_sha} else {} end)
                + (if $lint != "" then (try {lint: ($lint | fromjson)} catch {}) else {} end)
                + (if $coverage != "" then (try {coverage: ($coverage | fromjson)} catch {}) else {} end)
                + (if $mutation != "" then (try {mutation: ($mutation | fromjson)} catch {}) else {} end)
                + (if $targeted != "" then (try {targeted: ($targeted | fromjson)} catch {}) else {} end)
                + (if ($fnd | length) > 0 then {failures: $fnd} else {} end)
                # #2271 (ADR-068): each failing test file is a numbered finding.
                + {findings: $numbered}
            )
        }' \
        2>/dev/null \
      | atomic_write "$path"
    local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"
    (( _aw_rc != 0 )) && _jq_rc="$_aw_rc"
    (( _jq_rc != 0 )) || stage_result_add "$path" "$outcome" "$reason" 2>/dev/null || _jq_rc=1

    if (( _jq_rc != 0 )); then
        # #1754: a file still at the path is an earlier round's; it goes first,
        # so a fallback that cannot be written leaves no result, never a stale one.
        rm -f "$path" 2>/dev/null || true
        # Fail-closed: overwrite with a degenerate-but-valid JSON object so
        # the primary output always parses. Sanitizers already constrained
        # exit_code_json to {integer, "null"} so %s interpolation is safe.
        # The top-level mirrors are emitted here too: a consumer cannot tell
        # which writer produced the artifact, so a fallback that dropped them
        # would hand `.exit_code` back as null purely because the primary write
        # failed. Same shape, degenerate values — not a v2-flavoured subset.
        # run_mode is interpolated raw (no jq --arg here), so constrain it to
        # the declared tokens rather than trusting the caller's string.
        local _fb_run_mode="full"
        case "$run_mode" in targeted|targeted+full) _fb_run_mode="$run_mode" ;; esac
        printf '{"test_output":"","run_mode":"%s","exit_code":%s,"data":{"exit_code":%s,"passed":null,"failed":null,"test_output":"","diff_applied":false,"test_cmd":"","run_mode":"%s"}}\n' \
            "$_fb_run_mode" "$exit_code_json" "$exit_code_json" "$_fb_run_mode" | atomic_write "$path" \
            && stage_result_add "$path" broken "result_write_failed" 2>/dev/null \
            || rm -f "$path" 2>/dev/null || true
        local _fb_result=broken; [[ -f "$path" ]] || _fb_result=absent
        emit_event "test.result_write.fallback" "path=$path" "result=$_fb_result" 2>/dev/null || true
    fi
}
