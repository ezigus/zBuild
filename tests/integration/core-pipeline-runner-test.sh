#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — pipeline orchestrator behaviors
# ADR-001 (plugin contract), ADR-006 (resume contract)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/pipeline/runner — orchestrator behaviors (ADR-001, ADR-006)"
setup_test_env "pipeline-runner"
# Wave 12-E (#664): default is enforce. Stub plugins below lack honest
# inputs/outputs blocks; opt out — this suite tests runner mechanics.
export ZBUILD_CONTRACT_VALIDATOR=warn

# #1157: this suite runs on ALL platforms (no skip). It was previously gated off
# macOS (#996/#1059) on an unproven hypothesis that the shared macOS runner can't
# deliver the kill-mid-run signal. The real prior failures were a cascade of test
# bugs — all fixed here — not signal nondeterminism: a grep -c "0\n0" parse, a
# blocking `wait` on the orphaned-sleep-deferred exit, a post-kill poll shorter
# than the trap deferral, the run-tests.sh empty-skip-log bug, and the SQLite
# mirror making the spawn-heavy file exceed the macOS 300s budget. With those
# fixed the kill-mid-run abort checks are reliable, so they are FATAL (they carry
# the runner fail-closed mutation coverage — see runner-fail-closed-mutations.md).
# _kill_assert centralizes the deterministic pattern: anchor on plugin.run.start,
# poll PAST the deferred trap (bash runs TERM only after the foreground sleep
# returns), never block on the deferred exit.
_kill_assert() {  # <ok:0|1> <name> [detail]
    if [[ "$1" == "1" ]]; then
        assert_pass "$2"
    else
        assert_fail "$2" "${3:-}"
    fi
}

# Use shared factory from test-helpers.sh (Wave 4)
_make_plugin() { mock_plugin_factory "$@" >/dev/null; }   # #619: suppress factory's path echo

# Shared env: point all subsystems at the test temp dir.
PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
STATE_DIR="$TEST_TEMP_DIR/state"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_STATE_DIR="$STATE_DIR"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$EVENTS_JSONL"
# #1157: disable the SQLite mirror suite-wide. This file asserts only on
# events.jsonl (the source of truth) — nothing reads events.db — so the mirror
# is pure per-spawn + per-emit overhead (a sqlite3 fork per event). /dev/null is
# the graceful "no mirror" sentinel (#1153), and skipping it keeps this
# spawn-heavy suite well under the 300s per-file budget on the slow shared macOS
# runner. (Mirror behavior itself is covered by event-bus-concurrency-test.sh.)
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# #511 F2: these tests pre-date the standard.yaml cycle wiring and assert
# a strictly LINEAR per-stage banner/event sequence (e.g. "exactly 5 started
# suffixes"). Force-disable cycle dispatch so the runner walks the legacy
# linear path — the cycle path is covered by its own dedicated tests.
export ZBUILD_CYCLES_ENABLED=0
mkdir -p "$STATE_DIR" "$TEST_TEMP_DIR/events"

_make_plugin "intake"          "agent" 0
_make_plugin "plan"            "agent" 0
# #842: standard template now wraps design+impact in design_impact_cycle (plan is a leaf).
_make_plugin "design"          "agent" 0
_make_plugin "impact"          "agent" 0
_make_plugin "build"           "agent" 0
# #485: standard template now includes the test stage between build and review.
_make_plugin "test"            "tool"  0
# #568: standard template inserts test_assessment between test and review.
_make_plugin "test_assessment" "agent" 0
# #922: acceptance-gate leaf stage after test_assessment (ADR-036).
_make_plugin "acceptance-gate" "agent" 0
# #755: compound_quality split into 4 CQ leaf stages before review.
_make_plugin "cq-preflight"    "agent" 0
_make_plugin "cq-audit-plan"   "agent" 0
_make_plugin "cq-cycle"        "agent" 0
_make_plugin "cq-backtrack"    "agent" 0
_make_plugin "review"          "agent" 0
# #756: standard template now includes pr leaf stage after build_review_cycle.
_make_plugin "pr"              "agent" 0

# ─── Test 1: no args → exits 2 ──────────────────────────────────────────────
set +e; bash "$RUNNER" 2>/dev/null; rc=$?; set -e
assert_eq "no args exits 2" "2" "$rc"

# ─── Test 2: --help → exits 0 ───────────────────────────────────────────────
set +e; bash "$RUNNER" --help >/dev/null 2>&1; rc=$?; set -e
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: --issue with no value → exits 2 (controlled, not unbound var) ──
set +e; bash "$RUNNER" --issue 2>/dev/null; rc=$?; set -e
assert_eq "--issue with no value exits 2" "2" "$rc"

set +e; bash "$RUNNER" --goal 2>/dev/null; rc=$?; set -e
assert_eq "--goal with no value exits 2" "2" "$rc"

