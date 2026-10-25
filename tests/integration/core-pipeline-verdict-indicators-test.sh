#!/usr/bin/env bash
# Integration: runner stage-complete indicator reflects verdict (#507).
# Uses synthetic plugins that write a primary artifact with a controlled verdict.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner verdict-driven indicators (#507)"
setup_test_env "verdict-indicators"

# #1921 follow-up: reserved test identity (zb_test_issue). These were real
# issue numbers; a run keyed to one writes fabricated prior work onto that
# issue's state branch. Only identity positions and the strings DERIVED from
# them are swept — a bare number elsewhere is not an identity.
_ZB_ID="$(zb_test_issue)"
# Wave 12-E (#664): default is enforce. Stub plugins used here lack honest
# inputs/outputs blocks; opt out — this suite tests verdict indicators.
export ZBUILD_CONTRACT_VALIDATOR=warn

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# #511 F2: pre-cycle linear assertions; force linear dispatch.
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── Helper: synthetic plugin that writes its result with outcome X ───────────
# _make_verdict_plugin <stage_id> <kind> <output_relpath> <outcome> [role] [data-json]
_make_verdict_plugin() {
    local id="$1" kind="$2" out_rel="$3" outcome="$4" role="${5:-}" data="${6:-}"
    local dir="$PLUGINS_ROOT/$kind/$id"
    fixture_link_personas "$PLUGINS_ROOT"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    # #1850/#2366: the stub speaks result contract 3 — one outcome, written by
    # the engine's own writer.
    # Agent plugins must declare redaction in requires.core (registry rule).
    local core_list="[event-bus]"
    if [[ "$kind" == "agent" ]]; then
        core_list="[redaction, event-bus]"
    fi
    {
        cat <<EOF
id: $id
name: $id
kind: $kind
version: 0.0.1
hooks:
  run: $fn
requires:
  core: $core_list
EOF
        printf 'provides:\n  result_contract: 3\n'
        [[ -n "$role" ]] && printf '  role: %s\n' "$role"
        cat <<EOF
inputs: []
outputs:
  - id: ${id}_out
    path: \${artifact_dir}/$out_rel
    type: ${id}-out.json@1
    format: json
    required: true
    primary: true
EOF
    } > "$dir/manifest.yaml"
    cat > "$dir/plugin.sh" <<EOF
${fn}() {
    local state_file="\$2"
    local state_dir; state_dir="\$(dirname "\$state_file")"
    local art_dir="\$state_dir/artifacts"
    mkdir -p "\$art_dir"
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\$art_dir/$out_rel" $outcome stub '$data'
    return 0
}
EOF
}

# #1095 (PC2): scenarios 2–4 each assert one verdict→glyph mapping on a single
# stage. Booting the full ~14-stage standard roster (~13s each) just to read one
# glyph is wasteful. Instead drive the runner with a minimal single-stage fixture
# (~1.3s each). #1270: install each fixture as a per-repo `.zbuild/templates/`
# overlay in a temp repo (they accrete into the same repo across calls) and run
# the runner with CWD = that repo (resolver reads from $PWD); nothing lands in the
# tracked config/templates/, and the temp repo is reaped by the master trap.
VERDICT_OVERLAY_REPO="$(setup_git_temp_repo verdict-overlay-repo)"
_install_verdict_fixture() {
    install_template_overlay "$VERDICT_OVERLAY_REPO" "$1"
}

# _run_pipeline_template <template-id> — single-stage fixture run.
_run_pipeline_template() {
    rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
    ( cd "$VERDICT_OVERLAY_REPO" && bash "$RUNNER" --issue "$_ZB_ID" --template "$1" ) \
        2>"$TEST_TEMP_DIR/runner.err" >/dev/null
}

# ─── Scenario 1: all-pass → every line ends with ✓ ───────────────────────────
# #978 (EPIC #966): template-agnostic. Was pinned to `--template standard` with a
# hand-registered 14-stage standard roster; standard.yaml retires in #979. The
# behavior under test — all-pass stages each get a ✓, stage.complete carries
# verdict=pass, and stage_verdicts persists — is NOT roster-specific, so drive a
# small multi-leaf fixture the test owns (intake/build/test) via the same
# overlay+fixture pattern scenarios 2–4 already use.
print_test_section "all-pass: every stage line ends with ✓"
rm -rf "$PLUGINS_ROOT"
_install_verdict_fixture verdict-indicator-allpass
ALLPASS_STAGES=(intake build test)
_make_verdict_plugin intake agent intake.json pass intake
_make_verdict_plugin build  agent build-summary.json pass builder '{"scope_violation":false}'
_make_verdict_plugin test   tool  test-results.json  pass tester
set +e; _run_pipeline_template verdict-indicator-allpass; rc=$?; set -e
if [[ $rc -ne 0 ]]; then
    echo "--- runner.err on failure ---" >&2
    cat "$TEST_TEMP_DIR/runner.err" >&2 || true
    echo "--- end ---" >&2
