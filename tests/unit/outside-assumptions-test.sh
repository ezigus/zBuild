#!/usr/bin/env bash
# tests/unit/outside-assumptions-test.sh — design, build and the lenses are told
# one rule on what a change assumes about the world outside its code (#2584 R6;
# ADR-038, ADR-040, amended 2026-11-22).
#
# Why: on #1764 the engine claimed issues with a `zbuild:claimed` label that did
# not exist. Design did not name the assumption, build did not check it, and no
# lens could see it.
#
# OA1 [change] the rule names the kinds of outside thing and what handled means
# OA2 [change] design's prompt carries it, and asks design to name each one with
#              how it is handled
# OA3 [change] build's prompt carries it, and asks build to handle each one
# OA4 [change] the lens's prompt carries it (review-lens-asks-test.sh S7 checks
#              the lens's own sentences)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "one rule on outside assumptions, for design, build and the lenses (#2584)"
setup_test_env "outside-assumptions"
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }

# shellcheck source=../../scripts/lib/outside-assumptions.sh
source "$REPO_ROOT/scripts/lib/outside-assumptions.sh"
RULE="$(_flat "${ZB_OUTSIDE_ASSUMPTIONS_RULE:-<no rule>}")"; RULE="${RULE% }"

print_test_section "OA1: the rule"
for _k in "a service" "a repository setting" "an environment value" "a data format" "another program's output"; do
    assert_contains "[OA1] it names $_k" "$RULE" "$_k"
done
assert_contains "[OA1] handled: the code creates it" "$RULE" "Handled means the code creates it"
assert_contains "[OA1] ...or checks it and fails clearly" "$RULE" "checks it and fails clearly, with an event or a status line"
assert_contains "[OA1] ...or the design says why it is safe" "$RULE" "the design says why it is safe to assume"

print_test_section "OA2: design"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    route_to_model() { return 0; }
    apply_scope_redaction() { cp "$1" "$2"; }
    atomic_write() { cat - > "$1"; }
    art="$TEST_TEMP_DIR/state/artifacts"; mkdir -p "$art"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/state/scope-manifest.md"
    export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/state/events.jsonl" ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/state"
    _design_stage_run_inner "$TEST_TEMP_DIR/state/scope-manifest.md" "$art/design.md" "$art" >/dev/null 2>&1 || true
)
D="$(_flat "$(cat "$TEST_TEMP_DIR/state/artifacts/design-prompt.txt" 2>/dev/null)")"
assert_contains "fixture: design's prompt was written" "$D" "acceptance"
assert_contains "[OA2] design's prompt carries the rule" "$D" "$RULE"
assert_contains "[OA2] ...and asks it to name each one" "$D" "Name each outside assumption in the design, with how it is handled"

print_test_section "OA3: build"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
B="$(_flat "$(_build_compose_instructions)")"
assert_contains "[OA3] build's prompt carries the rule" "$B" "$RULE"
assert_contains "[OA3] ...and asks it to handle each one" "$B" "Handle each outside assumption the change makes"

print_test_section "OA4: the lens"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
assert_contains "[OA4] the lens's prompt carries the rule" "$(_flat "$(_rl_build_lens_prompt sre "THE-CHANGE" "")")" "$RULE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
