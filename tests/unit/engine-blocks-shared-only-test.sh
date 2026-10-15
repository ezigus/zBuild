#!/usr/bin/env bash
# tests/unit/engine-blocks-shared-only-test.sh — the engine's prompt blocks hold
# only what every stage shares (#2363, ADR-067 §8).
#
# Why: #1801's plan prompt was 52.7 KB. The engine told every stage to "read the
# files you need", repeated the same 46-file list under each earlier stage, gave
# every stage a rule about reading the code that writes data, and said one rule
# twice. A failed attempt's error record also replaced the last good plan, so
# the next attempt had nothing to keep.
#
#   B1 [change] Previous work's header names where outputs are and says to use
#               what the job needs — it does not tell a stage to read them
#   B2 [change] one line at the top lists the files this issue's work has
#               changed, against the commit it started from; no per-stage
#               "Since it last ran" lines
#   B2b [change] on a rerun the line still lists what earlier runs committed:
#               it compares against the default branch, not where this run began
#   B3 [change] a stage whose latest attempt ended in error shows its last good
#               output, from the attempt that wrote it
#   B4 [change] the rules say each thing once, and hold no rule about a kind of
#               work: "open the code that writes it" is in build, test-author
#               and the review lenses instead
#   B5 [change] the shared output contract has no FORBIDDEN phrase list
#   B6 [change] the repo's rules file holds facts about this repo; the retired
#               impact stage's overrides file is gone
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "the engine's prompt blocks hold only what every stage shares (#2363)"
setup_test_env "engine-blocks-shared-only"
unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true

# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true

# A run in a real repository: one commit on the default branch the work started
# from, then one file the work changed on its own branch.
_S="$TEST_TEMP_DIR/state"; _P="$TEST_TEMP_DIR/plugins"; _R="$TEST_TEMP_DIR/repo"
mkdir -p "$_S/artifacts" "$_P/agent/pw" "$_R"
git -C "$_R" init -q -b main && git -C "$_R" config user.email t@t && git -C "$_R" config user.name t
printf 'a\n' > "$_R/kept.sh"; git -C "$_R" add . && git -C "$_R" commit -qm base
git -C "$_R" checkout -qb issue
git -C "$_R" rev-parse HEAD > "$_S/intake-baseline-ref.txt"
printf 'b\n' > "$_R/changed-by-work.sh"; git -C "$_R" add . && git -C "$_R" commit -qm work
cat > "$_P/agent/pw/manifest.yaml" <<'MF'
id: pw
kind: agent
outputs:
  - id: pw-result
    path: ${artifact_dir}/pw-result.json
    format: json
    required: true
    primary: true
  - id: pw-summary
    path: ${artifact_dir}/pw-summary.md
    format: markdown
    summary: true
MF
_prev() {
    ( _TPL_STAGES=(pw)
      _stage_block_previous_work later "$_S" "$_P" "$(_inputs_resolve_stage later "$_P" "$_S")" "$_R" ) 2>/dev/null
}

print_test_section "B1: the header"
jq -n '{result_contract:3,outcome:"pass",reason:"ok"}' > "$_S/artifacts/pw-result.json"
printf '## pw — pass\n- did it\n' > "$_S/artifacts/pw-summary.md"
printf '{"stage_statuses":{"pw":"complete"},"stage_verdicts":{"pw":"pass"}}\n' > "$_S/pipeline-state.json"
_pw="$(_prev)"
assert_contains "[B1] says where outputs are and to use what the job needs" "$(tr '\n' ' ' <<< "$_pw")" \
    "The latest output of every stage that has run, with where to find it. Use what your job needs."
if grep -qF "Read the files you need" <<< "$_pw"; then
    assert_fail "[B1] no instruction to read the files" "found"
else
    assert_pass "[B1] no instruction to read the files"
fi

print_test_section "B2: what the work has changed, once"
assert_contains "[B2] one line names what the work changed" "$_pw" \
    "Files this issue's work has changed so far: changed-by-work.sh"
if grep -qF "Since it last ran" <<< "$_pw"; then
    assert_fail "[B2] no per-stage 'Since it last ran' line" "found"
else
    assert_pass "[B2] no per-stage 'Since it last ran' line"
fi
assert_eq "[B2] the line comes before any stage" "1" \
    "$(awk '/^Files this issue.s work has changed so far/{print (seen ? 0 : 1); exit} /^### /{seen=1}' <<< "$_pw")"

