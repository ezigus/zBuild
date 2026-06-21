#!/usr/bin/env bash
# Tests: plugins/tool/memory-ruflo/ — unit-level adversarial + injection tests (issue #217) — Part A
# Covers (tests 1-8): namespace shell injection, key path traversal, value round-trip with
#         metacharacters, '--' flag confusion, ruflo availability edge cases,
#         ruflo always-failing graceful degradation, non-executable ruflo,
#         repo-prefix determinism.
#
# Design: every test uses a mock ruflo that records all calls to ruflo.calls so
# assertions can verify what arguments actually reached the binary.  The mock
# also backs a real filesystem store so round-trip correctness is checkable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/tool/memory-ruflo"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugins/tool/memory-ruflo — unit: adversarial + injection Part A (tests 1-8)"

setup_test_env "memory-ruflo-adv-a"

# ─── Mock ruflo ───────────────────────────────────────────────────────────────
# Records every invocation as "CALL: <raw $*>" to ruflo.calls.
# Backs a filesystem store at $TEST_TEMP_DIR/ruflo-store/<namespace>/<key>.
# RUFLO_FAIL_ALL=1 makes every subcommand exit 1 (simulates a broken daemon).

RUFLO_STORE="$TEST_TEMP_DIR/ruflo-store"
RUFLO_CALLS="$TEST_TEMP_DIR/ruflo.calls"
mkdir -p "$RUFLO_STORE"

# The HEREDOC uses a single-quoted delimiter so $TEST_TEMP_DIR is NOT expanded
# at write-time; RUFLO_STORE is exported and read at runtime by the mock.
export RUFLO_STORE

cat > "$TEST_TEMP_DIR/bin/ruflo" << 'MOCK_EOF'
#!/usr/bin/env bash
# Mock ruflo — records calls verbatim, backs a filesystem store.
# Uses flag-based CLI matching the plugin.sh spec (issue #217).
# RUFLO_STORE must be exported by the test harness.

STORE="${RUFLO_STORE:?RUFLO_STORE must be exported by test harness}"
CALLS_LOG="${RUFLO_STORE}/../ruflo.calls"

# Record call VERBATIM so injection surfaces in the log.
printf 'CALL: %s\n' "$*" >> "$CALLS_LOG"

# Simulate a permanently-broken ruflo if requested.
if [[ "${RUFLO_FAIL_ALL:-0}" == "1" ]]; then
    printf 'mock ruflo: simulated failure (RUFLO_FAIL_ALL)\n' >&2
    exit 1
fi

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
        mkdir -p "$STORE/$_ns"
        printf '%s' "$_val" > "$STORE/$_ns/$_key"
        exit 0
        ;;
    retrieve)
        _key="$(_get_flag -k "$@" || true)"
        _ns="$(_get_flag -n "$@" || true)"
        [[ -z "$_key" || -z "$_ns" ]] && { printf 'mock ruflo retrieve: missing -k or -n\n' >&2; exit 1; }
        _f="$STORE/$_ns/$_key"
        if [[ -f "$_f" ]]; then
            _content="$(cat "$_f")"
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
            if grep -qF "$_query" 2>/dev/null <<< "$_k$_v"; then
                [[ $_first -eq 0 ]] && _results+=','
                _preview="${_v:0:50}"
                _preview="${_preview//\\/\\\\}"
                _preview="${_preview//\"/\\\"}"
                _results+="{\"key\":\"$_k\",\"preview\":\"$_preview\"}"
                _first=0; _count=$((_count + 1))
                [[ $_count -ge $_limit ]] && break
            fi
        done < <(find "$_dir" -maxdepth 1 -type f 2>/dev/null | sort)
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
            done < <(find "$_dir" -maxdepth 1 -type f 2>/dev/null | sort)
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
                    done < <(find "$_ns_dir" -maxdepth 1 -type f 2>/dev/null | sort)
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

# Point plugin at a deterministic ZBUILD_ROOT so prefix derivation is testable.
export ZBUILD_ROOT="$TEST_TEMP_DIR/project-root"
export ZBUILD_MEMORY_BACKEND="ruflo"

# Source the plugin under test.  If the plugin does not exist yet, the suite
# fails loudly here — the correct signal that issue #217 is not implemented.
# shellcheck disable=SC1090
source "$PLUGIN_DIR/plugin.sh"

# Confirm the backend initialises cleanly with ruflo present.
set +e
memory_backend_init >/dev/null 2>&1
_init_rc=$?
set -e
assert_exit_code "precondition: memory_backend_init exits 0 with mock ruflo" "0" "$_init_rc"

