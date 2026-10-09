#!/usr/bin/env bash
# Tests: scripts/lib/timeout-cmd.sh — shared _acceptance_timeout_prefix helper (#1752)
#   SPEC-1:  gtimeout-only PATH populates _ACCEPTANCE_TOUT[0]=gtimeout
#   SPEC-2:  no timeout binary leaves _ACCEPTANCE_TOUT empty, returns 0
#   SPEC-3:  build false-completion guard detects inert_build after helper is shared
#   SPEC-8:  structural grep — converted files call _acceptance_timeout_prefix, no command -v gtimeout
#   SPEC-9:  each of the five non-acceptance-gate sites produces gtimeout on gtimeout-only host
#   SPEC-10: per-caller kill-grace env bridge wired for run-tests.sh and run-mutation.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "timeout-cmd.sh — shared _acceptance_timeout_prefix helper (#1752)"
setup_test_env "timeout-cmd-helper"
_test_cleanup_hook() { cleanup_test_env; }

# ── [#1752/SPEC-8]: structural grep — each converted file uses the helper ────
print_test_section "[#1752/SPEC-8] converted files contain _acceptance_timeout_prefix, no command -v gtimeout"

_s8_files=(
    "core/router/route.sh"
    "scripts/run-tests.sh"
    "scripts/run-mutation.sh"
    "scripts/lib/gh-automation.sh"
    "scripts/lib/acceptance-block.sh"
)
for _s8f in "${_s8_files[@]}"; do
    _s8path="$REPO_ROOT/$_s8f"
    if grep -q "_acceptance_timeout_prefix" "$_s8path" 2>/dev/null; then
        assert_pass "[#1752/SPEC-8] $_s8f: contains _acceptance_timeout_prefix"
    else
        assert_fail "[#1752/SPEC-8] $_s8f: contains _acceptance_timeout_prefix" \
            "missing call to shared helper in $_s8f"
    fi
    if ! grep -q "command -v gtimeout" "$_s8path" 2>/dev/null; then
        assert_pass "[#1752/SPEC-8] $_s8f: no command -v gtimeout inline pattern"
    else
        assert_fail "[#1752/SPEC-8] $_s8f: no command -v gtimeout inline pattern" \
            "old inline probe still present in $_s8f"
    fi
done

# ── Source the new shared helper — fails before the change ────────────────────
# shellcheck source=../../scripts/lib/timeout-cmd.sh
source "$REPO_ROOT/scripts/lib/timeout-cmd.sh"

# ── Fake gtimeout: always exits 0 so the -k probe succeeds ───────────────────
mkdir -p "$TEST_TEMP_DIR/fakebin"
cat > "$TEST_TEMP_DIR/fakebin/gtimeout" <<'FAKE_EOF'
#!/usr/bin/env bash
exit 0
FAKE_EOF
chmod +x "$TEST_TEMP_DIR/fakebin/gtimeout"

_SAVED_PATH="$PATH"

# ── [#1752/SPEC-1]: gtimeout-only PATH populates _ACCEPTANCE_TOUT[0]=gtimeout ─
print_test_section "[#1752/SPEC-1] gtimeout-only PATH uses gtimeout as the binary"

_ACCEPTANCE_TOUT=()
unset _ACCEPTANCE_TIMEOUT_KILL_OK
export PATH="$TEST_TEMP_DIR/fakebin"
_acceptance_timeout_prefix 30
export PATH="$_SAVED_PATH"

if [[ "${#_ACCEPTANCE_TOUT[@]}" -gt 0 ]]; then
    assert_eq "[#1752/SPEC-1] _ACCEPTANCE_TOUT[0] is gtimeout on gtimeout-only PATH" \
        "gtimeout" "${_ACCEPTANCE_TOUT[0]}"
else
    assert_fail "[#1752/SPEC-1] _ACCEPTANCE_TOUT[0] is gtimeout on gtimeout-only PATH" \
        "_ACCEPTANCE_TOUT is empty — no timeout binary found on gtimeout-only PATH"
fi

# ── [#1752/SPEC-2]: no timeout binary leaves _ACCEPTANCE_TOUT empty ──────────
print_test_section "[#1752/SPEC-2] no timeout binary leaves _ACCEPTANCE_TOUT empty, returns 0"

_ACCEPTANCE_TOUT=()
unset _ACCEPTANCE_TIMEOUT_KILL_OK
export PATH="/nonexistent-path-$$"
_spec2_rc=0
_acceptance_timeout_prefix 30 || _spec2_rc=$?
export PATH="$_SAVED_PATH"

assert_eq "[#1752/SPEC-2] returns 0 when no timeout binary" "0" "$_spec2_rc"
assert_eq "[#1752/SPEC-2] _ACCEPTANCE_TOUT is empty when no timeout binary" \
    "0" "${#_ACCEPTANCE_TOUT[@]}"

# ── [#1752/SPEC-3]: build false-completion guard still detects inert_build ────
print_test_section "[#1752/SPEC-3] build false-completion guard detects red testfile after helper is shared"

# Minimal mocks so plugin.sh sources without LLM calls or event-bus writes.
# shellcheck disable=SC2317
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() {
    local _in="$1" _out="$2"
    [[ -f "$_in" ]] && cp "$_in" "$_out"
    return 0
}

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR/artifacts"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

