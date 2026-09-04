#!/usr/bin/env bash
# Tests: plugins/tool/shape-floor/plugin.sh — the declared summary output (#2053).
#
# The manifest declares shape_floor_detail (shape-floor-detail.md) required:true,
# and ADR-055 §9 says a summary is written on EVERY terminal verdict — absence is
# not a legitimate state. The write sat inside the `fault` branch instead, which
# only fires when an out-of-scope failure is detected, so pass/skip/in-scope-fail
# left the declared output missing. The engine then recorded
# plugin.contract.violated and marked the stage failed, while gate-aggregator read
# the result file and recorded the same stage as skip (run 33720837199).
#
# These SPECs drive the REAL shape_floor_run across all four exit paths. Only
# _sf_shape_floor is stubbed — it is the verdict source, and stubbing it is how
# each path is reached deterministically without constructing four git repos.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "shape-floor — the declared summary is written on every path (#2053)"

setup_test_env "shape-floor-detail-output"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
STATE_FILE="$STATE_DIR/pipeline-state.json"
DETAIL="$ART_DIR/shape-floor-detail.md"
RESULT="$ART_DIR/shape-floor-result.json"
mkdir -p "$ART_DIR"

# The manifest is the contract under test — read the declared path from it rather
# than restating it, so a manifest rename cannot leave this test asserting a path
# nothing produces any more.
SF_MANIFEST="$REPO_ROOT/plugins/tool/shape-floor/manifest.yaml"

# Drive one exit path. $1 is what the floor library reports; the plugin parses it
# exactly as it parses the real thing.
_run_with() {
    local shape_out="$1"
    rm -f "$DETAIL" "$RESULT"
    _sf_shape_floor() { printf '%s' "$shape_out"; }
    shape_floor_run "shape-floor" "$STATE_FILE" >/dev/null 2>&1
}

_verdict_of() { jq -r '.verdict // ""' "$RESULT" 2>/dev/null || true; }

# ─── [SPEC-1] the manifest still declares the output as required ─────────────
# Every assertion below is only meaningful while this holds. If the declaration
# were dropped, the engine would stop demanding the file and these SPECs would be
# asserting a contract that no longer exists.
print_test_section "SPEC-1 (guard) — shape_floor_detail is declared required"

_decl="$(grep -A5 'id: shape_floor_detail' "$SF_MANIFEST" 2>/dev/null || true)"
assert_contains "[SPEC-1 guard] the manifest declares shape-floor-detail.md" \
    "$_decl" 'shape-floor-detail.md'
assert_contains "[SPEC-1 guard] the declared output is required" \
    "$_decl" 'required: true'

# ─── [SPEC-2..5] every terminal verdict writes the summary ───────────────────
# Four paths, one per branch of the case statement plus the fault sub-branch.
print_test_section "SPEC-2..5 — all four exit paths write the declared summary"

# SPEC-2 — pass.
_run_with "SHAPE_FLOOR PASS"
assert_eq "[SPEC-2] pass → result verdict=pass" "pass" "$(_verdict_of)"
if [[ -s "$DETAIL" ]]; then
    assert_pass "[SPEC-2] pass writes a non-empty shape-floor-detail.md"
else
    assert_fail "[SPEC-2] pass writes a non-empty shape-floor-detail.md" \
        "missing or empty: $DETAIL"
fi

# SPEC-3 — skip. This is the shape the #1834 run hit on both iterations.
_run_with "SHAPE_FLOOR SKIP no_shape_change"
assert_eq "[SPEC-3] skip → result verdict=skip" "skip" "$(_verdict_of)"
if [[ -s "$DETAIL" ]]; then
    assert_pass "[SPEC-3] skip writes a non-empty shape-floor-detail.md"
else
    assert_fail "[SPEC-3] skip writes a non-empty shape-floor-detail.md" \
        "missing or empty: $DETAIL"
fi

