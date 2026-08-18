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
#   INVARIANT — EXIT CODE IS AUTHORITATIVE (#1229): rc≠0 ⇒ verdict ∈ {fail,error},
#   ALWAYS, independent of parsed counts. A summary must never contradict rc
#   (never report "all green" / "0 file failures" on a nonzero exit). Suite lines
#   are counted by SHAPE, not by a hardcoded suite-name list, so the parser is
#   repo-agnostic (any `<name>: N/M passed` / `<name>: FAIL` counts).
#
# Sourced library: no `set -euo pipefail`. POSIX-bash grep -E only (no PCRE).

[[ -n "${_ZBUILD_TEST_PARSE_LOADED:-}" ]] && return 0
_ZBUILD_TEST_PARSE_LOADED=1

# Per-file non-passing markers emitted by scripts/run-tests.sh, matched by SHAPE
# so any suite name is recognized (#1229). Two verbs (#1613):
#   <name>: FAIL <path>                                  — assertions failed
#   <name>: TIMEOUT <path> (exceeded Ns, rc=N)           — killed at its bound
# ONE definition, because three consumers below must agree: the failing-suite
# fold, the fail_files count, and _test_extract_failing_files (the red set that
# drives targeted rerun). A verb recognized by some but not all silently drops
# files from the rerun set.
_TEST_FAIL_MARKER_RE='^[A-Za-z][A-Za-z0-9_-]*: (FAIL|TIMEOUT) '

# ─── _test_pattern_runall ─────────────────────────────────────────────────────
# Matches zbuild's scripts/run-tests.sh aggregated output, counted by SHAPE so
# ANY suite name is recognized (repo-agnostic, #1229 — new tiers like `lint`
# must not be silently dropped):
#   <name>: N/M passed          e.g. unit / integration / lint / smoke …
# Plus per-suite file-fail markers: `<name>: FAIL <path>`.
# Anchor: at least one `^<name>: N/M passed` line. The `N/M passed` slash shape
# is unique to run-tests.sh — jest(`108 passed`), pytest(`3 failed, 42 passed`),
# cargo(`test result: ok. 42 passed`) never emit `word: N/M passed`, and a name
# token cannot precede ` :` — so a generic name class cannot cross-capture.
_test_pattern_runall() {
    local raw="$1" rc="$2"
    grep -qE '^[A-Za-z][A-Za-z0-9_-]*: [0-9]+/[0-9]+ passed' <<< "$raw" || return 1

    local total_passed=0 total_count=0 fail_files=0 parts="" failing=""
    local line suite n m
    while IFS= read -r line; do
        # Tokens: suite, N, M  (awk split on ":", " ", "/" )
        suite="$(printf '%s' "$line" | awk -F'[: /]+' '{print $1}')"
        # Skip run-tests.sh's `total: P/T passed` AGGREGATE line (#1234) — summing
        # it would double-count (aggregate + every per-suite line). `total` is the
        # aggregate keyword of this format; every OTHER suite name still counts.
        [[ "$suite" == "total" ]] && continue
        n="$(printf '%s' "$line"     | awk -F'[: /]+' '{print $2}')"
        m="$(printf '%s' "$line"     | awk -F'[: /]+' '{print $3}')"
        [[ "$n" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]] || continue
        total_passed=$((total_passed + n))
        total_count=$((total_count + m))
        parts="${parts}${suite} ${n}/${m} · "
        [[ "$n" -lt "$m" ]] && failing="${failing}${suite} "
    done < <(printf '%s\n' "$raw" | grep -E '^[A-Za-z][A-Za-z0-9_-]*: [0-9]+/[0-9]+ passed')

    # Fold in suite names carried by explicit failure markers (dedup against above).
    # #1613: run-tests.sh reports a file killed at its per-file time bound as
    # `TIMEOUT`, not `FAIL`, so a reader can tell a hang from an assertion failure.
    # Both shapes are non-passing and MUST count here — matching only FAIL would
    # under-report the failure count and, worse, drop the timed-out file from the
    # red set below so the targeted rerun never re-runs it.
    local fline fsuite
    while IFS= read -r fline; do
        [[ -n "$fline" ]] || continue
        fsuite="$(printf '%s' "$fline" | awk -F'[: ]+' '{print $1}')"
        case " $failing " in *" $fsuite "*) : ;; *) failing="${failing}${fsuite} " ;; esac
    done < <(printf '%s\n' "$raw" | grep -E "$_TEST_FAIL_MARKER_RE")

    fail_files="$(printf '%s\n' "$raw" | grep -cE "$_TEST_FAIL_MARKER_RE")"
    [[ "$fail_files" =~ ^[0-9]+$ ]] || fail_files=0

    local failed=$((total_count - total_passed))
    # File-fail count is more meaningful than derived diff when present.
    [[ "$fail_files" -gt 0 ]] && failed="$fail_files"

    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"

    # Honest summary — never contradict rc (#1229). Name the failing suite(s)
    # when any; else if rc≠0 with nothing counted, say so; else all-green.
    local summary
    if [[ -n "$failing" ]]; then
        summary="${parts}FAIL: ${failing% } (exit ${rc})"
    elif [[ "$rc" -ne 0 ]]; then
        summary="${parts}exited ${rc} — not attributable to a parsed suite; see log"
    else
        summary="${parts}all suites passed (exit ${rc})"
    fi
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
    grep -qE '^[[:space:]]+[0-9]+ passing' <<< "$raw" || return 1

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
    grep -qE '^(=== RUN|--- (PASS|FAIL):)' <<< "$raw" || return 1

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
    grep -qE '^test result: (ok|FAILED)\. [0-9]+ passed' <<< "$raw" || return 1

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
# Pattern matched by SHAPE (repo-agnostic, #1229): ^<name>: (FAIL|TIMEOUT) <path>
# Outputs one absolute path per line, sorted, deduplicated.
# Outputs nothing when no markers are present (empty → no red set to grow).
# The path is taken as the token AFTER the verb, not $NF (#1613): a TIMEOUT line
# ends in `(exceeded 480s, rc=124)`, so $NF would yield `rc=124)` and the timed-out
# file would silently vanish from the rerun set. The token is still filtered to
# path-like values (must contain `/`) so a non-file suffix such as
# `lint: FAIL (npm run lint)` → `(npm` is never injected into the build-cycle red
# set (a failing suite with no file has no path to grow).
# Usage: _test_extract_failing_files <raw_output>
_test_extract_failing_files() {
    local raw="$1"
    # `grep ... || true`: when no FAIL lines exist grep exits 1; the `|| true`
    # keeps the pipeline exit code at 0 so callers with `set -e` do not abort.
    printf '%s\n' "$raw" \
        | grep -E "$_TEST_FAIL_MARKER_RE" \
        | awk '{
              for (i = 1; i < NF; i++) {
                  if ($i == "FAIL" || $i == "TIMEOUT") {
                      if ($(i+1) ~ /\//) print $(i+1)
                      break
                  }
              }
          }' \
        | sort -u \
        || true
}

