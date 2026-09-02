#!/usr/bin/env bash
# Integration test (#483): producer-side banner rendering across the
# subprocess boundary. The plan stage must opt into the renderer registry
# such that the stage-io OUTPUT banner shows rendered markdown instead of
# raw JSON when the real claude stub is on PATH.
#
# This test exercises:
#   - real route_to_model (no shadow)
#   - real capture_stage_io
#   - real install_envelope_mock_claude binary on PATH
#   - real render_artifact dispatch through the registry
# and captures fd 3 (ZBUILD_STAGE_IO_FD) to assert the banner content.
# (The former review-stage banner sections were removed with #979 — the
# review agent plugin is retired; the plan stage covers the same generic
# producer-side banner-render feature.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "agent-stage banner: rendered markdown across subprocess boundary (#483)"

setup_test_env "agent-banner-rendered-md"

# #1921 follow-up: reserved test identity (zb_test_issue). These were real
# issue numbers; a run keyed to one writes fabricated prior work onto that
# issue's state branch. Only identity positions and the strings DERIVED from
# them are swept — a bare number elsewhere is not an identity.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="banner-md-test-$$"
mkdir -p "$TEST_TEMP_DIR/bin"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

STATE_DIR="$TEST_TEMP_DIR/state"
STATE_FILE="$STATE_DIR/pipeline-state.json"
ARTIFACTS_DIR="$STATE_DIR/artifacts"
mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
echo '{"schema_version":1,"run_id":"banner-md-test","issue":"999","stage_statuses":{}}' > "$STATE_FILE"

cat > "$STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
# ADR-043: redaction is owned by route_to_model, which reads ZBUILD_SCOPE_MANIFEST
# (runner-exported per-stage) and fail-closes if the events log does not yet
# exist (the runner emits stage events first). Mirror the runner here so the
# first plan_run below routes instead of refusing.
export ZBUILD_SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"
: > "$ZBUILD_EVENTS_JSONL"

# ─── Plan banner test ───────────────────────────────────────────────────────
print_test_section "plan stage OUTPUT banner renders via render_plan_md (#483)"

PLAN_CANNED="$TEST_TEMP_DIR/plan-canned.json"
printf '%s\n' '{"schema_version":1,"title":"Boundary Plan","goal":"render across exec","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$PLAN_CANNED"
install_envelope_mock_claude --file "$PLAN_CANNED"

# Enable stage-io capture for the plan stage (stdout dest).
export ZBUILD_CURRENT_STAGE=plan
export _TPL_STAGE_IO_DESTS_plan="stdout"
PLAN_BANNER="$TEST_TEMP_DIR/plan-banner.txt"
: > "$PLAN_BANNER"
exec 3>"$PLAN_BANNER"
export ZBUILD_STAGE_IO_FD=3

# shellcheck source=../../plugins/agent/plan/plugin.sh
source "$REPO_ROOT/plugins/agent/plan/plugin.sh"

export ZBUILD_GOAL="banner integration test"
export ZBUILD_ISSUE="$_ZB_ID"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_plan

assert_eq "plan_run rc=0 with banner capture on" "0" "$rc"

plan_banner_content="$(cat "$PLAN_BANNER" 2>/dev/null || true)"
if grep -qF "# Plan: Boundary Plan" <<< "$plan_banner_content"; then
    assert_pass "plan banner contains rendered markdown heading across subprocess"
else
    assert_fail "plan banner missing markdown heading across subprocess" \
        "got: $(printf '%s' "$plan_banner_content" | head -40)"
fi

plan_output_section="$(printf '%s' "$plan_banner_content" | sed -n '/seq=[0-9]* output /,/── end stage-io/p')"
if grep -qF '"title":"Boundary Plan"' <<< "$plan_output_section"; then
    assert_fail "plan banner raw JSON leaked into output section" \
        "got: $(printf '%s' "$plan_output_section" | head -20)"
else
    assert_pass "plan banner output section free of raw JSON"
fi

# ─── Plan banner: prose+JSON envelope splits into plan + llm comment (#510) ─
print_test_section "plan stage OUTPUT banner splits prose+JSON envelope (#510)"

