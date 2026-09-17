#!/usr/bin/env bash
# Unit: _ag_classify_disposition (#1585) — tautology + inert_wiring are BUILD-FIXABLE
# (recoverable, so the build_test_cycle re-iterates and feeds build), while a genuine
# terminal class still OUTRANKS them. Completes #1583 (which fixed only route_target).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "_ag_classify_disposition — tautology/inert_wiring recoverable (#1585)"
setup_test_env "acceptance-disposition-classify"

# Load the plugin to expose _ag_classify_disposition (same guard-unset the gate
# integration test uses for a fresh load).
unset _ZBUILD_ACCEPTANCE_GATE_LOADED
# shellcheck disable=SC1090
source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh"

if ! declare -F _ag_classify_disposition >/dev/null; then
    assert_fail "plugin exposes _ag_classify_disposition" "(function not found)"
    print_test_results
fi

# ── recoverable (build-fixable) classes ──────────────────────────────────────
assert_eq "tautology only → recoverable" "recoverable" \
    "$(_ag_classify_disposition "tautology:SPEC-1")"
assert_eq "inert_wiring only → recoverable (#1585)" "recoverable" \
    "$(_ag_classify_disposition "inert_wiring:plugins/agent/build/plugin.sh")"
assert_eq "untagged_spec only → recoverable (unchanged)" "recoverable" \
    "$(_ag_classify_disposition "untagged_spec:SPEC-2")"
assert_eq "tautology + inert_wiring (the #1576 shape) → recoverable" "recoverable" \
    "$(_ag_classify_disposition "tautology:SPEC-1" "tautology:SPEC-2" "inert_wiring:plugins/agent/build/plugin.sh")"
assert_eq "tautology + untagged → recoverable" "recoverable" \
    "$(_ag_classify_disposition "tautology:SPEC-1" "untagged_spec:SPEC-2")"

# ── wiring_not_on_path: recoverable (routes to design) ──────────────────────
assert_eq "wiring_not_on_path only → recoverable" "recoverable" \
    "$(_ag_classify_disposition "wiring_not_on_path:.github/workflows/ci.yml")"
assert_eq "wiring_not_on_path + inert_wiring → recoverable (both build-class)" "recoverable" \
    "$(_ag_classify_disposition "wiring_not_on_path:foo.yml" "inert_wiring:bar.sh")"
assert_eq "wiring_not_on_path + terminal class → terminal outranks" "terminal" \
    "$(_ag_classify_disposition "wiring_not_on_path:foo.yml" "malformed_acceptance_block")"

# SPEC-2 (iter=1 sets no route_target) is NOT asserted here. The assertion that
# used to sit at this spot re-derived the condition inside the test —
#   assert_eq ... "0" "$([[ "${ZBUILD_CYCLE_ITER:-1}" -ge 2 ]] && echo 1 || echo 0)"
# — which exercises bash's `-ge`, not the gate: it stayed green with the whole
# escalation deleted from plugin.sh (verified). It now lives in
# tests/integration/acceptance-gate-inert-wiring-iter1-test.sh, where it reads
# route_target back out of the real result artifact and dies to a `-ge 1` mutant.

# ── [SPEC-3] guard: inert_wiring disposition stays recoverable when escalated ─
# The #1711 escalation sets route_target=design on iter≥2 but MUST NOT change
# disposition to terminal — a terminal halt would prevent the aggregator from
# reading route_target and emitting route_design.
assert_eq "[SPEC-3] inert_wiring disposition stays recoverable at any iter (escalation only changes route_target)" \
    "recoverable" "$(_ag_classify_disposition "inert_wiring:.github/workflows/test.yml")"

# ── a genuine terminal class OUTRANKS recoverable ────────────────────────────
assert_eq "tautology + malformed → terminal (terminal outranks)" "terminal" \
    "$(_ag_classify_disposition "tautology:SPEC-1" "malformed_acceptance_block")"
