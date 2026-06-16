#!/usr/bin/env bash
# plugins/tool/test/lib/parse.sh — test output pattern bank + orchestrator (#584)
#
# Public API:
#   _test_parse_summary <raw_output> <exit_code>
#     Echoes one pipe-delimited line: verdict|passed|failed|summary|recognized
#       verdict     ∈ {pass, fail, error}
#       passed      integer ≥ 0  OR literal "null" on fail-safe
#       failed      integer ≥ 0  OR literal "null" on fail-safe
#       summary     human one-liner for the stage-io banner
#       recognized  ∈ {1, 0}  (0 ⇒ fail-safe path; caller must honor reason)
#
# Design (see ADR/issue #584):
#   Six pattern functions are tried in fixed order; first non-empty wins.
#   Each pattern requires a structural ANCHOR (e.g. `^Tests:` for jest,
#   `^test result:` for cargo) so prose mentioning "passed"/"failed" cannot
#   trigger false positives. Fail-safe NEVER fabricates counts — passed/failed
#   are emitted as the literal token `null` so the JSON writer can translate
#   them to JSON null via `--argjson`.
#
# Sourced library: no `set -euo pipefail`. POSIX-bash grep -E only (no PCRE).

[[ -n "${_ZBUILD_TEST_PARSE_LOADED:-}" ]] && return 0
_ZBUILD_TEST_PARSE_LOADED=1

# ─── _test_pattern_runall ─────────────────────────────────────────────────────
# Matches zbuild's scripts/run-tests.sh aggregated output:
#   unit: N/M passed
#   integration: N/M passed
#   e2e: N/M passed
#   golden: N/M passed
#   mutation: N/M passed
# Plus per-tier file-fail markers: `unit: FAIL <path>`.
# Anchor: at least one `^(unit|integration|e2e|golden|mutation): N/M passed` line.
_test_pattern_runall() {
    local raw="$1" rc="$2"
    printf '%s' "$raw" | grep -qE '^(unit|integration|e2e|golden|mutation): [0-9]+/[0-9]+ passed' || return 1

    local total_passed=0 total_count=0 fail_files=0 parts=""
    local line suite n m
    while IFS= read -r line; do
        # Tokens: suite, N, M  (awk split on ":", " ", "/" )
        suite="$(printf '%s' "$line" | awk -F'[: /]+' '{print $1}')"
        n="$(printf '%s' "$line"     | awk -F'[: /]+' '{print $2}')"
        m="$(printf '%s' "$line"     | awk -F'[: /]+' '{print $3}')"
        [[ "$n" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]] || continue
        total_passed=$((total_passed + n))
        total_count=$((total_count + m))
        parts="${parts}${suite} ${n}/${m} · "
    done < <(printf '%s\n' "$raw" | grep -E '^(unit|integration|e2e|golden|mutation): [0-9]+/[0-9]+ passed')

    fail_files="$(printf '%s\n' "$raw" | grep -cE '^(unit|integration|e2e|golden|mutation): FAIL ')"
    [[ "$fail_files" =~ ^[0-9]+$ ]] || fail_files=0

    local failed=$((total_count - total_passed))
    # File-fail count is more meaningful than derived diff when present.
    [[ "$fail_files" -gt 0 ]] && failed="$fail_files"

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"

    local summary="${parts}${fail_files} file failures (exit ${rc})"
    printf '%s|%d|%d|%s\n' "$verdict" "$total_passed" "$failed" "$summary"
}

# ─── _test_pattern_jest ───────────────────────────────────────────────────────
# Jest / vitest summary:  `Tests:       18 failed, 108 passed, 126 total`
# Anchor: `^Tests:` followed by `total`.
_test_pattern_jest() {
    local raw="$1" rc="$2"
    local line
    line="$(printf '%s\n' "$raw" | grep -E '^Tests:[[:space:]]+.*[0-9]+ total' | head -n1)"
    [[ -n "$line" ]] || return 1

    local passed failed
    passed="$(printf '%s' "$line" | grep -oE '[0-9]+ passed' | head -n1 | awk '{print $1}')"
    failed="$(printf '%s' "$line" | grep -oE '[0-9]+ failed' | head -n1 | awk '{print $1}')"
    [[ -z "$passed" ]] && passed=0
    [[ -z "$failed" ]] && failed=0

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"
    printf '%s|%d|%d|jest: %d passed, %d failed (exit %d)\n' \
        "$verdict" "$passed" "$failed" "$passed" "$failed" "$rc"
}

# ─── _test_pattern_mocha ──────────────────────────────────────────────────────
# Mocha summary:
#     108 passing (2s)
#     18 failing
# Anchor: leading whitespace + `N passing` (distinguishes from jest's `passed`).
_test_pattern_mocha() {
    local raw="$1" rc="$2"
    printf '%s\n' "$raw" | grep -qE '^[[:space:]]+[0-9]+ passing' || return 1

    local passed failed
    passed="$(printf '%s\n' "$raw" | grep -oE '[0-9]+ passing' | tail -n1 | awk '{print $1}')"
    failed="$(printf '%s\n' "$raw" | grep -oE '[0-9]+ failing' | tail -n1 | awk '{print $1}')"
    [[ -z "$passed" ]] && passed=0
    [[ -z "$failed" ]] && failed=0

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"
    printf '%s|%d|%d|mocha: %d passing, %d failing (exit %d)\n' \
        "$verdict" "$passed" "$failed" "$passed" "$failed" "$rc"
}