# ─── Test 1: Namespace with shell metacharacters — no injection ───────────────
# The plugin MUST pass the namespace as a single quoted argument to ruflo.
# If it constructs a command string and evaluates it without proper quoting,
# the semicolons will spawn a second shell command and create the canary file.
print_test_section "1. Namespace injection: 'ns; touch CANARY' is passed as a literal string"

CANARY_1="$TEST_TEMP_DIR/INJECTION_CANARY_1"
INJECT_NS="mynamespace; touch ${CANARY_1} #"

set +e
memory_put "$INJECT_NS" "harmless-key" "harmless-value" 2>/dev/null
inject_put_rc=$?
set -e

if [[ -f "$CANARY_1" ]]; then
    assert_fail "namespace injection: CANARY_1 must NOT be created" \
        "INJECTION DETECTED: touch executed via namespace metacharacters"
else
    assert_pass "namespace injection: CANARY_1 was not created (no shell injection)"
fi

# rc=0 (stored with literal namespace) or rc=2 (rejected) are both acceptable.
# rc=1 from a shell parse error in the plugin's command expansion is also a bug.
if [[ "$inject_put_rc" -eq 0 || "$inject_put_rc" -eq 2 ]]; then
    assert_pass "namespace injection: memory_put exits 0 or 2, not a crash (rc=$inject_put_rc)"
else
    assert_fail "namespace injection: memory_put exits 0 or 2" \
        "got rc=$inject_put_rc — possible unquoted expansion bug"
fi

# ─── Test 2: Key with path traversal — no filesystem escape ──────────────────
# If the plugin or the mock ruflo constructs a file path by concatenating the
# key without sanitising, '../../../etc/passwd' would escape the store root.
print_test_section "2. Key path traversal: '../../../etc/passwd' rejected or treated as literal"

TRAVERSAL_KEY="../../../etc/passwd"

set +e
memory_put "safe-ns" "$TRAVERSAL_KEY" "pwned" 2>&1
trav_rc=$?
set -e

# rc=2 is the explicit validation-rejection path (preferred).
if [[ "$trav_rc" -eq 2 ]]; then
    assert_pass "key traversal: memory_put exits 2 (explicit rejection)"
elif [[ "$trav_rc" -eq 0 ]]; then
    # Plugin accepted the key as a literal.  Verify no file was written outside
    # the store directory.  We check whether any regular file now exists at a
    # path that would result from unescaped traversal.
    _escaped_path="$RUFLO_STORE/safe-ns/$TRAVERSAL_KEY"
    # Resolve the path to check if it escaped the store.
    if command -v realpath >/dev/null 2>&1; then
        _resolved="$(realpath -m "$_escaped_path" 2>/dev/null || echo "$_escaped_path")"
    else
        _resolved="$_escaped_path"
    fi
    if [[ "$_resolved" == "$RUFLO_STORE"* ]]; then
        assert_pass "key traversal: if accepted, file remains inside store root"
    else
        assert_fail "key traversal: if accepted, file remains inside store root" \
            "resolved path '$_resolved' escaped store root '$RUFLO_STORE'"
    fi
else
    assert_fail "key traversal: memory_put exits 0 (literal) or 2 (rejected)" \
        "got rc=$trav_rc"
fi

# ─── Test 3: Value with single-quotes and backslashes round-trips correctly ───
# SQLite, shell, and ruflo CLI all have quoting hazards.  A value containing
# single-quotes or backslashes must arrive at ruflo verbatim and be returnable
# unchanged by memory_get.
print_test_section "3. Value round-trip: single-quotes and backslashes survive intact"

ROUNDTRIP_NS="roundtrip-ns"
ROUNDTRIP_KEY="rt-key"
ROUNDTRIP_VAL="it's a 'tricky' value with back\\slashes and \\\"escaped quotes\\\""

set +e
memory_put "$ROUNDTRIP_NS" "$ROUNDTRIP_KEY" "$ROUNDTRIP_VAL" 2>/dev/null
rt_put_rc=$?
set -e

assert_exit_code "value round-trip: memory_put exits 0" "0" "$rt_put_rc"

set +e
rt_got="$(memory_get "$ROUNDTRIP_NS" "$ROUNDTRIP_KEY" 2>/dev/null)"
rt_get_rc=$?
set -e

assert_exit_code "value round-trip: memory_get exits 0" "0" "$rt_get_rc"
assert_eq "value round-trip: retrieved value matches original" "$ROUNDTRIP_VAL" "$rt_got"

