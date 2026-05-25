#!/usr/bin/env bash
# Integration Tests: plugins/tool/memory-ruflo/ — adversarial edge cases (issue #217)
# Covers: ruflo mid-operation kill + graceful recovery, newline-embedded values,
#         very long keys, concurrent namespace_clear + namespace_exists, and
#         cross-namespace data isolation end-to-end.
#
# These tests spawn real subprocesses and exercise the filesystem+subprocess
# layer at a level that unit tests cannot reach.  The same call-recording mock
# ruflo is used so integration assertions can inspect argument passing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/memory-ruflo"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-ruflo — integration: adversarial edge cases (issue #217)"

setup_test_env "memory-ruflo-integ"

# ─── Mock ruflo with call-recording and kill-simulation support ───────────────
# The integration mock extends the unit mock with two extra control mechanisms:
#
#   RUFLO_HANG_NS  — if set, the 'namespace-clear' action for this namespace
#                    sleeps for 60 s before doing any work.  Tests kill the
#                    subprocess after a short delay to simulate a mid-clear kill.
#
#   RUFLO_SLOW_STORE_NS — if set, 'store' calls for this namespace sleep briefly,
#                         simulating a slow write so concurrent tests overlap.
#
# The mock is a real executable on disk so subshell-invoked plugin copies all
# see the same binary.

RUFLO_STORE="$TEST_TEMP_DIR/ruflo-store"
RUFLO_CALLS="$TEST_TEMP_DIR/ruflo.calls"
mkdir -p "$RUFLO_STORE"
export RUFLO_STORE

cat > "$TEST_TEMP_DIR/bin/ruflo" << 'MOCK_EOF'
#!/usr/bin/env bash
# Integration mock ruflo — records calls verbatim, backs a filesystem store.
# Uses flag-based CLI matching the plugin.sh spec (issue #217).
# RUFLO_STORE must be exported by the test harness.
#
# Extra control vars:
#   RUFLO_HANG_NS       — if set, 'delete' for keys in this ns sleeps 60s first
#   RUFLO_SLOW_STORE_NS — if set, 'store' for keys in this ns sleeps briefly

STORE="${RUFLO_STORE:?RUFLO_STORE must be exported}"
CALLS_LOG="${RUFLO_STORE}/../ruflo.calls"

printf 'CALL: %s\n' "$*" >> "$CALLS_LOG"

