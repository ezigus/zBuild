#!/usr/bin/env bash
# tests/unit/test-author-test.sh — assertions are authored from the SPEC, by a
# stage that cannot see the implementation (#2022).
#
# Build authoring both the code and the assertion is correlated error: the two
# agree by construction, so no check comparing them can catch a misreading. Two
# runs shipped exactly that (ADR-036:512; #1978). This stage takes assertion
# authorship back, and its ISOLATION is the mechanism — an author that can read
# the implementation would just describe it, which is the defect wearing a
# different hat.
#
#   SPEC-1 [change]: the prompt carries the SPEC's requirement TEXT, not just
#                    its id — the #1978 defect was the text sitting 130 lines
#                    away while the instruction named only the id
#   SPEC-2 [guard] : the prompt carries NO implementation — not the diff, not
#                    the build summary. Isolation is the whole mechanism
#   SPEC-3 [change]: a completed authoring pass records the assertion digests,
#                    so assertion-integrity has a baseline to compare against
#   SPEC-4 [guard] : v2 contract — result_contract:2 on the result, rc binary
#   SPEC-5 [change]: a router failure maps to a DISPOSITION (ADR-054 §6), not to
#                    a cheerful verdict — the stage did not do its job
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-author: assertions from the SPEC, blind to the code (#2022)"
setup_test_env "test-author"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true

_TA_PROMPT="$TEST_TEMP_DIR/prompt.txt"
_TA_RC=0
route_to_model() { printf '%s' "$2" > "$_TA_PROMPT"; printf 'authored\n'; return $_TA_RC; }
resolve_tier() { printf 'T2'; }

# shellcheck source=../../plugins/agent/test-author/plugin.sh
source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"

_setup() {
    _S="$TEST_TEMP_DIR/$1"; _A="$_S/artifacts"; _R="$_S/repo"
    mkdir -p "$_A" "$_R/tests"
    export ZBUILD_REPO_ROOT="$_R" ZBUILD_ARTIFACT_DIR="$_A"
    printf '%s\n' 'assert_eq "[SPEC-1] placeholder" "1" "$got"' > "$_R/tests/acc-test.sh"
    cat > "$_A/design.md" <<'EOF'
# Design
```acceptance
SPEC-1[change]: plugin-specific fields live under data:{} not at the top level
TESTFILES:
SPEC-1: tests/acc-test.sh
WIRING: scripts/thing.sh
```
EOF
    # The implementation, sitting right beside the design where a careless
    # prompt builder would sweep it in.
    printf 'diff --git a/x b/x\n+exit_code at top level\n' > "$_A/diff.patch"
    printf '{"verdict":"pass","files_changed_count":3}' > "$_A/build-summary.json"
    printf '{}' > "$_S/pipeline-state.json"
}
_res() { jq -r "$1" "$_A/test-author-result.json" 2>/dev/null || echo MISSING; }

# ─── Happy path ─────────────────────────────────────────────────────────────
_setup ok
_TA_RC=0
set +e; test_author_run "test-author" "$_S/pipeline-state.json"; _rc=$?; set -e
_P="$(cat "$_TA_PROMPT" 2>/dev/null || true)"

assert_contains "[SPEC-1][change] the prompt carries the SPEC's requirement TEXT" \
    "$_P" "fields live under data:{} not at the top level"
assert_eq "[SPEC-2][guard] the prompt carries NO diff" \
    "0" "$(grep -c 'diff --git' <<< "$_P" || true)"
assert_eq "[SPEC-2][guard] nor the build summary" \
    "0" "$(grep -c 'files_changed_count' <<< "$_P" || true)"
assert_file_exists "[SPEC-3][change] a completed pass records the assertion digests" \
    "$_A/assertion-digests.txt"
assert_eq "[SPEC-4][guard] the result declares result_contract 2" "2" "$(_res '.result_contract')"
assert_eq "[SPEC-4][guard] rc is binary — a good pass is 0" "0" "$_rc"
assert_eq "[SPEC-4][guard] a completed pass is disposition=complete" \
    "complete" "$(_res '.disposition')"

# ─── Router failure ─────────────────────────────────────────────────────────
_setup timeout
_TA_RC=124
set +e; test_author_run "test-author" "$_S/pipeline-state.json"; _rc2=$?; set -e
assert_eq "[SPEC-5][change] a router timeout is NOT reported as a clean authoring pass" \
    "degraded" "$(_res '.verdict')"
assert_eq "[SPEC-5][change] and it maps to a non-complete disposition" \
    "1" "$([[ "$(_res '.disposition')" != "complete" ]] && echo 1 || echo 0)"
assert_eq "[SPEC-4][guard] rc stays binary on failure" \
    "1" "$([[ "$_rc2" == "0" || "$_rc2" == "1" ]] && echo 1 || echo 0)"

print_test_results
exit $((FAIL > 0))