: > "$ZBUILD_EVENTS_JSONL"
PLAN_MIX="$TEST_TEMP_DIR/plan-canned-mixed.json"
printf '%s' 'Here is the plan.
{"schema_version":1,"title":"Mixed Plan","goal":"split prose","steps":[{"id":"step-1","description":"d","files":["core/foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
Let me know if you want changes.' > "$PLAN_MIX"
PLAN_PROMPT_REC="$TEST_TEMP_DIR/plan-mix-prompt.txt"
install_envelope_mock_claude --file "$PLAN_MIX" --record-prompt "$PLAN_PROMPT_REC"

export ZBUILD_CURRENT_STAGE=plan
export _TPL_STAGE_IO_DESTS_plan="stdout"
PLAN_BANNER_MIX="$TEST_TEMP_DIR/plan-banner-mix.txt"
: > "$PLAN_BANNER_MIX"
exec 3>"$PLAN_BANNER_MIX"
export ZBUILD_STAGE_IO_FD=3

rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
rc=$?
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_plan

assert_eq "plan_run rc=0 on prose+JSON envelope" "0" "$rc"

plan_mix_content="$(cat "$PLAN_BANNER_MIX" 2>/dev/null || true)"
plan_mix_output="$(printf '%s' "$plan_mix_content" | sed -n '/seq=[0-9]* output /,/── end stage-io/p')"

if grep -qF "# Plan: Mixed Plan" <<< "$plan_mix_output"; then
    assert_pass "prose+JSON banner: rendered plan heading present"
else
    assert_fail "prose+JSON banner: rendered plan heading present" \
        "got: $(printf '%s' "$plan_mix_output" | head -40)"
fi
if grep -qF "## Steps" <<< "$plan_mix_output"; then
    assert_pass "prose+JSON banner: ## Steps section present"
else
    assert_fail "prose+JSON banner: ## Steps section present" \
        "got: $(printf '%s' "$plan_mix_output" | head -40)"
fi
if grep -qF "── llm comment ──" <<< "$plan_mix_output"; then
    assert_pass "prose+JSON banner: llm comment block emitted"
else
    assert_fail "prose+JSON banner: llm comment block emitted" \
        "got: $(printf '%s' "$plan_mix_output" | head -40)"
fi
if grep -qF "Let me know if you want changes" <<< "$plan_mix_output"; then
    assert_pass "prose+JSON banner: suffix prose preserved in comment"
else
    assert_fail "prose+JSON banner: suffix prose preserved in comment" \
        "got: $(printf '%s' "$plan_mix_output" | head -40)"
fi

# plan.json on disk must be ONLY the JSON object (envelope prose stripped).
PLAN_ON_DISK="$ARTIFACTS_DIR/plan.json"
if [[ -f "$PLAN_ON_DISK" ]] && jq empty "$PLAN_ON_DISK" >/dev/null 2>&1; then
    title_on_disk="$(jq -r '.title' "$PLAN_ON_DISK")"
    if [[ "$title_on_disk" == "Mixed Plan" ]]; then
        assert_pass "plan.json on disk parses + contains pure JSON object"
    else
        assert_fail "plan.json on disk title mismatch" "got: $title_on_disk"
    fi
else
    assert_fail "plan.json on disk parses with jq" "missing or invalid: $PLAN_ON_DISK"
fi

# ─── Plan banner: JSON-only envelope → NO comment marker (regression lock) ─
print_test_section "plan stage OUTPUT banner: JSON-only envelope has no comment marker (#510)"

: > "$ZBUILD_EVENTS_JSONL"
install_envelope_mock_claude --file "$PLAN_CANNED"

export ZBUILD_CURRENT_STAGE=plan
export _TPL_STAGE_IO_DESTS_plan="stdout"
PLAN_BANNER_JO="$TEST_TEMP_DIR/plan-banner-json-only.txt"
: > "$PLAN_BANNER_JO"
exec 3>"$PLAN_BANNER_JO"
export ZBUILD_STAGE_IO_FD=3

rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR"

set +e
plan_run "plan" "$STATE_FILE" >/dev/null 2>&1
set -e

exec 3>&-
unset ZBUILD_STAGE_IO_FD ZBUILD_CURRENT_STAGE _TPL_STAGE_IO_DESTS_plan

plan_jo_output="$(sed -n '/seq=[0-9]* output /,/── end stage-io/p' "$PLAN_BANNER_JO" 2>/dev/null || true)"
if grep -qF "── llm comment ──" <<< "$plan_jo_output"; then
    assert_fail "JSON-only banner has NO llm comment marker (regression lock)" \
        "got: $(printf '%s' "$plan_jo_output" | head -40)"
else
    assert_pass "JSON-only banner has NO llm comment marker (regression lock)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
