#!/usr/bin/env bash
# Integration Tests: plugins/tool/memory-ruflo/ — end-to-end roundtrip (issue #217)
# Covers: put/get/search roundtrip, namespace isolation, clear lifecycle,
#         list_namespaces, namespace_exists, concurrent puts, limit enforcement.
# All tests use a filesystem-backed mock ruflo (no real daemon required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/memory-ruflo"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-ruflo — integration: roundtrip + lifecycle (issue #217)"

setup_test_env "memory-ruflo-integ"

# Prevent project config from leaking into tests.
export ZBUILD_CONFIG_FILE="/dev/null"
export ZBUILD_PROJECT_ROOT="$TEST_TEMP_DIR/project"

# ─── Filesystem-backed mock ruflo ────────────────────────────────────────────
# Placed in $TEST_TEMP_DIR/bin/ so it shadows the real ruflo for the duration
# of this test suite.  The store lives at $MOCK_STORE_DIR; each namespace is a
# subdirectory, each key is a file inside that directory.
#
# CLI surface (flag-based, matching plugin.sh spec):
#   ruflo memory store   -k KEY --value VALUE -n NS --upsert --quiet
#   ruflo memory retrieve -k KEY -n NS --format json --quiet
#   ruflo memory search  -q QUERY -n NS -t TYPE -l LIMIT --format json --quiet
#   ruflo memory list    --format json --quiet -l LIMIT [-n NS]
#   ruflo memory delete  -k KEY -n NS -f --quiet
#
MOCK_STORE_DIR="$TEST_TEMP_DIR/ruflo-store"
mkdir -p "$MOCK_STORE_DIR"
export MOCK_STORE_DIR

cat > "$TEST_TEMP_DIR/bin/ruflo" << 'MOCK_EOF'
#!/usr/bin/env bash
# Integration mock ruflo — fully filesystem-backed for round-trip correctness.
# Uses atomic write (tmp+rename) for concurrent safety.

STORE="${MOCK_STORE_DIR:?MOCK_STORE_DIR must be set}"

subcmd="${1:-}"     # expected: "memory"
verb="${2:-}"       # store | retrieve | search | list | delete
shift 2 || true

# Parse flags from remaining args
_get_flag() {
    local flag="$1" prev=""
    shift
    for arg in "$@"; do
        [[ "$prev" == "$flag" ]] && { printf '%s' "$arg"; return 0; }
        prev="$arg"
    done
    return 1
}

