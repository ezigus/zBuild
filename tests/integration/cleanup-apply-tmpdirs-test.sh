#!/usr/bin/env bash
# Integration: zbuild cleanup --tmpdirs --apply reclaims all scan patterns (#752)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild cleanup --apply tmpdir whitelist (#752)"
setup_test_env "cleanup-apply-tmpdirs"

ZBUILD="$REPO_ROOT/scripts/zbuild"

# ── Synthetic TMPDIR fixture ─────────────────────────────────────────────────
FAKE_TMP="$TEST_TEMP_DIR/faketmp"
mkdir -p "$FAKE_TMP"

# Create one aged dir per pattern.  Touch with a timestamp well in the past
# so --age-hours 0 still flags them.
make_old_dir() {
    local d="$FAKE_TMP/$1"
    mkdir -p "$d"
    touch -t 200001010000 "$d"
}

make_old_dir "zb-applycheck-abc123"
make_old_dir "zbuild-test-stage.1234"
make_old_dir "zb-loop-iters.5678"
make_old_dir "zb-test-auto.9012"
make_old_dir "zb-test.3456"

# Control: unknown prefix — must NOT be deleted.
make_old_dir "myapp-tmpwork.9999"

PASS=0
FAIL=0

assert_deleted() {
    local dir="$FAKE_TMP/$1"
    if [[ ! -d "$dir" ]]; then
        echo "  PASS: $1 was deleted"
        (( PASS++ )) || true
    else
        echo "  FAIL: $1 still exists (should have been deleted)"
        (( FAIL++ )) || true
    fi
}

assert_kept() {
    local dir="$FAKE_TMP/$1"
    if [[ -d "$dir" ]]; then
        echo "  PASS: $1 was kept"
        (( PASS++ )) || true
    else
        echo "  FAIL: $1 was deleted (should have been kept)"
        (( FAIL++ )) || true
    fi
}

# Run cleanup with the fake TMPDIR so we don't touch the real one.
TMPDIR="$FAKE_TMP" "$ZBUILD" cleanup --tmpdirs --apply --age-hours 0

assert_deleted "zb-applycheck-abc123"
assert_deleted "zbuild-test-stage.1234"
assert_deleted "zb-loop-iters.5678"
assert_deleted "zb-test-auto.9012"
assert_deleted "zb-test.3456"
assert_kept    "myapp-tmpwork.9999"

if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: $FAIL assertion(s) failed"
    exit 1
fi

echo "RESULT: all $PASS assertions passed"
