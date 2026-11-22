#!/usr/bin/env bash
# plugins/agent/review-lens/tests/review-lens-whole-inputs-test.sh — a lens is
# shown its inputs whole (#2584 R3; ADR-038, amended 2026-11-22).
#
# Why: on #1764 run 44910536811 THE ISSUE and THE REQUIREMENTS were cut at
# 6,000 characters, so DSCLA-23 never reached any lens. Each section is given
# in full; one over the size a prompt holds inline is given as the path of the
# file that holds it whole, for the lens to read. Nothing is cut.
#
# W1 [change] an issue past 6,000 characters is in the prompt whole, its last
#             words included
# W2 [change] requirements past 6,000 characters: the last one is in the prompt
# W3 [change] the design's decisions past 80 lines: the last decision is there
# W4 [change] the design steps build found not needed, past 4,000 characters:
#             the last one is there
# W5 [change] an issue over the inline size: the prompt names the file that
#             holds it whole, and holds no piece of it; that file holds the
#             whole issue
# W6 [change] requirements and decisions over the inline size: the prompt names
#             the design file that holds them, and holds no piece of them
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "plugin: review-lens — every input whole, or its path (#2584 R3)"
setup_test_env "plugin-review-lens-whole-inputs"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"
# shellcheck source=../../../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

PROMPT_F="$TEST_TEMP_DIR/prompt.txt"
route_to_model() { zb_test_lens_check_answer "$2" && return 0; printf '%s' "$2" > "$PROMPT_F"; printf '%s' '{"score":9,"findings":[]}'; }
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# _filler <n> <word> — about <n> characters of sentences, none repeating a marker.
_filler() { local o="" i=0; while (( ${#o} < $1 )); do o+="$2 sentence $i of the issue body. "; i=$(( i + 1 )); done; printf '%s' "$o"; }

# _setup <dir> <issue> <n_specs> <n_decisions> <n_steps> [pad] — one run's
# earlier work, each made by its writer: the issue as intake hands it on, a
# design (each SPEC and decision padded by [pad]), build's steps.
_setup() {
    local d="$1" i pad="${6:-}"
    rm -rf "$d"; mkdir -p "$d/art"
    zb_test_issue_output "$d/art" "$2" >/dev/null
    { printf '# Design\n\n'
      for (( i = 1; i <= $4; i++ )); do printf 'Decision %s: DECISION-%s keeps the claim with the engine.%s\n' "$i" "$i" "$pad"; done
      printf '\n```acceptance\n'
      for (( i = 1; i <= $3; i++ )); do printf 'SPEC-%s[change]: SPECTEXT-%s the engine claims the issue before it starts work on it and releases the claim after%s\n' "$i" "$i" "$pad"; done
      printf '```\n'; } > "$d/art/design.md"
    local steps="[]"
    if (( $5 > 0 )); then
        steps="$(jq -nc --argjson n "$5" '[range(1; $n + 1) | "step \(.): not needed — STEPWHY-\(.) the label already exists in every repository the engine runs on"]')"
    fi
    stage_result_write "$d/art/build-summary.json" pass "built" "$(jq -nc --argjson s "$steps" '{steps: $s}')" >/dev/null
    printf 'diff --git a/a.sh b/a.sh\n+x=1\n' > "$d/art/diff.patch"
}
_run() {
    : > "$PROMPT_F"
    _review_lens_run_inner correctness "" "$1/art/diff.patch" "$1/art/lens-correctness.json" "$1/art" >/dev/null 2>&1 || true
    P="$(cat "$PROMPT_F")"
}

print_test_section "W1–W4: past the old cuts, still whole"
D="$TEST_TEMP_DIR/w1"
_setup "$D" "$(_filler 7000 'ISSUEWORD')ISSUE-END-MARKER the very last words" 45 85 60 " and keeps it while the run is live"
_run "$D"
assert_contains "[W1] the issue's last words are in the prompt" "$P" "ISSUE-END-MARKER the very last words"
assert_contains "[W2] the last requirement is there" "$P" "SPECTEXT-45 "
assert_contains "[W3] the last decision is there" "$P" "DECISION-85 "
assert_contains "[W4] the last not-needed step is there" "$P" "STEPWHY-60 "

print_test_section "W5–W6: over the inline size, the path"
D="$TEST_TEMP_DIR/w5"
_setup "$D" "$(_filler 200000 'BIGWORD')BIG-END-MARKER" 20 20 0 "$(_filler 1500 'PAD')"
_run "$D"
assert_contains "[W5] the prompt names the file that holds the issue" "$P" "$D/art/intake-result.json"
_lacks "[W5] ...and holds no piece of it" "$P" "BIGWORD sentence 0 "
assert_contains "[W5] that file holds the whole issue" "$(jq -r '.data.issue_text' "$D/art/intake-result.json")" "BIG-END-MARKER"
assert_contains "[W6] the prompt names the design file for the requirements" "$P" "$D/art/design.md"
_lacks "[W6] ...and holds no piece of the requirements" "$P" "SPECTEXT-1 "
_lacks "[W6] ...nor of the decisions" "$P" "DECISION-1 "

cleanup_test_env
print_test_results
exit $((FAIL > 0))
