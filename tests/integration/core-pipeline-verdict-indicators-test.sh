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
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# #511 F2: pre-cycle linear assertions; force linear dispatch.
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# ─── Helper: synthetic plugin that writes test-results.json with verdict X ───
# _make_verdict_plugin <stage_id> <kind> <output_relpath> <json> [role]
_make_verdict_plugin() {
    local id="$1" kind="$2" out_rel="$3" json="$4" role="${5:-}"
    local dir="$PLUGINS_ROOT/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
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
        if [[ -n "$role" ]]; then
            cat <<EOF
provides:
  role: $role
EOF
        fi
        cat <<EOF
inputs: []
outputs:
  - id: ${id}_out
    path: \${artifact_dir}/$out_rel
    type: json
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
    printf '%s' '$json' > "\$art_dir/$out_rel"
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
    ( cd "$VERDICT_OVERLAY_REPO" && bash "$RUNNER" --issue 83 --template "$1" ) \
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
_make_verdict_plugin intake agent intake.json '{"verdict":"pass"}' intake
_make_verdict_plugin build  agent build-summary.json '{"verdict":"pass","scope_violation":false}' builder
_make_verdict_plugin test   tool  test-results.json  '{"verdict":"pass"}' tester
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
_make_verdict_plugin test tool test-results.json '{"verdict":"fail"}' tester
set +e; _run_pipeline_template verdict-indicator-test; rc=$?; set -e
err="$(cat "$TEST_TEMP_DIR/runner.err")"
if grep -E "✗.*Stage.*test.*complete" <<<"$err" >/dev/null; then
    assert_pass "test verdict=fail -> ✗ on test line"
else
    assert_fail "test verdict=fail -> ✗ on test line" "$(grep -i 'test.*complete' <<<"$err" || echo 'no line')"
fi

# ─── Scenario 3: build scope_violation=true → ✗ on build line ────────────────
# #1095 (PC2): minimal single-stage fixture roster — the assertion only inspects
# the `build` stage glyph.
# #1280 (ADR-047 §3): build PUSHES its verdict — a scope_violation rides
# .verdict:"scope_violation" (build-summary schema v4), not a bare .scope_violation
# flag the reader derives by name.
print_test_section "build scope_violation=true produces ✗"
rm -rf "$PLUGINS_ROOT"
_install_verdict_fixture verdict-indicator-build
_make_verdict_plugin build agent build-summary.json '{"verdict":"scope_violation","scope_violation":true}' builder
set +e; _run_pipeline_template verdict-indicator-build; rc=$?; set -e
err="$(cat "$TEST_TEMP_DIR/runner.err")"
if grep -E "✗.*Stage.*build.*complete" <<<"$err" >/dev/null; then
    assert_pass "build scope_violation=true -> ✗ on build line"
else
    assert_fail "build scope_violation=true -> ✗ on build line" "$(grep -i 'build.*complete' <<<"$err" || echo 'no line')"
fi

# ─── Scenario 4: review request_changes → ⚠ on review line ───────────────────
# #1095 (PC2): minimal single-stage fixture roster — the assertion only inspects
# the `review` stage glyph.
print_test_section "review request_changes produces ⚠"
rm -rf "$PLUGINS_ROOT"
_install_verdict_fixture verdict-indicator-review
_make_verdict_plugin review agent review.json '{"verdict":"request_changes"}' reviewer
set +e; _run_pipeline_template verdict-indicator-review; rc=$?; set -e
err="$(cat "$TEST_TEMP_DIR/runner.err")"
if grep -E "⚠.*Stage.*review.*complete" <<<"$err" >/dev/null; then
    assert_pass "review request_changes -> ⚠ on review line"
else
    assert_fail "review request_changes -> ⚠ on review line" "$(grep -i 'review.*complete' <<<"$err" || echo 'no line')"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