case "$verb" in
    store)
        key="$(_get_flag -k "$@" || true)"
        value="$(_get_flag --value "$@" || true)"
        ns="$(_get_flag -n "$@" || true)"
        [[ -z "$key" || -z "$ns" ]] && { echo "mock ruflo store: missing -k or -n" >&2; exit 1; }
        ns_dir="$STORE/$ns"
        mkdir -p "$ns_dir"
        # Atomic write: write to tmp then rename so concurrent callers
        # never read a partial value.
        tmp_file="$(mktemp "$ns_dir/.put.XXXXXX")"
        printf '%s' "$value" > "$tmp_file"
        mv -f "$tmp_file" "$ns_dir/$key"
        exit 0
        ;;
    retrieve)
        key="$(_get_flag -k "$@" || true)"
        ns="$(_get_flag -n "$@" || true)"
        [[ -z "$key" || -z "$ns" ]] && { echo "mock ruflo retrieve: missing -k or -n" >&2; exit 1; }
        f="$STORE/$ns/$key"
        if [[ -f "$f" ]]; then
            content="$(cat "$f")"
            content="${content//\\/\\\\}"
            content="${content//\"/\\\"}"
            content="${content//$'\n'/\\n}"
            printf '{"content":"%s"}\n' "$content"
            exit 0
        else
            exit 1
        fi
        ;;
    search)
        query="$(_get_flag -q "$@" || true)"
        ns="$(_get_flag -n "$@" || true)"
        limit="$(_get_flag -l "$@" || true)"
        [[ -z "$limit" ]] && limit=10
        [[ -z "$ns" ]] && { printf '{"results":[]}\n'; exit 0; }
        dir="$STORE/$ns"
        if [[ ! -d "$dir" ]]; then
            printf '{"results":[]}\n'
            exit 0
        fi
        results='{"results":['
        first=1
        count=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            k="$(basename "$f")"
            v="$(cat "$f" 2>/dev/null || true)"
            if printf '%s' "$k$v" | grep -qF "$query" 2>/dev/null; then
                [[ $first -eq 0 ]] && results+=','
                preview="${v:0:50}"
                preview="${preview//\\/\\\\}"
                preview="${preview//\"/\\\"}"
                results+="{\"key\":\"$k\",\"preview\":\"$preview\"}"
                first=0
                count=$((count + 1))
                [[ $count -ge $limit ]] && break
            fi
        done < <(find "$dir" -maxdepth 1 -type f -not -name '.*' 2>/dev/null | sort)
        results+=']}'
        printf '%s\n' "$results"
        exit 0
        ;;
    list)
        ns="$(_get_flag -n "$@" || true)"
        limit="$(_get_flag -l "$@" || true)"
        [[ -z "$limit" ]] && limit=10000
        if [[ -n "$ns" ]]; then
            dir="$STORE/$ns"
            if [[ ! -d "$dir" ]]; then
                printf '[]\n'; exit 0
            fi
            result='['
            first=1
            count=0
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                k="$(basename "$f")"
                [[ $first -eq 0 ]] && result+=','
                result+="{\"namespace\":\"$ns\",\"key\":\"$k\"}"
                first=0
                count=$((count + 1))
                [[ $count -ge $limit ]] && break
            done < <(find "$dir" -maxdepth 1 -type f -not -name '.*' 2>/dev/null | sort)
            result+=']'
            printf '%s\n' "$result"
        else
            # List ALL entries across all namespaces
            result='['
            first=1
            count=0
            if [[ -d "$STORE" ]]; then
                while IFS= read -r ns_dir; do
                    [[ -z "$ns_dir" ]] && continue
                    ns_name="$(basename "$ns_dir")"
                    while IFS= read -r f; do
                        [[ -z "$f" ]] && continue
                        k="$(basename "$f")"
                        [[ $first -eq 0 ]] && result+=','
                        result+="{\"namespace\":\"$ns_name\",\"key\":\"$k\"}"
                        first=0
                        count=$((count + 1))
                        [[ $count -ge $limit ]] && break 2
                    done < <(find "$ns_dir" -maxdepth 1 -type f -not -name '.*' 2>/dev/null | sort)
                done < <(find "$STORE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
            fi
            result+=']'
            printf '%s\n' "$result"
        fi
        exit 0
        ;;
    delete)
        key="$(_get_flag -k "$@" || true)"
        ns="$(_get_flag -n "$@" || true)"
        [[ -z "$key" || -z "$ns" ]] && { echo "mock ruflo delete: missing -k or -n" >&2; exit 1; }
        f="$STORE/$ns/$key"
        [[ -f "$f" ]] && rm -f "$f"
        exit 0
        ;;
    *)
        printf 'mock ruflo: unknown verb: %s\n' "$verb" >&2
        exit 1
        ;;
esac
MOCK_EOF
chmod +x "$TEST_TEMP_DIR/bin/ruflo"

# Source the plugin under test.
# shellcheck disable=SC1090
source "$PLUGIN_DIR/plugin.sh"

# Initialise the backend; if this fails the plugin is not ready and the suite
# should abort to avoid cascading false-positives.
memory_backend_init || {
    printf 'FATAL: memory_backend_init failed — plugin not ready\n' >&2
    exit 1
}

# ─── Test 1: put-then-get round-trip — stored value is returned ───────────────
print_test_section "1. put → get round-trip: stored value is returned"

memory_put "rt-ns" "rt-key" "roundtrip-value"
rt_result="$(memory_get "rt-ns" "rt-key")"
assert_eq "put→get round-trip: correct value returned" "roundtrip-value" "$rt_result"