# ─── Test 4: dry-run prints 4-stage plan without executing ──────────────────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
out="$(bash "$RUNNER" --issue 83 --dry-run 2>&1)"
assert_contains "dry-run shows intake stage" "$out" "intake"
assert_contains "dry-run shows build stage"  "$out" "build"
assert_contains "dry-run shows review stage" "$out" "review"
assert_file_not_exists "dry-run leaves state file untouched" "$STATE_DIR/pipeline-state.json"

# ─── Test 5: happy path → exits 0, emits pipeline.start + pipeline.end ──────
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e   # #619: suppress info banner
assert_eq "happy path exits 0" "0" "$rc"
assert_file_exists "events.jsonl created" "$EVENTS_JSONL"

start_count=$(grep -c '"pipeline.start"' "$EVENTS_JSONL" || true)
assert_eq "pipeline.start emitted once" "1" "$start_count"

end_count=$(grep -c '"pipeline.end"' "$EVENTS_JSONL" || true)
assert_eq "pipeline.end emitted once" "1" "$end_count"

success_in_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"success"' || true)
assert_eq "pipeline.end carries status=success" "1" "$success_in_end"

# ─── Test 6: stage lifecycle events emitted ─────────────────────────────────
for stage_event in stage.start stage.complete; do
    count=$(grep -c "\"$stage_event\"" "$EVENTS_JSONL" || true)
    # #755: 12 stages + #922: acceptance-gate + #756: pr = 14.
    assert_eq "[SPEC-1] $stage_event emitted for each MVP stage (14x)" "14" "$count"
done

# ─── Test 7: ADR-006 stage status enum — "complete" not "success" ───────────
STATE_FILE="$STATE_DIR/pipeline-state.json"
assert_file_exists "state file created" "$STATE_FILE"

intake_status="$(jq -r '.stage_statuses.intake // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "intake stage_status=complete (ADR-006 enum)" "complete" "$intake_status"

plan_status="$(jq -r '.stage_statuses.plan // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "plan stage_status=complete (ADR-006 enum)" "complete" "$plan_status"

build_status="$(jq -r '.stage_statuses.build // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "build stage_status=complete (ADR-006 enum)" "complete" "$build_status"

review_status="$(jq -r '.stage_statuses.review // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "review stage_status=complete (ADR-006 enum)" "complete" "$review_status"

# ─── Test 8: mid-stage failure → exits 1, pipeline.end + stage.fail ──────────
_make_plugin "build" "agent" 1
rm -f "$EVENTS_JSONL" "$STATE_FILE"

set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e   # #619: suppress info banner
assert_eq "mid-stage failure exits 1" "1" "$rc"
assert_file_exists "events.jsonl present on failure" "$EVENTS_JSONL"

failed_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"failed"' || true)
assert_eq "pipeline.end status=failed emitted" "1" "$failed_end"

stage_in_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"build"' || true)
assert_eq "pipeline.end names the failing stage" "1" "$stage_in_end"

stage_fail_event=$(grep -c '"stage.fail"' "$EVENTS_JSONL" || true)
assert_eq "stage.fail event emitted" "1" "$stage_fail_event"

build_fail_status="$(jq -r '.stage_statuses.build // empty' "$STATE_FILE" 2>/dev/null)"
assert_eq "build stage_status=failed in state" "failed" "$build_fail_status"

# ─── Test 9: missing plugin for required stage → fails pipeline ───────────────
rm -rf "$PLUGINS_ROOT/agent/intake"
rm -f "$EVENTS_JSONL" "$STATE_FILE"

set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e   # #619: suppress info banner
assert_eq "missing required plugin exits 1" "1" "$rc"

if [[ -f "$EVENTS_JSONL" ]]; then
    fail_from_no_plugin=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"failed"' || true)
    assert_eq "missing plugin causes pipeline.end status=failed" "1" "$fail_from_no_plugin"
else
    assert_fail "events.jsonl not created for missing-plugin failure"
fi

# ─── Test 10: EXIT trap emits pipeline.abort (not pipeline.end) ──────────────
_make_plugin "intake" "agent" 0
rm -f "$EVENTS_JSONL" "$STATE_FILE"

# Use a long-running plugin to ensure we can kill mid-run.
mkdir -p "$PLUGINS_ROOT/agent/intake"
cat > "$PLUGINS_ROOT/agent/intake/manifest.yaml" <<EOF
id: intake
name: Slow Intake
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
EOF
cat > "$PLUGINS_ROOT/agent/intake/plugin.sh" <<'EOF'
intake_run() { sleep 5; return 0; }
EOF

