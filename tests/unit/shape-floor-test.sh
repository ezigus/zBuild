#!/usr/bin/env bash
# Tests: scripts/lib/shape-floor.sh (ADR-040, issue #1134, EPIC #1129)
# The un-gameable shape-floor check (extracted from the retired ablation logic, #971).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/shape-floor.sh — un-gameable shape floor (#1134)"
setup_test_env "shape-floor"

_test_cleanup_hook() { cleanup_test_env; }

_SHAPE_FLOOR_SH="$REPO_ROOT/scripts/lib/shape-floor.sh"

# ─── SPEC-1: sources cleanly ──────────────────────────────────────────────────

set +e
# shellcheck source=../../scripts/lib/shape-floor.sh
source "$_SHAPE_FLOOR_SH"
_spec1_rc=$?
set -e

assert_eq "[SPEC-1] shape-floor.sh sources without error" "0" "$_spec1_rc"

# ─── Shape floor tests — minimal temp repo ───────────────────────────────────
# Minimal repo with a controlled shape-change-paths.txt + golden file.
# ZBUILD_DIFF_CMD mocks the git diff output so no real git ops are needed.

_sr="$TEST_TEMP_DIR/shape-repo"
mkdir -p "$_sr/config" "$_sr/tests/golden/mytest"
printf 'config/templates/*.yaml\n' > "$_sr/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr/tests/golden/mytest/event-sequence.golden"

# ─── SPEC-2: shape floor SKIP — no shape-change file in diff ──────────────────
# Diff has no file matching shape-change-paths.txt → SHAPE_FLOOR SKIP.

set +e
_spec2_out="$(ZBUILD_DIFF_CMD="printf 'scripts/lib/helpers.sh\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-2] non-shape file in diff → SHAPE_FLOOR SKIP" \
    "$_spec2_out" "SHAPE_FLOOR SKIP no_shape_change"

# ─── SPEC-3: shape floor FAIL — shape-change file in diff, golden absent ──────
# Shape-change file detected but event-sequence.golden NOT in diff → FAIL.

set +e
_spec3_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-3] shape change without golden in diff → SHAPE_FLOOR FAIL" \
    "$_spec3_out" "SHAPE_FLOOR FAIL missing_floor_files"

# ─── SPEC-4: shape floor PASS — shape-change file + golden both in diff ───────
# Both shape-change file and golden file in diff (no _TPL_STAGES[N] files in this
# minimal repo) → PASS.

set +e
_spec4_out="$(ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\ntests/golden/mytest/event-sequence.golden\n'" \
    _sf_shape_floor "$_sr")"
set -e

assert_contains "[SPEC-4] shape change + golden in diff → SHAPE_FLOOR PASS" \
    "$_spec4_out" "SHAPE_FLOOR PASS"

# ─── SPEC-5: append-only event-schema.json → SHAPE_FLOOR SKIP ────────────────
# When config/event-schema.json is the SOLE shape-change match AND the diff has
# no removed lines, shape-floor treats it as no shape change (SKIP).
# CHANGE: fails at baseline (before _sf_is_schema_append_only exemption is wired).

_sr2="$TEST_TEMP_DIR/schema-append-repo"
mkdir -p "$_sr2/config" "$_sr2/tests/golden/mytest"
printf 'config/event-schema.json\n' > "$_sr2/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr2/tests/golden/mytest/event-sequence.golden"

set +e
_spec5_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf '+  \"shape_floor.new_event\",\n'" \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-5] append-only known_types addition → SHAPE_FLOOR SKIP" \
    "$_spec5_out" "SHAPE_FLOOR SKIP"

# ─── SPEC-6 (GUARD): non-append-only schema diff → SHAPE_FLOOR FAIL ──────────
# When the event-schema.json diff has removed lines, the exemption must NOT fire.
# Golden file absent → FAIL (same as without the exemption).

