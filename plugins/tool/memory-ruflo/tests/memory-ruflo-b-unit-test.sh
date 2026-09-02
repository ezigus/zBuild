#!/usr/bin/env bash
# Tests: plugins/tool/memory-ruflo/ — unit-level tests Part B (issue #217)
# Covers (tests 10-18): search, list_namespaces, namespace_exists/clear,
#         and ruflo failure propagation.
# All tests mock the `ruflo` binary via PATH-shadow using $TEST_TEMP_DIR/bin/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/memory-ruflo"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-ruflo — unit Part B: search + namespaces + failure (tests 10-18)"

setup_test_env "memory-ruflo-unit-b"

# ─── Shared mock-store used by the ruflo mock ─────────────────────────────────
MOCK_STORE_DIR="$TEST_TEMP_DIR/store"
mkdir -p "$MOCK_STORE_DIR"
export MOCK_STORE_DIR

# ─── Install mock ruflo in the PATH-shadow bin dir ───────────────────────────
cat > "$TEST_TEMP_DIR/bin/ruflo" << 'MOCK_EOF'
#!/usr/bin/env bash
STORE="${MOCK_STORE_DIR:?MOCK_STORE_DIR must be set}"
subcmd="${1:-}"
verb="${2:-}"
shift 2 || true

_get_flag() {
    local flag="$1" prev=""
    shift
    for arg in "$@"; do
        [[ "$prev" == "$flag" ]] && { printf '%s' "$arg"; return 0; }
        prev="$arg"
    done
    return 1
}

if [[ -n "${RUFLO_FAIL_NEXT:-}" && "$verb" == "$RUFLO_FAIL_NEXT" ]]; then
    printf 'mock ruflo: injected failure for %s\n' "$verb" >&2
    exit 1
fi

