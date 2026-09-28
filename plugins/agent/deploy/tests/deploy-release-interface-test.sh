#!/usr/bin/env bash
# Tests: plugins/agent/deploy — the run paths through the REAL deploy-release
# plugin (issue #1846, review #2219). Split from deploy-test.sh (500-line rule).
#
# Added by hand after PR #2219's review (lenses + claude-review). The run-path
# tests below exercise the REAL deploy-release plugin; only the outside world —
# `git` and `gh` — is faked, on PATH. The mock these tests used before accepted
# any arguments, so a call that dropped deploy-release's state_file argument
# passed every test while every real deploy failed.
# R1 [change] a passing gate cuts and pushes the release tag through the real
#             deploy-release, and the result carries the tag and the PR
# R2 [change] a failed `git tag` keeps deploy-release's own disposition (broken)
# R3 [change] a failed `git push` keeps deploy-release's own disposition
#             (unavailable) and rolls the local tag back
# R4 [change] deploy-release writes into ZBUILD_ARTIFACT_DIR, not beside the state file
# R5 [change] a signal mid-release writes disposition=interrupted and returns 1
# R6 [change] no ZBUILD_ARTIFACT_DIR: rc=1 and a deploy.result.unwritable event
#             (there is nowhere to write an envelope; the event is the record)
# R7 [change] an input path outside the run's state directory is refused, not read
# R8 [change] a preset _ZBUILD_DEPLOY_RELEASE_LOADED cannot swap in another
#             deploy_release_run — the real plugin is always loaded
# R9 [change] no `jq … | atomic_write` pipe in plugin.sh (SIGPIPE rule)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: deploy agent — through the real deploy-release (#1846, review #2219)"

setup_test_env "plugin-deploy-interface"

# #1921 follow-up: reserved test identity — the QUOTED assignment form.
_ZB_ID="$(zb_test_issue)"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="deploy-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="$_ZB_ID"

PLUGIN_FILE="$REPO_ROOT/plugins/agent/deploy/plugin.sh"
_MANIFEST="$REPO_ROOT/plugins/agent/deploy/manifest.yaml"

# Source the deploy agent plugin
# shellcheck source=../../../../plugins/agent/deploy/plugin.sh
source "$PLUGIN_FILE"

# Source manifest-router-budget.sh for manifest_router_knob (SPEC-15)
# shellcheck source=../../../../core/plugin-registry/manifest-router-budget.sh
source "$REPO_ROOT/core/plugin-registry/manifest-router-budget.sh"

# shellcheck source=deploy-test-lib.sh
source "$SCRIPT_DIR/deploy-test-lib.sh"

# ---------------------------------------------------------------------------
# SPEC-20 [#1846/SPEC-20] (rewritten after review #2219): when deploy-release
#        fails, deploy-release's OWN disposition reaches the engine — deploy
#        never overwrites it. The old assertion (always `unavailable`) described
#        the overwrite itself.  R2 / R3.
# ---------------------------------------------------------------------------
_r2="$TEST_TEMP_DIR/r2-tagfail"
_rc_r2="$(_deploy_case "$_r2" pass FAKE_GIT_TAG_RC=1)"
assert_eq "[R2] a failed git tag → rc=1" "1" "$_rc_r2"
assert_eq "[R2] ...deploy-release's disposition (broken) is what the engine reads" "broken" "$(_rj "$_r2" .disposition)"
assert_eq "[R2] ...with its reason" "git tag failed" "$(_rj "$_r2" .reason)"
_v2_keys_ok "[#1846/SPEC-10] tag-fail exit path:" "$_r2/artifacts/deploy-result.json"

