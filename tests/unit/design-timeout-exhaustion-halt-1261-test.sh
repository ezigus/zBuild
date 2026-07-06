#!/usr/bin/env bash
# Tests: issue #1261 — a PERSISTENT design router-timeout must HALT the pipeline
# cleanly (reason=design_timeout_exhausted), NOT fall through to build with the
# empty #945 timeout marker.
#
# Background: design_verify_cycle is `max_iterations: 3, on_max: continue`. #945
# makes a SINGLE timeout recoverable — design writes a gate-FAILING marker so the
# cycle re-iterates. But if ALL iters time out (persistent INFRA), the cycle
# exhausts and ADR-019 `on_max: continue` falls through, carrying the empty
# "# Design incomplete — router timeout" marker to build → build implements from
# nothing. That is the bug this issue fixes.
#
# Fix (reason-aware exhaustion, NOT on_max:halt): the terminating iteration is
# TIMEOUT-driven when a member surfaces the repo-neutral `did_not_finish` verdict
# (build's #1208 verdict; design's #1261 verdict). At exhaustion, if that tail is
# present AND the cycle has NO authoritative verifier signal (no `test` member
# verdict / no test-results.json), HALT (rc=8, reason=design_timeout_exhausted)
# even under on_max=continue. A CONTENT non-convergence (no did_not_finish tail)
# keeps the ADR-019 continue fall-through. GENERIC: keys on the timeout signal +
# absence of a test signal, NOT the `design` stage id — build_test_cycle ALWAYS
# runs `test` (has a signal) so it is unaffected.
#
# SPECs:
#   1 [change] design times out EVERY iter → cycle HALTS rc=8, reason
#              design_timeout_exhausted, cycle.timeout_exhausted emitted. Does
#              NOT converge, does NOT fall through as unconverged→review (rc=2).
#   2 [guard]  design-gate fails on CONTENT 3× (design produces a real design.md,
#              NO did_not_finish tail) → rc=2 (unconverged→review, on_max=continue
#              honored, ADR-019 UNCHANGED). No design_timeout_exhausted.
#   3 [guard]  a converging design (design-gate passes) → rc=0. Unaffected.
#   4 [guard/build-neutral] a build_test_cycle-shaped cycle (has a `test` member)
#              whose build times out every iter but tests PASS → rc=2 (the #1208
#              contract), NOT design_timeout_exhausted. Proves build_test_cycle is
#              untouched (scope: design-only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "design: persistent router-timeout exhaustion HALTS (design_timeout_exhausted) (#1261)"
setup_test_env "design-timeout-exhaustion-halt-1261"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── design-verify-cycle fixture (design → design-gate; NO test member) ───────
DESIGN_TPL="$TEST_TEMP_DIR/design-verify-cycle.yaml"
cat > "$DESIGN_TPL" <<'YAML'
id: design1261
name: design timeout exhaustion
defaults:
  strategy: fanout
stages:
  - id: design-verify
    type: cycle
    stages: [design, design-gate]
    until:
      stage: design-gate
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
    on_max: continue
stage_definitions:
  design:
    roles: [designer]
  design-gate:
    roles: [design_gate]
YAML

# build_test_cycle-shaped fixture (has a `test` member) — the build-neutral guard.
BUILD_TPL="$TEST_TEMP_DIR/build-test-cycle.yaml"
cat > "$BUILD_TPL" <<'YAML'
id: build1261
name: build timeout (neutral guard)
defaults:
  strategy: fanout
stages:
  - id: build-test
    type: cycle
    stages: [build, test]
    until:
      stage: test
      field: verdict
      op: eq
      value: pass
    max_iterations: 3
    on_max: continue
stage_definitions:
  build:
    roles: [builder]
  test:
    roles: [tester]
YAML