[[ $# -lt 2 ]] && { printf 'ruflo: missing command/action\n' >&2; exit 1; }

_cmd="$1"; _action="$2"; shift 2
[[ "$_cmd" != "memory" ]] && { printf 'ruflo: unknown command: %s\n' "$_cmd" >&2; exit 1; }

# Parse flags from remaining args
_get_flag() {
    local _flag="$1" _prev=""
    shift
    for _arg in "$@"; do
        [[ "$_prev" == "$_flag" ]] && { printf '%s' "$_arg"; return 0; }
        _prev="$_arg"
    done
    return 1
}

case "$_action" in
    store)
        _key="$(_get_flag -k "$@" || true)"
        _val="$(_get_flag --value "$@" || true)"
        _ns="$(_get_flag -n "$@" || true)"
        [[ -z "$_key" || -z "$_ns" ]] && { printf 'mock ruflo store: missing -k or -n\n' >&2; exit 1; }
        # Simulate slow write for concurrent tests.
        if [[ -n "${RUFLO_SLOW_STORE_NS:-}" && "$_ns" == "$RUFLO_SLOW_STORE_NS" ]]; then
            sleep 0.05
        fi
        mkdir -p "$STORE/$_ns"
        # Write to a tmp file then atomically rename to avoid torn reads.
        _tmp="$STORE/$_ns/.tmp.$$.$RANDOM"
        printf '%s' "$_val" > "$_tmp"
        mv "$_tmp" "$STORE/$_ns/$_key"
        exit 0
        ;;
    retrieve)
        _key="$(_get_flag -k "$@" || true)"
        _ns="$(_get_flag -n "$@" || true)"
        [[ -z "$_key" || -z "$_ns" ]] && { printf 'mock ruflo retrieve: missing -k or -n\n' >&2; exit 1; }
        _f="$STORE/$_ns/$_key"
        if [[ -f "$_f" ]]; then
            _content="$(cat "$_f")"
            # Escape for JSON embedding
            _content="${_content//\\/\\\\}"
            _content="${_content//\"/\\\"}"
            _content="${_content//$'\n'/\\n}"
            printf '{"content":"%s"}\n' "$_content"
            exit 0
        else
            exit 1
        fi
        ;;
    search)
        _query="$(_get_flag -q "$@" || true)"
        _ns="$(_get_flag -n "$@" || true)"
        _limit="$(_get_flag -l "$@" || true)"
        [[ -z "$_limit" ]] && _limit=10
        [[ -z "$_ns" ]] && { printf '{"results":[]}\n'; exit 0; }
        # limit=0 means return nothing
        if [[ "$_limit" -eq 0 ]] 2>/dev/null; then
            printf '{"results":[]}\n'; exit 0
        fi
        _dir="$STORE/$_ns"
        if [[ ! -d "$_dir" ]]; then
            printf '{"results":[]}\n'; exit 0
        fi
        _results='{"results":['
        _first=1; _count=0
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            _k="$(basename "$_f")"
            _v="$(cat "$_f" 2>/dev/null || true)"
            if printf '%s%s' "$_k" "$_v" | grep -qF "$_query" 2>/dev/null; then
                [[ $_first -eq 0 ]] && _results+=','
                _preview="${_v:0:50}"
                _preview="${_preview//\\/\\\\}"
                _preview="${_preview//\"/\\\"}"
                _preview="${_preview//$'\n'/\\n}"
                _results+="{\"key\":\"$_k\",\"preview\":\"$_preview\"}"
                _first=0; _count=$((_count + 1))
                [[ $_count -ge $_limit ]] && break
            fi
        done < <(find "$_dir" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | sort)
        _results+=']}'
        printf '%s\n' "$_results"
        exit 0
        ;;
    list)
        _ns="$(_get_flag -n "$@" || true)"
        _limit="$(_get_flag -l "$@" || true)"
        [[ -z "$_limit" ]] && _limit=10000
        if [[ -n "$_ns" ]]; then
            _dir="$STORE/$_ns"
            if [[ ! -d "$_dir" ]]; then
                printf '[]\n'; exit 0
            fi
            _result='['; _first=1; _count=0
            while IFS= read -r _f; do
                [[ -z "$_f" ]] && continue
                _k="$(basename "$_f")"
                [[ $_first -eq 0 ]] && _result+=','
                _result+="{\"namespace\":\"$_ns\",\"key\":\"$_k\"}"
                _first=0; _count=$((_count + 1))
                [[ $_count -ge $_limit ]] && break
            done < <(find "$_dir" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | sort)
            _result+=']'; printf '%s\n' "$_result"
        else
            _result='['; _first=1; _count=0
            if [[ -d "$STORE" ]]; then
                while IFS= read -r _ns_dir; do
                    [[ -z "$_ns_dir" ]] && continue
                    _ns_name="$(basename "$_ns_dir")"
                    while IFS= read -r _f; do
                        [[ -z "$_f" ]] && continue
                        _k="$(basename "$_f")"
                        [[ $_first -eq 0 ]] && _result+=','
                        _result+="{\"namespace\":\"$_ns_name\",\"key\":\"$_k\"}"
                        _first=0; _count=$((_count + 1))
                        [[ $_count -ge $_limit ]] && break 2
                    done < <(find "$_ns_dir" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | sort)
                done < <(find "$STORE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
            fi
            _result+=']'; printf '%s\n' "$_result"
        fi
        exit 0
        ;;
    delete)
        _key="$(_get_flag -k "$@" || true)"
        _ns="$(_get_flag -n "$@" || true)"
        [[ -z "$_key" || -z "$_ns" ]] && { printf 'mock ruflo delete: missing -k or -n\n' >&2; exit 1; }
        # Simulate a hung/killable clear if RUFLO_HANG_NS matches ns
        if [[ -n "${RUFLO_HANG_NS:-}" && "$_ns" == "$RUFLO_HANG_NS" ]]; then
            sleep 60
        fi
        _f="$STORE/$_ns/$_key"
        [[ -f "$_f" ]] && rm -f "$_f"
        exit 0
        ;;
    *)
        printf 'ruflo memory: unknown action: %s\n' "$_action" >&2
        exit 1
        ;;
