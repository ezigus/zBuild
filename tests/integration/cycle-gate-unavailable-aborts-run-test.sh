#!/usr/bin/env bash
# Integration: ADR-063 §4 (review on PR #2262) — a gate member that reports
# `unavailable` ENDS the run, even when its verdict reads as a pass.
# The issue-acceptance stub (a convergence gate in build_test_cycle) writes a v2
# result with verdict pass, disposition unavailable, and returns 0 — the shape a
# failed model call takes when part of a reply still parses. Every other member
# passes, so if the engine read the verdict and ignored the disposition the
# cycle would go on to gate-aggregator and converge. Instead the engine must
# halt on halt_unavailable (ADR-054 §6, #2111): gate-aggregator never runs, the
# cycle does not converge, the run ends pipeline.end status=aborted with
# pipeline.aborted reason=llm_unavailable, and the runner exits 9.
# This is why `unavailable` is not one of disposition_unfinished's words: it is
# not retried, so a cycle never reaches convergence on it.
# Real runner (core/pipeline/runner.sh --template simple) over stub plugins
# (tests/lib/simple-run-stubs.sh). #2582: the stage's reason is a router reason
# and no router mark is set — the router_* rule alone makes it llm_unavailable.
# The other ways a run stops: tests/integration/stage-stop-names-cause-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "ADR-063 §4: a gate that reports unavailable ends the run — it does not converge"
setup_test_env "cycle-gate-unavailable-aborts"

# #1921 follow-up: the runner resolves repo_root from CWD, so a --goal run
# started from the working checkout snapshots zbuild/state/goal-<hash> into it.
# Measured in an isolated clone: a full suite went from 0 state refs to 2, both
# goal refs, and this file produced one of them. The issue-keyed sweep missed
# these because it looked for issue identity.
_ZB_REPO="$(zb_test_repo cycle-gate-unavailable)"
_ZB_GOAL="$(zb_test_goal gate-unavailable-abort)"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_CYCLES_ENABLED=1
export ZBUILD_CONTRACT_VALIDATOR=warn
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

# shellcheck source=../lib/simple-run-stubs.sh
source "$REPO_ROOT/tests/lib/simple-run-stubs.sh"
simple_stubs_roster

# issue-acceptance: the model call failed (disposition unavailable), yet the
# result carries a passing verdict and the stage returns 0.
_make_unavailable_issue_acceptance_plugin() {
    local dir="$PLUGINS_ROOT/agent/issue-acceptance"
    mkdir -p "$dir"
    cat > "$dir/manifest.yaml" <<'EOF'
id: issue-acceptance
name: Test issue-acceptance (unavailable)
kind: agent
version: 0.0.1
hooks:
  run: issue_acceptance_run
requires:
  core:
    - redaction
provides:
  role: issue_acceptance
  result_contract: 3
outputs:
  - id: issue_acceptance_result
    path: ${artifact_dir}/issue-acceptance-result.json
    type: json
    required: true
    primary: true
EOF
    cat > "$dir/plugin.sh" <<'PLUG'
issue_acceptance_run() {
    local state_dir; state_dir="$(dirname "$2")"
    mkdir -p "$state_dir/artifacts"
    source "$STAGE_RESULT_LIB"
    # #2582 review: no router mark here — the router reason alone
    # (router_rc_nonzero) says a model call failed.
    stage_result_write "$state_dir/artifacts/issue-acceptance-result.json" unavailable "router_rc_nonzero"
    printf 'issue-acceptance ran\n' >> "${ZBUILD_TEST_DISPATCH_LOG:?}"
    return 0
}
PLUG
}
_make_unavailable_issue_acceptance_plugin
# ─────────────────────────────────────────────────────────────────────────────
# The run ends on the unavailable gate: aborted, resumable, not converged.
# ─────────────────────────────────────────────────────────────────────────────

export ZBUILD_TEST_DISPATCH_LOG="$TEST_TEMP_DIR/dispatch.log"; : > "$ZBUILD_TEST_DISPATCH_LOG"

print_test_section "[ADR-063 §4] a gate reporting unavailable with a passing verdict ends the run; the cycle does not converge"
_run_pipeline
assert_eq "[ADR-063 §4] the unavailable gate ran exactly once — it is not retried" \
    "1" "$(grep -c 'issue-acceptance ran' "$ZBUILD_TEST_DISPATCH_LOG" || true)"
assert_eq "[ADR-063 §4] gate-aggregator never ran — the cycle did not reach its convergence check" \
    "0" "$(grep -c 'gate-aggregator ran' "$ZBUILD_TEST_DISPATCH_LOG" || true)"
assert_eq "[ADR-063 §4] the engine announced the halt on unavailable for issue-acceptance" "1" \
    "$(jq -c 'select(.type=="cycle.member.disposition.halt" and .data.member=="issue-acceptance" and .data.disposition=="unavailable")' "$EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
end_status="$(jq -r 'select(.type=="pipeline.end") | .data.status' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "[ADR-063 §4] pipeline.end status=aborted (not success: the cycle did not converge)" "aborted" "$end_status"
abort_reason="$(jq -r 'select(.type=="pipeline.aborted") | .data.reason' "$EVENTS_JSONL" 2>/dev/null | head -1)"
assert_eq "[ADR-063 §4] pipeline.aborted reason=llm_unavailable" "llm_unavailable" "$abort_reason"
assert_eq "[ADR-063 §4] pipeline-state.json status=aborted (resumable, ADR-050)" "aborted" \
    "$(jq -r '.status // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null || true)"
# #1850 (ADR-054 §4): was 9 (the llm-abort rc). Every halt exits 1; the
# llm_unavailable word above (event + state) is what says why.
assert_eq "[ADR-063 §4] the runner exits 1 — not 0, not the old llm-abort rc 9" "1" "${_RUNNER_RC:-}"

assert_contains "[ADR-063 §4] the stop line says the model could not be reached (a model call failed)" \
    "$(cat "$TEST_TEMP_DIR/runner.stderr")" "the model could not be reached"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
