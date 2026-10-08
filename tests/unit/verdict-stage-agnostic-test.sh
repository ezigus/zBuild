#!/usr/bin/env bash
# tests/unit/verdict-stage-agnostic-test.sh — EPIC #1277 / issue #1280.
#
# Fictitious-stage harness (ADR-047 §3): the verdict reader names NO stage. A
# stage PUSHES its verdict to the canonical channel — the .verdict of its v2
# result, which is its primary artifact. #1850 retired the <stage>-verdict.json
# sidecar a non-JSON primary once used, and the channel-missing→warn overlay: a
# stage with no readable v2 result has failed.
#
# This proves a fictitiously-named stage's verdict is read with ZERO stage-specific
# code in the mechanic: verdict.sh contains no fixture stage-name literal and is
# byte-identical before/after the reads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERDICT_SH="$REPO_ROOT/core/pipeline/verdict.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "verdict reader is stage-agnostic — fictitious-stage harness (#1280)"
setup_test_env "verdict-stage-agnostic"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

_sha_before="$(shasum "$VERDICT_SH" | awk '{print $1}')"

# shellcheck source=../../core/pipeline/verdict.sh
source "$VERDICT_SH"

STATE_DIR="$TEST_TEMP_DIR/state"
ART_DIR="$STATE_DIR/artifacts"
mkdir -p "$ART_DIR"

_make_manifest() {
    local dir="$1" id="$2" path="$3" out_id="${4:-out}" type="${5:-json}"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: $id
kind: tool
version: 0.0.1
hooks:
  run: ${id//-/_}_run
requires:
  core: [event-bus]
inputs: []
outputs:
  - id: $out_id
    path: $path
    type: $type
    required: true
    primary: true
provides:
  result_contract: 2
config:
  valid_verdicts: [approve, block]
EOF
}

# ─── SPEC-1: a fictitious stage pushes `block` in its v2 result ──────────────
FROB="$TEST_TEMP_DIR/plugins/frobnicate"
_make_manifest "$FROB" "frobnicate" "${ART_DIR}/frobnicate-result.json" "frob_result" "json"
printf '%s' '{"result_contract":2,"verdict":"block","disposition":"complete","reason":"r"}' > "$ART_DIR/frobnicate-result.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$FROB/manifest.yaml" "frobnicate" 0)"
assert_eq "SPEC-1: v2 result verdict=block -> block (structural pass-through #550)" "block" "$got"
raw="$(runner_read_stage_verdict_raw "$STATE_DIR" "$FROB/manifest.yaml" "frobnicate" 0)"
assert_eq "SPEC-1: raw channel returns the pushed verdict 'block'" "block" "$raw"

# ─── SPEC-2: a non-JSON primary cannot carry a result — and no sidecar speaks
# for it any more (#1850): the stage has failed, whatever file sits beside it.
DOC="$TEST_TEMP_DIR/plugins/docstage"
_make_manifest "$DOC" "docstage" "${ART_DIR}/docstage.md" "doc" "markdown"
printf '# a document\n' > "$ART_DIR/docstage.md"
printf '%s' '{"verdict":"approve"}' > "$ART_DIR/docstage-verdict.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$DOC/manifest.yaml" "docstage" 0)"
assert_eq "SPEC-2: non-JSON primary, even with a sidecar -> error (#1850)" "error" "$got"

# ─── SPEC-3: fictitious JSON-primary stage pushes .verdict directly ──────────
WIDGET="$TEST_TEMP_DIR/plugins/widget"
_make_manifest "$WIDGET" "widget" "${ART_DIR}/widget.json" "widget_out" "json"
printf '%s' '{"result_contract":2,"verdict":"approve","disposition":"complete","reason":"r"}' > "$ART_DIR/widget.json"
got="$(runner_read_stage_verdict "$STATE_DIR" "$WIDGET/manifest.yaml" "widget" 0)"
assert_eq "SPEC-3: JSON primary .verdict=approve -> classified pass" "pass" "$got"
raw="$(runner_read_stage_verdict_raw "$STATE_DIR" "$WIDGET/manifest.yaml" "widget" 0)"
assert_eq "SPEC-3: raw channel returns pushed .verdict 'approve'" "approve" "$raw"

# ─── SPEC-4: the mechanic is stage-agnostic ──────────────────────────────────
if grep -qE '"frobnicate"|"widget"|"docstage"' "$VERDICT_SH"; then
    assert_fail "SPEC-4a: verdict.sh names no fixture stage" "found a fixture stage-name literal"
else
    assert_pass "SPEC-4a: verdict.sh names no fixture stage (verdict is a pushed channel)"
fi
_sha_after="$(shasum "$VERDICT_SH" | awk '{print $1}')"
assert_eq "SPEC-4b: verdict.sh byte-identical after reading fictitious stages" "$_sha_before" "$_sha_after"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