bash "$RUNNER" --issue 83 >/dev/null 2>&1 &
runner_pid=$!
# #1149: wait for the SLOW intake stage's plugin.run.start, not merely
# pipeline.start. plugin.run.start is emitted strictly AFTER pipeline.start
# (runner.sh L1185) which is itself AFTER the abort EXIT/TERM traps install
# (L1152-1159) — so by the time it appears the trap is armed AND intake is
# blocked in `sleep 10`, giving a live, killable child and a wide kill window.
# This removes the "kill landed after pipeline.start but before the plugin was
# running / the trap was armed" race the prior pipeline.start anchor left open
# (#494/#908). Shared wait_for_event poll replaces the inline loop. #619.
# #1157: poll-not-block + FATAL via _kill_assert (see top). bash defers the TERM
# trap behind the foreground `sleep` stub, so poll for the deferred pipeline.abort
# event (~25s) and never block on the sleep-deferred exit; then force-reap.
t10_abort_ok=0
if wait_for_event "$EVENTS_JSONL" '"plugin.run.start"' 150 0.1; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait_for_event "$EVENTS_JSONL" '"pipeline.abort"' 120 0.1 || true
    grep -q '"pipeline.abort"' "$EVENTS_JSONL" 2>/dev/null && t10_abort_ok=1
fi
kill -KILL "$runner_pid" 2>/dev/null || true
wait "$runner_pid" 2>/dev/null || true
_kill_assert "$t10_abort_ok" "kill mid-run emits pipeline.abort"

# ─── Test 11: --template flag parsed; missing template falls back gracefully ──
_make_plugin "intake"  "agent" 0
_make_plugin "plan"    "agent" 0
_make_plugin "build"   "agent" 0
_make_plugin "test"    "tool"  0
_make_plugin "review"  "agent" 0
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json" "$STATE_DIR/platforms.json"

out="$(bash "$RUNNER" --issue 83 --dry-run --template standard 2>&1)"
assert_contains "--template standard dry-run shows intake"  "$out" "intake"
assert_contains "--template standard dry-run shows plan"    "$out" "plan"
assert_contains "--template standard dry-run shows build"   "$out" "build"
assert_contains "--template standard dry-run shows review"  "$out" "review"

out="$(bash "$RUNNER" --issue 83 --dry-run --template nonexistent 2>&1)"
assert_contains "missing template falls back to built-in stages"  "$out" "intake"

# ─── Test 12: role-based dispatch — resolver path executes correctly ───────────
# Helpers for role-based plugins (provides.role field)
_make_role_plugin() {
    local id="$1" role="$2" exit_code="${3:-0}"
    local dir="$TEST_TEMP_DIR/plugins/agent/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Role Plugin $id
kind: agent
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
provides:
  role: $role
EOF
    printf '%s() { return %d; }\n' "$fn" "$exit_code" > "$dir/plugin.sh"
}

rm -rf "$PLUGINS_ROOT/agent/" "$PLUGINS_ROOT/tool/"
_make_role_plugin "intake-agent"          "intake"          0
_make_role_plugin "plan-agent"            "planner"         0
# #746: impact_analyzer role added for the impact stage
_make_role_plugin "impact-agent"          "impact_analyzer" 0
# #754: standard template adds `design` between impact and build.
_make_role_plugin "design-agent"          "designer"        0
_make_role_plugin "build-agent"           "builder"         0
# #485: tester role added for the test stage
_make_role_plugin "test-agent"            "tester"          0
# #568: test_assessment role added for the new assessment stage
_make_role_plugin "test-assessment-agent" "test_assessment" 0
# #922: acceptance-gate role for the new gate stage
_make_role_plugin "acceptance-gate-agent" "acceptance_gate"  0
# #755: 4 CQ leaf stages replacing compound_quality
_make_role_plugin "cq-preflight-agent"   "cq_preflight"    0
_make_role_plugin "cq-audit-plan-agent"  "cq_audit_plan"   0
_make_role_plugin "cq-cycle-agent"       "cq_cycle"        0
_make_role_plugin "cq-backtrack-agent"   "cq_backtrack"    0
_make_role_plugin "review-agent"          "reviewer"        0
# #756: pr leaf stage after build_review_cycle uses pr_delivery role.
_make_role_plugin "pr-agent"             "pr_delivery"     0
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json" "$STATE_DIR/platforms.json"

set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e   # #619: suppress info banner
assert_eq "role-based dispatch exits 0" "0" "$rc"

role_complete=$(grep -c '"stage.complete"' "$EVENTS_JSONL" || true)
# #755: 12 stages + #922: acceptance-gate + #756: pr = 14.
assert_eq "role-based dispatch: 14 stage.complete events" "14" "$role_complete"

role_build_status="$(jq -r '.stage_statuses.build // empty' "$STATE_DIR/pipeline-state.json" 2>/dev/null)"
assert_eq "role-based: build stage_status=complete" "complete" "$role_build_status"

# ─── Test 13: fanout with 2 detected platforms — plugin invoked once per platform
# Pre-populate platforms.json cache so detect_platforms returns 2 platforms.
current_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
mkdir -p "$STATE_DIR"
printf '{"schema_version":1,"repo_head_sha":"%s","detected":["node","ios"],"overrides":[],"updated_at":"2026-01-01T00:00:00Z"}\n' \
    "$current_sha" > "$STATE_DIR/platforms.json"
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"