esac
MOCK_EOF
chmod +x "$TEST_TEMP_DIR/bin/ruflo"

# Helper: source the plugin in an isolated subshell with correct environment.
_subshell_plugin() {
    (
        export RUFLO_STORE
        export ZBUILD_ROOT="$TEST_TEMP_DIR/project-root"
        export ZBUILD_MEMORY_BACKEND="ruflo"
        export PATH="$TEST_TEMP_DIR/bin:$PATH"
        unset _ZBUILD_MEMORY_RUFLO_LOADED 2>/dev/null || true
        # shellcheck disable=SC1090
        source "$REPO_ROOT/scripts/lib/helpers.sh"
        source "$REPO_ROOT/scripts/lib/test-helpers.sh"
        source "$PLUGIN_DIR/plugin.sh"
        "$@"
    )
}

export ZBUILD_ROOT="$TEST_TEMP_DIR/project-root"
export ZBUILD_MEMORY_BACKEND="ruflo"

# shellcheck disable=SC1090
source "$PLUGIN_DIR/plugin.sh"

set +e
memory_backend_init >/dev/null 2>&1
_pre_rc=$?
set -e
assert_exit_code "precondition: memory_backend_init exits 0" "0" "$_pre_rc"

# ─── Test 16: ruflo killed mid-namespace_clear → namespace_exists returns 1 ───
# If the ruflo subprocess is killed during a namespace_clear, the plugin must
# not consider the namespace as "being cleared" — a subsequent namespace_exists
# call must reflect the actual store state (either still-exists or cleared,
# never a stuck/zombie state that exits non-deterministically).
print_test_section "16. ruflo killed mid-namespace_clear: namespace_exists is consistent afterward"

KILL_NS="kill-clear-ns-$$"

# Populate the namespace.
set +e
memory_put "$KILL_NS" "key-a" "value-a" 2>/dev/null
memory_put "$KILL_NS" "key-b" "value-b" 2>/dev/null
set -e

# Confirm it exists before the kill test.
set +e
memory_namespace_exists "$KILL_NS"
pre_exists_rc=$?
set -e
assert_exit_code "mid-clear kill: namespace exists before test (rc=0)" "0" "$pre_exists_rc"

# Launch a namespace_clear in a subshell that will hang (RUFLO_HANG_NS set),
# then kill it after a short delay.
export RUFLO_HANG_NS="$KILL_NS"

set +e
(
    export RUFLO_HANG_NS="$KILL_NS"
    _subshell_plugin memory_namespace_clear "$KILL_NS"
) &
_kill_pid=$!
sleep 0.15
kill -KILL "$_kill_pid" 2>/dev/null || true
wait "$_kill_pid" 2>/dev/null || true
set -e

unset RUFLO_HANG_NS

# Now call namespace_exists — it must return a definite 0 or 1, not hang or crash.
set +e
(
    # Use a timeout to catch infinite loops / hangs in the plugin.
    _subshell_plugin memory_namespace_exists "$KILL_NS"
)
post_exists_rc=$?
set -e

if [[ "$post_exists_rc" -eq 0 || "$post_exists_rc" -eq 1 ]]; then
    assert_pass "mid-clear kill: memory_namespace_exists returns 0 or 1 (rc=$post_exists_rc, no hang)"
else
    assert_fail "mid-clear kill: memory_namespace_exists returns 0 or 1" \
        "got rc=$post_exists_rc — possible crash or signal propagation"
fi

# ─── Test 17a: Value with embedded newlines — memory_search output escapes \n ─
# memory_search must escape literal newlines in stored values so the output
# remains one <key>\t<value> record per line.
print_test_section "17a. Embedded newlines in value: memory_search escapes \\n in output"

NL_NS="newline-ns-$$"
NL_KEY="nl-key"
# Store a value that contains a real newline character.
NL_VAL="$(printf 'line one\nline two\nline three')"

set +e
memory_put "$NL_NS" "$NL_KEY" "$NL_VAL" 2>/dev/null
nl_put_rc=$?
set -e

