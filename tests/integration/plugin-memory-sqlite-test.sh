#!/usr/bin/env bash
# Integration Tests: plugins/tool/memory-sqlite/ — end-to-end roundtrip (issue #302)
# Covers: put/get/search roundtrip, namespace isolation, search --limit,
#         list/exists/clear lifecycle, schema persistence across reinit,
#         concurrent puts (atomic, no last-writer-wins overwrite of unrelated keys).
#
# 5-trial-per-keeper for #216 (memory-sqlite); KEEPERS §G mandate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/memory-sqlite"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-sqlite — integration: roundtrip + lifecycle (issue #302)"

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "SKIP: sqlite3 not available on this system" >&2
    exit 0
fi

setup_test_env "memory-sqlite-integ"

export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR"

# Use an isolated DB path so this test never touches the user's real memory.
export ZBUILD_MEMORY_DB="$TEST_TEMP_DIR/memory-sqlite-test.db"

# shellcheck disable=SC1090,SC1091
source "$PLUGIN_DIR/plugin.sh"

memory_backend_init || { echo "FATAL: memory_backend_init failed" >&2; exit 1; }

# ─── Test 1: capabilities advertisement ─────────────────────────────────────
print_test_section "1. capabilities: declares text_search, namespacing, persistence"
caps="$(memory_capabilities)"
for required in "text_search" "namespacing" "persistence"; do
    if grep -q "\"$required\"" <<< "$caps"; then
        assert_pass "capability '$required' declared"
    else
        assert_fail "capability '$required' declared" "got: $caps"
    fi
done

# ─── Test 2: put → get roundtrip ────────────────────────────────────────────
print_test_section "2. put → get roundtrip"
memory_put "rt-ns" "rt-key" "roundtrip-value"
result="$(memory_get "rt-ns" "rt-key")"
assert_eq "stored value is returned" "roundtrip-value" "$result"

# Values with single quotes (SQL injection sentinel)
memory_put "rt-ns" "quote-key" "value with 'single' quotes"
result="$(memory_get "rt-ns" "quote-key")"
assert_eq "value with single quotes preserved (SQL escape works)" \
    "value with 'single' quotes" "$result"

# Values with newlines
memory_put "rt-ns" "multi-key" $'line1\nline2\nline3'
result="$(memory_get "rt-ns" "multi-key")"
assert_eq "multi-line value preserved" $'line1\nline2\nline3' "$result"

# ─── Test 3: namespace isolation ────────────────────────────────────────────
print_test_section "3. namespace isolation"
memory_put "ns-a" "same-key" "value-a"
memory_put "ns-b" "same-key" "value-b"
ra="$(memory_get "ns-a" "same-key")"
rb="$(memory_get "ns-b" "same-key")"
assert_eq "ns-a returns its own value" "value-a" "$ra"
assert_eq "ns-b returns its own value" "value-b" "$rb"

# Searching one namespace doesn't return entries from another
memory_put "iso-a" "alpha" "isolated-content-aaa"
memory_put "iso-b" "alpha" "isolated-content-bbb"
search_a="$(memory_search "iso-a" "isolated-content")"
if grep -q "isolated-content-aaa" <<< "$search_a" \
   && ! grep -q "isolated-content-bbb" <<< "$search_a"; then
    assert_pass "search scoped to namespace"
else
    assert_fail "search scoped to namespace" "got: $search_a"
fi

# ─── Test 4: search with --limit ────────────────────────────────────────────
print_test_section "4. search --limit caps results"
memory_put "limit-ns" "k1" "limit-content-1"
memory_put "limit-ns" "k2" "limit-content-2"
memory_put "limit-ns" "k3" "limit-content-3"
limit_out="$(memory_search "limit-ns" "limit-content" --limit 2)"
hit_count="$(echo "$limit_out" | grep -c "limit-content" || true)"
assert_eq "search --limit 2 returns at most 2 hits" "2" "$hit_count"

# ─── Test 5: lifecycle (list / exists / clear) ──────────────────────────────
print_test_section "5. lifecycle: list_namespaces / namespace_exists / namespace_clear"

namespaces="$(memory_list_namespaces)"
for ns in rt-ns ns-a ns-b iso-a iso-b limit-ns; do
    if grep -Fxq "$ns" <<< "$namespaces"; then
        assert_pass "list_namespaces includes $ns"
    else
        assert_fail "list_namespaces includes $ns" "got: $namespaces"
    fi
