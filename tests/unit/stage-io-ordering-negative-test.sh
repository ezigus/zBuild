#!/usr/bin/env bash
# tests/unit/stage-io-ordering-negative-test.sh — negative cases for #491.
#
# (1) Mutation: temporarily inject `2>/dev/null` into a synthetic plugin
#     under TEST_TEMP_DIR and verify the lint guard fails on it.
# (2) FD validation: sourcing core/output/stage-io.sh with
#     ZBUILD_STAGE_IO_FD=1 (or 0) MUST refuse to load with rc=2.
# (3) FD validation: ZBUILD_STAGE_IO_FD=1799 (closed fd) MUST refuse.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "stage-io ordering negative — mutation + fd validation (#491)"
setup_test_env "stage-io-negative"

LINT="$REPO_ROOT/scripts/lib/lint-stage-io.sh"

# ── (1) Mutation: inject 2>/dev/null into a synthetic plugin ────────────────
# Copy the real plan plugin into TEST_TEMP_DIR, mutate it, point lint at the copy.
PLAN_REAL="$REPO_ROOT/plugins/agent/plan/plugin.sh"
PLAN_COPY="$TEST_TEMP_DIR/plan-copy.sh"
cp "$PLAN_REAL" "$PLAN_COPY"

# Sanity: the unmutated copy passes lint (lives outside the production tree).
set +e
bash "$LINT" "$PLAN_COPY" >/dev/null 2>&1
rc_pre=$?
set -e
assert_eq "(1a) unmutated copy passes lint" "0" "$rc_pre"

# Mutate: re-introduce the bug by appending 2>/dev/null on the route_to_model line.
# Use sed to add ` 2>/dev/null` before the closing `)` of the $() capture.
sed -i.bak 's|raw_response="$(route_to_model "$tier" "$prompt")"|raw_response="$(route_to_model "$tier" "$prompt" 2>/dev/null)"|' "$PLAN_COPY"

set +e
bash "$LINT" "$PLAN_COPY" >/dev/null 2>&1
rc_post=$?
set -e
assert_eq "(1b) mutated copy fails lint with rc=1" "1" "$rc_post"

# ── (2) FD validation: ZBUILD_STAGE_IO_FD=1 → source rc=2 ───────────────────
# Run in a subshell so the failed-source side effect doesn't pollute this test.
set +e
ZBUILD_STAGE_IO_FD=1 bash -c "source \"$REPO_ROOT/core/output/stage-io.sh\"" >/dev/null 2>&1
rc_fd1=$?
set -e
assert_eq "(2a) ZBUILD_STAGE_IO_FD=1 refused at module load" "2" "$rc_fd1"

set +e
ZBUILD_STAGE_IO_FD=0 bash -c "source \"$REPO_ROOT/core/output/stage-io.sh\"" >/dev/null 2>&1
rc_fd0=$?
set -e
assert_eq "(2b) ZBUILD_STAGE_IO_FD=0 refused at module load" "2" "$rc_fd0"

# Error message must mention "forbidden" or fd number for operator clarity.
fd1_err="$(ZBUILD_STAGE_IO_FD=1 bash -c "source \"$REPO_ROOT/core/output/stage-io.sh\"" 2>&1 >/dev/null || true)"
if printf '%s' "$fd1_err" | grep -q "ZBUILD_STAGE_IO_FD=1"; then
    assert_pass "(2c) fd-1 error message mentions ZBUILD_STAGE_IO_FD=1"
else
    assert_fail "(2c) fd-1 error message mentions ZBUILD_STAGE_IO_FD=1" \
        "stderr: $fd1_err"
fi

# ── (3) FD validation: closed fd 17 → relaxed fallback (#586) ───────────────
# #586 relaxed the hard `return 2` to a warn-once + fall back to fd 2 + emit
# `stage_io.fd_fallback` event. Source still succeeds (rc=0); effective fd is 2.
set +e
fb_out="$(ZBUILD_STAGE_IO_FD=17 ZBUILD_TEST_MODE=1 bash -c "source \"$REPO_ROOT/core/output/stage-io.sh\" && echo fd=\$ZBUILD_STAGE_IO_FD" 2>&1)"
rc_fd9=$?
set -e
assert_eq "(3) ZBUILD_STAGE_IO_FD=17 (closed fd) falls back (#586)" "0" "$rc_fd9"
assert_contains "(3b) closed-fd fallback sets effective fd=2 (#586)" "$fb_out" "fd=2"
assert_contains_regex "(3c) closed-fd fallback warns to stderr (#586)" "$fb_out" "fallback|fall.*back|fd 2"

# ── (4) FD validation: open fd 17 is accepted ────────────────────────────────
set +e
ZBUILD_STAGE_IO_FD=17 bash -c "exec 17>/dev/null; source \"$REPO_ROOT/core/output/stage-io.sh\"" >/dev/null 2>&1
rc_fd9ok=$?
set -e
assert_eq "(4) ZBUILD_STAGE_IO_FD=17 (open fd) accepted" "0" "$rc_fd9ok"

# ── (5) Default (unset) accepts fd 2 ────────────────────────────────────────
set +e
bash -c "unset ZBUILD_STAGE_IO_FD; source \"$REPO_ROOT/core/output/stage-io.sh\"" >/dev/null 2>&1
rc_default=$?
set -e
assert_eq "(5) ZBUILD_STAGE_IO_FD unset → defaults to 2 → accepted" "0" "$rc_default"

# ── (6) Garbage value rejected ──────────────────────────────────────────────
set +e
ZBUILD_STAGE_IO_FD=abc bash -c "source \"$REPO_ROOT/core/output/stage-io.sh\"" >/dev/null 2>&1
rc_garbage=$?
set -e
assert_eq "(6) ZBUILD_STAGE_IO_FD=abc refused (non-integer)" "2" "$rc_garbage"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