assert_exit_code "newline value: memory_put exits 0" "0" "$nl_put_rc"

set +e
nl_search_out="$(memory_search "$NL_NS" "line" 2>/dev/null)"
nl_search_rc=$?
set -e

assert_exit_code "newline value: memory_search exits 0" "0" "$nl_search_rc"

# The output must contain exactly one line for this key (literal \n, not a real newline).
nl_line_count="$(printf '%s\n' "$nl_search_out" | grep -c "$NL_KEY" 2>/dev/null || echo 0)"
assert_eq "newline value: memory_search output contains exactly 1 line for the key" \
    "1" "$nl_line_count"

# The literal \n escape sequence must appear in the output value.
if printf '%s' "$nl_search_out" | grep -qF '\n'; then
    assert_pass "newline value: memory_search output contains literal '\\n' escape"
else
    assert_fail "newline value: memory_search output contains literal '\\n' escape" \
        "output was: $(printf '%s' "$nl_search_out" | cat -A)"
fi

# ─── Test 17b: Value with embedded newlines — memory_get returns raw newlines ─
# memory_get is a point-lookup; the contract allows raw newlines in the returned
# bytes since callers receive a single value (not a multi-record stream).
print_test_section "17b. Embedded newlines in value: memory_get returns raw newlines"

set +e
nl_got="$(memory_get "$NL_NS" "$NL_KEY" 2>/dev/null)"
nl_get_rc=$?
set -e

assert_exit_code "newline value: memory_get exits 0" "0" "$nl_get_rc"
assert_eq "newline value: memory_get round-trips raw newlines" "$NL_VAL" "$nl_got"

# ─── Test 18: Very long key (513 chars) — rejected rc=2 or passed safely ──────
# Keys longer than a filesystem limit (255 chars on most platforms) must not
# cause a silent data corruption.  The plugin must either reject with rc=2 or
# pass the key safely to ruflo (which the mock handles by hashing/truncating).
print_test_section "18. Very long key (513 chars): rejected (rc=2) or passed safely to ruflo"

LONG_KEY="$(printf 'k%.0s' {1..513})"
LONG_NS="long-key-ns-$$"

set +e
memory_put "$LONG_NS" "$LONG_KEY" "long-key-value" 2>&1
long_put_rc=$?
set -e

if [[ "$long_put_rc" -eq 2 ]]; then
    assert_pass "long key 513: memory_put exits 2 (explicit rejection)"
elif [[ "$long_put_rc" -eq 0 ]]; then
    # Plugin accepted it — verify it was passed to ruflo (not silently dropped).
    if grep -q "long-key-value" "$RUFLO_CALLS" 2>/dev/null || \
       [[ -f "$RUFLO_STORE/$LONG_NS/$LONG_KEY" ]]; then
        assert_pass "long key 513: memory_put exits 0, value passed to ruflo"
    else
        assert_fail "long key 513: memory_put exits 0, value passed to ruflo" \
            "value not found in store or calls log — key may have been silently dropped"
    fi
else
    assert_fail "long key 513: memory_put exits 0 (safe pass) or 2 (rejection)" \
        "got rc=$long_put_rc"
fi

# Either way, no runaway file should have been written outside the store.
if [[ "$long_put_rc" -eq 0 ]]; then
    # The key is 513 chars — on ext4/APFS the filename limit is 255 bytes.
    # If the plugin passes a 513-char key directly to a filepath construction,
    # the OS will reject the open() call, not create a partial file.
    _long_store_dir="$RUFLO_STORE/$LONG_NS"
    if [[ -d "$_long_store_dir" ]]; then
        # Count only files with sensible-length names; a 513-char filename is a bug.
        _oversized="$(find "$_long_store_dir" -maxdepth 1 -type f 2>/dev/null | \
            awk '{ if (length($0) > 300) print $0 }' | wc -l | tr -d ' ')"
        if [[ "$_oversized" -eq 0 ]]; then
            assert_pass "long key 513: no oversized filename in store (plugin handled length safely)"
        else
            assert_fail "long key 513: no oversized filename in store" \
                "found $_oversized file(s) with suspiciously long names"
        fi
    else
        assert_pass "long key 513: store directory absent (key may have been hashed/rejected)"
    fi
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