set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e   # #619: suppress info banner
assert_eq "fanout 2 platforms exits 0" "0" "$rc"

# #756: 14 stages × 2 platforms = 28 plugin.run.start events via fanout
plugin_run_count=$(grep -c '"plugin.run.start"' "$EVENTS_JSONL" || true)
assert_eq "fanout 2 platforms: 28 plugin.run.start events (14 stages × 2)" "28" "$plugin_run_count"

# ─── Test 14: partial fanout failure — stage.fail + pipeline.end status=failed ─
# Platform-specific success (node) + generic failure (ios fallback) → partial.
# Requires _make_platform_role_plugin helper.
_make_platform_role_plugin() {
    local id="$1" role="$2" platform="$3" exit_code="${4:-0}"
    local dir="$TEST_TEMP_DIR/plugins/agent/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Platform Role Plugin $id
kind: agent
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
platform: $platform
provides:
  role: $role
EOF
    printf '%s() { return %d; }\n' "$fn" "$exit_code" > "$dir/plugin.sh"
}

# build-agent (generic, exit 1) = ios fallback fails
_make_role_plugin "build-agent" "builder" 1
# build-agent-node (platform=node, exit 0) = node-specific succeeds
_make_platform_role_plugin "build-agent-node" "builder" "node" 0
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
# Reuse platforms.json from test 13: ["node", "ios"]
# node: resolve finds build-agent-node (platform=node) → exit 0
# ios:  resolve finds build-agent (generic)             → exit 1
# → success_count=1, fail_count=1 → partial (rc=2)

set +e; bash "$RUNNER" --issue 83 >/dev/null 2>&1; rc=$?; set -e   # #619: suppress info banner
assert_eq "partial fanout failure exits 1" "1" "$rc"

partial_stage_fail=$(grep '"stage.fail"' "$EVENTS_JSONL" | grep -c '"partial"' || true)
assert_eq "partial fanout emits stage.fail with reason=partial" "1" "$partial_stage_fail"

partial_pipeline_end=$(grep '"pipeline.end"' "$EVENTS_JSONL" | grep -c '"failed"' || true)
assert_eq "partial fanout emits pipeline.end status=failed" "1" "$partial_pipeline_end"

# ─── Test A2: abort trap emits pipeline.abort (fail-closed path) ─────────────
# Verifies that the converted fail-closed abort trap emits pipeline.abort and
# marks the pipeline as interrupted in state. Uses a completely isolated temp
# dir to avoid interference from role-based plugins created by earlier tests.
A2_DIR="$TEST_TEMP_DIR/a2"
A2_PLUGINS="$A2_DIR/plugins"
A2_STATE_DIR="$A2_DIR/state"
A2_EVENTS_DIR="$A2_DIR/events"
A2_EVENTS_JSONL="$A2_EVENTS_DIR/events.jsonl"
mkdir -p "$A2_PLUGINS/agent/intake" "$A2_PLUGINS/agent/build" \
         "$A2_PLUGINS/agent/review" "$A2_STATE_DIR" "$A2_EVENTS_DIR"

# Slow intake plugin (blocks pipeline for >1 second so kill fires mid-run)
cat > "$A2_PLUGINS/agent/intake/manifest.yaml" <<'EOF'
id: intake
name: Slow Intake A2
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
EOF
cat > "$A2_PLUGINS/agent/intake/plugin.sh" <<'EOF'
intake_run() { sleep 5; return 0; }
EOF

# Fast downstream plugins (never reached due to kill)
cat > "$A2_PLUGINS/agent/build/manifest.yaml" <<'EOF'
id: build
name: Fast Build
kind: agent
version: 0.0.1
hooks:
  run: build_run
requires:
  core:
    - redaction
EOF
cat > "$A2_PLUGINS/agent/build/plugin.sh" <<'EOF'
build_run() { return 0; }
EOF
cat > "$A2_PLUGINS/agent/review/manifest.yaml" <<'EOF'
id: review
name: Fast Review
kind: agent
version: 0.0.1
hooks:
  run: review_run
requires:
  core:
    - redaction
EOF
cat > "$A2_PLUGINS/agent/review/plugin.sh" <<'EOF'
review_run() { return 0; }
EOF

