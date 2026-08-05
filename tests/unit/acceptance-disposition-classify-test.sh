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

# ── [SPEC-3] guard: inert_wiring disposition stays recoverable when escalated ─
# The #1711 escalation sets route_target=design on iter≥2 but MUST NOT change
# disposition to terminal — a terminal halt would prevent the aggregator from
# reading route_target and emitting route_design.
assert_eq "[SPEC-3] inert_wiring disposition stays recoverable at any iter (escalation only changes route_target)" \
    "recoverable" "$(_ag_classify_disposition "inert_wiring:.github/workflows/test.yml")"

# ── a genuine terminal class OUTRANKS recoverable ────────────────────────────
assert_eq "tautology + malformed → terminal (terminal outranks)" "terminal" \
    "$(_ag_classify_disposition "tautology:SPEC-1" "malformed_acceptance_block")"
assert_eq "not_passing_at_head stays terminal" "terminal" \
    "$(_ag_classify_disposition "not_passing_at_head:SPEC-1")"

# ── advisory / none unchanged ────────────────────────────────────────────────
assert_eq "negctl_error → advisory" "advisory" \
    "$(_ag_classify_disposition "negctl_error:timeout:SPEC-1")"
assert_eq "no failures → none" "none" \
    "$(_ag_classify_disposition)"

cleanup_test_env
print_test_results
