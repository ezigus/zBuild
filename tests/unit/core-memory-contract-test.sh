#!/usr/bin/env bash
# Tests: core/memory/contract.sh — memory backend contract (issue #215)
# TDD order: written BEFORE contract.sh exists; run to verify failures, then
# implement to make them pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/memory/contract — unit tests (ADR-011, issue #215)"

setup_test_env "core-memory-contract-unit"

# Prevent project config from leaking into tests.
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# ─── Create a mock memory backend plugin ─────────────────────────────────────
MOCK_PLUGIN_DIR="$TEST_TEMP_DIR/plugins/tool/mock-memory"
MOCK_STORE_DIR="$TEST_TEMP_DIR/mock-mem-store"
mkdir -p "$MOCK_PLUGIN_DIR"
mkdir -p "$MOCK_STORE_DIR"

cat > "$MOCK_PLUGIN_DIR/manifest.yaml" <<'MANIFEST_EOF'
id: mock-memory
name: Mock Memory Backend
kind: tool
version: 0.0.1
provides:
  role: memory-backend
  alias: mock-memory
  capabilities: [text_search, namespacing, persistence]
MANIFEST_EOF

cat > "$MOCK_PLUGIN_DIR/plugin.sh" <<PLUGIN_EOF
#!/usr/bin/env bash
# Mock memory backend — stores key/value as files under \$MOCK_STORE_DIR
[[ -n "\${_ZBUILD_MOCK_MEMORY_LOADED:-}" ]] && return 0
_ZBUILD_MOCK_MEMORY_LOADED=1

MOCK_STORE_DIR="\${MOCK_STORE_DIR:-${MOCK_STORE_DIR}}"

memory_capabilities() {
    printf '["text_search","namespacing","persistence"]\n'
}

memory_backend_init() {
    mkdir -p "\$MOCK_STORE_DIR"
    return 0
}

memory_put() {
    local ns="\$1" key="\$2" value="\$3"
    [[ -z "\$ns" || -z "\$key" ]] && return 2
    mkdir -p "\$MOCK_STORE_DIR/\$ns"
    printf '%s' "\$value" > "\$MOCK_STORE_DIR/\$ns/\$key"
    return 0
}

memory_get() {
    local ns="\$1" key="\$2"
    [[ -z "\$ns" || -z "\$key" ]] && return 2
    local f="\$MOCK_STORE_DIR/\$ns/\$key"
    if [[ -f "\$f" ]]; then
        cat "\$f"
    fi
    return 0
}

memory_search() {
    local ns="\$1" query="\$2"
    local limit=""
    if [[ "\${3:-}" == "--limit" && -n "\${4:-}" ]]; then
        limit="\$4"
    fi
    local dir="\$MOCK_STORE_DIR/\$ns"
    [[ ! -d "\$dir" ]] && return 0
    local count=0
    while IFS= read -r f; do
        local key val
        key="\$(basename "\$f")"
        val="\$(cat "\$f" 2>/dev/null || true)"
        # Escape embedded newlines in value
        val="\${val//$'\n'/\\\\n}"
        if printf '%s' "\$key\$val" | grep -qF "\$query" 2>/dev/null; then
            printf '%s\t%s\n' "\$key" "\$val"
            count=\$((count + 1))
            if [[ -n "\$limit" && "\$count" -ge "\$limit" ]]; then
                break
            fi
        fi
    done < <(find "\$dir" -maxdepth 1 -type f 2>/dev/null | sort)
    return 0
}

memory_list_namespaces() {
    local dir="\$MOCK_STORE_DIR"
    [[ ! -d "\$dir" ]] && return 0
    find "\$dir" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort
    return 0
}

memory_namespace_exists() {
    local ns="\$1"
    [[ -d "\$MOCK_STORE_DIR/\$ns" ]] && return 0
    return 1
}

memory_namespace_clear() {
    local ns="\$1"
    local dir="\$MOCK_STORE_DIR/\$ns"
    if [[ -d "\$dir" ]]; then
        rm -rf "\$dir"
    fi
    return 0
}
PLUGIN_EOF
chmod +x "$MOCK_PLUGIN_DIR/plugin.sh"

# Override ZBUILD_PLUGINS_ROOT to point at our mock
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"

# Force the mock backend
export ZBUILD_MEMORY_BACKEND="mock-memory"

# Source dependencies
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# Source the contract layer under test
# shellcheck source=../../core/memory/contract.sh
source "$REPO_ROOT/core/memory/contract.sh"

# Initialize the backend
memory_init