# ─── Test 2: put-then-search — entry appears in search results ─────────────────
print_test_section "2. put → search: entry appears in search results"

memory_put "search-rt-ns" "search-key-001" "searchable-content"
search_rt_out="$(memory_search "search-rt-ns" "searchable")"

assert_contains "put→search: key present in results" "$search_rt_out" "search-key-001"
assert_contains "put→search: value present in results" "$search_rt_out" "searchable-content"

# Verify tab-separated format is preserved end-to-end.
if printf '%s' "$search_rt_out" | grep -q $'search-key-001\tsearchable-content'; then
    assert_pass "put→search: output is tab-separated key<TAB>value"
else
    assert_fail "put→search: output is tab-separated key<TAB>value" \
        "got: $(printf '%s' "$search_rt_out" | cat -A)"
fi

# ─── Test 3: search with --limit N — results capped at N ──────────────────────
print_test_section "3. search --limit N: results capped at N"

memory_put "limit-rt-ns" "item-aaa" "content-aaa"
memory_put "limit-rt-ns" "item-bbb" "content-bbb"
memory_put "limit-rt-ns" "item-ccc" "content-ccc"
memory_put "limit-rt-ns" "item-ddd" "content-ddd"

limit_out="$(memory_search "limit-rt-ns" "item" --limit 2)"
limit_line_count="$(printf '%s\n' "$limit_out" | grep -c 'item' 2>/dev/null || echo 0)"

if [[ "$limit_line_count" -le 2 ]]; then
    assert_pass "search --limit 2: at most 2 results returned (got $limit_line_count)"
else
    assert_fail "search --limit 2: at most 2 results returned" \
        "got $limit_line_count results"
fi

# ─── Test 4: namespace isolation — put in ns-A not visible in ns-B ────────────
print_test_section "4. namespace isolation: put in ns-A not visible in ns-B"

memory_put "iso-ns-a" "shared-key" "value-from-a"
memory_put "iso-ns-b" "shared-key" "value-from-b"

result_a="$(memory_get "iso-ns-a" "shared-key")"
result_b="$(memory_get "iso-ns-b" "shared-key")"

assert_eq "ns-A: correct value returned" "value-from-a" "$result_a"
assert_eq "ns-B: correct value returned" "value-from-b" "$result_b"

# Confirm search in ns-A does not bleed into ns-B.
search_a="$(memory_search "iso-ns-a" "value-from")"
if ! printf '%s\n' "$search_a" | grep -qF "value-from-b"; then
    assert_pass "namespace isolation: ns-A search does not return ns-B values"
else
    assert_fail "namespace isolation: ns-A search does not return ns-B values" \
        "ns-B value leaked into ns-A search: $search_a"
fi

# ─── Test 5: namespace_clear removes all entries from namespace ────────────────
print_test_section "5. namespace_clear: removes all entries; namespace_exists returns 1 after"

memory_put "clear-rt-ns" "k1" "v1"
memory_put "clear-rt-ns" "k2" "v2"
memory_put "clear-rt-ns" "k3" "v3"

set +e
memory_namespace_clear "clear-rt-ns"
clear_rc=$?
set -e

assert_exit_code "namespace_clear exits 0" "0" "$clear_rc"

# All keys must be gone.
cleared_k1="$(memory_get "clear-rt-ns" "k1")"
cleared_k2="$(memory_get "clear-rt-ns" "k2")"
cleared_k3="$(memory_get "clear-rt-ns" "k3")"

if [[ -z "$cleared_k1" && -z "$cleared_k2" && -z "$cleared_k3" ]]; then
    assert_pass "namespace_clear: all three keys are gone"
else
    assert_fail "namespace_clear: all three keys are gone" \
        "k1='$cleared_k1' k2='$cleared_k2' k3='$cleared_k3'"
fi