# #2097: not_passing_at_head is the same "weak assertion" symptom as tautology /
# inert_wiring / guard_regressed — build owns the assertion (#1477) and the test
# stage has ALREADY failed on the same file at the same HEAD, so terminal only
# cancels the retry the cycle would otherwise run. Run 34869844093 halted at
# iter 1 on a comment-blind awk that build could have fixed in one iteration.
assert_eq "not_passing_at_head only → recoverable (#2097)" "recoverable" \
    "$(_ag_classify_disposition "not_passing_at_head:SPEC-1")"
assert_eq "not_passing_at_head + inert_wiring (the #1848 shape) → recoverable" "recoverable" \
    "$(_ag_classify_disposition "not_passing_at_head:SPEC-14" "inert_wiring:plugins/tool/secret-scan/plugin.sh")"
assert_eq "not_passing_at_head + malformed → terminal (terminal still outranks)" "terminal" \
    "$(_ag_classify_disposition "not_passing_at_head:SPEC-1" "malformed_acceptance_block")"

# ── advisory / none unchanged ────────────────────────────────────────────────
assert_eq "negctl_error → advisory" "advisory" \
    "$(_ag_classify_disposition "negctl_error:timeout:SPEC-1")"
assert_eq "no failures → none" "none" \
    "$(_ag_classify_disposition)"

cleanup_test_env
# ── #2109: reachability's honest classes ─────────────────────────────────────
assert_eq "[#2109] no_testfiles only → recoverable (test-author/build can create the file)" "recoverable" \
    "$(_ag_classify_disposition "no_testfiles:impl.sh")"
assert_eq "[#2109] reachability harness error → advisory (infra, never a violation)" "advisory" \
    "$(_ag_classify_disposition "reachability_error:harness:impl.sh tests/t-test.sh")"

# ── #1959 / #2129: the fallback inverts and is audible ───────────────────────
# Every entry in the allowlist was added after a run died on the class it was
# missing (#1583, #1585, #1686, #1670, #2097). A class nobody remembered to
# name must re-iterate — the cycle budget is the backstop — not halt.
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events-1959"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
assert_eq "[#1959] an unrecognised class → recoverable, not terminal" "recoverable" \
    "$(_ag_classify_disposition "brand_new_class:SPEC-9")"
assert_event_emitted "[#1959] …and it is evented" "$ZBUILD_EVENTS_JSONL" "acceptance.gate.unknown_failure_class"
assert_contains "[#1959] the event names the class" \
    "$(grep 'unknown_failure_class' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | head -1)" '"class":"brand_new_class"'
assert_eq "[#1959] malformed_acceptance_block is still terminal by name" "terminal" \
    "$(_ag_classify_disposition "malformed_acceptance_block")"
assert_eq "[#1959] no_testfile → recoverable, like untagged_spec" "recoverable" \
    "$(_ag_classify_disposition "no_testfile:SPEC-1")"
if declare -F _ag_failure_class_disposition >/dev/null 2>&1; then
    assert_eq "[#1959] the table is a function the lint can read: tautology" "recoverable" "$(_ag_failure_class_disposition tautology)"
    assert_eq "[#1959] the table is a function the lint can read: negctl_error" "advisory" "$(_ag_failure_class_disposition negctl_error)"
    assert_eq "[#1959] the table is a function the lint can read: unknown → empty" "" "$(_ag_failure_class_disposition wobble)"
else
    assert_fail "[#1959] _ag_failure_class_disposition exists" "function not defined"
fi
assert_contains "[#1959] the manifest declares config.valid_failure_classes" \
    "$(cat "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")" "valid_failure_classes:"
assert_contains "[#1959] …covering not_passing_at_head" \
    "$(awk '/valid_failure_classes:/,/^[[:space:]]*[a-z_]+:/' "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")" "not_passing_at_head"
assert_contains "[#1959] the event is registered in the manifest's provides.events" \
    "$(cat "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")" "acceptance.gate.unknown_failure_class"

print_test_results