# SPEC-4 — in-scope fail. No scope allowlist set, so no fault is derived and the
# plugin takes the else branch that never wrote the file.
unset ZBUILD_SHAPE_FLOOR_SCOPE ZBUILD_SCOPE_ALLOWLIST
_run_with "SHAPE_FLOOR FAIL missing_floor_files: tests/golden/x.golden"
assert_eq "[SPEC-4] in-scope fail → result verdict=fail" "fail" "$(_verdict_of)"
if [[ -s "$DETAIL" ]]; then
    assert_pass "[SPEC-4] in-scope fail writes a non-empty shape-floor-detail.md"
else
    assert_fail "[SPEC-4] in-scope fail writes a non-empty shape-floor-detail.md" \
        "missing or empty: $DETAIL"
fi

# SPEC-5 (guard) — the out-of-scope fail path already wrote the file, and must
# keep doing so, and must keep putting `fault` in the result.
print_test_section "SPEC-5 (guard) — the out-of-scope fail path is unchanged"

_sf_collect_missing_floor_files() { printf 'tests/golden/x.golden\n'; }
_sf_diff_files() { printf 'config/templates/simple.yaml\n'; }
export ZBUILD_SHAPE_FLOOR_SCOPE="plugins/tool/shape-floor/plugin.sh"
_run_with "SHAPE_FLOOR FAIL missing_floor_files: tests/golden/x.golden"

assert_eq "[SPEC-5 guard] out-of-scope fail → result verdict=fail" "fail" "$(_verdict_of)"
assert_eq "[SPEC-5 guard] out-of-scope fail still records fault=scope" \
    "scope" "$(jq -r '.fault // ""' "$RESULT" 2>/dev/null || true)"
if [[ -s "$DETAIL" ]]; then
    assert_pass "[SPEC-5 guard] out-of-scope fail still writes the summary"
else
    assert_fail "[SPEC-5 guard] out-of-scope fail still writes the summary" \
        "missing or empty: $DETAIL"
fi

unset ZBUILD_SHAPE_FLOOR_SCOPE
unset -f _sf_collect_missing_floor_files _sf_diff_files

# ─── [SPEC-6] a non-fail clears a previous iteration's findings ──────────────
# The comment on the write says the file is "cleared on a non-fail so a stale
# file from a previous iteration never renders as a current finding" — behaviour
# the else branch could not produce, since it never touched the file at all. A
# cycle that fails then passes must not keep showing the failure.
print_test_section "SPEC-6 — a later pass does not leave the earlier failure showing"

_sf_collect_missing_floor_files() { printf 'tests/golden/x.golden\n'; }
_sf_diff_files() { printf 'config/templates/simple.yaml\n'; }
export ZBUILD_SHAPE_FLOOR_SCOPE="plugins/tool/shape-floor/plugin.sh"
_run_with "SHAPE_FLOOR FAIL missing_floor_files: tests/golden/stale-finding.golden"
unset ZBUILD_SHAPE_FLOOR_SCOPE
unset -f _sf_collect_missing_floor_files _sf_diff_files

assert_contains "[SPEC-6] the failing iteration's detail names the missing file" \
    "$(cat "$DETAIL" 2>/dev/null || true)" "stale-finding.golden"

# Same artifacts dir, next iteration passes — deliberately NOT removing the file,
# which is the situation the clearing is for.
_sf_shape_floor() { printf '%s' "SHAPE_FLOOR PASS"; }
shape_floor_run "shape-floor" "$STATE_FILE" >/dev/null 2>&1

_after="$(cat "$DETAIL" 2>/dev/null || true)"
if grep -qF "stale-finding.golden" <<< "$_after"; then
    assert_fail "[SPEC-6] a passing iteration clears the previous failure's detail" \
        "stale finding still present: $_after"
else
    assert_pass "[SPEC-6] a passing iteration clears the previous failure's detail"
fi
assert_contains "[SPEC-6] and the cleared summary still states the current verdict" \
    "$_after" "pass"

print_test_results
