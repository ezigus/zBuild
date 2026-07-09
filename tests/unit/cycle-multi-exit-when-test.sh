#!/usr/bin/env bash
# Tests: multi-condition exit_when (all/any combinator) for cycles (#1284, ADR-047)
# SPEC-1: single-condition exit_when is byte-identical (regression)
# SPEC-2: all: converges only when every condition holds
# SPEC-3: any: converges when any condition holds
# SPEC-4: a condition referencing a not-yet-passing stage keeps iterating
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "cycle — multi-condition exit_when (all/any) — ADR-047 #1284"
setup_test_env "cycle-multi-exit-when"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

FIXT="$REPO_ROOT/tests/fixtures/templates"

# ── SPEC-1: single-condition form is byte-identical (regression) ─────────────
# Load a single-condition template; verify _cycle_check_until behaves identically.
load_template "$FIXT/cycle-converges-iter2.yaml"
assert_eq "SPEC-1: single-cond template loads (exit combinator unset)" \
    "" "${_TPL_CYCLE_EXIT_COMBINATOR_build_test:-}"

_CYCLE_TRAP_CYCLE_ID="build-test"
_CYCLE_TRAP_ITER=1
_cycle_load_template "build-test"
assert_eq "SPEC-1: single-cond _cycle_load_template exits combinator empty" \
    "" "${_CYCLE_EXIT_COMBINATOR:-}"
assert_eq "SPEC-1: UNTIL_STAGE populated" "test" "${_CYCLE_UNTIL_STAGE:-}"
assert_eq "SPEC-1: UNTIL_FIELD populated" "verdict" "${_CYCLE_UNTIL_FIELD:-}"
assert_eq "SPEC-1: UNTIL_OP populated" "eq" "${_CYCLE_UNTIL_OP:-}"
assert_eq "SPEC-1: UNTIL_VALUE populated" "pass" "${_CYCLE_UNTIL_VALUE:-}"

# eq match converges (rc=0)
blob='{"test":{"verdict":"pass","status":"complete"},"build":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-1: single-cond eq match → rc=0 (converged)" "0" "$rc"

# eq mismatch does not converge (rc=1)
blob='{"test":{"verdict":"fail","status":"complete"},"build":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-1: single-cond eq mismatch → rc=1" "1" "$rc"

# field missing → rc=1 (NEVER falsely converge)
blob='{"test":{"status":"complete"},"build":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-1: single-cond field missing → rc=1" "1" "$rc"

# ── SPEC-2: all: converges only when every condition holds ────────────────────
load_template "$FIXT/cycle-multi-exit-when-all.yaml"
assert_eq "SPEC-2: all template: EXIT_COMBINATOR set" \
    "all" "${_TPL_CYCLE_EXIT_COMBINATOR_build_test_cycle:-}"
assert_eq "SPEC-2: all template: EXIT_COUNT=2" \
    "2" "${_TPL_CYCLE_EXIT_COUNT_build_test_cycle:-}"
assert_eq "SPEC-2: all template: cond 1 stage=gate-a" \
    "gate-a" "${_TPL_CYCLE_EXIT_1_STAGE_build_test_cycle:-}"
assert_eq "SPEC-2: all template: cond 2 stage=gate-b" \
    "gate-b" "${_TPL_CYCLE_EXIT_2_STAGE_build_test_cycle:-}"

_CYCLE_TRAP_CYCLE_ID="build-test-cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "build-test-cycle"
assert_eq "SPEC-2: _cycle_load_template sets EXIT_COMBINATOR=all" \
    "all" "${_CYCLE_EXIT_COMBINATOR:-}"
assert_eq "SPEC-2: _CYCLE_EXIT_CONDITIONS has 2 entries" \
    "2" "${#_CYCLE_EXIT_CONDITIONS[@]}"

# both pass → converge (rc=0)
blob='{"gate-a":{"verdict":"pass","status":"complete"},"gate-b":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-2: all — both pass → rc=0 (converged)" "0" "$rc"

# only gate-a passes → no convergence (rc=1)
blob='{"gate-a":{"verdict":"pass","status":"complete"},"gate-b":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-2: all — only gate-a passes → rc=1" "1" "$rc"

# only gate-b passes → no convergence (rc=1)
blob='{"gate-a":{"verdict":"fail","status":"complete"},"gate-b":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-2: all — only gate-b passes → rc=1" "1" "$rc"

# neither passes → no convergence (rc=1)
blob='{"gate-a":{"verdict":"fail","status":"complete"},"gate-b":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-2: all — neither passes → rc=1" "1" "$rc"

# ── SPEC-3: any: converges when any condition holds ───────────────────────────
load_template "$FIXT/cycle-multi-exit-when-any.yaml"
assert_eq "SPEC-3: any template: EXIT_COMBINATOR set" \
    "any" "${_TPL_CYCLE_EXIT_COMBINATOR_build_test_cycle:-}"

_CYCLE_TRAP_CYCLE_ID="build-test-cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "build-test-cycle"
assert_eq "SPEC-3: _cycle_load_template sets EXIT_COMBINATOR=any" \
    "any" "${_CYCLE_EXIT_COMBINATOR:-}"

# both pass → converge (rc=0)
blob='{"gate-a":{"verdict":"pass","status":"complete"},"gate-b":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-3: any — both pass → rc=0 (converged)" "0" "$rc"

