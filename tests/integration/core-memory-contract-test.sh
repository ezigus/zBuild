#!/usr/bin/env bash
# Tests: core/memory/contract.sh — integration tests (issue #215)
# Uses the mock backend to exercise full roundtrip, namespace isolation,
# search, and lifecycle operations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/memory/contract — integration tests (ADR-011, issue #215)"

setup_test_env "core-memory-contract-integration"

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

export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_MEMORY_BACKEND="mock-memory"

# Source dependencies
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/config/config.sh
source "$REPO_ROOT/core/config/config.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/memory/contract.sh
source "$REPO_ROOT/core/memory/contract.sh"

memory_init

# ─── Test 1: put → get basic roundtrip ───────────────────────────────────────
print_test_section "1. put → get basic roundtrip"

memory_put "ns-basic" "hello" "world"
result="$(memory_get "ns-basic" "hello")"
assert_eq "get returns stored value" "world" "$result"

# ─── Test 2: roundtrip with spaces and punctuation ───────────────────────────
print_test_section "2. roundtrip with spaces and punctuation in value"

memory_put "ns-basic" "complex-key" "value with spaces & punctuation!"
result="$(memory_get "ns-basic" "complex-key")"
assert_eq "get returns value with spaces and punctuation" "value with spaces & punctuation!" "$result"

# ─── Test 3: overwrite existing key ──────────────────────────────────────────
print_test_section "3. overwrite existing key"

memory_put "ns-basic" "overwrite-me" "original"
memory_put "ns-basic" "overwrite-me" "updated"
result="$(memory_get "ns-basic" "overwrite-me")"
assert_eq "overwrite: get returns updated value" "updated" "$result"

# ─── Test 4: namespace isolation (ns-A vs ns-B) ───────────────────────────────
print_test_section "4. namespace isolation"

memory_put "ns-A" "shared-key" "value-from-A"
memory_put "ns-B" "shared-key" "value-from-B"

result_a="$(memory_get "ns-A" "shared-key")"
result_b="$(memory_get "ns-B" "shared-key")"

assert_eq "ns-A returns its own value" "value-from-A" "$result_a"
assert_eq "ns-B returns its own value" "value-from-B" "$result_b"

# ─── Test 5: namespace_exists returns 0 for present namespace ─────────────────
print_test_section "5. namespace_exists returns 0 for present namespace"

memory_put "ns-exists" "k" "v"
set +e
memory_namespace_exists "ns-exists"
exists_rc=$?
set -e
assert_exit_code "namespace_exists returns 0 for ns-exists" "0" "$exists_rc"

# ─── Test 6: namespace_exists returns 1 for absent namespace ─────────────────
print_test_section "6. namespace_exists returns 1 for absent namespace"

set +e
memory_namespace_exists "ns-does-not-exist-$$"
absent_rc=$?
set -e
assert_exit_code "namespace_exists returns 1 for absent namespace" "1" "$absent_rc"

# ─── Test 7: namespace_clear removes all keys ────────────────────────────────
print_test_section "7. namespace_clear removes all keys"

memory_put "ns-clear" "k1" "v1"
memory_put "ns-clear" "k2" "v2"
memory_namespace_clear "ns-clear"

result_k1="$(memory_get "ns-clear" "k1")"
result_k2="$(memory_get "ns-clear" "k2")"

if [[ -z "$result_k1" && -z "$result_k2" ]]; then
    assert_pass "namespace_clear removes all keys"
else
    assert_fail "namespace_clear removes all keys" "k1='$result_k1' k2='$result_k2'"
fi

# ─── Test 8: namespace_clear is idempotent ────────────────────────────────────
print_test_section "8. namespace_clear is idempotent"

set +e
memory_namespace_clear "ns-clear"
clear_rc=$?
set -e
assert_exit_code "second namespace_clear exits 0 (idempotent)" "0" "$clear_rc"

# ─── Test 9: namespace_clear does not affect sibling namespace ───────────────
print_test_section "9. namespace_clear does not affect sibling namespace"

memory_put "ns-sibling-A" "key" "stay"
memory_put "ns-sibling-B" "key" "also-stay"
memory_namespace_clear "ns-sibling-A"

result_b="$(memory_get "ns-sibling-B" "key")"
assert_eq "sibling namespace unaffected after clear" "also-stay" "$result_b"

