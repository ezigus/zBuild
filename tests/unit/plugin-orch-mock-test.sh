#!/usr/bin/env bash
# Tests: orch-mock orch_collect honors the 0/1/2 contract (PR #269) — issue #277
# Sibling backends (orch-sequential, orch-bash-parallel, orch-ruflo-hive) were
# normalised in #269; orch-mock was missed. This test guards the fix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "orch-mock — orch_collect returns 0/1/2 per orch contract"

setup_test_env "plugin-orch-mock"
export ORCH_MOCK_DIR="$TEST_TEMP_DIR/orch-mock"

# shellcheck source=../../plugins/tool/orch-mock/plugin.sh
source "$REPO_ROOT/plugins/tool/orch-mock/plugin.sh"

# ─── M1: all-pass → 0 ────────────────────────────────────────────────────────
pool="m1-all-pass"
orch_spawn "$pool" 3 ""
orch_dispatch "$pool" "$(orch_work_unit 'exit 0')" >/dev/null
orch_dispatch "$pool" "$(orch_work_unit 'exit 0')" >/dev/null
orch_dispatch "$pool" "$(orch_work_unit 'exit 0')" >/dev/null
set +e
orch_collect "$pool" >/dev/null
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    assert_pass "M1: all-pass returns 0 (got $rc)"
else
    assert_fail "M1: all-pass returns 0" "got $rc"
fi
orch_shutdown "$pool"

# ─── M2: all-fail → 1 ────────────────────────────────────────────────────────
# First exit code is intentionally NOT 1 — pre-fix code returned the first
# non-zero rc encountered, so if the first failure were 1 this assertion
# would pass on the buggy version. Putting 5 first makes the test
# discriminating: only the 0/1/2 normaliser can return 1 here.
pool="m2-all-fail"
orch_spawn "$pool" 3 ""
orch_dispatch "$pool" "$(orch_work_unit 'exit 5')" >/dev/null
orch_dispatch "$pool" "$(orch_work_unit 'exit 2')" >/dev/null
orch_dispatch "$pool" "$(orch_work_unit 'exit 7')" >/dev/null
set +e
orch_collect "$pool" >/dev/null
rc=$?
set -e
if [[ $rc -eq 1 ]]; then
    assert_pass "M2: all-fail returns 1 (got $rc) — not raw rc passthrough (pre-fix would have returned 5)"
else
    assert_fail "M2: all-fail returns 1" "got $rc (pre-fix would have returned 5, the first non-zero)"
fi
orch_shutdown "$pool"

# ─── M3: mixed → 2 ──────────────────────────────────────────────────────────
pool="m3-mixed"
orch_spawn "$pool" 3 ""
orch_dispatch "$pool" "$(orch_work_unit 'exit 0')" >/dev/null
orch_dispatch "$pool" "$(orch_work_unit 'exit 1')" >/dev/null
orch_dispatch "$pool" "$(orch_work_unit 'exit 0')" >/dev/null
set +e
orch_collect "$pool" >/dev/null
rc=$?
set -e
if [[ $rc -eq 2 ]]; then
    assert_pass "M3: mixed returns 2 (got $rc) — partial-failure signal"
else
    assert_fail "M3: mixed returns 2" "got $rc (pre-fix would have been 1, not 2)"
fi
orch_shutdown "$pool"

# ─── M4: empty pool → 0 ──────────────────────────────────────────────────────
pool="m4-empty"
orch_spawn "$pool" 1 ""
set +e
orch_collect "$pool" >/dev/null
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    assert_pass "M4: empty pool returns 0 (got $rc)"
else
    assert_fail "M4: empty pool returns 0" "got $rc"
fi
orch_shutdown "$pool"

cleanup_test_env