set +e
_spec6_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf '-  \"old.event\",\n+  \"new.event\",\n'" \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-6] non-append-only event-schema diff → SHAPE_FLOOR FAIL (not SKIP)" \
    "$_spec6_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-7 (GUARD): multiple shape-change files → exemption does not apply ───
# When event-schema.json AND another shape-change file are both in the diff, the
# append-only exemption must not suppress the floor check.

_sr3="$TEST_TEMP_DIR/multi-shape-repo"
mkdir -p "$_sr3/config" "$_sr3/tests/golden/mytest"
printf 'config/event-schema.json\nconfig/templates/*.yaml\n' > "$_sr3/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr3/tests/golden/mytest/event-sequence.golden"

set +e
_spec7_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\nconfig/templates/simple.yaml\n'" \
    ZBUILD_SCHEMA_DIFF_CMD="printf '+  \"shape_floor.new_event\",\n'" \
    _sf_shape_floor "$_sr3")"
set -e

assert_contains "[SPEC-7] multiple shape-change files → SHAPE_FLOOR FAIL (exemption not applied)" \
    "$_spec7_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-2 (plugin): out-of-scope escalation → route_target=design ──────────
# When shape_floor_run finds ALL missing floor files outside the build's scope,
# it must write route_target=design into shape-floor-result.json.
# CHANGE: fails at baseline (before route_target injection in shape_floor_run).

_sr_oos="$TEST_TEMP_DIR/oos-plugin-repo"
mkdir -p "$_sr_oos/config" "$_sr_oos/tests/golden/oosspec"
printf 'config/templates/*.yaml\n' > "$_sr_oos/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr_oos/tests/golden/oosspec/event-sequence.golden"

_sf_art_oos="$TEST_TEMP_DIR/sf-oos-artifacts"
mkdir -p "$_sf_art_oos"

# shellcheck source=../../plugins/tool/shape-floor/plugin.sh
source "$REPO_ROOT/plugins/tool/shape-floor/plugin.sh"

set +e
ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="scripts/lib/helpers.sh" \
ZBUILD_REPO_ROOT="$_sr_oos" \
ZBUILD_ARTIFACT_DIR="$_sf_art_oos" \
    shape_floor_run "shape-floor" ""
set -e

_sf_oos_result="$_sf_art_oos/shape-floor-result.json"
_sf_oos_rt=""
[[ -f "$_sf_oos_result" ]] \
    && _sf_oos_rt="$(jq -r '.route_target // empty' "$_sf_oos_result" 2>/dev/null)"

assert_eq "[SPEC-2] out-of-scope missing floor files → route_target=design in artifact" \
    "design" "$_sf_oos_rt"

# ─── SPEC-8 (GUARD): additive but STRUCTURAL schema change → FAIL, not SKIP ──
# The append-only exemption covers known_types entries only. A diff that adds a
# new object KEY removes no lines, so a removals-only test would exempt it — but
# a structural schema addition can change pipeline shape and must stay gated.

set +e
_spec8_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD='printf "+  \"required_stages\": [\"build\",\"test\"],\n"' \
    _sf_shape_floor "$_sr2")"
set -e

assert_contains "[SPEC-8] additive structural schema key → SHAPE_FLOOR FAIL (exemption is known_types-only)" \
    "$_spec8_out" "SHAPE_FLOOR FAIL"

# ─── SPEC-10 (GUARD): one file matching TWO globs is still a sole match ─────
# _matched_files accumulates one entry per (pattern, file) hit. A single file
# matching two globs must not inflate the count and disable the exemption —
# "sole match" is about distinct files, not pattern hits.

_sr4="$TEST_TEMP_DIR/dup-pattern-repo"
mkdir -p "$_sr4/config" "$_sr4/tests/golden/mytest"
printf 'config/event-schema.json\nconfig/*.json\n' > "$_sr4/config/shape-change-paths.txt"
printf 'golden-event-content\n' > "$_sr4/tests/golden/mytest/event-sequence.golden"