ZBUILD_PLUGINS_ROOT="$A2_PLUGINS" \
ZBUILD_STATE_DIR="$A2_STATE_DIR" \
ZBUILD_EVENTS_DIR="$A2_EVENTS_DIR" \
ZBUILD_EVENTS_JSONL="$A2_EVENTS_JSONL" \
ZBUILD_EVENTS_DB="/dev/null" \
bash "$RUNNER" --issue 83 >/dev/null 2>&1 &   # #619: suppress info banner
a2_pid=$!
# #1149: anchor the kill on the slow stage's plugin.run.start (not just
# pipeline.start). It is emitted after the abort trap installs AND after intake
# blocks in `sleep 15`, so the trap is armed and there is a live child to kill —
# removing the pre-trap / not-yet-running kill window. Shared wait_for_event
# poll replaces the inline loop. #619.
# #1157: poll-not-block + FATAL via _kill_assert (see top). Same as Test 10/I6 —
# the TERM trap is deferred behind the foreground `sleep`; poll the deferred
# event, never block on the sleep-deferred exit, then force-reap.
a2_abort_ok=0
a2_no_state_err=0
if wait_for_event "$A2_EVENTS_JSONL" '"plugin.run.start"' 150 0.1; then
    kill -TERM "$a2_pid" 2>/dev/null || true
    wait_for_event "$A2_EVENTS_JSONL" '"pipeline.abort"' 120 0.1 || true
    grep -q '"pipeline.abort"' "$A2_EVENTS_JSONL" 2>/dev/null && a2_abort_ok=1
    grep -q '"pipeline.state.error"' "$A2_EVENTS_JSONL" 2>/dev/null || a2_no_state_err=1
fi
kill -KILL "$a2_pid" 2>/dev/null || true
wait "$a2_pid" 2>/dev/null || true
_kill_assert "$a2_abort_ok" "A2 abort trap: pipeline.abort event emitted on kill"
_kill_assert "$a2_no_state_err" "A2 abort trap: no state.error when state file writable"

# ─── Test A2b: abort trap marks pipeline as interrupted in state ───────────────
a2_state_file="$A2_STATE_DIR/pipeline-state.json"
a2_interrupted_ok=0
if [[ -f "$a2_state_file" ]] && \
   [[ "$(jq -r '.status // empty' "$a2_state_file" 2>/dev/null || true)" == "interrupted" ]]; then
    a2_interrupted_ok=1
fi
_kill_assert "$a2_interrupted_ok" "A2 abort trap: pipeline status=interrupted in state"

# ─── Test A3: artifact contract — plugin declares provides.artifact_type ──────
# ARCHITECTURE.md §2: if a plugin declares provides.artifact_type but writes
# no artifact, the engine MUST emit plugin.contract.violated and create a
# synthetic blocking finding.
A3_DIR="$TEST_TEMP_DIR/a3"
A3_PLUGINS="$A3_DIR/plugins"
A3_STATE_DIR="$A3_DIR/state"
A3_EVENTS_DIR="$A3_DIR/events"
A3_EVENTS_JSONL="$A3_EVENTS_DIR/events.jsonl"
mkdir -p "$A3_PLUGINS/agent/noartifact" "$A3_PLUGINS/agent/build" \
         "$A3_PLUGINS/agent/review" "$A3_STATE_DIR" "$A3_EVENTS_DIR"

# Plugin that declares provides.artifact_type but writes NO artifact file
cat > "$A3_PLUGINS/agent/noartifact/manifest.yaml" <<'EOF'
id: intake
name: No-Artifact Intake
kind: agent
version: 0.0.1
hooks:
  run: noartifact_run
requires:
  core:
    - redaction
provides:
  artifact_type: findings.json
outputs:
  - name: findings
    path: artifacts/intake-findings.json
    type: findings.json
EOF
cat > "$A3_PLUGINS/agent/noartifact/plugin.sh" <<'EOF'
noartifact_run() {
    # Intentionally does NOT write artifacts/intake-findings.json
    return 0
}
EOF

cat > "$A3_PLUGINS/agent/build/manifest.yaml" <<'EOF'
id: build
name: Fast Build
kind: agent
version: 0.0.1
hooks:
  run: build_run
requires:
  core:
    - redaction
EOF
cat > "$A3_PLUGINS/agent/build/plugin.sh" <<'EOF'
build_run() { return 0; }
EOF
cat > "$A3_PLUGINS/agent/review/manifest.yaml" <<'EOF'
id: review
name: Fast Review
kind: agent
version: 0.0.1
hooks:
  run: review_run
requires:
  core:
    - redaction
EOF
cat > "$A3_PLUGINS/agent/review/plugin.sh" <<'EOF'
review_run() { return 0; }
EOF

# Behaviour under test is the plugin.contract.violated event count, not the
# runner's exit code (which is non-zero on violation). Use `|| true` instead
# of capturing an unused rc.
ZBUILD_PLUGINS_ROOT="$A3_PLUGINS" \
ZBUILD_STATE_DIR="$A3_STATE_DIR" \
ZBUILD_EVENTS_DIR="$A3_EVENTS_DIR" \
ZBUILD_EVENTS_JSONL="$A3_EVENTS_JSONL" \
ZBUILD_EVENTS_DB="/dev/null" \
bash "$RUNNER" --issue 83 >/dev/null 2>&1 || true   # #619: suppress info banner

