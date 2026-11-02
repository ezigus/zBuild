#!/usr/bin/env bash
# tests/unit/test-author-fixup-per-file-test.sh — a round after the first is one
# author call per test file that has findings, given only that file's findings
# (#2450, ADR-040).
#
# Why: on #1805 (run 41365460329) both of test-author's fix-up calls were given
# every finding for all four test files at once; each re-read everything,
# planned every fix, and was cut off at 15 minutes before it had edited much.
#
# F2 [change] findings in two test files: the next round makes two author calls,
#             each naming its own file and holding only that file's findings
# F3 [guard]  a per-file call that does not finish ends the try with its
#             outcome, and what was written is committed
# F4 [change] no findings: one author call, one check
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "test-author's fix-up is one call per test file (#2450)"
setup_test_env "test-author-fixup-per-file"

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"

# A test file that runs on its own and fails on the old code, as a [code] test must.
_write_test() {  # <file> <spec>
    {
        printf '#!/usr/bin/env bash\n'
        printf 'assert_eq() { if [[ "$2" == "$3" ]]; then printf "  ✓ %%s\\n" "$1"; else printf "  ✗ %%s\\n" "$1"; return 1; fi; }\n'
        printf 'rc=0\n'
        printf 'assert_eq "%s holds" "1" "$rc" || exit 1\n' "$(acceptance_spec_tag "$2")"
    } > "$R/$1"
}
# The author's model: writes both test files and says done; AUTHOR_END[n-1]
# (default done_sentinel) is how call n ends.
AUTHOR_END=()
route_to_model_loop() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/author-calls"
    cp "$2" "$TEST_TEMP_DIR/author-prompt-$n"
    _write_test tests/a-test.sh SPEC-1
    _write_test tests/b-test.sh SPEC-2
    printf '# call %s\n' "$n" >> "$R/tests/a-test.sh"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="${AUTHOR_END[$((n - 1))]:-done_sentinel}"
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# The check's model: answer n is ${JUDGE[n-1]} (the last repeats).
JUDGE=()
route_to_model() {
    local n; n=$(( $(cat "$TEST_TEMP_DIR/judge-calls" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$TEST_TEMP_DIR/judge-calls"
    printf '%s\n' "${JUDGE[$((n - 1))]:-${JUDGE[${#JUDGE[@]}-1]}}"
    return 0
}

_run() {
    rm -rf "$TEST_TEMP_DIR/run" "$TEST_TEMP_DIR"/author-* "$TEST_TEMP_DIR"/judge-*
    local d="$TEST_TEMP_DIR/run"; R="$d/repo"; A="$d/state/artifacts"
    mkdir -p "$A" "$R/tests"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && : > tests/a-test.sh && : > tests/b-test.sh && git add -A && git commit -q -m seed ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    cat > "$A/design.md" <<'MD'
# Design
```acceptance
SPEC-1[code]: the first thing holds
SPEC-2[code]: the second thing holds
WIRING: none
TESTFILES:
SPEC-1: tests/a-test.sh
SPEC-2: tests/b-test.sh
```
MD
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
    RC=$?
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/test-author-result.json" 2>/dev/null || echo MISSING)"
    CALLS="$(cat "$TEST_TEMP_DIR/author-calls" 2>/dev/null || echo 0)"
}
_prompt() { tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/author-prompt-$1" 2>/dev/null; }

BOTH_PARTIAL="SPEC-1: VERDICT: partial | REASON: reason-about-the-first-file
SPEC-2: VERDICT: partial | REASON: reason-about-the-second-file"
BOTH_OK="SPEC-1: VERDICT: corresponds | REASON: ok
SPEC-2: VERDICT: corresponds | REASON: ok"

# ── F2 ───────────────────────────────────────────────────────────────────────
JUDGE=("$BOTH_PARTIAL" "$BOTH_OK"); AUTHOR_END=()
_run
assert_eq "[F2] findings in two files: one call to write, then one per file" "3" "$CALLS"
assert_contains "[F2] the first fix-up call names its file" "$(_prompt 2)" "tests/a-test.sh"
assert_contains "[F2] ...and holds its file's finding" "$(_prompt 2)" "reason-about-the-first-file"
assert_eq "[F2] ...and not the other file's" "0" "$(grep -c 'reason-about-the-second-file' <<< "$(_prompt 2)" || true)"
assert_contains "[F2] the second fix-up call names its file" "$(_prompt 3)" "tests/b-test.sh"
assert_contains "[F2] ...and holds its file's finding" "$(_prompt 3)" "reason-about-the-second-file"
assert_eq "[F2] ...and not the other file's" "0" "$(grep -c 'reason-about-the-first-file' <<< "$(_prompt 3)" || true)"
assert_eq "[F2] corresponding after the fix-ups passes" "pass" "$OUTCOME"

# ── F3 ───────────────────────────────────────────────────────────────────────
JUDGE=("$BOTH_PARTIAL"); AUTHOR_END=(done_sentinel router_timeout)
_run
assert_eq "[F3] a per-file call that does not finish ends the try there" "2" "$CALLS"
assert_eq "[F3] ...with its outcome" "timed_out" "$OUTCOME"
assert_eq "[F3] ...rc 1" "1" "$RC"
assert_contains "[F3] what was written is committed" "$(git -C "$R" log -1 --format=%s 2>/dev/null)" "partial assertions"

# ── F4 ───────────────────────────────────────────────────────────────────────
JUDGE=("$BOTH_OK"); AUTHOR_END=()
_run
assert_eq "[F4] no findings: one author call" "1" "$CALLS"
assert_eq "[F4] ...and one check" "1" "$(cat "$TEST_TEMP_DIR/judge-calls" 2>/dev/null || echo 0)"
assert_eq "[F4] ...and it passes" "pass" "$OUTCOME"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
