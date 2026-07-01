#!/usr/bin/env bash
# Tests: cycle-orchestrator _cycle_acceptance_terminal_failure (#1044, #1188)
#
# The acceptance-gate writes artifacts/acceptance-gate-result.json with
# {"verdict":"fail","failures":[...]} and returns rc=1 for EVERY fail class.
# TWO kinds of failure are NON-terminal (must NOT hard-abort):
#   - untagged_spec:*  RECOVERABLE (fed back to build via the #951 edge).
#   - negctl_error:* / reachability_error:*  INFRASTRUCTURE (ADR-036 #1188):
#     resolve/worktree failures and negctl/reachability TIMEOUTS.
# GENUINE violations stay terminal and make the verdict load-bearing at
# completion: tautology / inert_wiring / not_passing_at_head / no_testfile /
# malformed_acceptance_block. This helper draws that line. Membership guard:
# only fires when acceptance-gate is a cycle member so inner cycles
# (build_test_cycle) are never affected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "cycle-orchestrator — acceptance terminal failure (#1044)"
setup_test_env "cycle-acceptance-terminal"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$STATE_DIR/artifacts"
RESULT="$STATE_DIR/artifacts/acceptance-gate-result.json"

_write_result() { printf '%s' "$1" > "$RESULT"; }

# ── [SPEC-1] terminal classes (inert_wiring / tautology) with membership → 0 ──
_CYCLE_STAGES=(build acceptance-gate review)

_write_result '{"verdict":"fail","failures":["inert_wiring:config/x.yaml"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-1] inert_wiring fail + member → terminal (rc=0)" "0" "$rc"

_write_result '{"verdict":"fail","failures":["tautology:SPEC-2"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-1] tautology fail + member → terminal (rc=0)" "0" "$rc"

# ── [SPEC-2] untagged_spec-only → NOT terminal (recovery preserved) → 1 ──
_write_result '{"verdict":"fail","failures":["untagged_spec:SPEC-1"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-2] untagged_spec-only → NOT terminal (rc=1)" "1" "$rc"

# A multi-entry untagged_spec list (still homogeneous L1) stays recoverable.
_write_result '{"verdict":"fail","failures":["untagged_spec:SPEC-1","untagged_spec:SPEC-3"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-2] untagged_spec list → NOT terminal (rc=1)" "1" "$rc"

# ── [SPEC-5] infra classes negctl_error/reachability_error → NOT terminal (#1188) ──
# Infra failures (resolve/worktree/timeout) must never hard-fail the pipeline as
# if the acceptance contract were violated.
_write_result '{"verdict":"fail","failures":["negctl_error:baseline_resolve_failed"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-5] negctl_error resolve → NOT terminal (rc=1)" "1" "$rc"

_write_result '{"verdict":"fail","failures":["negctl_error:timeout:SPEC-1"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-5] negctl_error timeout → NOT terminal (rc=1)" "1" "$rc"

_write_result '{"verdict":"fail","failures":["reachability_error:timeout:core/x.sh"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-5] reachability_error timeout → NOT terminal (rc=1)" "1" "$rc"

# Mixed infra-only list stays non-terminal.
_write_result '{"verdict":"fail","failures":["untagged_spec:SPEC-1","negctl_error:timeout:SPEC-2","reachability_error:worktree_failed"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-5] infra+untagged mix → NOT terminal (rc=1)" "1" "$rc"

# But a GENUINE violation alongside infra still makes the verdict terminal.
_write_result '{"verdict":"fail","failures":["negctl_error:timeout:SPEC-1","tautology:SPEC-2"]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-5] infra + real violation → terminal (rc=0)" "0" "$rc"

# verdict=pass is never terminal regardless of membership.
_write_result '{"verdict":"pass","failures":[]}'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-2] verdict=pass → NOT terminal (rc=1)" "1" "$rc"

# ── [SPEC-3] membership guard + missing file → 1 ──
# Terminal failure file present, but acceptance-gate NOT a cycle member.
_write_result '{"verdict":"fail","failures":["inert_wiring:config/x.yaml"]}'
_CYCLE_STAGES=(build test)
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-3] not a member → never blocks (rc=1)" "1" "$rc"

# Member again, but result file missing → never falsely block.
_CYCLE_STAGES=(build acceptance-gate review)
rm -f "$RESULT"
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-3] missing result file → returns 1" "1" "$rc"

# Garbage / unparseable JSON → never falsely block.
_write_result 'not json at all'
set +e; _cycle_acceptance_terminal_failure "$STATE_DIR"; rc=$?; set -e
assert_eq "[SPEC-3] unparseable result → returns 1" "1" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
