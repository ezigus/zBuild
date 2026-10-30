#!/usr/bin/env bash
# tests/integration/test-checks-own-run-test.sh — test checks its own run
# (#2372, ADR-040, ADR-068).
#
# Why: a check that reads one stage's output belongs to that stage. test runs
# the suite, then the checks that were the shape-floor and acceptance-gate
# stages, and checks that the assertion files are the ones their author wrote
# (was assertion-integrity). test has no model to go back to: it fails with
# every failure as a numbered finding, and the build loop goes round.
#
# R1 [change] an assertion file changed since it was fingerprinted: test fails,
#             naming the file
# R2 [guard]  unchanged since fingerprinted: no finding from that check
# R3 [change] no earlier output carries fingerprints: a warning, never a failure
# R4 [change] the acceptance check runs inside test: an untagged requirement
#             fails test; the finding lives only in the check's own result
#             (#2428), and test's reason names the check
# R6 [change] design's Previous work shows the acceptance check's finding, and
#             build's shows it once (#2428, ADR-071 §2)
# R5 [change] shape-floor, acceptance-gate and assertion-integrity are no
#             longer stages; test declares the checks' outputs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "test checks its own run (#2372)"
setup_test_env "test-checks-own-run"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"
export ZBUILD_TEST_CMD="printf 'unit: 1/1 passed\\n'" ZBUILD_TEST_FRAMEWORK=0

# _run <name> <design.md body or ""> <fingerprint json or "">
_run() {
    local d="$TEST_TEMP_DIR/$1"; R="$d/repo"; S="$d/state"; A="$S/artifacts"
    mkdir -p "$A" "$R/tests"
    ( cd "$R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
        && printf 'assert_eq "x" 1 1\n' > tests/a-test.sh && git add -A && git commit -q -m seed \
        && git checkout -q -b zbuild/issue-1 && printf 'echo hi\n' > app.sh && git add -A && git commit -q -m change ) >/dev/null 2>&1
    printf '{"schema_version":1}' > "$S/pipeline-state.json"
    git -C "$R" diff main HEAD > "$A/diff.patch"
    local idx="$S/stage-inputs.json" inputs='{}'
    if [[ -n "$2" ]]; then printf '%s' "$2" > "$A/design.md"; inputs="$(jq -c --arg p "$A/design.md" '. + {design: $p}' <<< "$inputs")"; fi
    if [[ -n "$3" ]]; then printf '%s' "$3" > "$A/author-result.json"; inputs="$(jq -c --arg p "$A/author-result.json" '. + {author_result: $p}' <<< "$inputs")"; fi
    jq -n --argjson i "$inputs" '{schema_version:2, stage:"test", inputs:$i}' > "$idx"
    export ZBUILD_REPO_ROOT="$R" ZBUILD_STAGE_INPUTS="$idx" ZBUILD_ARTIFACT_DIR="$A"
    export ZBUILD_EVENTS_JSONL="$d/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    ( cd "$R" && test_run test "$S/pipeline-state.json" ) >/dev/null 2>&1
    OUTCOME="$(jq -r '.outcome // "MISSING"' "$A/test-results.json" 2>/dev/null || echo MISSING)"
    FINDINGS="$(jq -r '.data.findings[]?.text // empty' "$A/test-results.json" 2>/dev/null || true)"
}
_fp() {   # _fp <hash> — an earlier output carrying a fingerprint of tests/a-test.sh
    jq -nc --arg h "$1" '{result_contract:3, outcome:"pass", reason:"x", data:{testfiles:{"tests/a-test.sh":$h}}}'
}

# ── R1 / R2 ──────────────────────────────────────────────────────────────────
_run r1 "" "$(_fp 0000000000000000000000000000000000000000)"
assert_eq "[R1] a changed assertion file fails test" "fail" "$OUTCOME"
assert_contains "[R1] ...naming the file" "$FINDINGS" "tests/a-test.sh"
_h="$(git -C "$R" hash-object tests/a-test.sh)"
_run r2 "" "$(_fp "$_h")"
assert_eq "[R2] unchanged since fingerprinted: no finding about it" "0" "$(grep -c 'tests/a-test.sh' <<< "$FINDINGS" || true)"
assert_eq "[R2] ...and test passes" "pass" "$OUTCOME"