set +e
_spec10_out="$(ZBUILD_DIFF_CMD="printf 'config/event-schema.json\n'" \
    ZBUILD_SCHEMA_DIFF_CMD='printf "+  \"shape_floor.new_event\",\n"' \
    _sf_shape_floor "$_sr4")"
set -e

assert_contains "[SPEC-10] one file matching two shape globs → SHAPE_FLOOR SKIP (dedup before counting)" \
    "$_spec10_out" "SHAPE_FLOOR SKIP"

# ─── SPEC-9 (GUARD): missing floor files IN scope → fail, NO route_target ────
# Escalation is for demands build cannot legally satisfy. When the missing floor
# file IS in build's scope, build owns the fix and the gate must stay a plain
# fail — routing back to design would rewind for work build can already do.
# (This is the design's SPEC-3; tagged SPEC-9 because [SPEC-3] is already taken
# in this file by an unrelated pre-existing assertion — see #1670.)

_sf_art_ins="$TEST_TEMP_DIR/sf-inscope-artifacts"
mkdir -p "$_sf_art_ins"

set +e
ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="tests/golden/oosspec/event-sequence.golden" \
ZBUILD_REPO_ROOT="$_sr_oos" \
ZBUILD_ARTIFACT_DIR="$_sf_art_ins" \
    shape_floor_run "shape-floor" ""
set -e

_sf_ins_result="$_sf_art_ins/shape-floor-result.json"
_sf_ins_rt="absent"; _sf_ins_verdict=""
if [[ -f "$_sf_ins_result" ]]; then
    _sf_ins_verdict="$(jq -r '.verdict // empty' "$_sf_ins_result" 2>/dev/null)"
    _sf_ins_rt="$(jq -r 'if has("route_target") then .route_target else "absent" end' \
        "$_sf_ins_result" 2>/dev/null)"
fi

assert_eq "[SPEC-9] in-scope missing floor file → verdict=fail" \
    "fail" "$_sf_ins_verdict"
assert_eq "[SPEC-9] in-scope missing floor file → no route_target field" \
    "absent" "$_sf_ins_rt"

# ─── SPEC-11 (GUARD): the fail EVENT names the failure the same as the artifact
# The artifact writes `reason`; the event must not call the same value `detail`.
# Captured by stubbing eb_emit_event (which _sf_emit dispatches to when defined)
# rather than grepping the source — a source grep would pass on a comment.

_sf_ev_capture="$TEST_TEMP_DIR/sf-events.txt"
: > "$_sf_ev_capture"
eb_emit_event() { printf '%s\n' "$*" >> "$_sf_ev_capture"; }

_sf_art_ev="$TEST_TEMP_DIR/sf-event-artifacts"
mkdir -p "$_sf_art_ev"

set +e
ZBUILD_DIFF_CMD="printf 'config/templates/simple.yaml\n'" \
ZBUILD_SCHEMA_DIFF_CMD="" \
ZBUILD_SHAPE_FLOOR_SCOPE="" \
ZBUILD_SCOPE_ALLOWLIST="" \
ZBUILD_REPO_ROOT="$_sr_oos" \
ZBUILD_ARTIFACT_DIR="$_sf_art_ev" \
    shape_floor_run "shape-floor" ""
set -e
unset -f eb_emit_event

_sf_fail_ev="$(grep '^shape_floor.fail' "$_sf_ev_capture" 2>/dev/null || true)"
_sf_art_reason="$(jq -r '.reason // empty' "$_sf_art_ev/shape-floor-result.json" 2>/dev/null)"

assert_contains "[SPEC-11] shape_floor.fail event names the failure 'reason=', matching the artifact" \
    "$_sf_fail_ev" "reason=$_sf_art_reason"

# ─── Results ─────────────────────────────────────────────────────────────────

print_test_results