if [[ -f "$A3_EVENTS_JSONL" ]]; then
    a3_violated=$(grep -c '"plugin.contract.violated"' "$A3_EVENTS_JSONL" || true)
    assert_eq "A3 artifact contract: plugin.contract.violated event emitted" "1" "$a3_violated"
else
    assert_fail "A3 artifact contract: events.jsonl not created"
fi

# The engine creates the synthetic file under artifacts/ so the output aggregator picks it up
a3_findings="$A3_STATE_DIR/artifacts/intake-intake-contract-violated-findings.json"
if [[ -f "$a3_findings" ]]; then
    a3_blocking=$(jq '[.findings[] | select(.severity == "blocking")] | length' "$a3_findings" 2>/dev/null || echo "0")
    assert_eq "A3 artifact contract: synthetic findings.json has 1 blocking finding" "1" "$a3_blocking"
else
    assert_fail "A3 artifact contract: synthetic findings.json not created"
fi

# ─── Test I1 (#508): 6-stage happy path emits divider+running+complete with UTC ─
# Reset to a clean plugin set in the shared PLUGINS_ROOT (mock_plugin_factory
# writes under $TEST_TEMP_DIR/plugins regardless of ZBUILD_PLUGINS_ROOT —
# match that convention rather than fight it).
rm -rf "$PLUGINS_ROOT/agent" "$PLUGINS_ROOT/tool"
_make_plugin "intake"          "agent" 0 >/dev/null
_make_plugin "plan"            "agent" 0 >/dev/null
# #842: standard template now includes impact inside design_impact_cycle.
_make_plugin "impact"          "agent" 0 >/dev/null
# #842: design is a cycle member of design_impact_cycle.
_make_plugin "design"          "agent" 0 >/dev/null
_make_plugin "build"           "agent" 0 >/dev/null
_make_plugin "test"            "tool"  0 >/dev/null
# #623: standard template's build_test_cycle (#582) requires test_assessment.
# Without it the cycle fails with verdict=error, cycle blocked, rc=5 —
# `set -e` kills the test before I1's assertions run.
_make_plugin "test_assessment" "agent" 0 >/dev/null
# NB: objective-gate is NOT registered here — it lives in simple.yaml only, not
# the standard template this test exercises (#970). See the 13-stage count below.
# #922: acceptance-gate leaf stage after test_assessment (ADR-036).
_make_plugin "acceptance-gate" "agent" 0 >/dev/null
# #755: build_review_cycle.flow now includes the 4 compound_quality stages; without
# stubs the cycle hits cq-preflight (no plugin), fails rc=5, and `set -e` kills
# I1 before its assertions run.
_make_plugin "cq-preflight"    "agent" 0 >/dev/null
_make_plugin "cq-audit-plan"   "agent" 0 >/dev/null
_make_plugin "cq-cycle"        "agent" 0 >/dev/null
_make_plugin "cq-backtrack"    "agent" 0 >/dev/null
_make_plugin "review"          "agent" 0 >/dev/null
# #756: pr leaf stage after build_review_cycle.
_make_plugin "pr"              "agent" 0 >/dev/null

I1_STDERR="$TEST_TEMP_DIR/i1.runner.stderr"
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
NO_COLOR=1 \
bash "$RUNNER" --issue 83 2>"$I1_STDERR" >/dev/null

I1_OUT="$(cat "$I1_STDERR")"
assert_contains "I1 #508: stderr carries UTC timestamps" "$I1_OUT" "UTC"
assert_contains "I1 #508: running line uses 'started'"   "$I1_OUT" "started 03:25:45 UTC"
assert_contains "I1 #508: complete line uses 'finished'" "$I1_OUT" "finished 03:25:45 UTC"

# I1b: exactly 14 'started ' and 14 'finished ' suffixes (one per stage).
# Standard template has 14 stages (#756: pr added); objective-gate lives in simple.yaml only.
started_count=$(grep -c 'started 03:25:45 UTC' "$I1_STDERR" || true)
assert_eq "I1b #508: exactly 14 'started ' suffixes" "14" "$started_count"
finished_count=$(grep -c 'finished 03:25:45 UTC' "$I1_STDERR" || true)
assert_eq "I1b #508: exactly 14 'finished ' suffixes" "14" "$finished_count"

# ─── Test I2 (#508): failure path emits ✗ with rc + finished + duration ─────
_make_plugin "build" "agent" 1 >/dev/null
I2_STDERR="$TEST_TEMP_DIR/i2.runner.stderr"
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
NO_COLOR=1 \
bash "$RUNNER" --issue 83 2>"$I2_STDERR" >/dev/null
set -e

I2_OUT="$(cat "$I2_STDERR")"
assert_contains "I2 #508: fail line carries rc + finished + duration" \
    "$I2_OUT" "Stage build failed (rc=1, finished 03:25:45 UTC"

