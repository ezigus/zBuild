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
#   SPEC-8 [change]: a SPEC that demands less than its requirement does not
#                    cover it — fidelity, not just a mapping (#1849)
#                    (ADR-060 §1/§2)
#   SPEC-9 [code]  : an issue requirement an already-done SPEC covers counts as
#                    covered — issue-acceptance checks the claim later (#2304,
#                    ADR-069 §7); the how-it-is-verified exemption is kept
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

# ─── SPEC-7 (#2176): process requirements are the pipeline's to prove ────────
# #1841: the issue's "Reddens at the merge-base" checkbox was demanded as a
# SPEC three design rounds running; the gate proves that mechanically for every
# [change] SPEC, and the design invented two unverifiable SPECs trying to comply.
# #2308 (ADR-067 §8): reworded so it says what this stage owns — the behaviour,
# judged before any code exists — not that the pipeline proves the rest.
print_test_section "SPEC-7: the prompt says verification-process requirements are not gaps"
_P7="$(tr -s '[:space:]' ' ' <<< "$_P")"
assert_contains "[SPEC-7][change] the prompt distinguishes behaviour from how the change is verified" \
    "$_P7" "your part of each requirement is the BEHAVIOUR it asks of the software"
assert_contains "[SPEC-7][change] …and says such a requirement does not go in UNCOVERED" "$_P7" \
    "the check that compares the finished change with the issue judges it there. It does not go in UNCOVERED"

# #1849 (run 36238164552): the issue said "constructs no artifact paths in code";
# the SPEC said "no hardcoded declared-input paths" — narrower — and this stage
# called it covered. Mapping to a SPEC is not enough; the SPEC must demand all of it.
print_test_section "SPEC-8: a SPEC that narrows a requirement does not cover it"
assert_contains "[SPEC-8][change] the prompt says a narrower SPEC leaves the requirement uncovered" \
    "$_P" "demands less than the requirement"
assert_contains "[SPEC-8][change] …naming the ways a SPEC narrows (subset of cases, weaker condition)" \
    "$_P" "a subset of the cases"

# #2304 (ADR-069 §7): a [done] SPEC is a claim that the code already does it.
# This stage reads the issue before any code exists and cannot check the claim;
# issue-acceptance does, against the code. Here it counts as covered.
print_test_section "SPEC-9: a requirement an already-done SPEC covers is covered"
_P9="$(tr -s '[:space:]' ' ' <<< "$_P")"
assert_contains "[SPEC-9] the prompt says an already-done SPEC covers its requirement" \
    "$_P9" "A SPEC tagged [done] says the code already does it. A requirement it covers counts as covered"
assert_contains "[SPEC-9] ...because the claim is judged against the code once it is built" \
    "$_P9" "the claim is judged against the code once the change is built"
assert_contains "[SPEC-9] the how-it-is-verified exemption is kept" "$_P9" "It does not go in UNCOVERED"

# ─── [#2032/SPEC-3]: route_to_model rc=124 (timeout) → disposition=timed_out ──
# Before fix: `|| true` discards the rc and _scv_write always writes disposition:"complete".
# After  fix: rc is captured, classified via _router_rc_classify + router_reason_disposition,
#             and the result carries the classified disposition (rc=124 → router_timeout → timed_out).
print_test_section "[#2032/SPEC-3]: router timeout classified into disposition"
_setup sc3_timeout "# Add a --dry-run flag, and make it refuse a missing config"
route_to_model() { return 124; }   # timeout, no output — rc must not be discarded
set +e; spec_coverage_run "spec-coverage" "$_S/pipeline-state.json"; _rc_s3=$?; set -e
# Restore the module-level stub so later tests are unaffected (none exist, but safe).
route_to_model() { printf '%s' "$2" > "$_SCV_PROMPT"; printf '%s' "$_SCV_REPLY"; return 0; }
assert_eq "[#2032/SPEC-3] rc=0 — finding a timeout is not a stage failure" "0" "$_rc_s3"
assert_eq "[#2032/SPEC-3] route_to_model rc=124 → disposition=timed_out (not hardcoded complete)" \
    "timed_out" "$(_res '.disposition')"

# SPEC-3 covers any non-zero rc, not just rc=124 (which is named only as an example).
# rc=1 (generic non-zero, no output) must also produce a classified disposition, not 'complete'.
_setup sc3_rc1 "# Add a --dry-run flag, and make it refuse a missing config"
route_to_model() { return 1; }
set +e; spec_coverage_run "spec-coverage" "$_S/pipeline-state.json"; _rc_s3b=$?; set -e
route_to_model() { printf '%s' "$2" > "$_SCV_PROMPT"; printf '%s' "$_SCV_REPLY"; return 0; }
assert_eq "[#2032/SPEC-3] rc=0 for any non-zero router rc (not a stage failure)" "0" "$_rc_s3b"
assert_eq "[#2032/SPEC-3] route_to_model rc=1 → disposition=unavailable (any non-zero rc classified, not hardcoded complete)" \
    "unavailable" "$(_res '.disposition')"

print_test_results
exit $((FAIL > 0))