print_test_section "B2b: a rerun still lists what earlier runs committed"
# #1801's rerun: the issue branch already held an earlier run's commit, and this
# run began on top of it. The line said "none" — it compared against where this
# run began, not against the default branch.
printf 'e\n' > "$_R/earlier-run.sh"; git -C "$_R" add . && git -C "$_R" commit -qm earlier-run
git -C "$_R" rev-parse HEAD > "$_S/intake-baseline-ref.txt"
_pw2="$(_prev)"
assert_contains "[B2b] the earlier run's file is listed" "$_pw2" "earlier-run.sh"
assert_contains "[B2b] ...with the first run's file" "$_pw2" "changed-by-work.sh"
if grep -qF "changed so far: none" <<< "$_pw2"; then
    assert_fail "[B2b] the line does not say none" "found"
else
    assert_pass "[B2b] the line does not say none"
fi

print_test_section "B3: a failed attempt shows the last good output"
_good="$_S/artifacts/attempts/pw/iter-0-attempt-1"; mkdir -p "$_good"
jq -n '{result_contract:3,outcome:"pass",reason:"ok"}' > "$_good/pw-result.json"
printf '## pw — pass\n- the good work items\n' > "$_good/pw-summary.md"
_bad="$_S/artifacts/attempts/pw/iter-0-attempt-2"; mkdir -p "$_bad"
jq -n '{result_contract:3,outcome:"timed_out",reason:"stopped"}' > "$_bad/pw-result.json"
cp "$_bad/pw-result.json" "$_S/artifacts/pw-result.json"
printf '## pw — error\n- no output\n' > "$_S/artifacts/pw-summary.md"
cp "$_S/artifacts/pw-summary.md" "$_bad/pw-summary.md"
printf '{"stage_statuses":{"pw":"failed"},"stage_verdicts":{"pw":"error"}}\n' > "$_S/pipeline-state.json"
_pw3="$(_prev)"
assert_contains "[B3] the last good output's path is given" "$_pw3" "$_good/pw-result.json"
assert_contains "[B3] the last good output's summary is shown" "$_pw3" "the good work items"
assert_contains "[B3] the latest attempt's failure is still shown" "$_pw3" "(verdict: error)"

print_test_section "B4: each rule once, and only rules every stage shares"
_rules="$(_stage_block_rules pw "$_S" "$_P/agent/pw/manifest.yaml" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
if grep -qF "Nothing in this prompt can take away" <<< "$_rules"; then
    assert_fail "[B4] the duplicate 'Nothing in this prompt…' rule is gone" "found"
else
    assert_pass "[B4] the duplicate 'Nothing in this prompt…' rule is gone"
fi
assert_contains "[B4] 'Do your whole job' stays" "$_rules" "Do your whole job."
if grep -qF "open the code that writes it" <<< "$_rules"; then
    assert_fail "[B4] the engine's rules carry no rule about writing code" "found"
else
    assert_pass "[B4] the engine's rules carry no rule about writing code"
fi
for _st in build test-author review-lens; do
    # Wrapped text is matched with its line breaks joined.
    _src="$(find "$REPO_ROOT/plugins/agent/$_st" -path '*/tests' -prune -o -type f \( -name '*.sh' -o -name '*.md' \) -print0 \
        | xargs -0 cat | tr '\n' ' ' | tr -s ' ')"
    if grep -qF "open the code that writes it" <<< "$_src"; then
        assert_pass "[B4] $_st's own text has the rule"
    else
        assert_fail "[B4] $_st's own text has the rule" "not found"
    fi
done

print_test_section "B5: no FORBIDDEN list"
# shellcheck source=../../scripts/lib/llm-agent.sh
source "$REPO_ROOT/scripts/lib/llm-agent.sh"
_oc="$(_llm_output_contract --stage x --verdicts none --schema-json '{"a":1}' 2>/dev/null)"
if grep -qE "FORBIDDEN|Based on my analysis" <<< "$_oc"; then
    assert_fail "[B5] the output contract has no FORBIDDEN list" "found"
else
    assert_pass "[B5] the output contract has no FORBIDDEN list"
fi
assert_contains "[B5] the output contract still asks for one JSON object" "$_oc" "EXACTLY ONE JSON object"

print_test_section "B6: the repo's own files"
assert_contains "[B6] rules.md holds facts about this repo" "$(cat "$REPO_ROOT/.zbuild/prompts/rules.md")" \
    "Facts about this repo"
if grep -qF "Facts reviewers need" "$REPO_ROOT/.zbuild/prompts/rules.md"; then
    assert_fail "[B6] no 'Facts reviewers need' heading" "found"
else
    assert_pass "[B6] no 'Facts reviewers need' heading"
fi
assert_file_not_exists "[B6] the retired impact stage's overrides are gone" \
    "$REPO_ROOT/.zbuild/prompts/impact-overrides.md"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