_r3="$TEST_TEMP_DIR/r3-pushfail"
_rc_r3="$(_deploy_case "$_r3" pass FAKE_GIT_PUSH_RC=1)"
assert_eq "[R3] a failed git push → rc=1" "1" "$_rc_r3"
assert_eq "[#1846/SPEC-20] a failed push keeps deploy-release's disposition (unavailable)" "unavailable" "$(_rj "$_r3" .disposition)"
assert_eq "[R3] ...with its reason" "git push tag failed" "$(_rj "$_r3" .reason)"
assert_contains "[R3] ...and the local tag is rolled back" "$(cat "$_r3/git.log" 2>/dev/null)" "tag -d zbuild-run-"
_v2_keys_ok "[#1846/SPEC-10] push-fail exit path:" "$_r3/artifacts/deploy-result.json"

# ---------------------------------------------------------------------------
# SPEC-2 (delegation) / SPEC-10 (success path) — R1: through the REAL
#        deploy-release; only git is faked.
# ---------------------------------------------------------------------------
_run_success="$TEST_TEMP_DIR/run_success"
_rc_r1="$(_deploy_case "$_run_success" pass ZBUILD_RUN_ID=r1-run)"
assert_eq "[R1] a passing gate deploys → rc=0" "0" "$_rc_r1"
_gl="$(cat "$_run_success/git.log" 2>/dev/null)"
assert_contains "[#1846/SPEC-2] the release tag is created" "$_gl" "tag zbuild-run-r1-run"
assert_contains "[R1] ...and pushed to origin" "$_gl" "push origin zbuild-run-r1-run"
_v2_keys_ok "[#1846/SPEC-10] successful-deploy exit path:" "$_run_success/artifacts/deploy-result.json"
_vs="$(_rj "$_run_success" .verdict)"
assert_eq "[#1846/SPEC-14] successful deploy writes verdict=deployed (v2)" "deployed" "$_vs"
assert_eq "[R1] the result names the tag deploy-release cut" "zbuild-run-r1-run" "$(_rj "$_run_success" .data.tag)"
assert_eq "[R1] ...and the PR" "https://github.com/test/repo/pull/42" "$(_rj "$_run_success" .data.pr_url)"

# R4: deploy-release's own artifacts land in ZBUILD_ARTIFACT_DIR even when the
# state file lives somewhere else.
_r4="$TEST_TEMP_DIR/r4-elsewhere"; mkdir -p "$TEST_TEMP_DIR/r4-state"
( _make_state "$_r4"
  printf 'https://github.com/test/repo/pull/42\n' > "$_r4/artifacts/pr-url.txt"
  printf '{"verdict":"pass"}\n' > "$_r4/artifacts/gate-aggregator-result.json"
  export PATH="$FAKE_BIN:$PATH" FAKE_GIT_LOG="$_r4/git.log" ZBUILD_DRY_RUN=0
  : > "$FAKE_GIT_LOG"
  printf '{}' > "$TEST_TEMP_DIR/r4-state/state.json"
  deploy_agent_run "deploy" "$TEST_TEMP_DIR/r4-state/state.json" ) >/dev/null 2>&1 || true
assert_file_exists "[R4] deploy-release's summary is in ZBUILD_ARTIFACT_DIR" "$_r4/artifacts/deploy-release-summary.md"
if [[ -e "$TEST_TEMP_DIR/r4-state/artifacts" ]]; then
    assert_fail "[R4] nothing is written beside the state file" "$TEST_TEMP_DIR/r4-state/artifacts exists"
else
    assert_pass "[R4] nothing is written beside the state file"
fi

# R5: a signal mid-release (the engine stopping the stage while git pushes).
_r5="$TEST_TEMP_DIR/r5-signal"
_rc_r5="$(_deploy_case "$_r5" pass FAKE_GIT_PUSH_SIGNAL=1)"
assert_eq "[R5] interrupted → rc=1" "1" "$_rc_r5"
assert_eq "[R5] ...disposition=interrupted" "interrupted" "$(_rj "$_r5" .disposition)"
_v2_keys_ok "[#1846/SPEC-10] interrupted exit path:" "$_r5/artifacts/deploy-result.json"

