#!/usr/bin/env bash
# Tests: plugins/tool/memory-sqlite/plugin.sh — rc=2 on unrecoverable init paths (issue #382)
# ADR-001 contract: rc=0 success, rc=1 soft/retryable, rc=2 hard/unrecoverable.
# memory_backend_init must return rc=2 when the backend cannot possibly succeed:
#   - sqlite3 binary missing (no amount of retrying helps)
#   - schema init fails (DB corruption, disk full, permission error)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-sqlite — rc=2 on unrecoverable init paths (ADR-001, issue #382)"

setup_test_env "plugin-memory-sqlite-rc"

export ZBUILD_CONFIG_FILE="/dev/null"

# ─── Test 1: memory_backend_init returns rc=2 when sqlite3 is absent ─────────
print_test_section "1. memory_backend_init returns rc=2 when sqlite3 is not in PATH"

(
    # Reload the plugin in a clean subshell to avoid guard interference
    unset _ZBUILD_MEMORY_SQLITE_LOADED

    # Point DB at a temp dir we control
    export ZBUILD_MEMORY_DB="$TEST_TEMP_DIR/test-rc2-absent.db"

    # Shadow sqlite3 with a stub that simulates binary-not-found:
    # PATH manipulation is the standard approach for this pattern.
    local_bin="$TEST_TEMP_DIR/bin-absent"
    mkdir -p "$local_bin"
    # Deliberately do NOT place sqlite3 in local_bin
    # Remove sqlite3 from PATH entirely for this subshell
    export PATH="$local_bin"

    # shellcheck source=../../plugins/tool/memory-sqlite/plugin.sh
    source "$REPO_ROOT/plugins/tool/memory-sqlite/plugin.sh"

    set +e
    memory_backend_init
    rc=$?
    set -e

    if [[ "$rc" -eq 2 ]]; then
        echo "PASS: memory_backend_init returned rc=$rc (expected 2)"
        exit 0
    else
        echo "FAIL: memory_backend_init returned rc=$rc (expected 2)" >&2
        exit 1
    fi
) 2>/dev/null
subshell_rc=$?

if [[ "$subshell_rc" -eq 0 ]]; then
    assert_pass "memory_backend_init rc=2 when sqlite3 absent"
else
    assert_fail "memory_backend_init rc=2 when sqlite3 absent" \
        "subshell exited $subshell_rc — see test output above"
fi

# ─── Test 2: memory_backend_init returns rc=2 when DB path is unwritable ─────
print_test_section "2. memory_backend_init returns rc=2 when DB path is unwritable (schema init fails)"

(
    unset _ZBUILD_MEMORY_SQLITE_LOADED

    # Point DB at a path inside a read-only directory so sqlite3 can't create it
    local_bin="$TEST_TEMP_DIR/bin-schema-fail"
    mkdir -p "$local_bin"

    # Make a stub sqlite3 that always exits non-zero to simulate schema failure
    cat > "$local_bin/sqlite3" <<'SH'
#!/usr/bin/env bash
# Stub: simulate schema init failure (rc=1 from sqlite3 itself)
echo "error: disk I/O error" >&2
exit 1
SH
    chmod +x "$local_bin/sqlite3"

    export PATH="$local_bin:$PATH"
    export ZBUILD_MEMORY_DB="$TEST_TEMP_DIR/test-rc2-schema.db"

    # shellcheck source=../../plugins/tool/memory-sqlite/plugin.sh
    source "$REPO_ROOT/plugins/tool/memory-sqlite/plugin.sh"

    set +e
    memory_backend_init 2>/dev/null
    rc=$?
    set -e

    if [[ "$rc" -eq 2 ]]; then
        echo "PASS: memory_backend_init returned rc=$rc (expected 2)"
        exit 0
    else
        echo "FAIL: memory_backend_init returned rc=$rc (expected 2)" >&2
        exit 1
    fi
)
subshell_rc=$?

if [[ "$subshell_rc" -eq 0 ]]; then
    assert_pass "memory_backend_init rc=2 on schema init failure"
else
    assert_fail "memory_backend_init rc=2 on schema init failure" \
        "subshell exited $subshell_rc — schema failure path returned wrong rc"
fi

# ─── Test 3: memory_backend_init returns rc=0 on success ─────────────────────
print_test_section "3. memory_backend_init returns rc=0 on success (sanity check)"

if ! command -v sqlite3 >/dev/null 2>&1; then
    assert_pass "memory_backend_init rc=0 on success (SKIP: sqlite3 not available in test env)"
else
    (
        unset _ZBUILD_MEMORY_SQLITE_LOADED
        export ZBUILD_MEMORY_DB="$TEST_TEMP_DIR/test-rc0-success.db"

        # shellcheck source=../../plugins/tool/memory-sqlite/plugin.sh
        source "$REPO_ROOT/plugins/tool/memory-sqlite/plugin.sh"

        set +e
        memory_backend_init 2>/dev/null
        rc=$?
        set -e

        if [[ "$rc" -eq 0 ]]; then
            echo "PASS: memory_backend_init returned rc=$rc (expected 0)"
            exit 0
        else
            echo "FAIL: memory_backend_init returned rc=$rc (expected 0)" >&2
            exit 1
        fi
    )
    subshell_rc=$?

    if [[ "$subshell_rc" -eq 0 ]]; then
        assert_pass "memory_backend_init rc=0 on success"
    else
        assert_fail "memory_backend_init rc=0 on success" \
            "subshell exited $subshell_rc"
    fi
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
