#!/usr/bin/env bash
# Guard (issue #921): _ZBUILD_STANDARD_ROSTER in test-helpers.sh MUST match the
# leaf-stage list produced by load_template(standard.yaml). If a stage is added
# to / removed from standard.yaml without updating the helper roster, this test
# fails loudly — making the helper the single source of truth for the roster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "standard roster single-source guard (#921)"
setup_test_env "standard-roster-single-source"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"

# ── G1: load_template populates _TPL_STAGES (the flat leaf-stage view) ────────
# Capture stderr so a parse failure surfaces the real error (keeps the guard
# "loud") instead of degrading to a bare empty-array assertion.
_TPL_STAGES=(); _TPL_CYCLES=()
_lt_err="$TEST_TEMP_DIR/load_template.err"
load_template "$REPO_ROOT/config/templates/standard.yaml" >/dev/null 2>"$_lt_err" || true
if [[ ${#_TPL_STAGES[@]} -gt 0 ]]; then
    assert_pass "G1: load_template populates _TPL_STAGES"
else
    assert_fail "G1: load_template populates _TPL_STAGES" \
        "empty _TPL_STAGES — load_template stderr: $(cat "$_lt_err" 2>/dev/null)"
fi

# ── G2: helper roster ids == template leaf stages, in order ──────────────────
mapfile -t helper_ids < <(standard_stage_ids)
template_ids=("${_TPL_STAGES[@]}")

assert_eq "G2: helper roster count == template leaf count" \
    "${#template_ids[@]}" "${#helper_ids[@]}"

all_match=1
for i in "${!template_ids[@]}"; do
    t_id="${template_ids[$i]}"
    h_id="${helper_ids[$i]:-MISSING}"
    if [[ "$t_id" != "$h_id" ]]; then
        assert_fail "G2: stage[$i] order match" \
            "template=$t_id helper=$h_id — update _ZBUILD_STANDARD_ROSTER in scripts/lib/test-helpers.sh"
        all_match=0
    fi
done
[[ $all_match -eq 1 ]] && assert_pass "G2: all stage ids match the template, in order"

# ── G3: standard_stage_count() agrees with the template ──────────────────────
assert_eq "G3: standard_stage_count() == template leaf count" \
    "${#template_ids[@]}" "$(standard_stage_count)"

# ── G4: register_standard_pipeline_stubs lays down every leaf stage's dir ─────
register_standard_pipeline_stubs
missing=0
while IFS=: read -r stage_id kind _role; do
    [[ -z "$stage_id" ]] && continue
    if [[ ! -f "$TEST_TEMP_DIR/plugins/$kind/$stage_id/plugin.sh" ]]; then
        assert_fail "G4: stub registered for $stage_id" \
            "missing $TEST_TEMP_DIR/plugins/$kind/$stage_id/plugin.sh"
        missing=1
    fi
done < <(printf '%s\n' "${_ZBUILD_STANDARD_ROSTER[@]}")
[[ $missing -eq 0 ]] && assert_pass "G4: register_standard_pipeline_stubs created all stage dirs"

# ── G5: per-stage exit-code override is honored ──────────────────────────────
ZBUILD_STUB_RC_build=7 register_standard_pipeline_stubs
# shellcheck disable=SC1090
source "$TEST_TEMP_DIR/plugins/agent/build/plugin.sh"
set +e; build_run; rc=$?; set -e
assert_eq "G5: ZBUILD_STUB_RC_build override applied to build stub" "7" "$rc"

cleanup_test_env
print_test_results  # exits with $FAIL