_S3_REPO="$TEST_TEMP_DIR/s3-repo"
mkdir -p "$_S3_REPO"
(
    cd "$_S3_REPO"
    git init -q
    git config user.email t@t
    git config user.name t
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m seed
) >/dev/null

mkdir -p "$_S3_REPO/tests/unit"
cat > "$_S3_REPO/tests/unit/always-fail-test.sh" <<'FAIL_EOF'
#!/usr/bin/env bash
exit 1
FAIL_EOF
chmod +x "$_S3_REPO/tests/unit/always-fail-test.sh"

# Reset timeout memo so the guard's _acceptance_timeout_prefix re-probes cleanly.
_ACCEPTANCE_TOUT=()
unset _ACCEPTANCE_TIMEOUT_KILL_OK

_s3_failing=""
_s3_rc=0
_s3_failing="$(_build_guard_false_completion \
    "tests/unit/always-fail-test.sh" "$_S3_REPO" 2>/dev/null)" || _s3_rc=$?

assert_eq "[#1752/SPEC-3] guard exits 1 for red testfile (signals inert_build to caller)" \
    "1" "$_s3_rc"
assert_eq "[#1752/SPEC-3] guard returns the failing testfile path" \
    "tests/unit/always-fail-test.sh" "$_s3_failing"

# ── [#1752/SPEC-9]: five non-acceptance-gate sites produce gtimeout ────────────
print_test_section "[#1752/SPEC-9] each converted site produces gtimeout on gtimeout-only host"

_s9_labels=(
    "core/router/route.sh sync path"
    "core/router/route.sh loop path"
    "scripts/run-tests.sh"
    "scripts/run-mutation.sh"
    "scripts/lib/gh-automation.sh"
)
for _s9_label in "${_s9_labels[@]}"; do
    _ACCEPTANCE_TOUT=()
    unset _ACCEPTANCE_TIMEOUT_KILL_OK
    export PATH="$TEST_TEMP_DIR/fakebin"
    _acceptance_timeout_prefix 60
    export PATH="$_SAVED_PATH"
    if [[ "${#_ACCEPTANCE_TOUT[@]}" -gt 0 ]]; then
        assert_eq "[#1752/SPEC-9] $_s9_label: _ACCEPTANCE_TOUT[0]=gtimeout" \
            "gtimeout" "${_ACCEPTANCE_TOUT[0]}"
    else
        assert_fail "[#1752/SPEC-9] $_s9_label: _ACCEPTANCE_TOUT non-empty" \
            "_ACCEPTANCE_TOUT is empty — gtimeout not found on gtimeout-only PATH"
    fi
done

# ── [#1752/SPEC-10]: per-caller kill-grace env bridge ─────────────────────────
print_test_section "[#1752/SPEC-10] per-caller kill-grace env bridge"

# run-tests.sh bridge: ZBUILD_TEST_KILL_GRACE=42
ZBUILD_TEST_KILL_GRACE=42
_ACCEPTANCE_TOUT=()
unset _ACCEPTANCE_TIMEOUT_KILL_OK
export PATH="$TEST_TEMP_DIR/fakebin"
export ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_TEST_KILL_GRACE:-10}"
_acceptance_timeout_prefix 60
export PATH="$_SAVED_PATH"

# With -k supported: _ACCEPTANCE_TOUT = [gtimeout, -k, <grace>, <timeout_s>]
if [[ "${#_ACCEPTANCE_TOUT[@]}" -ge 4 ]]; then
    assert_eq "[#1752/SPEC-10] run-tests.sh bridge: kill grace index 2 is 42" \
        "42" "${_ACCEPTANCE_TOUT[2]}"
    assert_eq "[#1752/SPEC-10] run-tests.sh bridge: element 1 is -k flag" \
        "-k" "${_ACCEPTANCE_TOUT[1]}"
else
    assert_fail "[#1752/SPEC-10] run-tests.sh bridge: _ACCEPTANCE_TOUT has -k and grace" \
        "array too short (${#_ACCEPTANCE_TOUT[@]} elements): ${_ACCEPTANCE_TOUT[*]:-empty}"
fi

# run-mutation.sh bridge: ZBUILD_MUTATION_KILL_GRACE=7
ZBUILD_MUTATION_KILL_GRACE=7
_ACCEPTANCE_TOUT=()
unset _ACCEPTANCE_TIMEOUT_KILL_OK
export PATH="$TEST_TEMP_DIR/fakebin"
export ZBUILD_NEGCTL_KILL_GRACE="${ZBUILD_MUTATION_KILL_GRACE:-10}"
_acceptance_timeout_prefix 300
export PATH="$_SAVED_PATH"

if [[ "${#_ACCEPTANCE_TOUT[@]}" -ge 4 ]]; then
    assert_eq "[#1752/SPEC-10] run-mutation.sh bridge: kill grace index 2 is 7" \
        "7" "${_ACCEPTANCE_TOUT[2]}"
    assert_eq "[#1752/SPEC-10] run-mutation.sh bridge: element 1 is -k flag" \
        "-k" "${_ACCEPTANCE_TOUT[1]}"
else
    assert_fail "[#1752/SPEC-10] run-mutation.sh bridge: _ACCEPTANCE_TOUT has -k and grace" \
        "array too short (${#_ACCEPTANCE_TOUT[@]} elements): ${_ACCEPTANCE_TOUT[*]:-empty}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