# ─── Test I3 (#525): happy path emits ✓ pipeline.end terminal banner ─────────
_make_plugin "build" "agent" 0 >/dev/null
I3_STDERR="$TEST_TEMP_DIR/i3.runner.stderr"
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
NO_COLOR=1 \
bash "$RUNNER" --issue 83 2>"$I3_STDERR" >/dev/null
I3_OUT="$(cat "$I3_STDERR")"

assert_contains "I3 #525: terminal banner frame uses ═"            "$I3_OUT" "═"
assert_contains "I3 #525: terminal banner labels pipeline.end"     "$I3_OUT" "pipeline.end"
assert_contains "I3 #525: banner status word maps success→complete" "$I3_OUT" "Pipeline complete:"
assert_contains "I3 #525: banner carries status=complete"          "$I3_OUT" "status=complete"
assert_contains "I3 #525: banner carries run_id=83-derived"        "$I3_OUT" "issue=83"
assert_contains "I3 #525: banner carries 'took ' duration token"   "$I3_OUT" "(took "

# Regression: event payload contract unchanged — pipeline.end event count = 1
i3_end_count=$(grep -c '"pipeline.end"' "$EVENTS_JSONL" || true)
assert_eq "I3 regression: banner adds no extra pipeline.end events" "1" "$i3_end_count"

# ─── Test I4 (#525): mid-stage failure emits ✗ banner with stage+rc ──────────
_make_plugin "build" "agent" 1 >/dev/null
I4_STDERR="$TEST_TEMP_DIR/i4.runner.stderr"
rm -f "$EVENTS_JSONL" "$STATE_DIR/pipeline-state.json"
set +e
ZBUILD_TERM_WIDTH_OVERRIDE=100 \
ZBUILD_STAGE_IO_NOW_MS_OVERRIDE=12345000 \
NO_COLOR=1 \
bash "$RUNNER" --issue 83 2>"$I4_STDERR" >/dev/null
set -e
I4_OUT="$(cat "$I4_STDERR")"

assert_contains "I4 #525: failure banner uses ✗"               "$I4_OUT" "✗"
assert_contains "I4 #525: failure banner reports stage=build"  "$I4_OUT" "stage=build"
assert_contains "I4 #525: failure banner reports rc=1"         "$I4_OUT" "rc=1"
assert_contains "I4 #525: failure banner word is 'failed'"     "$I4_OUT" "Pipeline failed:"

# Regression: one and only one pipeline.end event
i4_end_count=$(grep -c '"pipeline.end"' "$EVENTS_JSONL" || true)
assert_eq "I4 regression: exactly one pipeline.end event" "1" "$i4_end_count"

# ─── Test I5 (#525): NO_COLOR strips ANSI but keeps glyph + ts in banner ─────
I5_OUT="$I3_OUT"  # reuse happy-path stderr captured under NO_COLOR=1 above
if [[ "$I5_OUT" == *$'\033'* ]]; then
    assert_fail "I5 #525: NO_COLOR strips ANSI from banner" "ESC byte present"
else
    assert_pass "I5 #525: NO_COLOR strips ANSI from banner"
fi
assert_contains "I5 #525: NO_COLOR banner keeps timestamp" "$I5_OUT" "UTC"
assert_contains "I5 #525: NO_COLOR banner keeps ✓ glyph"   "$I5_OUT" "✓"

# ─── Test I6 (#525): SIGTERM mid-run → ✗ aborted banner via EXIT trap ───────
# Reuses the Test 10 / A2 pattern: slow intake plugin, kill mid-run.
I6_DIR="$TEST_TEMP_DIR/i6"
I6_PLUGINS="$I6_DIR/plugins"
I6_STATE_DIR="$I6_DIR/state"
I6_EVENTS_DIR="$I6_DIR/events"
I6_EVENTS_JSONL="$I6_EVENTS_DIR/events.jsonl"
I6_STDERR="$I6_DIR/runner.stderr"
mkdir -p "$I6_PLUGINS/agent/intake" "$I6_STATE_DIR" "$I6_EVENTS_DIR"

cat > "$I6_PLUGINS/agent/intake/manifest.yaml" <<'EOF'
id: intake
name: Slow Intake I6
kind: agent
version: 0.0.1
hooks:
  run: intake_run
requires:
  core:
    - redaction
EOF
cat > "$I6_PLUGINS/agent/intake/plugin.sh" <<'EOF'
intake_run() { sleep 5; return 0; }
EOF