case "$verb" in
    store)
        key="$(_get_flag -k "$@" || true)"
        value="$(_get_flag --value "$@" || true)"
        ns="$(_get_flag -n "$@" || true)"
        [[ -z "$key" || -z "$ns" ]] && { echo "mock ruflo store: missing -k or -n" >&2; exit 1; }
        mkdir -p "$STORE/$ns"
        printf '%s' "$value" > "$STORE/$ns/$key"
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
            printf '{"results":[]}\n'; exit 0
        fi
        results='{"results":['
        first=1; count=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            k="$(basename "$f")"
            v="$(cat "$f" 2>/dev/null || true)"
            if grep -qF "$query" 2>/dev/null <<< "$k$v"; then
                [[ $first -eq 0 ]] && results+=','
                preview="${v:0:50}"
                preview="${preview//\\/\\\\}"
                preview="${preview//\"/\\\"}"
                results+="{\"key\":\"$k\",\"preview\":\"$preview\"}"
                first=0; count=$((count + 1))
                [[ $count -ge $limit ]] && break
            fi
        done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)
        results+=']}'
        printf '%s\n' "$results"; exit 0
        ;;
    list)
        ns="$(_get_flag -n "$@" || true)"
        limit="$(_get_flag -l "$@" || true)"
        [[ -z "$limit" ]] && limit=10000
        if [[ -n "$ns" ]]; then
            dir="$STORE/$ns"
            if [[ ! -d "$dir" ]]; then printf '[]\n'; exit 0; fi
            result='['; first=1; count=0
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                k="$(basename "$f")"
                [[ $first -eq 0 ]] && result+=','
                result+="{\"namespace\":\"$ns\",\"key\":\"$k\"}"
                first=0; count=$((count + 1))
                [[ $count -ge $limit ]] && break
            done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)
            result+=']'; printf '%s\n' "$result"
        else
            result='['; first=1; count=0
            if [[ -d "$STORE" ]]; then
                while IFS= read -r ns_dir; do
                    [[ -z "$ns_dir" ]] && continue
                    ns_name="$(basename "$ns_dir")"
                    while IFS= read -r f; do
                        [[ -z "$f" ]] && continue
                        k="$(basename "$f")"
                        [[ $first -eq 0 ]] && result+=','
                        result+="{\"namespace\":\"$ns_name\",\"key\":\"$k\"}"
                        first=0; count=$((count + 1))
                        [[ $count -ge $limit ]] && break 2
                    done < <(find "$ns_dir" -maxdepth 1 -type f 2>/dev/null | sort)
                done < <(find "$STORE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
            fi
            result+=']'; printf '%s\n' "$result"
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

# shellcheck disable=SC1090
source "$PLUGIN_DIR/plugin.sh"

# ─── Test 10: memory_search returns <key>\t<value> lines in correct format ────
print_test_section "10. memory_search: output format is tab-separated key<TAB>value"

memory_put "search-ns" "fruit-key" "fruit-value"

set +e
search_out="$(memory_search "search-ns" "fruit" 2>/dev/null)"
search_rc=$?
set -e

assert_exit_code "memory_search exits 0" "0" "$search_rc"
assert_contains "memory_search: output contains key" "$search_out" "fruit-key"
assert_contains "memory_search: output contains value" "$search_out" "fruit-value"

if grep -q $'fruit-key\tfruit-value' <<< "$search_out"; then
    assert_pass "memory_search: output is tab-separated key<TAB>value"
else
    assert_fail "memory_search: output is tab-separated key<TAB>value" \
        "got: $(printf '%s' "$search_out" | cat -A)"
fi

# ─── Test 11: memory_search with --limit N passes limit to ruflo ──────────────
print_test_section "11. memory_search --limit N: results capped at N"

memory_put "limit-ns" "item-aaa" "v1"
memory_put "limit-ns" "item-bbb" "v2"
memory_put "limit-ns" "item-ccc" "v3"

set +e
limit_out="$(memory_search "limit-ns" "item" --limit 2 2>/dev/null)"
limit_rc=$?
set -e

assert_exit_code "memory_search --limit exits 0" "0" "$limit_rc"

limit_count="$(printf '%s\n' "$limit_out" | grep -c 'item' 2>/dev/null || true)"
if [[ "$limit_count" -le 2 ]]; then
    assert_pass "memory_search --limit 2: at most 2 results returned (got $limit_count)"
else
    assert_fail "memory_search --limit 2: at most 2 results returned" "got $limit_count results"
fi

# ─── Test 12: memory_search no matches → exits 0, empty stdout ───────────────
print_test_section "12. memory_search no matches: exits 0, empty stdout"

set +e
nomatch_out="$(memory_search "search-ns" "zzz-no-match-$$" 2>/dev/null)"
nomatch_rc=$?
set -e

assert_exit_code "memory_search no-match exits 0" "0" "$nomatch_rc"

if [[ -z "$nomatch_out" ]]; then
    assert_pass "memory_search no-match: stdout is empty"
else
    assert_fail "memory_search no-match: stdout is empty" "got: $nomatch_out"
fi

# ─── Test 13: memory_list_namespaces returns one namespace per line, strips prefix
print_test_section "13. memory_list_namespaces: one namespace per line, repo prefix stripped"

memory_put "ns-alpha" "k" "x"
memory_put "ns-beta" "k" "x"

set +e
ns_list_out="$(memory_list_namespaces 2>/dev/null)"
ns_list_rc=$?
set -e

assert_exit_code "memory_list_namespaces exits 0" "0" "$ns_list_rc"
assert_contains "memory_list_namespaces: ns-alpha is listed" "$ns_list_out" "ns-alpha"
assert_contains "memory_list_namespaces: ns-beta is listed" "$ns_list_out" "ns-beta"

ns_alpha_lines="$(printf '%s\n' "$ns_list_out" | grep -c '^ns-alpha$' 2>/dev/null || true)"
assert_eq "memory_list_namespaces: ns-alpha appears on its own line" "1" "$ns_alpha_lines"

if grep -q 'zbuild-repo-' <<< "$ns_list_out"; then
    assert_fail "memory_list_namespaces: repo prefix is stripped from output" \
        "raw prefix found in: $ns_list_out"
else
    assert_pass "memory_list_namespaces: repo prefix is stripped from output"
fi

# ─── Test 14: memory_namespace_exists exits 0 when namespace has entries ──────
print_test_section "14. memory_namespace_exists: exits 0 when namespace exists"

memory_put "exists-ns" "k" "v"

set +e
memory_namespace_exists "exists-ns"
exists_rc=$?
set -e

assert_exit_code "memory_namespace_exists exits 0 for present namespace" "0" "$exists_rc"

# ─── Test 15: memory_namespace_exists exits 1 when namespace empty/absent ─────
print_test_section "15. memory_namespace_exists: exits 1 when namespace absent"

set +e
memory_namespace_exists "absent-ns-$$"
absent_rc=$?
set -e

assert_exit_code "memory_namespace_exists exits 1 for absent namespace" "1" "$absent_rc"

# ─── Test 16: memory_namespace_clear exits 0 on success (idempotent on empty) ─
print_test_section "16. memory_namespace_clear: exits 0; idempotent on empty namespace"

memory_put "clear-ns" "k" "v"

set +e
memory_namespace_clear "clear-ns"
clear_rc=$?
set -e

assert_exit_code "memory_namespace_clear exits 0 on first call" "0" "$clear_rc"

set +e
memory_namespace_clear "clear-ns"
clear2_rc=$?
set -e

assert_exit_code "memory_namespace_clear exits 0 on second call (idempotent)" "0" "$clear2_rc"

# ─── Test 17: ruflo exits non-zero in memory_put → exits 1 with stderr ────────
print_test_section "17. memory_put: ruflo failure → exits 1 with stderr diagnostic"

export RUFLO_FAIL_NEXT="store"

set +e
fail_put_out="$(memory_put "unit-ns" "fail-key" "fail-value" 2>&1)"
fail_put_rc=$?
set -e

unset RUFLO_FAIL_NEXT

assert_exit_code "memory_put exits 1 on ruflo failure" "1" "$fail_put_rc"

if [[ -n "$fail_put_out" ]]; then
    assert_pass "memory_put: diagnostic emitted on ruflo failure"
else
    assert_fail "memory_put: diagnostic emitted on ruflo failure" "stderr/stdout was empty"
fi

# ─── Test 18: ruflo rc=1 in memory_get treated as miss → exits 0 empty stdout ─
print_test_section "18. memory_get: ruflo rc=1 treated as miss (exits 0, empty stdout)"

export RUFLO_FAIL_NEXT="retrieve"

set +e
fail_get_out="$(memory_get "unit-ns" "any-key" 2>/dev/null)"
fail_get_rc=$?
set -e

unset RUFLO_FAIL_NEXT

assert_exit_code "memory_get ruflo rc=1 exits 0 (treated as miss)" "0" "$fail_get_rc"

if [[ -z "$fail_get_out" ]]; then
    assert_pass "memory_get ruflo rc=1: stdout is empty (treated as miss)"
else
    assert_fail "memory_get ruflo rc=1: stdout is empty (treated as miss)" "got: $fail_get_out"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
