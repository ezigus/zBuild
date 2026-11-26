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
# W5 [change] an issue over the inline size: the prompt names a file in the
#             stage's scratch that holds it whole, and holds no piece of it
# W6 [change] requirements, decisions and the not-needed steps over the inline
#             size: each a file of its own, one path each, the prompt holding no
#             piece of them
# W7 [change] (review) such a file is sanitised and redacted as an inline
#             section is: a private path is <private>, no terminal escape
# W8 [change] (#2615, ADR-012) the lens never reads the checkout the suite
#             runs from: it reads the test's own repository
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
# #2615: git and grep calls are logged; the checkout must never be read.
# The lens reads the test's own repository (ZBUILD_REPO_ROOT), from inside it.
_HR="$(setup_git_temp_repo lens-own-repo)"; export ZBUILD_REPO_ROOT="$_HR"; cd "$_HR" || exit 1
_SPY_LOG="$TEST_TEMP_DIR/spy.log"; zb_test_repo_spy "$_SPY_LOG"
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
      for (( i = 1; i <= $3; i++ )); do printf 'WHLIN-%s[change]: SPECTEXT-%s the engine claims the issue before it starts work on it and releases the claim after%s\n' "$i" "$i" "$pad"; done
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

print_test_section "W5–W7: over the inline size, a file of the section, cleaned"
export ZBUILD_STAGE_SCRATCH="$TEST_TEMP_DIR/scratch"; mkdir -p "$ZBUILD_STAGE_SCRATCH"
D="$TEST_TEMP_DIR/w5"
_setup "$D" "$(_filler 40000 'BIGWORD')"$'\e[31mRED-MARK\e[0m'" see .env.production BIG-END-MARKER" 20 20 300 "$(_filler 1500 'PAD')"
_run "$D"
_ctx() { local f; f="$(/usr/bin/grep -oE "$ZBUILD_STAGE_SCRATCH/lens-correctness-context-$1\.md" <<< "$P" | head -n 1)"; printf '%s' "${f:-<not named>}"; }
F_ISSUE="$(_ctx issue)" F_REQS="$(_ctx requirements)" F_DEC="$(_ctx decisions)" F_STEPS="$(_ctx not-needed)"
assert_eq "[W5] the prompt names a file of the issue, in the stage's scratch" "yes" "$([[ -f "$F_ISSUE" ]] && echo yes || echo "no: $F_ISSUE")"
_lacks "[W5] ...and holds no piece of it" "$P" "BIGWORD sentence 0 "
assert_contains "[W5] that file holds the whole issue" "$(cat "$F_ISSUE" 2>/dev/null)" "BIG-END-MARKER"
assert_eq "[W6] the requirements: a file of their own" "yes" "$([[ -f "$F_REQS" ]] && echo yes || echo "no: $F_REQS")"
assert_contains "[W6] ...holding the last one" "$(cat "$F_REQS" 2>/dev/null)" "SPECTEXT-20 "
_lacks "[W6] ...and the prompt no piece of them" "$P" "SPECTEXT-1 "
assert_eq "[W6] the decisions: a file of their own" "yes" "$([[ -f "$F_DEC" ]] && echo yes || echo "no: $F_DEC")"
_lacks "[W6] ...and the prompt no piece of them" "$P" "DECISION-1 "
assert_eq "[W6] the not-needed steps: one file, one path" "yes" "$([[ -f "$F_STEPS" ]] && echo yes || echo "no: $F_STEPS")"
assert_contains "[W6] ...holding the last one" "$(cat "$F_STEPS" 2>/dev/null)" "STEPWHY-300 "
_I="$(cat "$F_ISSUE" 2>/dev/null)"
assert_contains "[W7] the file is redacted: a private path is <private>" "$_I" "see <private> BIG-END-MARKER"
_lacks "[W7] ...and sanitised: no terminal escape" "$_I" $'\e['
assert_contains "[W7] ...its text kept" "$_I" "RED-MARK"

print_test_section "W8: the checkout is never read (#2615)"
assert_eq "[W8] no git or grep call ran in the checkout the suite runs from" "" "$(zb_test_repo_spy_hits "$_SPY_LOG" "$REPO_ROOT")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
