#!/usr/bin/env bash
# tests/unit/design-behaviour-not-tests-test.sh — design writes what the code
# must do, never "write a test" (#2586 R1; ADR-073, ADR-071 §1).
#
# Why: on #2532 run 45017980554 the issue asked for a guard test. Design's
# check refused the SPEC's [no-code] because no guard existed yet, so design
# made it [code] and added a build step "Add a guard test that scans …" over
# scripts/lib/compat.sh. Build may not touch the tests, so the step could never
# be done; build's tries went round on it.
#
# BT1 [change] design's prompt: when the issue asks for a test, the
#              requirement is the behaviour that test proves; no step's work is
#              writing or changing a test
# BT2 [change] design's check judges a requested test by the behaviour it
#              proves: code that already does it gives BEFORE yes, though no
#              test exists yet
# BT3 [change] design's check offers `Steps: test` for a step whose job is
#              writing or changing a test
# BT4 [change] that answer is a finding on the steps, saying the tests are
#              test-author's, with the check's ACCEPTED IF
# BT5 [guard]  a step quoted by `Steps: test` whose words are in no step is not
#              taken: the reply is asked again
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "design writes behaviour, not tests (#2586 R1)"
setup_test_env "design-behaviour-not-tests"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# ── BT1: design's own prompt ─────────────────────────────────────────────────
_DP="$TEST_TEMP_DIR/design-prompt.txt"
route_to_model() { [[ -s "$_DP" ]] || printf '%s' "$2" > "$_DP"; return 0; }
apply_scope_redaction() { cp "$1" "$2"; return 0; }
D="$TEST_TEMP_DIR/run"; ST="$D/state"; AD="$ST/artifacts"; mkdir -p "$AD"
git -C "$D" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$ST/scope-manifest.md"
( export ZBUILD_REPO_ROOT="$D"
  _design_stage_run_inner "$ST/scope-manifest.md" "$AD/design.md" "$AD" ) >/dev/null 2>&1
_dp="$(_flat "$(cat "$_DP" 2>/dev/null)")"
# #2629 (ADR-075 §2): build's changed files are traced to the steps' areas by name.
assert_contains "[BT1] design's prompt: an area is a path or a folder ending in /, never a pattern" "$_dp" \
    "An area is a file's path from the repository root, or a folder's ending in /: never a pattern, and nothing around it."
assert_contains "[BT1] design's prompt: a test the issue asks for is the behaviour it proves" "$_dp" \
    "When the issue asks for a test, the requirement is the behaviour that test proves"
assert_contains "[BT1] ...and no step's work is writing or changing a test" "$_dp" \
    "No step's work is writing or changing a test"

# ── BT2-BT5: design's check ──────────────────────────────────────────────────
XR="$TEST_TEMP_DIR/repo"; mkdir -p "$XR/scripts/lib"
( cd "$XR" && git init -q && printf 'zb_platform() { :; }\n' > scripts/lib/compat.sh && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
export ZBUILD_REPO_ROOT="$XR" _DESIGN_BASE_DIR="$XR"
export artifact_dir="$TEST_TEMP_DIR/art"; mkdir -p "$artifact_dir"
DM="$TEST_TEMP_DIR/design.md"
cat > "$DM" <<'MD'
# Design
## Decision
Guard the platform reads.

```steps
- Add a guard test that scans core/, plugins/ and scripts/ for host branches | areas: scripts/lib/compat.sh | serves: DSPLAT-2
```
```acceptance
DSPLAT-2[no-code]: no code branches on ZBUILD_PLATFORM for a host value covers: RQTST-3
  When: the code is scanned for host branches on ZBUILD_PLATFORM
  Then: none is found
WIRING: none
```
MD
REQS='- RQTST-3: a guard test fails when code reads ZBUILD_PLATFORM to make a host decision'
_CP="$TEST_TEMP_DIR/check-prompt"; _CN="$TEST_TEMP_DIR/check-n"
STEPS_LINE="Steps: test | WHY: the step writes a guard test | ACCEPTED IF: no step's work is writing a test; the guard is test-author's | QUOTE: Add a guard test that scans core/"
route_to_model() {
    local n; n=$(( $(cat "$_CN" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$_CN"
    printf '%s' "$2" > "$_CP.$n"
    printf '%s' $'RQTST-3: covered\nDSPLAT-2: ok\n'"$STEPS_LINE"$'\nDecision: ok'
}
rm -f "$_CN"; _design_coverage "$DM" "$REQS" T2 ""
_cp="$(_flat "$(cat "$_CP.1" 2>/dev/null)")"
assert_contains "[BT2] the check judges a requested test by the behaviour it proves" "$_cp" \
    "When a SPEC is a test the issue asks for, judge the behaviour that test proves"
assert_contains "[BT2] ...code that already does it is BEFORE yes, though no test exists yet" "$_cp" \
    "no test of it existing yet does not make it [code]"
assert_contains_lines "[BT3] the check offers Steps: test" "$_cp" $'Steps: test\nwhy:'
_f="$(_design_coverage_findings)"
assert_contains "[BT4] the answer is a finding on the steps: the tests are test-author's" "$_f" \
    "Steps: a step whose work is writing or changing a test — the tests are test-author's"
assert_contains "[BT4] ...with the check's ACCEPTED IF" "$_f" "ACCEPTED IF: no step's work is writing a test"

rm -f "$_CN" "$artifact_dir/design-judged.json"
STEPS_LINE="Steps: test | WHY: the step writes a guard test | ACCEPTED IF: no step writes a test | QUOTE: write the whole suite again"
_design_coverage "$DM" "$REQS" T2 ""
assert_eq "[BT5] a quote in no step is not taken: asked again" "2" "$(cat "$_CN" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