# Plan-driven mock dispatch. Format: "stage:v1,v2,...;stage2:...". Verdicts:
#   dnf   — member surfaces did_not_finish (router-timeout mid-flight)
#   pass  — clean pass
#   fail  — verdict=fail (content non-convergence for a gate; failing tests for test)
# The `test` member also writes test-results.json so the orchestrator's
# authoritative-verifier read at exhaustion sees honest data (matching #1208).
cycle_dispatch_stage() {
    local stage="$1" iter="$2" state_file="$3"
    local sd; sd="$(dirname "$state_file")"
    local art="$sd/artifacts"; mkdir -p "$art"
    local IFS_save="$IFS"; IFS=';'
    # shellcheck disable=SC2206
    local -a parts=($MOCK_PLAN); IFS="$IFS_save"
    local p sname vlist v="pass"
    for p in "${parts[@]}"; do
        sname="${p%%:*}"; vlist="${p#*:}"
        if [[ "$sname" == "$stage" ]]; then
            IFS=','; # shellcheck disable=SC2206
            local -a vs=($vlist); IFS="$IFS_save"
            local idx=$(( iter - 1 ))
            [[ $idx -ge ${#vs[@]} ]] && idx=$(( ${#vs[@]} - 1 ))
            v="${vs[$idx]}"
            break
        fi
    done
    _CYCLE_DISPATCH_STATUS="complete"
    _CYCLE_DISPATCH_REASON=""
    case "$stage" in
        test)
            local tv="pass" nf=0
            [[ "$v" == "fail" ]] && { tv="fail"; nf=3; }
            printf '{"schema_version":2,"verdict":"%s","exit_code":0,"passed":5,"failed":%d,"run_mode":"full"}' \
                "$tv" "$nf" > "$art/test-results.json"
            _CYCLE_DISPATCH_VERDICT="$(verdict_classify "$tv" 2>/dev/null || echo fail)"
            _CYCLE_DISPATCH_VERDICT_RAW="$tv"
            ;;
        *)
            # design / design-gate / build — raw verdict drives the blob. The
            # `dnf` plan token maps to the repo-neutral did_not_finish verdict
            # (a router-timeout mid-flight resting point, #1208/#1261).
            local rv="$v"
            [[ "$v" == "dnf" ]] && { rv="did_not_finish"; _CYCLE_DISPATCH_REASON="router_timeout"; }
            _CYCLE_DISPATCH_VERDICT="$(verdict_classify "$rv" 2>/dev/null || echo warn)"
            _CYCLE_DISPATCH_VERDICT_RAW="$rv"
            ;;
    esac
    return 0
}

_seed() {
    STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
    : > "$ZBUILD_EVENTS_JSONL"
    rm -f "$STATE_FILE" "${STATE_FILE}.bak" "${STATE_FILE}.lock"
    rm -rf "$ZBUILD_STATE_DIR/artifacts"
    mkdir -p "$ZBUILD_STATE_DIR/artifacts"
    printf '{"schema_version":1,"status":"in_progress","stage_statuses":{}}' > "$STATE_FILE"
}

_run() {
    # $1 = template, $2 = cycle id, $3 = MOCK_PLAN
    _seed
    load_template "$1"
    MOCK_PLAN="$3"
    set +e
    cycle_orchestrator_run "$2" "$ZBUILD_STATE_DIR" "$STATE_FILE"
    RUN_RC=$?
    set -e
}

# ─── SPEC-1: persistent design timeout → HALT (design_timeout_exhausted) ──────
print_test_section "SPEC-1: design times out every iter → rc=8, reason=design_timeout_exhausted (no fall-through)"
_run "$DESIGN_TPL" "design-verify" "design:dnf,dnf,dnf;design-gate:fail,fail,fail"
assert_eq "[SPEC-1] persistent design timeout HALTS with rc=8" "8" "$RUN_RC"
assert_eq "[SPEC-1] terminal reason is design_timeout_exhausted" \
    "design_timeout_exhausted" "${_CYCLE_LAST_TERMINATED_REASON:-}"
assert_contains "[SPEC-1] cycle.complete carries reason=design_timeout_exhausted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" '"reason":"design_timeout_exhausted"'
assert_contains "[SPEC-1] cycle.timeout_exhausted diagnostic emitted" \
    "$(cat "$ZBUILD_EVENTS_JSONL")" "cycle.timeout_exhausted"
if grep -q '"reason":"converged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-1] must NOT converge on an empty timeout design" "converged emitted"
else
    assert_pass "[SPEC-1] did not converge on the empty timeout design"
fi

# ─── SPEC-2 [guard]: CONTENT non-convergence keeps ADR-019 continue (rc=2) ────
print_test_section "SPEC-2: design-gate fails on CONTENT 3x (no timeout) → rc=2 (on_max=continue, ADR-019 unchanged)"
_run "$DESIGN_TPL" "design-verify" "design:pass,pass,pass;design-gate:fail,fail,fail"
assert_eq "[SPEC-2] content non-convergence → rc=2 (unconverged→review)" "2" "$RUN_RC"
if [[ "${_CYCLE_LAST_TERMINATED_REASON:-}" == "design_timeout_exhausted" ]]; then
    assert_fail "[SPEC-2] content fail must NOT be treated as timeout exhaustion" \
        "reason=${_CYCLE_LAST_TERMINATED_REASON}"
else
    assert_pass "[SPEC-2] content fail keeps a non-timeout terminal reason (${_CYCLE_LAST_TERMINATED_REASON:-?})"
fi
if grep -q '"cycle.timeout_exhausted"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-2] no cycle.timeout_exhausted on a content non-convergence" "emitted"
else
    assert_pass "[SPEC-2] no cycle.timeout_exhausted on a content non-convergence"
fi

# ─── SPEC-3 [guard]: a converging design is unaffected ───────────────────────
print_test_section "SPEC-3: design converges (design-gate passes) → rc=0"
_run "$DESIGN_TPL" "design-verify" "design:pass;design-gate:pass"
assert_eq "[SPEC-3] converging design → rc=0" "0" "$RUN_RC"

# ─── SPEC-4 [guard]: build_test_cycle (has `test`) is UNTOUCHED ──────────────
print_test_section "SPEC-4: build times out every iter but tests PASS → rc=2 (#1208), NOT design_timeout_exhausted"
_run "$BUILD_TPL" "build-test" "build:dnf,dnf,dnf;test:pass,pass,pass"
assert_eq "[SPEC-4] build_test_cycle timeout + passing tests → rc=2 (unchanged #1208 contract)" "2" "$RUN_RC"
if [[ "${_CYCLE_LAST_TERMINATED_REASON:-}" == "design_timeout_exhausted" ]]; then
    assert_fail "[SPEC-4] build_test_cycle must NOT trip the timeout-exhaustion halt (out of scope)" \
        "reason=${_CYCLE_LAST_TERMINATED_REASON}"
else
    assert_pass "[SPEC-4] build_test_cycle unaffected (reason=${_CYCLE_LAST_TERMINATED_REASON:-?})"
fi

# ─── Schema registration ─────────────────────────────────────────────────────
grep -q '"cycle.timeout_exhausted"' "$REPO_ROOT/config/event-schema.json" \
    && assert_pass "schema: cycle.timeout_exhausted registered in event-schema.json" \
    || assert_fail "schema: cycle.timeout_exhausted missing from event-schema.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