done

if memory_namespace_exists "rt-ns"; then
    assert_pass "namespace_exists returns 0 for known ns"
else
    assert_fail "namespace_exists returns 0 for known ns" "exit code: $?"
fi

if ! memory_namespace_exists "nonexistent-ns-zzz"; then
    assert_pass "namespace_exists returns non-zero for unknown ns"
else
    assert_fail "namespace_exists returns non-zero for unknown ns" "exit code: 0"
fi

# Clear one namespace, verify entries gone, others untouched
memory_namespace_clear "rt-ns"
if [[ -z "$(memory_get "rt-ns" "rt-key" 2>/dev/null)" ]]; then
    assert_pass "namespace_clear removes entries in target ns"
else
    assert_fail "namespace_clear removes entries in target ns" \
        "rt-ns/rt-key still returns: $(memory_get "rt-ns" "rt-key")"
fi

result_a="$(memory_get "ns-a" "same-key")"
assert_eq "namespace_clear leaves other namespaces untouched" "value-a" "$result_a"

# ─── Test 6: schema persists across reinit ──────────────────────────────────
print_test_section "6. schema + data persist across reinit (durability)"
memory_put "persist-ns" "persist-key" "persist-value"

# Re-init should be idempotent and preserve data.
memory_backend_init
persist_result="$(memory_get "persist-ns" "persist-key")"
assert_eq "data survives backend_init re-call (idempotent)" "persist-value" "$persist_result"

# ─── Test 7: sequential puts overwrite cleanly (last-write-wins semantics) ──
print_test_section "7. sequential overwrite: last write wins on same (ns,key)"
memory_put "seq-ns" "k1" "first"
memory_put "seq-ns" "k1" "second"
memory_put "seq-ns" "k1" "third"
final="$(memory_get "seq-ns" "k1")"
assert_eq "INSERT OR REPLACE semantics: last write wins" "third" "$final"

# ─── Test 7b: concurrent puts to distinct keys — no lost writes (issue #303) ─
# Before the busy_timeout fix this test would fail intermittently because
# SQLITE_BUSY caused silent INSERT failures. With `-cmd ".timeout 5000"` set
# on every sqlite3 invocation, blocked writers wait + retry internally.
print_test_section "7b. concurrent puts to distinct keys: all writes durable (#303)"
CONCURRENT_N=20
for i in $(seq 1 "$CONCURRENT_N"); do
    memory_put "concur-ns" "key-$i" "value-$i" &
done
wait

missing=0
for i in $(seq 1 "$CONCURRENT_N"); do
    got="$(memory_get "concur-ns" "key-$i")"
    if [[ "$got" != "value-$i" ]]; then
        missing=$((missing + 1))
    fi
done
assert_eq "concurrent puts to ${CONCURRENT_N} distinct keys: all present (no SQLITE_BUSY drops)" "0" "$missing"

# ─── Test 7c: concurrent puts to same key — exactly one winner, no torn write ─
print_test_section "7c. concurrent puts to same key: one winner, no NULL/empty"
for i in $(seq 1 "$CONCURRENT_N"); do
    memory_put "race-ns" "shared" "writer-$i" &
done
wait

race_result="$(memory_get "race-ns" "shared")"
# A successful run is one where SOME writer-N value is present (not empty).
# A failed (pre-fix) run would frequently see an empty result or a missing row.
if [[ "$race_result" =~ ^writer-[0-9]+$ ]]; then
    assert_pass "same-key race produces a complete write (one writer wins)"
else
    assert_fail "same-key race produces a complete write (one writer wins)" \
        "memory left in non-winner state: '$race_result'"
fi

# ─── Test 8: schema-version unaware roundtrip with empty value ──────────────
print_test_section "8. edge cases"
memory_put "edge-ns" "empty-key" ""
empty_result="$(memory_get "edge-ns" "empty-key")"
assert_eq "empty value stores+retrieves as empty string" "" "$empty_result"

memory_put "edge-ns" "unicode-key" "héllo wörld 🚀"
uni_result="$(memory_get "edge-ns" "unicode-key")"
assert_eq "UTF-8 value preserved end-to-end" "héllo wörld 🚀" "$uni_result"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
