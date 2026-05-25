#!/usr/bin/env bash
# Tests: golden file harness — proves assert_golden works with 3 minimal snapshots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "golden contracts — assert_golden harness (E.1 seed set)"

# ─── G1: event shape golden ─────────────────────────────────────────────────
actual='{"event":"redaction.applied","version":"1"}'
set +e
assert_golden "redaction-applied-shape" "$actual"
g1_rc=$?
set -e
if [[ $g1_rc -eq 0 ]]; then
    assert_pass "G1: redaction.applied event shape matches golden"
else
    assert_fail "G1: redaction.applied event shape matches golden" "assert_golden returned $g1_rc"
fi

# ─── G2: init_state shape golden ────────────────────────────────────────────
actual='{"schema_version":"1","status":"pending"}'
set +e
assert_golden "init-state-shape" "$actual"
g2_rc=$?
set -e
if [[ $g2_rc -eq 0 ]]; then
    assert_pass "G2: init_state JSON shape matches golden"
else
    assert_fail "G2: init_state JSON shape matches golden" "assert_golden returned $g2_rc"
fi

# ─── G3: dry-run output golden ──────────────────────────────────────────────
actual="zbuild pipeline start --dry-run: ok"
set +e
assert_golden "cli-dry-run" "$actual"
g3_rc=$?
set -e
if [[ $g3_rc -eq 0 ]]; then
    assert_pass "G3: CLI dry-run output matches golden"
else
    assert_fail "G3: CLI dry-run output matches golden" "assert_golden returned $g3_rc"
fi

print_test_results
exit $((FAIL > 0))