# Flaky-kill mitigation (per #494/#908): retry on the rare signal-delivery quirk.
# #1149: the deterministic anchor is the slow stage's plugin.run.start, which is
# emitted AFTER the abort EXIT/TERM traps install (runner.sh L1152-1159 <
# pipeline.start L1185 < plugin.run.start) AND after intake blocks in `sleep 15`.
# Waiting for it (vs the old pipeline.start poll + a speculative `sleep 0.3`
# settle) proves the trap is armed and a live child is killable, closing the
# pre-trap / not-yet-running kill window the prior anchor left open. The retry
# loop remains as cheap insurance for genuine kernel signal-delivery races.
#
# #1156: two robustness fixes for the load-dependent CI flake on the ubuntu leg:
#   1. Only kill once plugin.run.start is CONFIRMED — never kill on a (rare)
#      pre-kill-anchor timeout, which could land the signal before the trap is
#      armed and produce neither event nor banner. A timed-out attempt retries.
#   2. Verify the AUTHORITATIVE `pipeline.abort` event (mirrors the Test 10 / A2
#      siblings) AND the stderr banner, each via a POST-kill poll to absorb
#      scheduling/flush lag the prior single-shot `grep` raced against. The
#      banner is the racier signal: the abort EXIT trap emits the event FIRST
#      and renders the banner LAST, so the event is the durable record and a
#      single un-polled `grep` immediately after `wait` can miss a banner that
#      lands a beat later under load. Asserting the polled event keeps the
#      proof anchored on the reliable record; polling the banner (now made
#      deterministic at all render sites by the runner.sh _render_pipeline_end
#      errexit fix in this change) keeps the original #525 intent intact.
i6_event_ok=0
i6_banner_ok=0
rm -f "$I6_EVENTS_JSONL" "$I6_STDERR"
ZBUILD_PLUGINS_ROOT="$I6_PLUGINS" \
ZBUILD_STATE_DIR="$I6_STATE_DIR" \
ZBUILD_EVENTS_DIR="$I6_EVENTS_DIR" \
ZBUILD_EVENTS_JSONL="$I6_EVENTS_JSONL" \
ZBUILD_EVENTS_DB="/dev/null" \
NO_COLOR=1 \
bash "$RUNNER" --issue 83 2>"$I6_STDERR" >/dev/null &
i6_pid=$!
# Anchor the kill on plugin.run.start (trap armed + live child). Fail-fast (~15s):
# locally it is near-instant; a box that can't get there in 15s is too sick to
# test signals on and must not stall the tier. Poll past the deferred trap: bash
# does NOT interrupt the foreground `sleep 15` to service TERM, so the abort
# event/banner only fire ~15s after the kill — poll 25s, never block on the
# (sleep-deferred) exit, then force-reap. Result is ADVISORY (#1157): the timing
# is nondeterministic on the parallel CI tier, so warn rather than fail.
if wait_for_event "$I6_EVENTS_JSONL" '"plugin.run.start"' 150 0.1; then
    kill -TERM "$i6_pid" 2>/dev/null || true
    wait_for_event "$I6_EVENTS_JSONL" '"pipeline.abort"' 120 0.1 || true
    grep -q '"pipeline.abort"' "$I6_EVENTS_JSONL" 2>/dev/null && i6_event_ok=1
    grep -q "Pipeline aborted:" "$I6_STDERR" 2>/dev/null && i6_banner_ok=1
fi
kill -KILL "$i6_pid" 2>/dev/null || true
wait "$i6_pid" 2>/dev/null || true

i6_ev_detail="$( [[ -f "$I6_EVENTS_JSONL" ]] && tr '\n' '|' < "$I6_EVENTS_JSONL" | head -c 200 )"
i6_err_detail="$( [[ -f "$I6_STDERR" ]] && tr '\n' '|' < "$I6_STDERR" | head -c 200 )"
_kill_assert "$i6_event_ok" "I6 #525: SIGTERM emits pipeline.abort event via EXIT trap" \
    "events: $i6_ev_detail"
_kill_assert "$i6_banner_ok" "I6 #525: SIGTERM emits ✗ aborted terminal banner" \
    "stderr: $i6_err_detail"


# ─── Test R1 (#619): _usage() writes to stderr, not stdout ────────────────────
# REGRESSION LOCK: catches a revert of runner.sh's `cat >&2 <<EOF`.
r1_stdout="$(bash "$RUNNER" 2>/dev/null || true)"
if [[ "$r1_stdout" == *"Usage: runner.sh"* ]]; then
    assert_fail "R1 #619: _usage() must NOT leak to stdout" "got: ${r1_stdout:0:120}..."
else
    assert_pass "R1 #619: _usage() writes to stderr only (stdout clean)"
fi
# Positive control: stderr still surfaces the Usage block on error path.
r1_stderr="$(bash "$RUNNER" 2>&1 >/dev/null || true)"
assert_contains "R1 #619: _usage() still reaches stderr" "$r1_stderr" "Usage: runner.sh"

# ─── Test R2 (#619): _make_plugin wrapper suppresses factory stdout ───────────
# REGRESSION LOCK: catches a revert of the wrapper's `>/dev/null`.
r2_stdout="$(_make_plugin "r2demo" "agent" 0)"
if [[ -z "$r2_stdout" ]]; then
    assert_pass "R2 #619: _make_plugin wrapper suppresses factory stdout"
else
    assert_fail "R2 #619: _make_plugin wrapper must suppress stdout" "leaked: $r2_stdout"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