# ─── Test 10: search returns matching entries ─────────────────────────────────
print_test_section "10. search returns matching entries"

memory_put "ns-search" "apple-key" "apple fruit"
memory_put "ns-search" "banana-key" "banana fruit"
memory_put "ns-search" "cherry-key" "cherry fruit"

search_out="$(memory_search "ns-search" "banana")"

assert_contains "search returns matching entry (banana-key)" "$search_out" "banana-key"
assert_contains "search returns matching entry (banana fruit)" "$search_out" "banana fruit"

# ─── Test 11: search does not return non-matching entries ────────────────────
print_test_section "11. search does not return non-matching entries"

if ! printf '%s' "$search_out" | grep -qF "apple"; then
    assert_pass "search omits non-matching entry (apple)"
else
    assert_fail "search omits non-matching entry (apple)" "apple appeared in: $search_out"
fi

# ─── Test 12: search in empty namespace exits 0 with empty output ─────────────
print_test_section "12. search in empty namespace exits 0, empty output"

search_empty="$(
    set -e
    memory_search "ns-empty-$$" "anything"
)"
search_empty_rc=$?

assert_exit_code "search in empty ns exits 0" "0" "$search_empty_rc"

if [[ -z "$search_empty" ]]; then
    assert_pass "search in empty ns produces empty output"
else
    assert_fail "search in empty ns produces empty output" "got: $search_empty"
fi

# ─── Test 13: list_namespaces includes all written namespaces ────────────────
print_test_section "13. list_namespaces includes all written namespaces"

memory_put "ns-list-alpha" "k" "v"
memory_put "ns-list-beta" "k" "v"
memory_put "ns-list-gamma" "k" "v"

ns_list="$(memory_list_namespaces)"

assert_contains "list_namespaces includes ns-list-alpha" "$ns_list" "ns-list-alpha"
assert_contains "list_namespaces includes ns-list-beta" "$ns_list" "ns-list-beta"
assert_contains "list_namespaces includes ns-list-gamma" "$ns_list" "ns-list-gamma"

# ─── Test 14: list_namespaces exits 0 ────────────────────────────────────────
print_test_section "14. list_namespaces exits 0"

set +e
memory_list_namespaces > /dev/null
list_rc=$?
set -e
assert_exit_code "list_namespaces exits 0" "0" "$list_rc"

# ─── Test 15: memory_get for missing key is set -e safe ──────────────────────
print_test_section "15. memory_get for missing key is safe under set -e"

was_safe=true
(
    set -e
    memory_get "ns-safety-$$" "nonexistent-key-$$"
) || was_safe=false

if $was_safe; then
    assert_pass "memory_get missing key does not abort under set -e"
else
    assert_fail "memory_get missing key does not abort under set -e" \
        "subshell exited non-zero"
fi

# ─── Test 16: memory_search is safe under set -e ─────────────────────────────
print_test_section "16. memory_search is safe under set -e"

was_safe=true
(
    set -e
    memory_search "ns-safety-$$" "no-match-query"
) || was_safe=false

if $was_safe; then
    assert_pass "memory_search no-match does not abort under set -e"
else
    assert_fail "memory_search no-match does not abort under set -e" \
        "subshell exited non-zero"
fi

# ─── Test 17: memory_list_namespaces is safe under set -e ────────────────────
print_test_section "17. memory_list_namespaces is safe under set -e"

was_safe=true
(
    set -e
    memory_list_namespaces > /dev/null
) || was_safe=false

if $was_safe; then
    assert_pass "memory_list_namespaces does not abort under set -e"
else
    assert_fail "memory_list_namespaces does not abort under set -e" \
        "subshell exited non-zero"
fi

# ─── Test 18: search output format is tab-separated key\tvalue ───────────────
print_test_section "18. search output format is tab-separated key<TAB>value"

memory_put "ns-fmt" "fmt-key" "fmt-value"
fmt_out="$(memory_search "ns-fmt" "fmt")"

# Should contain a tab between key and value
if printf '%s' "$fmt_out" | grep -qP 'fmt-key\tfmt-value' 2>/dev/null || \
   printf '%s' "$fmt_out" | grep -q $'fmt-key\tfmt-value'; then
    assert_pass "search output is tab-separated key<TAB>value"
else
    assert_fail "search output is tab-separated key<TAB>value" \
        "got: $(printf '%s' "$fmt_out" | cat -A)"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
