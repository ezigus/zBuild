#!/usr/bin/env bash
# Tests: prior-output-reader — unified artifact resolution (#1581)
#
# Covers:
#   - Intra-cycle source wins when ZBUILD_CYCLE_ITER >= 2
#   - Falls back to ZBUILD_RESTORED_ARTIFACTS_DIR when no cycle
#   - Falls back to ZBUILD_STATE_DIR/artifacts when neither
#   - Returns empty (rc 0) when nothing exists
#   - Precedence: cycle wins over restored over state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/prior-output-reader.sh
source "$REPO_ROOT/scripts/lib/prior-output-reader.sh"

print_test_header "prior-output-reader — unified artifact resolution (#1581)"
setup_test_env "prior-output-reader"

# ─── T1: Intra-cycle source wins (ZBUILD_CYCLE_ITER >= 2) ──────────────────
export ZBUILD_CYCLE_ITER="2"
export ZBUILD_CYCLE_FEEDBACK_DIR="$TEST_TEMP_DIR/cycle-feedback"
mkdir -p "$ZBUILD_CYCLE_FEEDBACK_DIR"

# Create prior_design.txt (artifact "design.md" → field "design")
printf 'prior design from cycle' > "$ZBUILD_CYCLE_FEEDBACK_DIR/prior_design.txt"

# Also create restored and state versions to verify cycle wins
export ZBUILD_RESTORED_ARTIFACTS_DIR="$TEST_TEMP_DIR/restored"
mkdir -p "$ZBUILD_RESTORED_ARTIFACTS_DIR"
printf 'restored design' > "$ZBUILD_RESTORED_ARTIFACTS_DIR/design.md"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR/artifacts"
printf 'state design' > "$ZBUILD_STATE_DIR/artifacts/design.md"

result=$(_read_prior_output "design.md")
assert_eq "T1: intra-cycle source (iter>=2) wins over restored and state" \
    "prior design from cycle" "$result"

# Cleanup cycle-related env vars
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

# ─── T2: Falls back to restored when no cycle ──────────────────────────────
# Keep ZBUILD_RESTORED_ARTIFACTS_DIR with prior content
# Create for artifact with different extension
printf 'restored plan' > "$ZBUILD_RESTORED_ARTIFACTS_DIR/plan.json"

result=$(_read_prior_output "plan.json")
assert_eq "T2: restored artifacts fallback when no cycle" \
    "restored plan" "$result"

# ─── T3: Falls back to state when neither cycle nor restored ───────────────
# Clear restored dir, but keep state with content
rm "$ZBUILD_RESTORED_ARTIFACTS_DIR/plan.json"

printf 'state plan' > "$ZBUILD_STATE_DIR/artifacts/plan.json"

result=$(_read_prior_output "plan.json")
assert_eq "T3: state artifacts fallback when no cycle/restored" \
    "state plan" "$result"

# ─── T4: Returns empty when nothing found ──────────────────────────────────
result=$(_read_prior_output "nonexistent.txt")
assert_eq "T4: returns empty string when artifact not found" \
    "" "$result"

# Capture exit code separately (since we're in a subshell with &&)
_read_prior_output "nonexistent.txt" >/dev/null 2>&1
rc=$?
assert_eq "T4: returns rc 0 when artifact not found" \
    "0" "$rc"

# ─── T5: Precedence verification with all three sources present ────────────
# Recreate cycle source to verify it truly wins
export ZBUILD_CYCLE_ITER="3"
export ZBUILD_CYCLE_FEEDBACK_DIR="$TEST_TEMP_DIR/cycle-feedback-v2"
mkdir -p "$ZBUILD_CYCLE_FEEDBACK_DIR"
printf 'build from cycle' > "$ZBUILD_CYCLE_FEEDBACK_DIR/prior_build.txt"

# Recreate restored source
mkdir -p "$ZBUILD_RESTORED_ARTIFACTS_DIR"
printf 'build from restored' > "$ZBUILD_RESTORED_ARTIFACTS_DIR/build.json"

# Keep state source
printf 'build from state' > "$ZBUILD_STATE_DIR/artifacts/build.json"

result=$(_read_prior_output "build.json")
assert_eq "T5: cycle precedence over restored over state (all present)" \
    "build from cycle" "$result"

# Test with field stripping (build.json → prior_build.txt)
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR ZBUILD_RESTORED_ARTIFACTS_DIR
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state-only"
mkdir -p "$ZBUILD_STATE_DIR/artifacts"
printf 'summary from state' > "$ZBUILD_STATE_DIR/artifacts/build-summary.json"

result=$(_read_prior_output "build-summary.json")
assert_eq "T5b: field name stripping (build-summary.json works)" \
    "summary from state" "$result"

# ─── T6: Empty prior file is treated as missing ────────────────────────────
export ZBUILD_CYCLE_ITER="2"
export ZBUILD_CYCLE_FEEDBACK_DIR="$TEST_TEMP_DIR/cycle-empty"
mkdir -p "$ZBUILD_CYCLE_FEEDBACK_DIR"
# Create empty file ([[ -s "$f" ]] checks for non-empty)
touch "$ZBUILD_CYCLE_FEEDBACK_DIR/prior_lens.txt"

result=$(_read_prior_output "lens.json")
assert_eq "T6: empty prior file is ignored (falls through)" \
    "" "$result"

# ─── T7: Hermetic env var handling (no leakage between test cases) ──────────
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR ZBUILD_RESTORED_ARTIFACTS_DIR ZBUILD_STATE_DIR

# Should fall back to default ./state/artifacts (not found)
result=$(_read_prior_output "test.txt")
assert_eq "T7: env vars cleared, returns empty from nonexistent default state" \
    "" "$result"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