# ─── Test 4: Namespace with '--' prefix not parsed as a flag ─────────────────
# If the plugin calls ruflo with: ruflo memory store $ns $key $val
# and $ns starts with '--', ruflo's option parser may consume it as a flag.
# The plugin must use '--' or positional-safe quoting to prevent this.
print_test_section "4. Namespace '--dangerous' not treated as a ruflo CLI flag"

FLAG_NS="--dangerous-namespace"

set +e
flag_out="$(memory_put "$FLAG_NS" "k" "v" 2>&1)"
flag_rc=$?
set -e

# rc=2 = plugin rejected the namespace (fine — guard at input boundary).
if [[ "$flag_rc" -eq 2 ]]; then
    assert_pass "'--dangerous' namespace: plugin rejected as invalid (rc=2)"
elif [[ "$flag_rc" -eq 0 ]]; then
    assert_pass "'--dangerous' namespace: plugin passed it safely to ruflo (rc=0)"
else
    # rc=1 may be a ruflo flag-parse error — check stderr.
    if grep -qiE "(unknown option|invalid flag|illegal option|unrecognized|--)" <<< "$flag_out"; then
        assert_fail "'--dangerous' namespace: not consumed as a CLI flag" \
            "ruflo appears to have parsed '--dangerous' as a flag: $flag_out"
    else
        # rc=1 for another backend reason is tolerable — just must not be a flag parse error.
        assert_pass "'--dangerous' namespace: rc=1 is a backend error, not a flag misparse"
    fi
fi

# ─── Test 5: ruflo absent from PATH — memory_backend_init exits 1 ────────────
# ZBUILD_MEMORY_BACKEND=ruflo is set.  When ruflo is not findable, the plugin
# must refuse to initialise (rc=1), not silently succeed and fail later.
# Use a minimal clean PATH (no ruflo binary present) to avoid interference from
# any real ruflo installation on the system.
print_test_section "5. ruflo absent: memory_backend_init exits 1 with diagnostic"

_NO_RUFLO_BIN="$TEST_TEMP_DIR/bin-no-ruflo"
mkdir -p "$_NO_RUFLO_BIN"
# Symlink jq so the plugin can find it (needed to reach the ruflo check)
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$_NO_RUFLO_BIN/jq" 2>/dev/null || true
fi
_NO_RUFLO_PATH="$_NO_RUFLO_BIN:/usr/bin:/bin"

set +e
absent_rc="$(
    export PATH="$_NO_RUFLO_PATH"
    unset _ZBUILD_MEMORY_RUFLO_LOADED
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/plugin.sh"
    memory_backend_init 2>/dev/null
    echo $?
)"
set -e

# Strip trailing newlines and extra output, keep just the exit code
absent_rc="${absent_rc##*$'\n'}"

assert_exit_code "ruflo absent: memory_backend_init exits 1" "1" "$absent_rc"

# Separately capture stderr to check for a human-readable message.
set +e
absent_msg="$(
    export PATH="$_NO_RUFLO_PATH"
    unset _ZBUILD_MEMORY_RUFLO_LOADED
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/plugin.sh"
    memory_backend_init 2>&1 || true
)"
set -e

if grep -qiE "(ruflo|not found|unavailable|missing|required|command)" <<< "$absent_msg"; then
    assert_pass "ruflo absent: diagnostic mentions ruflo or 'not found'"
else
    assert_fail "ruflo absent: diagnostic mentions ruflo or 'not found'" \
        "stderr was: $absent_msg"
fi

# ─── Test 6: ruflo always exits 1 — graceful degradation ─────────────────────
# get/search/list_namespaces must return empty + rc=0 (CACHE_MISS semantics).
# put/namespace_clear must return rc=1 with a warning — but must not crash.
print_test_section "6. ruflo always-failing: read ops degrade to empty+rc0; write ops return rc1"

export RUFLO_FAIL_ALL=1

set +e
fail_get_out="$(memory_get "any-ns" "any-key" 2>/dev/null)"
fail_get_rc=$?

fail_search_out="$(memory_search "any-ns" "any-query" 2>/dev/null)"
fail_search_rc=$?

fail_list_out="$(memory_list_namespaces 2>/dev/null)"
fail_list_rc=$?

memory_put "any-ns" "any-key" "any-val" 2>/dev/null
fail_put_rc=$?

memory_namespace_clear "any-ns" 2>/dev/null
fail_clear_rc=$?
set -e

unset RUFLO_FAIL_ALL

assert_exit_code "always-failing: memory_get exits 0" "0" "$fail_get_rc"
assert_eq "always-failing: memory_get returns empty stdout" "" "$fail_get_out"

