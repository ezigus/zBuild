#!/usr/bin/env bash
# tests/unit/spec-coverage-test.sh — does the design cover what the ISSUE asked
# for? (#1683)
#
# The acceptance chain verifies spec→assertion, assertion→code, and that the
# assertion can fail. Every one of those takes the SPEC as GIVEN. Design is the
# single reader of the issue, so a design that under-scopes it produces a
# contract everything downstream satisfies perfectly — green all the way down,
# and not what was asked for.
#
# It GATES, per ADR-040 §5 as amended by #2040: a model-judged stage may sit on
# a convergence path when the standard it judges against is one the judged party
# cannot re-author. The standard here is the ISSUE, and design cannot edit it,
# so the only way to converge is to actually cover it.
#
#   SPEC-1 [change]: an issue requirement no SPEC covers yields verdict=uncovered
#                    and NAMES the requirement in structured data
#   SPEC-2 [change]: a design that covers the issue yields verdict=covered
#   SPEC-3 [change]: placeholder issue text yields `unreadable`, NEVER "covered".
#                    intake writes the literal "GitHub issue #<N>" when the fetch
#                    fails, with no marker in the artifact (#1804) — a design
#                    judged against a placeholder must not read as satisfied.
#                    This is the #1947 shape: one branch serving "nothing to
#                    check" and "the check did not happen"
#   SPEC-4 [guard] : the prompt carries the issue text and the acceptance block,
#                    and NOT the diff
#   SPEC-5 [guard] : v2 contract — result_contract:2, rc binary, and a stage
#                    that merely FINDS a problem is disposition:complete
#   SPEC-6 [change]: findings are STRUCTURED data.uncovered[], not prose
#                    (ADR-060 §1/§2)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spec-coverage: does the design cover the ISSUE? (#1683)"
setup_test_env "spec-coverage"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

# shellcheck source=../../plugins/agent/spec-coverage/plugin.sh
source "$REPO_ROOT/plugins/agent/spec-coverage/plugin.sh"

# Mocks go AFTER the source, the convention every other agent-plugin unit test
# follows (design-persona-framing-test.sh et al). The plugin sources
# core/router/route.sh at file scope (#2061), so a stub defined BEFORE the load
# is overwritten by the real function — and a stub defined before the load is
# also what let this file pass while production's router was unreachable: the
# guard here always saw a route_to_model that only ever existed in this shell.
# tests/integration/spec-coverage-router-reachable-test.sh covers that seam;
# these remain unit tests of the parse/verdict logic with the model mocked out.
_SCV_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_SCV_REPLY='VERDICT: covered
REASON: every requirement the issue states maps to a declared SPEC'
route_to_model() { printf '%s' "$2" > "$_SCV_PROMPT"; printf '%s' "$_SCV_REPLY"; return 0; }
resolve_tier() { printf 'T2'; }

_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"
    mkdir -p "$_A"
    export ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_STATE_DIR="$_S"
    printf '%s\n' "${2:-Add a --dry-run flag, and make it refuse a missing config}" > "$_S/intake.md"
    cat > "$_A/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: a --dry-run flag is accepted
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF
    printf 'diff --git a/x b/x\n+SECRET_DIFF_MARKER\n' > "$_A/diff.patch"
    printf '{}' > "$_S/pipeline-state.json"
}
_res() { jq -r "$1" "$_A/spec-coverage-result.json" 2>/dev/null || echo MISSING; }

# ── SPEC-2: a covering design passes ───────────────────────────────────────
_setup covered
set +e; spec_coverage_run "spec-coverage" "$_S/pipeline-state.json"; _rc=$?; set -e
assert_eq "[SPEC-2][change] a covering design yields covered" "covered" "$(_res '.verdict')"
assert_eq "[SPEC-5][guard] rc is binary" "0" "$_rc"
assert_eq "[SPEC-5][guard] result_contract is 2" "2" "$(_res '.result_contract')"
assert_eq "[SPEC-5][guard] a stage that merely reports is disposition=complete" \
    "complete" "$(_res '.disposition')"

_P="$(cat "$_SCV_PROMPT" 2>/dev/null || true)"
assert_contains "[SPEC-4][guard] the prompt carries the issue text" "$_P" "make it refuse a missing config"
assert_contains "[SPEC-4][guard] and the acceptance block" "$_P" "a --dry-run flag is accepted"
assert_eq "[SPEC-4][guard] and NOT the diff" "0" "$(grep -c 'SECRET_DIFF_MARKER' <<< "$_P" || true)"

# ── SPEC-1 / SPEC-6: an uncovered requirement is named, structurally ───────
_setup uncovered
_SCV_REPLY='VERDICT: uncovered
REASON: the issue also requires refusing a missing config, which no SPEC covers
UNCOVERED: refusing a missing config'
set +e; spec_coverage_run "spec-coverage" "$_S/pipeline-state.json"; _rc2=$?; set -e
assert_eq "[SPEC-1][change] an uncovered requirement yields uncovered" "uncovered" "$(_res '.verdict')"
assert_eq "[SPEC-5][guard] and rc stays binary" "0" "$_rc2"
# Structured, not prose: the finding is an ARRAY ELEMENT, addressable by index —
# a prose blob would satisfy a `contains` check on .reason just as well, which is
# exactly the redundancy ADR-060 removed.
assert_eq "[SPEC-6][change] the finding is a structured data.uncovered[] element" \
    "refusing a missing config" "$(_res '.data.uncovered[0]')"
assert_eq "[SPEC-6][change] and it is a real array, not a string" \
    "array" "$(_res '.data.uncovered | type')"

# ── SPEC-3: a placeholder issue is unreadable, never covered ───────────────
_SCV_REPLY='VERDICT: covered
REASON: nothing to cover'
_setup placeholder "GitHub issue #4242"
set +e; spec_coverage_run "spec-coverage" "$_S/pipeline-state.json"; _rc3=$?; set -e
assert_eq "[SPEC-3][change] placeholder issue text yields unreadable" \
    "unreadable" "$(_res '.verdict')"
# Three paths write `unreadable` (plugin.sh:126, :134, :179), so the verdict
# alone cannot tell placeholder-detection from a router that never answered —
# the #2061 defect would satisfy it. Pin the reason, which separates them.
assert_contains "[SPEC-3][change] refused on the PLACEHOLDER path, not a silent router failure" \
    "$(_res '.reason')" "placeholder"
assert_eq "[SPEC-5][guard] rc binary on the unreadable path too" "0" "$_rc3"

print_test_results
exit $((FAIL > 0))