# only gate-a passes → converge (rc=0)
blob='{"gate-a":{"verdict":"pass","status":"complete"},"gate-b":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-3: any — only gate-a passes → rc=0 (converged)" "0" "$rc"

# only gate-b passes → converge (rc=0)
blob='{"gate-a":{"verdict":"fail","status":"complete"},"gate-b":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-3: any — only gate-b passes → rc=0 (converged)" "0" "$rc"

# neither passes → no convergence (rc=1)
blob='{"gate-a":{"verdict":"fail","status":"complete"},"gate-b":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-3: any — neither passes → rc=1" "1" "$rc"

# ── SPEC-4: not-yet-passing stage keeps iterating (field missing → rc=1) ─────
# Load the all: template; gate-a present + pass, gate-b verdict absent → no convergence.
load_template "$FIXT/cycle-multi-exit-when-all.yaml"
_CYCLE_TRAP_CYCLE_ID="build-test-cycle"
_CYCLE_TRAP_ITER=2
_cycle_load_template "build-test-cycle"

blob='{"gate-a":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-4: all — gate-b verdict missing → rc=1 (keep iterating)" "1" "$rc"

# Same for any: when the first condition's field is missing but second passes,
# any: must still converge (second condition saves it).
load_template "$FIXT/cycle-multi-exit-when-any.yaml"
_CYCLE_TRAP_CYCLE_ID="build-test-cycle"
_CYCLE_TRAP_ITER=2
_cycle_load_template "build-test-cycle"

blob='{"gate-b":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-4: any — gate-a missing but gate-b passes → rc=0 (converged)" "0" "$rc"

# all: with both stages missing → no convergence.
load_template "$FIXT/cycle-multi-exit-when-all.yaml"
_CYCLE_TRAP_CYCLE_ID="build-test-cycle"
_CYCLE_TRAP_ITER=2
_cycle_load_template "build-test-cycle"

blob='{}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-4: all — both stages missing → rc=1 (no convergence)" "1" "$rc"

# ── SPEC-5: BLOCK-form conditions parse == inline-form (#1284 Fix 1 regression) ─
# The single-condition field:/op:/value: awk handlers must NOT consume a block-form
# condition's continuation lines (which would corrupt cyc_uf/uo/uv and drop rows).
load_template "$FIXT/cycle-multi-exit-when-block.yaml"
assert_eq "SPEC-5: block template: EXIT_COMBINATOR=all" \
    "all" "${_TPL_CYCLE_EXIT_COMBINATOR_build_test_cycle:-}"
assert_eq "SPEC-5: block template: EXIT_COUNT=2" \
    "2" "${_TPL_CYCLE_EXIT_COUNT_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 1 stage=gate-a" \
    "gate-a" "${_TPL_CYCLE_EXIT_1_STAGE_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 1 field=verdict" \
    "verdict" "${_TPL_CYCLE_EXIT_1_FIELD_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 1 op=eq" \
    "eq" "${_TPL_CYCLE_EXIT_1_OP_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 1 value=pass" \
    "pass" "${_TPL_CYCLE_EXIT_1_VALUE_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 2 stage=gate-b" \
    "gate-b" "${_TPL_CYCLE_EXIT_2_STAGE_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 2 field=verdict" \
    "verdict" "${_TPL_CYCLE_EXIT_2_FIELD_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 2 op=eq" \
    "eq" "${_TPL_CYCLE_EXIT_2_OP_build_test_cycle:-}"
assert_eq "SPEC-5: block cond 2 value=pass" \
    "pass" "${_TPL_CYCLE_EXIT_2_VALUE_build_test_cycle:-}"
# Single-condition UNTIL vars MUST stay uncorrupted (empty) for multi-condition.
assert_eq "SPEC-5: block form leaves UNTIL_FIELD empty (not corrupted)" \
    "" "${_TPL_CYCLE_UNTIL_FIELD_build_test_cycle:-}"
assert_eq "SPEC-5: block form leaves UNTIL_OP empty (not corrupted)" \
    "" "${_TPL_CYCLE_UNTIL_OP_build_test_cycle:-}"
assert_eq "SPEC-5: block form leaves UNTIL_VALUE empty (not corrupted)" \
    "" "${_TPL_CYCLE_UNTIL_VALUE_build_test_cycle:-}"

# Runtime semantics match inline all: — both pass → converge, one fail → iterate.
_CYCLE_TRAP_CYCLE_ID="build-test-cycle"
_CYCLE_TRAP_ITER=1
_cycle_load_template "build-test-cycle"
assert_eq "SPEC-5: block _cycle_load_template EXIT_COMBINATOR=all" \
    "all" "${_CYCLE_EXIT_COMBINATOR:-}"
assert_eq "SPEC-5: block _CYCLE_EXIT_CONDITIONS has 2 entries" \
    "2" "${#_CYCLE_EXIT_CONDITIONS[@]}"
blob='{"gate-a":{"verdict":"pass","status":"complete"},"gate-b":{"verdict":"pass","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-5: block all — both pass → rc=0 (converged)" "0" "$rc"
blob='{"gate-a":{"verdict":"pass","status":"complete"},"gate-b":{"verdict":"fail","status":"complete"}}'
set +e; _cycle_check_until "$blob"; rc=$?; set -e
assert_eq "SPEC-5: block all — one fail → rc=1 (keep iterating)" "1" "$rc"

print_test_results
