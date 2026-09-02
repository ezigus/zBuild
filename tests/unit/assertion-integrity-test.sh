#!/usr/bin/env bash
# tests/unit/assertion-integrity-test.sh — build must not be able to rewrite an
# acceptance assertion to agree with its own code (#2022).
#
# The deny rules (#1919 P5) refuse Edit() on the TESTFILES, but P5 also measured
# that a Write(...) rule matches nothing — so prevention is incomplete BY
# CONSTRUCTION. This guard is the backstop: it compares the declared TESTFILES
# against the digest test-author recorded and fails the cycle when they differ.
#
#   SPEC-1 [change]: an unmodified testfile yields verdict=pass
#   SPEC-2 [change]: a MODIFIED testfile yields verdict=fail and names the file
#   SPEC-3 [guard] : the verdict rides a result_contract:2 artifact, and a gate
#                    that merely FINDS a problem is disposition:complete — it ran
#                    fine, the verdict carries the bad news (ADR-054 §6)
#   SPEC-4 [guard] : rc is binary (ADR-054 §4) — finding a violation is rc=0
#                    with verdict=fail, never a nonzero rc
#   SPEC-5 [change]: with no recorded digest the guard SKIPS rather than
#                    failing closed — a run whose author stage never ran has
#                    nothing to compare, and a false fail would stall the cycle
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "assertion-integrity: build cannot rewrite an assertion (#2022)"
setup_test_env "assertion-integrity"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../plugins/tool/assertion-integrity/plugin.sh
source "$REPO_ROOT/plugins/tool/assertion-integrity/plugin.sh"

_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; _R="$_S/repo"
    mkdir -p "$_A" "$_R/tests"
    export ZBUILD_REPO_ROOT="$_R"
    printf '%s\n' 'assert_eq "[SPEC-1] the boundary holds" "1" "$got"' \
        > "$_R/tests/acc-test.sh"
    cat > "$_A/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: the boundary holds
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF
    printf '{}' > "$_S/pipeline-state.json"
}
_result() { jq -r "$1" "$_A/assertion-integrity-result.json" 2>/dev/null || echo MISSING; }

# ─── SPEC-1: untouched testfile passes ──────────────────────────────────────
_setup unmodified
assertion_integrity_record "$_A" "$_R" 2>/dev/null || true
set +e; assertion_integrity_run "assertion-integrity" "$_S/pipeline-state.json"; _rc=$?; set -e
assert_eq "[SPEC-1][change] an unmodified testfile passes" "pass" "$(_result '.verdict')"
assert_eq "[SPEC-4][guard] finding nothing is rc=0" "0" "$_rc"

# ─── SPEC-2: modified testfile fails and names the file ─────────────────────
_setup modified
assertion_integrity_record "$_A" "$_R" 2>/dev/null || true
printf '%s\n' 'assert_eq "[SPEC-1] the boundary holds" "0" "$got"' \
    > "$_R/tests/acc-test.sh"   # build weakens the assertion to match its code
set +e; assertion_integrity_run "assertion-integrity" "$_S/pipeline-state.json"; _rc2=$?; set -e
assert_eq "[SPEC-2][change] a modified testfile fails" "fail" "$(_result '.verdict')"
assert_contains "[SPEC-2][change] and the reason names the file" \
    "$(_result '.reason')" "tests/acc-test.sh"
assert_eq "[SPEC-4][guard] finding a violation is STILL rc=0, not a nonzero rc" "0" "$_rc2"
assert_eq "[SPEC-3][guard] a gate that merely finds a problem is disposition=complete" \
    "complete" "$(_result '.disposition')"
assert_eq "[SPEC-3][guard] the artifact declares result_contract 2" \
    "2" "$(_result '.result_contract')"

# ─── SPEC-5: nothing recorded → skip, not a false fail ──────────────────────
_setup norecord
set +e; assertion_integrity_run "assertion-integrity" "$_S/pipeline-state.json"; _rc3=$?; set -e
assert_eq "[SPEC-5][change] no recorded digest skips rather than failing closed" \
    "skip" "$(_result '.verdict')"
assert_eq "[SPEC-4][guard] a skip is rc=0 too" "0" "$_rc3"

print_test_results
exit $((FAIL > 0))
