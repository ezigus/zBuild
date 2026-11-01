#!/usr/bin/env bash
# tests/unit/design-writes-as-it-goes-test.sh — design writes its own output as
# it goes and does not do build's job (#2376, ADR-067 §8 §9, ADR-050 §11).
#
# Why: in the #1801 and #1944 reruns (2026-10-13) design ran 61 then 31
# minutes in both runs and wrote no design.md. On #1801 its notes were a
# root-cause analysis of build's failing tests; on #1944 it read about 20 files
# end to end hunting an "exhaustive" scope. Its prompt never said to write early,
# and told it the ONLY file it may write is design.md — so not even its notes.
#
#   D1 [change] What you own opens with design's job: the decisions, the
#               acceptance contract and the scope, saved as it goes; a finding
#               that a design change would fix is answered in the design;
#               design does not debug code
#   D2 [change] the scope is found by searching for what the change alters,
#               not by an exhaustive read
#   D3 [change] design may write its notes file as well as its design (the
#               working copy, ADR-068 §8)
#   D4 [guard]  a design the call wrote before it timed out is kept
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design writes its own output as it goes (#2376)"
setup_test_env "design-writes-as-it-goes"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
# The model writes a design where its prompt says, then returns MOCK_RC
# (124: its time ran out).
MOCK_RC=0
route_to_model() {
    local _t; _t="$(zb_test_prompt_write_path "$2")"
    mkdir -p "$(dirname "$_t")"
    printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$_t"
    return "$MOCK_RC"
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }

FIX="$TEST_TEMP_DIR/fix"; mkdir -p "$FIX"
git -C "$FIX" init -q && git -C "$FIX" config user.email t@t && git -C "$FIX" config user.name t
ARTIFACT_DIR="$FIX/state/artifacts"; mkdir -p "$ARTIFACT_DIR"
SCOPE_MANIFEST="$FIX/state/scope-manifest.md"; printf '+ ./\n' > "$SCOPE_MANIFEST"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","areas":["foo.sh"]}],"open_questions":[]}' > "$PLAN_JSON"
OUTPUT_MD="$ARTIFACT_DIR/design.md"
export ZBUILD_REPO_ROOT="$FIX"

_design_stage_run_inner "$SCOPE_MANIFEST" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1 || true
P="$(cat "$ARTIFACT_DIR/design-prompt.txt" 2>/dev/null)"
FLAT="$(tr '\n' ' ' <<< "$P" | tr -s ' ')"

print_test_section "D1: the job, first"
_own="$(awk '/^## What you own/{f=1;next} f&&/^## /{exit} f' <<< "$P" | sed '/^[[:space:]]*$/d' | head -n1)"
assert_contains "[D1] What you own opens with the job" "$_own" "Your job: write the design"
assert_contains "[D1] ...saved as it goes" "$FLAT" "Save it as you go"
assert_contains "[D1] ...a design on disk counts" "$FLAT" "a design on disk when your time runs out still counts"
assert_contains "[D1] a finding a design change would fix is answered in the design" "$FLAT" "Answer each of those in the design"
assert_contains "[D1] design does not debug code" "$FLAT" "You do not debug code or work out why a test fails"

print_test_section "D2: the scope is searched for, not read exhaustively"
if grep -qiE "EXHAUSTIVE" <<< "$P"; then
    assert_fail "[D2] no exhaustive-enumeration instruction" "found"
else
    assert_pass "[D2] no exhaustive-enumeration instruction"
fi
assert_contains "[D2] find the scope by searching for what changes" "$FLAT" "search for the names, values and lists the change alters"

print_test_section "D3: design may write its notes"
if grep -qF "The ONLY file you write is the design.md" <<< "$FLAT"; then
    assert_fail "[D3] no ban on the notes file" "found"
else
    assert_pass "[D3] no ban on the notes file"
fi
assert_contains "[D3] the only files are its design and the notes file" "$FLAT" "Do not write any file other than the working copy above and your notes file"

print_test_section "D4: a design written before a timeout is kept"
rm -f "$OUTPUT_MD" "$ARTIFACT_DIR/design-draft.md"; MOCK_RC=124
_design_stage_run_inner "$SCOPE_MANIFEST" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1 || true
# It has no acceptance block, so it fails its checks: it stays as the working
# copy for the next run rather than being thrown away.
assert_contains "[D4] the design written before the timeout is kept" \
    "$(cat "$ARTIFACT_DIR/design-draft.md" 2>/dev/null)" '```scope'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
