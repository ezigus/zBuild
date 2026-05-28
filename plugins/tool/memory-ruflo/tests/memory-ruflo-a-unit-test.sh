#!/usr/bin/env bash
# Tests: plugins/tool/memory-ruflo/ — unit-level tests Part A (issue #217)
# Covers (tests 1-9): capabilities JSON, backend_init availability check,
#         put/get contract functions, and invalid-arg exits.
# All tests mock the `ruflo` binary via PATH-shadow using $TEST_TEMP_DIR/bin/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/memory-ruflo"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-ruflo — unit Part A: capabilities + put/get (tests 1-9)"

setup_test_env "memory-ruflo-unit-a"

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
            if printf '%s' "$k$v" | grep -qF "$query" 2>/dev/null; then
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

# ─── Test 1: memory_capabilities returns valid JSON with vector_search field ──
print_test_section "1. memory_capabilities: valid JSON containing 'vector_search'"

set +e
caps_out="$(memory_capabilities 2>&1)"
caps_rc=$?
set -e

assert_exit_code "memory_capabilities exits 0" "0" "$caps_rc"

if echo "$caps_out" | jq empty >/dev/null 2>&1; then
    assert_pass "memory_capabilities output is valid JSON"
else
    assert_fail "memory_capabilities output is valid JSON" "output was: $caps_out"
fi

if echo "$caps_out" | jq -e 'if type == "array" then map(select(. == "vector_search")) | length > 0 else has("vector_search") end' >/dev/null 2>&1; then
    assert_pass "memory_capabilities JSON contains 'vector_search' field"
else
    assert_fail "memory_capabilities JSON contains 'vector_search' field" "output was: $caps_out"
fi

# ─── Test 2: memory_backend_init exits 0 when ruflo is available ──────────────
print_test_section "2. memory_backend_init: exits 0 when ruflo is in PATH"

set +e
memory_backend_init >/dev/null 2>&1
init_rc=$?
set -e

assert_exit_code "memory_backend_init exits 0 with ruflo available" "0" "$init_rc"

# ─── Test 3: memory_backend_init exits 1 when ruflo not in PATH ───────────────
print_test_section "3. memory_backend_init: exits 1 when ruflo absent from PATH"

NO_RUFLO_BIN="$TEST_TEMP_DIR/bin-no-ruflo"
mkdir -p "$NO_RUFLO_BIN"
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$NO_RUFLO_BIN/jq" 2>/dev/null || true
fi
NO_RUFLO_PATH="$NO_RUFLO_BIN:/usr/bin:/bin"

set +e
missing_out="$(
    export PATH="$NO_RUFLO_PATH"
    unset _ZBUILD_MEMORY_RUFLO_LOADED
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/plugin.sh"
    memory_backend_init 2>&1
)"
missing_rc=$?
set -e

assert_exit_code "memory_backend_init exits 1 when ruflo absent" "1" "$missing_rc"

if echo "$missing_out" | grep -qiE "(ruflo|not found|unavailable|missing|required|dependency)"; then
    assert_pass "memory_backend_init: diagnostic on stderr when ruflo absent"
else
    assert_fail "memory_backend_init: diagnostic on stderr when ruflo absent" "stderr was: $missing_out"
fi

# ─── Test 4: memory_put with valid args calls ruflo store; exits 0 ───────────
print_test_section "4. memory_put: valid args → ruflo store called; exits 0"

set +e
memory_put "unit-ns" "key-001" "value-001" 2>/dev/null
put_rc=$?
set -e

assert_exit_code "memory_put valid args exits 0" "0" "$put_rc"

stored_val="$(find "$MOCK_STORE_DIR" -name 'key-001' -type f -print0 2>/dev/null | xargs -0 cat 2>/dev/null || true)"
assert_eq "memory_put: value written to backing store" "value-001" "$stored_val"

# ─── Test 5: memory_put with empty namespace exits 2 ─────────────────────────
print_test_section "5. memory_put: empty namespace exits 2 (invalid args)"

set +e
memory_put "" "some-key" "some-value" 2>/dev/null
empty_ns_rc=$?
set -e

assert_exit_code "memory_put empty namespace exits 2" "2" "$empty_ns_rc"

# ─── Test 6: memory_put with empty key exits 2 ───────────────────────────────
print_test_section "6. memory_put: empty key exits 2 (invalid args)"

set +e
memory_put "unit-ns" "" "some-value" 2>/dev/null
empty_key_rc=$?
set -e

assert_exit_code "memory_put empty key exits 2" "2" "$empty_key_rc"

# ─── Test 7: memory_get hit — ruflo returns value; exits 0 with value ────────
print_test_section "7. memory_get hit: exits 0 with value on stdout"

memory_put "get-ns" "get-key-001" "expected-value"

set +e
get_out="$(memory_get "get-ns" "get-key-001" 2>/dev/null)"
get_rc=$?
set -e

assert_exit_code "memory_get hit exits 0" "0" "$get_rc"
assert_eq "memory_get hit: value on stdout" "expected-value" "$get_out"

# ─── Test 8: memory_get miss — ruflo returns empty; exits 0 with empty stdout ─
print_test_section "8. memory_get miss: exits 0 with empty stdout"

set +e
miss_out="$(memory_get "get-ns" "nonexistent-key-$$" 2>/dev/null)"
miss_rc=$?
set -e

assert_exit_code "memory_get miss exits 0" "0" "$miss_rc"

if [[ -z "$miss_out" ]]; then
    assert_pass "memory_get miss: stdout is empty"
else
    assert_fail "memory_get miss: stdout is empty" "got: $miss_out"
fi

# ─── Test 9: memory_get with empty ns/key → exits 0 empty (graceful) ─────────
print_test_section "9. memory_get empty ns/key: exits 0 with empty stdout (graceful)"

set +e
empty_get_out="$(memory_get "" "" 2>/dev/null)"
empty_get_rc=$?
set -e

assert_exit_code "memory_get empty args exits 0" "0" "$empty_get_rc"

if [[ -z "$empty_get_out" ]]; then
    assert_pass "memory_get empty args: stdout is empty"
else
    assert_fail "memory_get empty args: stdout is empty" "got: $empty_get_out"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