assert_exit_code "always-failing: memory_search exits 0" "0" "$fail_search_rc"
assert_eq "always-failing: memory_search returns empty stdout" "" "$fail_search_out"

assert_exit_code "always-failing: memory_list_namespaces exits 0" "0" "$fail_list_rc"
assert_eq "always-failing: memory_list_namespaces returns empty stdout" "" "$fail_list_out"

if [[ "$fail_put_rc" -ne 0 ]]; then
    assert_pass "always-failing: memory_put exits non-zero (rc=$fail_put_rc)"
else
    assert_fail "always-failing: memory_put exits non-zero" "got rc=0 — error swallowed"
fi

if [[ "$fail_clear_rc" -ne 0 ]]; then
    assert_pass "always-failing: memory_namespace_clear exits non-zero (rc=$fail_clear_rc)"
else
    assert_fail "always-failing: memory_namespace_clear exits non-zero" \
        "got rc=0 — error swallowed"
fi

# ─── Test 7: ruflo binary not executable — treated as absent ──────────────────
# chmod 000 on the ruflo binary must be detected as "ruflo not available" rather
# than surfacing a cryptic exec failure.
print_test_section "7. Non-executable ruflo: treated as absent (memory_backend_init exits 1)"

mkdir -p "$TEST_TEMP_DIR/bin-nonexec"
cp "$TEST_TEMP_DIR/bin/ruflo" "$TEST_TEMP_DIR/bin-nonexec/ruflo"
chmod 000 "$TEST_TEMP_DIR/bin-nonexec/ruflo"
# Symlink jq so the plugin can attempt to check it
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin-nonexec/jq" 2>/dev/null || true
fi

set +e
(
    # Use ONLY the non-exec bin + system paths without ruflo — so only our
    # non-executable ruflo is found and no real ruflo sneaks in.
    export PATH="$TEST_TEMP_DIR/bin-nonexec:/usr/bin:/bin"
    unset _ZBUILD_MEMORY_RUFLO_LOADED
    # shellcheck disable=SC1090
    source "$PLUGIN_DIR/plugin.sh"
    memory_backend_init 2>/dev/null
)
nonexec_rc=$?
set -e

chmod 755 "$TEST_TEMP_DIR/bin-nonexec/ruflo" 2>/dev/null || true

if [[ "$nonexec_rc" -ne 0 ]]; then
    assert_pass "non-executable ruflo: memory_backend_init exits non-zero (rc=$nonexec_rc)"
else
    assert_fail "non-executable ruflo: memory_backend_init exits non-zero" \
        "got rc=0 — plugin treated a non-executable binary as available"
fi

# ─── Test 8: Repo prefix determinism — same ZBUILD_ROOT = same prefix ─────────
# A put followed by a get within the same ZBUILD_ROOT must produce matching
# namespace arguments in the ruflo.calls log.
print_test_section "8. Repo prefix determinism: put and get use the same prefixed namespace"

export ZBUILD_ROOT="$TEST_TEMP_DIR/project-root"

set +e
memory_put "scoping-ns" "det-key" "det-value" 2>/dev/null
set -e

set +e
det_got="$(memory_get "scoping-ns" "det-key" 2>/dev/null)"
set -e

assert_eq "prefix determinism: round-trip value is correct" "det-value" "$det_got"

# Extract namespace (-n FLAG value) from the CALL log for the put and get.
# store call: CALL: memory store -k det-key --value ... -n <ns> --upsert --quiet
# retrieve call: CALL: memory retrieve -k det-key -n <ns> --format json --quiet
_det_put_ns="$(grep 'CALL: memory store' "$RUFLO_CALLS" | grep 'det-key' | tail -1 | \
    grep -oE ' -n [^ ]+' | awk '{print $2}')"
_det_get_ns="$(grep 'CALL: memory retrieve' "$RUFLO_CALLS" | grep 'det-key' | tail -1 | \
    grep -oE ' -n [^ ]+' | awk '{print $2}')"

if [[ -n "$_det_put_ns" && "$_det_put_ns" == "$_det_get_ns" ]]; then
    assert_pass "prefix determinism: put ns='$_det_put_ns' matches get ns='$_det_get_ns'"
elif [[ -z "$_det_put_ns" && -z "$_det_get_ns" ]]; then
    # Plugin may use bare namespace without a prefix — acceptable if round-trip passed.
    assert_pass "prefix determinism: no prefix applied; both calls used bare namespace"
else
    assert_fail "prefix determinism: put and get use the same namespace argument" \
        "put_ns='$_det_put_ns', get_ns='$_det_get_ns'"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup_test_env
print_test_results