# R6: no ZBUILD_ARTIFACT_DIR — nowhere to write; the event is the record.
_r6ev="$TEST_TEMP_DIR/r6-events.jsonl"; : > "$_r6ev"
_rc_r6=0
( unset ZBUILD_ARTIFACT_DIR
  emit_event() { printf '%s\n' "$*" >> "$_r6ev"; }
  deploy_agent_run "deploy" "$TEST_TEMP_DIR/none.json" ) >/dev/null 2>&1 || _rc_r6=$?
assert_eq "[R6] no ZBUILD_ARTIFACT_DIR → rc=1" "1" "$_rc_r6"
assert_contains "[R6] ...and a deploy.result.unwritable event says why" "$(cat "$_r6ev")" "deploy.result.unwritable"

# R7: an input path outside the run's state directory is refused.
_r7="$TEST_TEMP_DIR/r7-outside"; _r7x="$TEST_TEMP_DIR/r7-elsewhere"; mkdir -p "$_r7x"
printf 'https://github.com/evil/repo/pull/1\n' > "$_r7x/pr-url.txt"
_rc_r7=0
( _make_state "$_r7"
  jq -n --arg pr "$_r7x/pr-url.txt" --arg gr "$_r7/artifacts/gate-aggregator-result.json" \
      '{"inputs":{"pr_url":$pr,"gate_aggregator_result":$gr}}' > "$_r7/stage-inputs/deploy.json"
  ZBUILD_DRY_RUN=1 deploy_agent_run "deploy" "$_r7/state.json" ) >/dev/null 2>&1 || _rc_r7=$?
assert_eq "[R7] an input outside the state directory → rc=1" "1" "$_rc_r7"
assert_eq "[R7] ...disposition=broken (an engine index pointing outside the run is a defect)" "broken" "$(_rj "$_r7" .disposition)"
if grep -qF "evil/repo" "$_r7/artifacts/deploy-result.json" 2>/dev/null; then
    assert_fail "[R7] ...and the outside file is never read" "its content reached the result"
else
    assert_pass "[R7] ...and the outside file is never read"
fi

# R7b (review #2219 round 2): an input in a directory that does not exist,
# outside the run, is refused — not waved through as "missing".
_r7b="$TEST_TEMP_DIR/r7b-nodir"; _r7bev="$TEST_TEMP_DIR/r7b-events.jsonl"; : > "$_r7bev"
_rc_r7b=0
( _make_state "$_r7b"
  emit_event() { printf '%s\n' "$*" >> "$_r7bev"; }
  jq -n --arg pr "$TEST_TEMP_DIR/no-such-dir/pr-url.txt" --arg gr "$_r7b/artifacts/gate-aggregator-result.json" \
      '{"inputs":{"pr_url":$pr,"gate_aggregator_result":$gr}}' > "$_r7b/stage-inputs/deploy.json"
  ZBUILD_DRY_RUN=1 deploy_agent_run "deploy" "$_r7b/state.json" ) >/dev/null 2>&1 || _rc_r7b=$?
assert_eq "[R7b] an unresolvable input directory outside the run → rc=1" "1" "$_rc_r7b"
assert_contains "[R7b] ...refused, not reported missing" "$(cat "$_r7bev")" "deploy.input.refused"

# R8: a preset guard variable cannot swap in another deploy_release_run.
_r8="$TEST_TEMP_DIR/r8-guard"
_rc_r8="$(_deploy_case "$_r8" pass _ZBUILD_DEPLOY_RELEASE_LOADED=1 ZBUILD_RUN_ID=r8-run)"
assert_contains "[R8] the real deploy-release still runs (git was called)" "$(cat "$_r8/git.log" 2>/dev/null)" "tag zbuild-run-r8-run"

# R9: no jq-into-atomic_write pipe.
_r9="$(grep -nE '\|[[:space:]]*atomic_write' "$PLUGIN_FILE" 2>/dev/null || true)"
_r9="$(grep -vE '^[0-9]+:[[:space:]]*#' <<< "$_r9" || true)"
if [[ -n "$_r9" ]]; then
    assert_fail "[R9] plugin.sh has no '| atomic_write' pipe" "$_r9"
else
    assert_pass "[R9] plugin.sh has no '| atomic_write' pipe"
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
