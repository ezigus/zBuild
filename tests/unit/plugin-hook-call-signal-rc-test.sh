#!/usr/bin/env bash
# Tests: plugin_hook_call returns the hook's own status when a signal the
# caller traps (and survives) cuts its wait short (ADR-005 §1: the run holds a
# signal while the claim is taken, so the claim's answer must be the hook's).
#
# S1 the signal's trap runs until the hook has ended: rc is the hook's 0, not
#    the interrupted wait's 143, and its output is whole
# S2 a hook that fails keeps its own status through the same signal
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "plugin_hook_call: a trapped signal does not take the hook's status"
setup_test_env "plugin-hook-call-signal-rc"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
_ZBUILD_ROOT="$REPO_ROOT"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

DIR="$TEST_TEMP_DIR/plugins/claim-coordinator/sig"; mkdir -p "$DIR"
TRAPPED="$TEST_TEMP_DIR/trapped"
cat > "$DIR/manifest.yaml" <<'EOF'
id: claim-coordinator-sig
name: Signal stub
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: sig_claim
  release: sig_release
  heartbeat: sig_hb
  list_claims: sig_list
provides:
  role: claim-coordinator
  alias: sig
EOF
# The hook signals the shell it serves (SIG_TARGET), waits until that
# shell's trap has run, then answers.
cat > "$DIR/plugin.sh" <<EOF
sig_claim() {
    kill -TERM "\$SIG_TARGET"
    for _ in \$(seq 1 400); do [[ -e "$TRAPPED" ]] && break; sleep 0.02; done
    printf '{"acquired": true}\n'
    return "\${SIG_RC:-0}"
}
sig_release() { return 0; }
sig_hb() { return 0; }
sig_list() { printf '[]\n'; }
EOF

# _call <hook rc> — in a shell whose TERM trap marks the signal and waits for the
# hook ($! is the hook's job) to be gone, as a slow trap would.
_call() {
    rm -f "$TRAPPED"
    (
        trap ': > "$TRAPPED"; for _ in $(seq 1 400); do kill -0 "$!" 2>/dev/null || break; sleep 0.02; done' TERM
        rc=0; SIG_TARGET="$BASHPID" SIG_RC="$1" plugin_hook_call "$DIR" claim 1 > "$TEST_TEMP_DIR/out" 2>/dev/null || rc=$?
        echo "$rc"
    )
}

print_test_section "S1"
got="$(_call 0)"
assert_file_exists "[S1] setup: the trap ran" "$TRAPPED"
assert_eq "[S1] rc is the hook's 0" "0" "$got"
assert_eq "[S1] …and its answer is whole" '{"acquired": true}' "$(cat "$TEST_TEMP_DIR/out")"

print_test_section "S2"
assert_eq "[S2] a failing hook keeps its own status (3)" "3" "$(_call 3)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