fi
assert_eq "all-pass: runner exits 0" "0" "$rc"

err="$(cat "$TEST_TEMP_DIR/runner.err")"
for stage in "${ALLPASS_STAGES[@]}"; do
    if grep -E "✓.*Stage.*${stage}.*complete" <<<"$err" >/dev/null; then
        assert_pass "all-pass: ✓ on $stage line"
    else
        assert_fail "all-pass: ✓ on $stage line" "stage line not found"
    fi
done

# Verdict attribute on stage.complete events — one verdict=pass per fixture stage.
all_pass_with_verdict=$(grep '"stage.complete"' "$EVENTS_JSONL" | grep -c '"pass"' || true)
[[ "$all_pass_with_verdict" -ge "${#ALLPASS_STAGES[@]}" ]] \
    && assert_pass "stage.complete carries verdict=pass for each stage" \
    || assert_fail "stage.complete carries verdict=pass for each stage" "got $all_pass_with_verdict"

# stage_verdicts persisted in state
verdict_intake="$(jq -r '.stage_verdicts.intake // empty' "$STATE_DIR/pipeline-state.json")"
assert_eq "state.stage_verdicts.intake == pass" "pass" "$verdict_intake"

# ─── Scenario 2: test verdict=fail → ✗ on test line ──────────────────────────
# #1095 (PC2): minimal single-stage fixture roster — the assertion only inspects
# the `test` stage glyph, so the other 13 standard stages add no coverage here.
print_test_section "test verdict=fail produces ✗"
rm -rf "$PLUGINS_ROOT"
_install_verdict_fixture verdict-indicator-test
_make_verdict_plugin test tool test-results.json fail tester
set +e; _run_pipeline_template verdict-indicator-test; rc=$?; set -e
err="$(cat "$TEST_TEMP_DIR/runner.err")"
# #1798: a failing verdict now ENDS the run, so the ✗ is on the line that says
# the stage reported it — not on a "complete" line, which no longer prints.
if grep -E "✗.*Stage test reported fail" <<<"$err" >/dev/null; then
    assert_pass "test verdict=fail -> ✗ on test line"
else
    assert_fail "test verdict=fail -> ✗ on test line" "$(grep -i 'test' <<<"$err" || echo 'no line')"
fi
assert_eq "test verdict=fail -> ✗ on test line: the run stops (rc 1)" "1" "$rc"

# ─── Scenario 3: build scope_violation=true → ✗ on build line ────────────────
# #1095 (PC2): minimal single-stage fixture roster — the assertion only inspects
# the `build` stage glyph.
# #2366: build PUSHES its outcome — a scope violation is outcome fail, with the
# detail under data, not a per-stage verdict word.
print_test_section "build scope_violation=true produces ✗"
rm -rf "$PLUGINS_ROOT"
_install_verdict_fixture verdict-indicator-build
_make_verdict_plugin build agent build-summary.json fail builder '{"scope_violation":true}'
set +e; _run_pipeline_template verdict-indicator-build; rc=$?; set -e
err="$(cat "$TEST_TEMP_DIR/runner.err")"
# #1798: a failing verdict now ENDS the run, so the ✗ is on the line that says
# the stage reported it — not on a "complete" line, which no longer prints.
if grep -E "✗.*Stage build reported fail" <<<"$err" >/dev/null; then
    assert_pass "build scope_violation=true -> ✗ on build line"
else
    assert_fail "build scope_violation=true -> ✗ on build line" "$(grep -i 'build' <<<"$err" || echo 'no line')"
fi
assert_eq "build scope_violation=true -> ✗ on build line: the run stops (rc 1)" "1" "$rc"

# Scenario 4 (review request_changes → ⚠) retired by #2366: an outcome is pass
# or fail, or how the stage failed to finish — there is no warn outcome.

cleanup_test_env
print_test_results
exit $((FAIL > 0))
