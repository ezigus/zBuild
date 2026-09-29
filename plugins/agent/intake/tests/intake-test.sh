#!/usr/bin/env bash
# Tests: plugins/agent/intake — goal capture, sentinel sanitization, scope manifest (issue #85)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: intake (goal capture + scope manifest — issue #85)"

setup_test_env "plugin-intake"

# shellcheck source=intake-test-lib.sh
source "$SCRIPT_DIR/intake-test-lib.sh"

# ─── Test 1: manifest validates + plugin is discoverable ─────────────────────
set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "intake manifest validates" "0" "$rc"

discovered="$(discover_plugins "$REPO_ROOT/plugins")"
assert_contains "intake discovered in plugin registry" "$discovered" "agent/intake"

# ─── Test 1b: manifest declares outputs[] with intake-result.json first (SPEC-6) ─
first_output="$(awk '
    /^outputs:/ { in_outputs=1; next }
    in_outputs && /^[a-zA-Z_]/ { in_outputs=0 }
    in_outputs && /path:/ {
        sub(/^[[:space:]]*path:[[:space:]]*/, "")
        sub(/[[:space:]]*#.*/, "")
        gsub(/^["'"'"']|["'"'"']$/, "")
        print; exit
    }
' "$PLUGIN_DIR/manifest.yaml" 2>/dev/null || true)"
assert_contains "intake manifest outputs[0].path is intake-result.json" \
    "$first_output" "intake-result.json"

# ─── Test 2: ZBUILD_GOAL unset AND no issue → rc=2 ───────────────────────────
unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="0"

set +e
err="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1837/SPEC-1] unset ZBUILD_GOAL with no issue returns rc=1" "1" "$rc"
assert_contains "stderr mentions ZBUILD_GOAL" "$err" "ZBUILD_GOAL"

# ─── Test 3: goal written to state/intake.md ─────────────────────────────────
export ZBUILD_GOAL="fix auth bug"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "valid run returns rc=0" "0" "$rc"
assert_file_exists "state/intake.md created" "$STATE_DIR/intake.md"
assert_contains "intake.md contains sanitized goal" "$(cat "$STATE_DIR/intake.md")" "fix auth bug"

# ─── Test 4: synthesized sentinel stripped from goal ─────────────────────────
ZBUILD_GOAL="$(printf 'fix the login flow\n\n## Plan Summary\nsome noise')"
export ZBUILD_GOAL

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "sentinel-strip run returns rc=0" "0" "$rc"
intake_content="$(cat "$STATE_DIR/intake.md")"
assert_contains "intake.md has original prefix" "$intake_content" "fix the login flow"
if grep -q "Plan Summary" <<< "$intake_content"; then
    assert_fail "sentinel ## Plan Summary should be stripped from intake.md"
else
    assert_pass "sentinel ## Plan Summary stripped from intake.md"
fi

# ─── Test 5: platforms.json drives scope-manifest lines ──────────────────────
cat > "$STATE_DIR/platforms.json" <<'JSON'
{"detected":["ios","node"],"repo_head_sha":"abc123"}
JSON

export ZBUILD_GOAL="add feature"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "platform-aware run returns rc=0" "0" "$rc"
assert_file_exists "scope-manifest.md created" "$STATE_DIR/scope-manifest.md"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "scope-manifest has + ios/" "$scope" "+ ios/"
assert_contains "scope-manifest has + node/" "$scope" "+ node/"

# Each entry must be a "+" line (format consumed by scope-redaction.sh:73)
plus_lines="$(grep -c '^\+' "$STATE_DIR/scope-manifest.md" || true)"
assert_gt "scope-manifest entries are + lines" "$plus_lines" "0"

# ─── Test 5b: injection guard — invalid platform ID is dropped ───────────────
cat > "$STATE_DIR/platforms.json" <<'JSON'
{"detected":["ios","bad\nvalue","../etc","ok-platform"],"repo_head_sha":"abc"}
JSON

export ZBUILD_GOAL="injection test"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "injection guard run returns rc=0" "0" "$rc"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "valid platform ok-platform written" "$scope" "+ ok-platform/"
if grep -q '\.\.' <<< "$scope"; then
    assert_fail "path traversal should be filtered from scope-manifest"
else
    assert_pass "path traversal filtered from scope-manifest"
fi

# ─── Test 6: no platforms.json → generic fallback (+ ./) ─────────────────────
rm -f "$STATE_DIR/platforms.json"

export ZBUILD_GOAL="fix something"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "generic fallback run returns rc=0" "0" "$rc"
scope="$(cat "$STATE_DIR/scope-manifest.md")"
assert_contains "generic fallback writes + ./" "$scope" "+ ./"

# ─── Test 7: plugin.result event emitted on EVERY success run (SPEC-9) ────────
# Reset to a clean slate so we can count exactly — two runs must yield two events.
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_GOAL="spec-9 verify emission on every success run: first"
export ZBUILD_ISSUE="0"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
_s9_count1="$(grep -c '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#1837/SPEC-9] plugin.result emitted on first success run" "1" "$_s9_count1"

export ZBUILD_GOAL="spec-9 verify emission on every success run: second"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
_s9_count2="$(grep -c '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_eq "[#1837/SPEC-9] plugin.result emitted on every success run (two runs yield two events)" "2" "$_s9_count2"
_s9_plugin_field="$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | \
    jq -r 'select(.type=="plugin.result") | .data.plugin // empty' 2>/dev/null | tail -1 || true)"
assert_eq "[#1837/SPEC-9] plugin.result has plugin=intake" "intake" "$_s9_plugin_field"

# ─── Test 9: empty ZBUILD_GOAL + ZBUILD_ISSUE=0 → rc=2 ──────────────────────
export ZBUILD_GOAL=""
export ZBUILD_ISSUE="0"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "[#1837/SPEC-1] empty ZBUILD_GOAL with no issue returns rc=1" "1" "$rc"

# ─── Test 10: --issue mode fetches real title+body via gh ────────────────────
_set_gh_mock "Fix login crash on launch" $'Steps to reproduce:\n1. Open app\n2. Tap login' 0
unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="$_ZB_ID"

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "--issue mode with no goal text returns rc=0" "0" "$rc"
assert_contains "--issue mode writes fetched title to intake.md" \
    "$(cat "$STATE_DIR/intake.md")" "Fix login crash on launch"
assert_contains "--issue mode writes fetched body to intake.md" \
    "$(cat "$STATE_DIR/intake.md")" "Steps to reproduce"

# ─── Test 10b (#1804): a failed fetch FAILS CLOSED ──────────────────────────
# It used to warn and set the goal to the literal "GitHub issue #<N>", then let
# plan, design (up to three cycles), impact, build, test and six review lenses
# all run against a goal carrying NO information about what to build. Every
# other intake failure mode is rc=2; this one was not.
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"

set +e
intake_stderr="$(intake_run "intake" "$STATE_FILE" 2>&1 >/dev/null)"
rc=$?
set -e

assert_eq "[#1804][#1837/SPEC-1] a failed fetch with no supplied goal fails the run rc=1" "1" "$rc"
assert_contains "[#1804] and says why, naming the issue" \
    "$intake_stderr" "#$_ZB_ID"
assert_file_not_exists "[#1804] no fabricated goal is left on disk for the pipeline to use" \
    "$STATE_DIR/intake.md"

# ─── Test 10b2 (#1804): the offline placeholder survives, behind an opt-in ──
# A smoke run without network is legitimate — it just has to say so.
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_INTAKE_ALLOW_PLACEHOLDER=1 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[#1804] the opt-in still returns rc=0" "0" "$rc"
assert_contains "[#1804] and writes the placeholder it asked for" \
    "$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)" "GitHub issue #$_ZB_ID"

# ─── Test 10b3 (#1804): an explicit goal works with no network ──────────────
_set_gh_mock "" "" 1
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_GOAL="Explicitly supplied goal text" intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
assert_eq "[#1804] an explicit goal needs no fetch at all" "0" "$rc"
assert_contains "[#1804] and is what lands in intake.md" \
    "$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)" "Explicitly supplied goal text"

# ─── Test 10c: null body — title-only fetch is acceptable ───────────────────
_set_gh_mock "Refactor cache layer" "" 0

set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

assert_eq "title-only fetch returns rc=0" "0" "$rc"
assert_contains "title-only intake.md contains title" \
    "$(cat "$STATE_DIR/intake.md")" "Refactor cache layer"

# NOTE: do not _clear_gh_mock here — T_456_* tests reuse the gh PATH shim.

unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="$_ZB_ID"

# ─── #1729: issue COMMENTS reach the goal, filtered by author ───────────────
# Comments are where an issue is corrected and extended after filing. #1685 is
# the worked example: its body describes one problem, and a later owner comment
# added a second, independent half. The pipeline was structurally blind to it —
# and the acceptance-gate would have agreed the work was complete, because the
# SPECs it checks derive from the same truncated goal text. Silent scope loss
# with every gate green.
#
# Author filtering is the load-bearing part: zbuild posts its own
# run-completion comments, so an unfiltered append would feed the pipeline's own
# failure log straight back to the planner.
print_test_section "#1729: comments reach the goal, bots and retractions do not"

MOCK_GH_COMMENTS="$(cat <<'CMTS'
[
  {"author":{"login":"ezigus"},"authorAssociation":"OWNER","isMinimized":false,
   "body":"CORRECTION_FROM_OWNER also handle the timeout case"},
  {"author":{"login":"github-actions"},"authorAssociation":"NONE","isMinimized":false,
   "body":"BOTNOISE zbuild pipeline finished with result failed"},
  {"author":{"login":"some-bot[bot]"},"authorAssociation":"CONTRIBUTOR","isMinimized":false,
   "body":"BRACKETBOTNOISE automated message"},
  {"author":{"login":"ezigus"},"authorAssociation":"OWNER","isMinimized":true,
   "body":"RETRACTEDCOMMENT this was wrong"},
  {"author":{"login":"a-collaborator"},"authorAssociation":"COLLABORATOR","isMinimized":false,
   "body":"COLLABORATOR_ADDITION and refuse an empty config"}
]
CMTS
)"
export MOCK_GH_COMMENTS
_set_gh_mock "Fix login crash on launch" "Steps to reproduce click login" 0
rm -f "$STATE_DIR/intake.md"
set +e
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e
_c_goal="$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)"

assert_eq "[#1729] the fetch still succeeds" "0" "$rc"
assert_contains "[#1729] an OWNER comment reaches the goal" \
    "$_c_goal" "CORRECTION_FROM_OWNER"
assert_contains "[#1729] a COLLABORATOR comment reaches it too" \
    "$_c_goal" "COLLABORATOR_ADDITION"
assert_contains "[#1729] under a labelled heading, not silently concatenated" \
    "$_c_goal" "Additional context from issue comments"
assert_eq "[#1729] a github-actions comment does NOT — it is the pipeline's own log" \
    "0" "$(grep -c 'BOTNOISE' <<< "$_c_goal" || true)"
assert_eq "[#1729] nor any [bot] login" \
    "0" "$(grep -c 'BRACKETBOTNOISE' <<< "$_c_goal" || true)"
assert_eq "[#1729] nor a minimized comment — minimizing is an explicit retraction" \
    "0" "$(grep -c 'RETRACTEDCOMMENT' <<< "$_c_goal" || true)"
assert_contains "[#1729] and the body itself survives" "$_c_goal" "Steps to reproduce"

# ─── #1729: growth is bounded, and truncation SAYS so ──────────────────────
# The goal feeds the redaction chokepoint and every downstream prompt, so an
# unbounded comment thread inflates every stage. Silent truncation would be the
# worse failure: a shortened goal that still reads as complete.
_big_body="$(python3 -c 'print("X"*9000)')"
MOCK_GH_COMMENTS="$(jq -nc --arg b "$_big_body" \
    '[{author:{login:"ezigus"},authorAssociation:"OWNER",isMinimized:false,body:$b}]')"
export MOCK_GH_COMMENTS
rm -f "$STATE_DIR/intake.md"
set +e
ZBUILD_INTAKE_COMMENT_MAX_BYTES=500 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
set -e
_t_goal="$(cat "$STATE_DIR/intake.md" 2>/dev/null || true)"
assert_eq "[#1729] the comment section is capped" \
    "1" "$([[ "${#_t_goal}" -lt 9000 ]] && echo 1 || echo 0)"
assert_contains "[#1729] and the truncation is STATED, not silent" \
    "$_t_goal" "truncated"
unset MOCK_GH_COMMENTS

_clear_gh_mock

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
exit $((FAIL > 0))