# ─── Test 1: All 6 contract functions are defined after source + init ──────────
print_test_section "1. Required contract functions are defined after source and init"

for fn in memory_put memory_get memory_search memory_list_namespaces memory_namespace_exists memory_namespace_clear; do
    if declare -F "$fn" >/dev/null 2>&1; then
        assert_pass "function $fn is defined"
    else
        assert_fail "function $fn is defined" "declare -F $fn returned nothing"
    fi
done

# ─── Test 2: memory_has_capability "text_search" → exit 0 ────────────────────
print_test_section "2. memory_has_capability text_search returns 0"

set +e
memory_has_capability "text_search"
cap_rc=$?
set -e

assert_exit_code "memory_has_capability text_search returns 0" "0" "$cap_rc"

# ─── Test 3: memory_has_capability "vector_search" → exit 1 ──────────────────
print_test_section "3. memory_has_capability vector_search returns 1 (not in mock)"

set +e
memory_has_capability "vector_search"
cap_rc=$?
set -e

assert_exit_code "memory_has_capability vector_search returns 1" "1" "$cap_rc"

# ─── Test 4: memory_put with empty key → exit non-zero ───────────────────────
print_test_section "4. memory_put with empty key exits non-zero"

set +e
memory_put "test-ns" "" "some-value"
put_rc=$?
set -e

if [[ "$put_rc" -ne 0 ]]; then
    assert_pass "memory_put with empty key exits non-zero (rc=$put_rc)"
else
    assert_fail "memory_put with empty key exits non-zero" "got rc=0"
fi

# ─── Test 5: memory_get for missing key → exit 0, empty stdout ────────────────
# MUST be safe under set -e (the spec says exit 0 always for cache miss)
print_test_section "5. memory_get for missing key exits 0 and produces empty stdout (set -e safe)"

# Run inside a subshell that has set -e to prove safety
result="$(
    set -e
    memory_get "nonexistent-ns" "nonexistent-key"
)"
get_rc=$?

assert_exit_code "memory_get missing key exits 0" "0" "$get_rc"

if [[ -z "$result" ]]; then
    assert_pass "memory_get missing key produces empty stdout"
else
    assert_fail "memory_get missing key produces empty stdout" "got: $result"
fi

# ─── Test 6: memory_has_capability helper is defined ─────────────────────────
print_test_section "6. memory_has_capability function is defined"

if declare -F "memory_has_capability" >/dev/null 2>&1; then
    assert_pass "memory_has_capability is defined"
else
    assert_fail "memory_has_capability is defined" "function not found"
fi

# ─── Test 7: memory_put with valid args exits 0 ───────────────────────────────
print_test_section "7. memory_put with valid args exits 0"

set +e
memory_put "unit-test-ns" "key1" "value1"
put_rc=$?
set -e

assert_exit_code "memory_put with valid args exits 0" "0" "$put_rc"

# ─── Test 8: memory_init is idempotent (double call) ─────────────────────────
print_test_section "8. memory_init is idempotent"

set +e
memory_init
init_rc=$?
set -e

assert_exit_code "second memory_init call returns 0" "0" "$init_rc"

# ─── Test 9: memory_has_capability "namespacing" → exit 0 ────────────────────
print_test_section "9. memory_has_capability namespacing returns 0"

set +e
memory_has_capability "namespacing"
cap_rc=$?
set -e

assert_exit_code "memory_has_capability namespacing returns 0" "0" "$cap_rc"

# ─── Test 10: memory_put with empty namespace → exit non-zero ─────────────────
print_test_section "10. memory_put with empty namespace exits non-zero"

set +e
memory_put "" "some-key" "some-value"
put_rc=$?
set -e

if [[ "$put_rc" -ne 0 ]]; then
    assert_pass "memory_put with empty namespace exits non-zero (rc=$put_rc)"
else
    assert_fail "memory_put with empty namespace exits non-zero" "got rc=0"
fi

# ─── Test 11: _ZBUILD_MEMORY_INITIALIZED is set after memory_init ─────────────
print_test_section "11. _ZBUILD_MEMORY_INITIALIZED is set to 1 after init"

if [[ "${_ZBUILD_MEMORY_INITIALIZED:-0}" -eq 1 ]]; then
    assert_pass "_ZBUILD_MEMORY_INITIALIZED is 1 after memory_init"
else
    assert_fail "_ZBUILD_MEMORY_INITIALIZED is 1 after memory_init" \
        "got: ${_ZBUILD_MEMORY_INITIALIZED:-unset}"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
