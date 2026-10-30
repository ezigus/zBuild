#!/usr/bin/env bash
# tests/unit/lens-fail-rule-test.sh — the template defines a lens's fail rule
# (#2368 part 3, ADR-040).
#
# Why: when a lens fails was written into review-lens's code ("a high or
# critical problem the change introduced"). What makes a stage fail is the
# template's to say, like what blocks a loop.
#
#   F1 [change] a stage's `fail_on:` list reaches its plugin as
#               _TPL_STAGE_FAIL_ON_<stage>
#   F2 [change] a lens fails only on a problem the change introduced whose
#               severity the template lists — and passes on any other
#   F3 [change] the shipped templates say a lens fails on high or critical
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the template defines a lens's fail rule (#2368 part 3)"
setup_test_env "lens-fail-rule"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

print_test_section "F1: the template's list reaches the plugin"
_got="$(bash -c 'source "$1/scripts/lib/helpers.sh"; source "$1/core/pipeline/template.sh"
    load_template "$1/config/templates/simple.yaml" >/dev/null 2>&1; printf "%s" "${_TPL_STAGE_FAIL_ON_review_lenses:-unset}"' _ "$REPO_ROOT")"
assert_eq "[F1] simple.yaml's review_lenses fail_on reaches the plugin (#2433: medium and above)" "medium high critical" "$_got"

print_test_section "F2: the lens fails only on what the template lists"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
ART="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ART"
: > "$ART/diff.patch"; printf 'scope: all\n' > "$TEST_TEMP_DIR/scope-manifest.md"
_lens() {  # <fail_on> <findings json> — prints the lens's outcome
    route_to_model() { printf '%s' "{\"score\":7,\"findings\":$_FINDINGS}"; return 0; }
    rm -f "$ART/lens-red-team.json"
    _FINDINGS="$2" _TPL_STAGE_FAIL_ON_review_lenses="$1" ZBUILD_CURRENT_STAGE=review_lenses \
        ZBUILD_REVIEW_LENS_ID=red-team \
        _review_lens_run_inner red-team "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1 || true
    jq -r '.outcome // "none"' "$ART/lens-red-team.json" 2>/dev/null
}
_med='[{"file":"a.sh","category":"x","severity":"medium","line":1,"message":"m","introduced":true}]'
_high_old='[{"file":"a.sh","category":"x","severity":"high","line":1,"message":"h","introduced":false}]'
_high='[{"file":"a.sh","category":"x","severity":"high","line":1,"message":"h","introduced":true}]'
assert_eq "[F2] fail_on medium: a medium problem the change introduced fails" "fail" "$(_lens "medium" "$_med")"
assert_eq "[F2] fail_on critical: a high problem passes" "pass" "$(_lens "critical" "$_high")"
assert_eq "[F2] fail_on high: a high problem the change did NOT introduce passes" "pass" "$(_lens "high critical" "$_high_old")"
# ADR-040 (#2368 part 3): a lens with no list never fails (review on PR #2392).
assert_eq "[F2] no fail_on: a high problem the change introduced passes" "pass" "$(_lens "" "$_high")"

print_test_section "F3: the shipped templates"
for _t in simple deployed; do
    assert_contains "[F3] $_t.yaml: a lens fails on medium, high or critical (#2433)" \
        "$(awk '/^review_lenses:/{f=1} f&&/^[a-z_-]+:/&&!/^review_lenses:/{exit} f' "$REPO_ROOT/config/templates/$_t.yaml")" "fail_on: [medium, high, critical]"
done

cleanup_test_env
print_test_results
exit $((FAIL > 0))