# ─── _test_parse_declared_count (#1208, repo-declarable count contract) ──────
# FIRST-PRIORITY, repo-agnostic count source so the granular pass/fail signal
# works for ANY target (iOS/Swift via xcodebuild/xcresulttool, etc.) without a
# per-ecosystem recognizer. Two forms, checked in order:
#   ZBUILD_TEST_RESULTS_JSON — path to a {passed,failed,total,skipped?} JSON file
#                              the test command wrote.
#   ZBUILD_TEST_COUNT_CMD    — a command whose stdout is that JSON.
# The JSON MUST carry numeric `passed` and `failed`. On success echoes the same
# pipe line the pattern bank emits (verdict|passed|failed|summary) and returns 0;
# on absence / malformed / non-numeric counts returns 1 so the caller falls back
# to the recognizer bank (never fabricate counts — fail SAFE).
_test_parse_declared_count() {
    local rc="$1" src="" json=""
    if [[ -n "${ZBUILD_TEST_RESULTS_JSON:-}" && -s "${ZBUILD_TEST_RESULTS_JSON}" ]]; then
        json="$(cat "$ZBUILD_TEST_RESULTS_JSON" 2>/dev/null || true)"; src="results_json"
    elif [[ -n "${ZBUILD_TEST_COUNT_CMD:-}" ]]; then
        json="$(eval "$ZBUILD_TEST_COUNT_CMD" 2>/dev/null || true)"; src="count_cmd"
    else
        return 1
    fi
    [[ -n "$json" ]] || return 1
    jq -e . >/dev/null 2>&1 <<<"$json" || return 1
    local passed failed
    passed="$(jq -r '.passed // empty' <<<"$json" 2>/dev/null || true)"
    failed="$(jq -r '.failed // empty' <<<"$json" 2>/dev/null || true)"
    [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]] || return 1
    local verdict="pass"
    [[ "$rc" -ne 0 || "$failed" -gt 0 ]] && verdict="fail"
    printf '%s|%d|%d|declared(%s): %d passed, %d failed (exit %d)\n' \
        "$verdict" "$passed" "$failed" "$src" "$passed" "$failed" "$rc"
}

# ─── _test_parse_summary (orchestrator) ───────────────────────────────────────
# #1208: a repo-declarable count source (ZBUILD_TEST_RESULTS_JSON / _COUNT_CMD)
# is consulted FIRST; the built-in recognizer bank stays as the out-of-box
# fallback for common runners; else fail-safe. All three keep counts HONEST.
# Fail-safe: emit `error|null|null|<banner>|0` — NEVER fabricate counts.
_test_parse_summary() {
    local raw="$1" rc="$2" line fn
    # First-priority repo-declared contract (portability, #1208).
    line="$(_test_parse_declared_count "$rc")" || line=""
    if [[ -n "$line" ]]; then
        printf '%s|1\n' "$line"
        return 0
    fi
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