# ─── _test_pattern_pytest ─────────────────────────────────────────────────────
# Pytest summary banner: `===== 3 failed, 42 passed in 1.23s =====`
# Anchor: `={3,}` flanking a `passed|failed|error` token.
_test_pattern_pytest() {
    local raw="$1" rc="$2"
    local line
    line="$(printf '%s\n' "$raw" | grep -E '={3,}.*(passed|failed|error).*={3,}' | tail -n1)"
    [[ -n "$line" ]] || return 1

    local passed failed
    passed="$(printf '%s' "$line" | grep -oE '[0-9]+ passed' | tail -n1 | awk '{print $1}')"
    failed="$(printf '%s' "$line" | grep -oE '[0-9]+ (failed|error)' | tail -n1 | awk '{print $1}')"
    [[ -z "$passed" ]] && passed=0
    [[ -z "$failed" ]] && failed=0

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"
    printf '%s|%d|%d|pytest: %d passed, %d failed (exit %d)\n' \
        "$verdict" "$passed" "$failed" "$passed" "$failed" "$rc"
}

# ─── _test_pattern_gotest ─────────────────────────────────────────────────────
# go test verbose output: count `^--- PASS:` and `^--- FAIL:` lines.
# Anchor: `^(=== RUN|--- (PASS|FAIL):)`.
_test_pattern_gotest() {
    local raw="$1" rc="$2"
    printf '%s\n' "$raw" | grep -qE '^(=== RUN|--- (PASS|FAIL):)' || return 1

    local passed failed
    passed="$(printf '%s\n' "$raw" | grep -cE '^--- PASS:')"
    failed="$(printf '%s\n' "$raw" | grep -cE '^--- FAIL:')"
    [[ "$passed" =~ ^[0-9]+$ ]] || passed=0
    [[ "$failed" =~ ^[0-9]+$ ]] || failed=0

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"
    printf '%s|%d|%d|go: %d PASS, %d FAIL (exit %d)\n' \
        "$verdict" "$passed" "$failed" "$passed" "$failed" "$rc"
}

# ─── _test_pattern_cargo ──────────────────────────────────────────────────────
# Cargo / rustc test summary line(s): `test result: ok. 42 passed; 0 failed; ...`
# Multi-crate runs emit multiple summary lines; sum across them.
# Anchor: `^test result: (ok|FAILED)\. N passed`.
_test_pattern_cargo() {
    local raw="$1" rc="$2"
    printf '%s\n' "$raw" | grep -qE '^test result: (ok|FAILED)\. [0-9]+ passed' || return 1

    local passed failed
    passed="$(printf '%s\n' "$raw" \
        | grep -E '^test result: ' \
        | grep -oE '[0-9]+ passed' \
        | awk '{s+=$1} END{print s+0}')"
    failed="$(printf '%s\n' "$raw" \
        | grep -E '^test result: ' \
        | grep -oE '[0-9]+ failed' \
        | awk '{s+=$1} END{print s+0}')"
    [[ -z "$passed" ]] && passed=0
    [[ -z "$failed" ]] && failed=0

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"
    printf '%s|%d|%d|cargo: %d passed, %d failed (exit %d)\n' \
        "$verdict" "$passed" "$failed" "$passed" "$failed" "$rc"
}

# ─── _test_extract_failing_files ─────────────────────────────────────────────
# Parses raw test output for zbuild runall FAIL markers and echoes the unique
# sorted list of test file paths that failed (ADR-034 / issue #846).
# Pattern matched: ^(unit|integration|e2e|golden|mutation): FAIL <path>
# Outputs one absolute path per line, sorted, deduplicated.
# Outputs nothing when no FAIL lines are present (empty → no red set to grow).
# Usage: _test_extract_failing_files <raw_output>
_test_extract_failing_files() {
    local raw="$1"
    # `grep ... || true`: when no FAIL lines exist grep exits 1; the `|| true`
    # keeps the pipeline exit code at 0 so callers with `set -e` do not abort.
    printf '%s\n' "$raw" \
        | grep -E '^(unit|integration|e2e|golden|mutation): FAIL ' \
        | awk '{print $NF}' \
        | sort -u \
        || true
}

# ─── _test_parse_summary (orchestrator) ───────────────────────────────────────
# Dispatch to pattern functions in fixed order; first non-empty match wins.
# Anchors enforce mutual exclusivity by construction.
# Fail-safe: emit `error|null|null|<banner>|0` — NEVER fabricate counts.
_test_parse_summary() {
    local raw="$1" rc="$2" line fn
    for fn in _test_pattern_runall _test_pattern_jest _test_pattern_mocha \
              _test_pattern_pytest _test_pattern_gotest _test_pattern_cargo; do
        line="$("$fn" "$raw" "$rc")" || continue
        if [[ -n "$line" ]]; then
            printf '%s|1\n' "$line"
            return 0
        fi
    done

    # Fail-safe — no pattern recognized this output. Do NOT guess counts.
    local first_fail summary
    first_fail="$(printf '%s\n' "$raw" \
        | grep -E 'FAIL|Error|✗|✘|AssertionError|panic|Exception' \
        | head -n1)"
    summary="exit=${rc} · summary unavailable (unrecognized test runner output)"
    [[ -n "$first_fail" ]] && summary="${summary} · first failure: ${first_fail}"
    printf 'error|null|null|%s|0\n' "$summary"
}
