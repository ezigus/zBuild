#!/usr/bin/env bash
# Tests: a lens whose reply cannot be used is asked again at once, told what was
# wrong and shown its reply (ADR-060 §6, amended). On #1760 the correctness
# lens's reply held five findings and broke on one unescaped quote; nothing
# asked it again, and its findings were lost.
#
#   L1 [change]: a reply that is not valid JSON is asked again once; the second
#                prompt names jq's complaint and carries the first reply; the
#                lens's result is built from the second reply
#   L2 [change]: a reply still unusable after the second ask makes the lens
#                unusable, and its result and summary say what was wrong
#   L3 [change]: valid JSON without a findings list is asked again, naming that
#   L4 [guard] : a failed model call (time limit, turns, provider) is not asked
#                again — a lens that does not finish stops the run (ADR-040)
#   L5 [change]: every reply the lens got is kept, in the order it came
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "plugin: review-lens — a reply that cannot be used is asked again (ADR-060 §6)"
setup_test_env "plugin-review-lens-reask"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# Each call's prompt is kept as prompt-<n>.txt; the reply is the next line of
# $_RL_REPLIES (a file counter survives the plugin's subshells).
_RQ_DIR="$TEST_TEMP_DIR/calls"
_rl_reset() { rm -rf "$_RQ_DIR"; mkdir -p "$_RQ_DIR"; printf '0' > "$_RQ_DIR/n"; printf '%s\n' "$@" > "$_RQ_DIR/replies"; }
_rl_calls() { cat "$_RQ_DIR/n"; }
# shellcheck disable=SC2329  # invoked by the sourced plugin
route_to_model() {
    local n; n=$(( $(cat "$_RQ_DIR/n") + 1 )); printf '%s' "$n" > "$_RQ_DIR/n"
    printf '%s' "$2" > "$_RQ_DIR/prompt-$n.txt"
    local r; r="$(sed -n "${n}p" "$_RQ_DIR/replies")"
    [[ "$r" == RC=* ]] && return "${r#RC=}"
    printf '%s' "$r"
}

artifact_dir="$TEST_TEMP_DIR/artifacts"
mkdir -p "$artifact_dir"
scope_manifest="$TEST_TEMP_DIR/scope-manifest.md"; printf '+ core/\n' > "$scope_manifest"
evidence="$artifact_dir/diff.patch"
printf 'diff --git a/core/x.sh b/core/x.sh\n+ new line\n' > "$evidence"

# #1760's breakage: a quoted phrase inside a string, its quotes not escaped.
BAD='{"score":6,"findings":[{"file":"core/x.sh","severity":"medium","message":"the message "until.{stage,field,op,value} all required" is wrong","introduced":true}]}'
GOOD='{"score":6,"findings":[{"file":"core/x.sh","severity":"low","message":"the message \"until\" is wrong","introduced":true}]}'

# ─── L1 ──────────────────────────────────────────────────────────────────────
_rl_reset "$BAD" "$GOOD"
out="$artifact_dir/lens-l1.json"
_review_lens_run_inner "l1" "$scope_manifest" "$evidence" "$out" "$artifact_dir" >/dev/null 2>&1
assert_eq "L1: the lens was asked twice" "2" "$(_rl_calls)"
_p2="$(cat "$_RQ_DIR/prompt-2.txt" 2>/dev/null)"
assert_contains "L1: the second ask says the reply is not valid JSON" "$_p2" "is not valid JSON"
assert_contains "L1: the second ask carries jq's own complaint" "$_p2" "$(_llm_envelope_parse_error "$BAD")"
assert_contains "L1: the second ask carries the first reply" "$_p2" "$BAD"
assert_eq "L1: the result is built from the second reply" "pass" "$(jq -r '.outcome // empty' "$out" 2>/dev/null)"
assert_eq "L1: the second reply's finding is kept" "1" "$(jq -r '.findings | length' "$out" 2>/dev/null)"

# ─── L2 ──────────────────────────────────────────────────────────────────────
_rl_reset "$BAD" "$BAD"
out="$artifact_dir/lens-l2.json"
_review_lens_run_inner "l2" "$scope_manifest" "$evidence" "$out" "$artifact_dir" >/dev/null 2>&1
assert_eq "L2: the lens was asked twice, no more" "2" "$(_rl_calls)"
assert_eq "L2: still unusable, the lens is unusable" "unusable" "$(jq -r '.outcome // empty' "$out" 2>/dev/null)"
assert_contains "L2: its result says what was wrong" "$(jq -r '.reason // empty' "$out" 2>/dev/null)" "is not valid JSON"
assert_contains "L2: its summary says what was wrong" "$(cat "$artifact_dir/lens-l2-summary.md" 2>/dev/null)" "is not valid JSON"

# ─── L3 ──────────────────────────────────────────────────────────────────────
_rl_reset '{"score":6,"notes":"looks fine"}' "$GOOD"
out="$artifact_dir/lens-l3.json"
_review_lens_run_inner "l3" "$scope_manifest" "$evidence" "$out" "$artifact_dir" >/dev/null 2>&1
assert_eq "L3: valid JSON in the wrong shape is asked again" "2" "$(_rl_calls)"
assert_contains "L3: the second ask names the missing findings list" "$(cat "$_RQ_DIR/prompt-2.txt" 2>/dev/null)" "no findings list"
# Before this, a reply with no findings list read as a clean review: no findings.
assert_eq "L3: the result is built from the second reply" "1" "$(jq -r '.findings | length' "$out" 2>/dev/null)"

# ─── L4 ──────────────────────────────────────────────────────────────────────
_rl_reset "RC=124" "$GOOD"
out="$artifact_dir/lens-l4.json"
_review_lens_run_inner "l4" "$scope_manifest" "$evidence" "$out" "$artifact_dir" >/dev/null 2>&1
assert_eq "L4: a failed call is not asked again" "1" "$(_rl_calls)"
assert_eq "L4: the lens did not finish" "timed_out" "$(jq -r '.outcome // empty' "$out" 2>/dev/null)"

# ─── L5 ──────────────────────────────────────────────────────────────────────
_r="$artifact_dir/lens-l1-reply.txt"
assert_file_exists "L5: the lens's replies are kept" "$_r"
_rt="$(cat "$_r" 2>/dev/null)"
assert_contains "L5: the first reply is kept" "$_rt" "$BAD"
assert_contains "L5: the second reply is kept" "$_rt" "$GOOD"
_a="${_rt%%"$BAD"*}"; _b="${_rt%%"$GOOD"*}"
if [[ ${#_a} -lt ${#_b} ]]; then
    assert_pass "L5: in the order they came"
else
    assert_fail "L5: in the order they came" "second before first"
fi
assert_contains "L5: the reply file is a declared output" "$(cat "$PLUGIN_DIR/manifest.yaml")" 'lens-${ZBUILD_REVIEW_LENS_ID}-reply.txt'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
