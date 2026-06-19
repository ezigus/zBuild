#!/usr/bin/env bash
# Tests: core/state/{atomic,resume}.sh
# Verifies the resume contract (ADR-006) and atomic write primitives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../core/state/atomic.sh
source "$REPO_ROOT/core/state/atomic.sh"  # read_state (idempotent via load sentinel)

print_test_header "core/state — atomic + resume contract"

setup_test_env "core-state"
STATE_FILE="$TEST_TEMP_DIR/state/pipeline-state.json"
mkdir -p "$(dirname "$STATE_FILE")"

# ─── init_state ─────────────────────────────────────────────────────────────
init_state "$STATE_FILE" "test-run-1" 42 >/dev/null
assert_file_exists "init_state creates state file" "$STATE_FILE"
assert_eq "schema_version is 1" "1" "$(jq -r .schema_version "$STATE_FILE")"
assert_eq "current_iteration starts at 0" "0" "$(jq -r .current_iteration "$STATE_FILE")"

# ─── current_iteration persists (the legacy resume gap fix) ────────────────────
increment_iteration "$STATE_FILE" >/dev/null
increment_iteration "$STATE_FILE" >/dev/null
increment_iteration "$STATE_FILE" >/dev/null
assert_eq "current_iteration persisted after 3 increments" "3" \
    "$(get_state_field "$STATE_FILE" '.current_iteration' '0')"

# ─── resume_state preserves current_iteration ──────────────────────────────
resume_state "$STATE_FILE" >/dev/null
assert_eq "current_iteration survives resume (FIXES legacy resume gap)" "3" \
    "$(get_state_field "$STATE_FILE" '.current_iteration' '0')"

# ─── atomic_write rotates .bak ──────────────────────────────────────────────
set_state_field "$STATE_FILE" '.current_iteration' "100"
assert_file_exists "atomic_write rotates previous to .bak" "${STATE_FILE}.bak"
assert_eq ".bak contains pre-update value" "3" "$(jq -r .current_iteration "${STATE_FILE}.bak")"
assert_eq "current state has new value" "100" "$(jq -r .current_iteration "$STATE_FILE")"

# ─── validate_json recovers from corrupt main file using .bak ──────────────
echo "not valid json {{{" > "$STATE_FILE"
if validate_json "$STATE_FILE" >/dev/null 2>&1; then
    assert_eq "validate_json recovered from .bak (current_iteration=3)" "3" \
        "$(jq -r .current_iteration "$STATE_FILE")"
else
    assert_fail "validate_json should have recovered from .bak"
fi

# ─── read_state recovers from corrupt main via atomic restore (#946) ──────────
# read_state holds no flock; its .bak→main restore must be atomic (atomic_replace),
# return 0, emit the recovered content, and leave main as valid JSON. (.bak=3 here.)
printf 'corrupt}}}' > "$STATE_FILE"   # invalid JSON; .bak remains valid (current_iteration=3)
set +e; rs_out="$(read_state "$STATE_FILE" 2>/dev/null)"; rs_rc=$?; set -e
assert_eq "read_state returns 0 recovering from .bak" "0" "$rs_rc"
assert_eq "read_state output is the recovered .bak content" "3" \
    "$(printf '%s' "$rs_out" | jq -r .current_iteration)"
assert_eq "read_state rewrote main from .bak (valid JSON)" "3" \
    "$(jq -r .current_iteration "$STATE_FILE")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