# After clear, namespace_exists should return 1
set +e
memory_namespace_exists "clear-rt-ns"
post_clear_exists_rc=$?
set -e
assert_exit_code "namespace_exists exits 1 after clear" "1" "$post_clear_exists_rc"

# ─── Test 6: memory_list_namespaces shows created namespaces ──────────────────
print_test_section "6. memory_list_namespaces: lists namespaces written via put"

memory_put "list-ns-alpha" "k" "v"
memory_put "list-ns-beta"  "k" "v"
memory_put "list-ns-gamma" "k" "v"

ns_list="$(memory_list_namespaces)"

assert_contains "list_namespaces: list-ns-alpha present" "$ns_list" "list-ns-alpha"
assert_contains "list_namespaces: list-ns-beta present"  "$ns_list" "list-ns-beta"
assert_contains "list_namespaces: list-ns-gamma present" "$ns_list" "list-ns-gamma"

# Each namespace name must appear on its own line, not fused with siblings.
alpha_lines="$(printf '%s\n' "$ns_list" | grep -c '^list-ns-alpha$' 2>/dev/null || echo 0)"
assert_eq "list_namespaces: list-ns-alpha is on its own line" "1" "$alpha_lines"

# ─── Test 7: namespace_exists true after put, false after clear ───────────────
print_test_section "7. namespace_exists: true after put, false after clear"

memory_put "lifecycle-ns" "k" "v"

set +e
memory_namespace_exists "lifecycle-ns"
exists_after_put_rc=$?
set -e

assert_exit_code "namespace_exists exits 0 after put" "0" "$exists_after_put_rc"

memory_namespace_clear "lifecycle-ns"

set +e
memory_namespace_exists "lifecycle-ns"
exists_after_clear_rc=$?
set -e

assert_exit_code "namespace_exists exits 1 after clear" "1" "$exists_after_clear_rc"

# ─── Test 8: Concurrent puts to same namespace — no corruption ────────────────
# Two background subshells write different keys to the same namespace using the
# mock ruflo's atomic write (tmp+rename).  After both complete, both values must
# be retrievable and intact.
print_test_section "8. Concurrent puts: no corruption under parallel writers"

CONC_NS="concurrent-ns-$$"

# Subshell helper: source the plugin and mock, then write one key.
_conc_put() {
    local ns="$1" key="$2" val="$3"
    (
        export MOCK_STORE_DIR="$MOCK_STORE_DIR"
        export PATH="$TEST_TEMP_DIR/bin:$PATH"
        # shellcheck disable=SC1090
        source "$REPO_ROOT/scripts/lib/helpers.sh"
        # shellcheck disable=SC1090
        source "$PLUGIN_DIR/plugin.sh"
        memory_backend_init >/dev/null 2>&1 || true
        memory_put "$ns" "$key" "$val"
    )
}

_conc_put "$CONC_NS" "writer-a" "payload-a" &
PID_A=$!
_conc_put "$CONC_NS" "writer-b" "payload-b" &
PID_B=$!

wait "$PID_A" 2>/dev/null || true
wait "$PID_B" 2>/dev/null || true

# Both keys must be readable and correct.
conc_a="$(memory_get "$CONC_NS" "writer-a")"
conc_b="$(memory_get "$CONC_NS" "writer-b")"

assert_eq "concurrent puts: writer-a value intact" "payload-a" "$conc_a"
assert_eq "concurrent puts: writer-b value intact" "payload-b" "$conc_b"

# Verify no leftover tmp files from the atomic writes.
# The scoped namespace in the store is prefixed, so we glob for .put.* anywhere
scoped_store_dir="$(find "$MOCK_STORE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -F "$CONC_NS" || true)"
if [[ -n "$scoped_store_dir" ]] && find "$scoped_store_dir" -maxdepth 1 -name '.put.*' 2>/dev/null | grep -q .; then
    assert_fail "concurrent puts: no leftover .put.* tmp files" \
        "orphaned tmp file(s) found under $scoped_store_dir"
else
    assert_pass "concurrent puts: no leftover .put.* tmp files"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