# ── R3 ───────────────────────────────────────────────────────────────────────
_run r3 "" ""
assert_eq "[R3] no fingerprints: test still passes" "pass" "$OUTCOME"
assert_contains "[R3] ...with a warning that the assertions were not checked" \
    "$(cat "$A/test-failures-summary.md" 2>/dev/null)" "not fingerprinted"
assert_contains "[R3] ...and an event saying so" "$(cat "$ZBUILD_EVENTS_JSONL")" '"test.assertions.unchecked"'

# ── R4 ───────────────────────────────────────────────────────────────────────
_run r4 '# Design
```acceptance
SPEC-1[code]: the app says hi
WIRING: none
TESTFILES:
SPEC-1: tests/a-test.sh
```
' ""
assert_eq "[R4] an untagged requirement fails test" "fail" "$OUTCOME"
assert_contains "[R4] ...with the finding in the acceptance check's own result" \
    "$(jq -r '.data.findings[]?.text // empty' "$A/acceptance-gate-result.json" 2>/dev/null)" "SPEC-1"
assert_eq "[R4] ...and not copied into test's result (#2428)" "" "$(grep 'SPEC-1' <<< "$FINDINGS" || true)"
assert_contains "[R4] ...whose reason names the check" "$(jq -r '.reason // ""' "$A/test-results.json")" "the acceptance check failed"

# ── R6 ───────────────────────────────────────────────────────────────────────
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
unset ZBUILD_STAGE_INPUTS
init_state "$S/pipeline-state.json" run-1 1 >/dev/null 2>&1
_update_stage_status "$S/pipeline-state.json" test complete
_zbuild_state_set_stage_verdict "$S/pipeline-state.json" test fail
_TPL_STAGES=(test design build)
_ap="$(jq -r '.data.findings[0].text // empty' "$A/acceptance-gate-result.json" 2>/dev/null)"
_pw6() { local idx; idx="$(_inputs_resolve_stage "$1" "$REPO_ROOT/plugins" "$S" 2>/dev/null)"
         _stage_block_previous_work "$1" "$S" "$REPO_ROOT/plugins" "$idx" "$R" "$REPO_ROOT/plugins/agent/$1/manifest.yaml" 2>/dev/null; }
_pwd="$(_pw6 design)"; _pwb="$(_pw6 build)"
assert_contains "[R6] design is shown the acceptance check's finding" "$_pwd" "acceptance-gate finding 1 (opened by test): ${_ap:0:40}"
assert_eq "[R6] build is shown it as a finding once" "1" \
    "$(grep -E '^- [a-z-]+ finding [0-9]+ \(opened by test\): ' <<< "$_pwb" | grep -cF -- "${_ap:0:40}")"

# ── R7 ───────────────────────────────────────────────────────────────────────
# A check that fails with no findings and a reason over two lines gets ONE
# finding: the reason is one item, not one per line (#2428 review).
shape_floor_run() { stage_result_write "$ZBUILD_ARTIFACT_DIR/shape-floor-result.json" fail $'line one\nline two'; }
acceptance_gate_run() { stage_result_write "$ZBUILD_ARTIFACT_DIR/acceptance-gate-result.json" pass ok; }
_test_own_checks test "$S/pipeline-state.json" "$A/test-results.json" "$R" >/dev/null 2>&1
assert_eq "[R7] a two-line reason is one finding" "1" \
    "$(jq '(.data.findings // []) | length' "$A/shape-floor-result.json" 2>/dev/null)"
assert_contains "[R7] ...holding both lines" "$(jq -r '.data.findings[0].text // ""' "$A/shape-floor-result.json")" "line one line two"

# ── R5 ───────────────────────────────────────────────────────────────────────
for _p in tool/shape-floor agent/spec-acceptance tool/assertion-integrity; do
    assert_eq "[R5] $_p is no longer a plugin" "absent" "$([[ -d "$REPO_ROOT/plugins/$_p" ]] && echo present || echo absent)"
done
for _s in shape-floor acceptance-gate assertion-integrity; do
    assert_eq "[R5] simple.yaml has no $_s stage" "0" "$(grep -cE "^$_s:|- $_s\$|stage: $_s," "$REPO_ROOT/config/templates/simple.yaml" || true)"
done
_out="$(sed -n '/^outputs:/,/^[a-z]/p' "$REPO_ROOT/plugins/tool/test/manifest.yaml")"
assert_contains "[R5] test declares the acceptance check's result" "$_out" "acceptance-gate-result.json"
assert_contains "[R5] ...and the shape-floor check's" "$_out" "shape-floor-result.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
