#!/usr/bin/env bash
# tests/unit/cut-off-hand-off-test.sh — a stage's notes are a hand-off, and a
# cut-off call's steps come back to the stage's next try (#2443, ADR-063).
#
# Why: on #1754 (run 41249802310) build's 3 tries were each cut off at 15
# minutes; each started over, read the same files again, and wrote no notes.
# The notes rule said "write as you work" but not who reads them; and the steps
# the cut-off call did make, which the engine keeps, reached no one.
#
# H1 [change] the notes rule says to write them as a hand-off that someone
#             starting fresh, without your context, can pick up from
# H2 [change] the stage's own Previous work shows the steps of its last
#             cut-off call, saying the call was cut off
# H3 [guard]  another stage's Previous work does not show them
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
print_test_header "notes are a hand-off; a cut-off call's steps reach the next try (#2443)"
setup_test_env "cut-off-hand-off"

S="$TEST_TEMP_DIR/state"; P="$TEST_TEMP_DIR/plugins"
mkdir -p "$S/artifacts" "$P/agent/cut"
cat > "$P/agent/cut/manifest.yaml" <<'MF'
id: cut
kind: agent
outputs:
  - id: cut-result
    path: ${artifact_dir}/cut-result.json
    format: json
    required: true
    primary: true
MF
stage_result_write "$S/artifacts/cut-result.json" timed_out stopped >/dev/null
printf '{"stage_statuses":{"cut":"failed"},"stage_verdicts":{"cut":"error"}}\n' > "$S/pipeline-state.json"

print_test_section "H1: the notes rule"
_rules="$(_stage_block_rules cut "$S" "$P/agent/cut/manifest.yaml" 2>/dev/null)"
assert_contains "[H1] notes are written for someone starting fresh" "$_rules" "starting fresh"

print_test_section "H2/H3: the steps of a cut-off call"
_n="$(stage_notes_path "$S" cut)"; mkdir -p "${_n%/*}"
printf -- '- read /w/intake-result-test.sh\n' > "${_n%.md}.cut-off.md"
_own="$( _TPL_STAGES=(cut); zb_test_previous_work "$S/pipeline-state.json" "$P" cut )"
assert_contains "[H2] the stage's next try gets the steps" "$_own" "read /w/intake-result-test.sh"
assert_contains "[H2] ...told the call was cut off" "$_own" "cut off"
_later="$( _TPL_STAGES=(cut); zb_test_previous_work "$S/pipeline-state.json" "$P" later )"
if grep -qF "read /w/intake-result-test.sh" <<< "$_later"; then
    assert_fail "[H3] another stage does not get them" "found in a later stage's Previous work"
else
    assert_pass "[H3] another stage does not get them"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
