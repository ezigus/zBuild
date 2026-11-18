#!/usr/bin/env bash
# tests/unit/finding-topics-test.sh — a stage is shown only what is tagged for
# it: each output holds one kind of finding, and a finding goes by its output's
# tag (#2556, ADR-071 §1 §2; was #2452's per-finding topic).
#
# Why: on #1764 run 43772987273 issue-acceptance wrote one result holding
# requirement-findings, code-findings and change-findings, the file itself
# tagged requirement-findings. Design takes that tag, so it was shown the
# file's path and summary, opened it, took a [fix-code] finding meant for
# build, and added a SPEC the check then refused. Per-finding tags routed each
# finding, but a file's path and summary still went by the file's tag.
#
#   F1 [change]: stage_findings_json reads every line as a finding's text; a
#                line "<tag><TAB><text>" names no tag
#   F2 [change]: a finding goes by its output's tag only: one carrying a tag of
#                its own in a requirement-findings output reaches design, and
#                not a stage that takes only code-findings
#   F3 [change]: an output with no tag — its findings, summary and path — reaches
#                no stage that declares takes:
#   F4 [guard] : an output whose manifest quotes its tag goes by that tag
#   F5 [change]: stage_findings_route writes each tag's findings, numbered, to an
#                output of its own, removes one with none, and gives every
#                finding, untagged, for the stage's own result
#   F6 [change]: issue-acceptance writes one output per tag — [fix-design] and an
#                unmarked line to -requirement, [fix-code] and an unasked
#                [fix-test] to -code, any other unasked line to -change — none
#                with a verdict of its own; its own result holds all three,
#                untagged; its summary does not list them
#   F7 [change]: with issue-acceptance's real manifest, design's Previous work
#                holds no [fix-code] finding and no issue-acceptance path; build's
#                holds the finding
#   F8 [change]: the acceptance check writes its code findings to
#                acceptance-gate-code-result.json and the rest to
#                acceptance-gate-requirement-result.json
#   F9 [change]: no shipped manifest has finding_topics:, and validate_manifest
#                refuses an output that does
#   F10 [change] (review): an acceptance check that skips (a precondition unmet)
#                leaves no output by topic from an earlier try
#   F11 [change] (review): test's failures summary names no topic — a stage that
#                takes code-findings is not shown a failing file only the code
#                can fix
#   F12 [change] (review): a stage with no takes: is shown each finding once —
#                from the output by topic, not again from the untagged result
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "a stage is shown only what is tagged for it (#2556, ADR-071)"
setup_test_env "finding-topics"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

# ── F1 ───────────────────────────────────────────────────────────────────────
print_test_section "F1: stage_findings_json reads no tag"
_f1="$(printf 'code-findings\tthe code skips it\nplain finding\n' | stage_findings_json)"
assert_eq "[F1] a line with a tag word names no tag" "null" "$(jq -r '.[0].topic' <<< "$_f1")"
assert_eq "[F1] ...and is kept whole" $'code-findings\tthe code skips it' "$(jq -r '.[0].text' <<< "$_f1")"
assert_eq "[F1] numbering is unchanged" "1 2" "$(jq -r '[.[].n] | map(tostring) | join(" ")' <<< "$_f1")"

# ── Previous work fixtures ───────────────────────────────────────────────────
PROOT="$TEST_TEMP_DIR/plugins"
STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
mkdir -p "$ART"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1

# _producer <name> <topic|-> <findings-json> — a stage whose result, summary and
# error log all have <topic> ("-": none), its result holding <findings-json>.
_producer() {
    local s="$1" t="$2" f="$3" u="${1//-/_}" tl=""
    [[ "$t" != - ]] && tl="    topic: $t"$'\n'
    mkdir -p "$PROOT/tool/$s"
    {
        printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\nhooks:\n  run: x_run\noutputs:\n' "$s" "$s"
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n%s' "$u" "$s" "$tl"
        printf '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n    type: text\n    required: false\n    summary: true\n%s' "$u" "$s" "$tl"
        printf '  - id: %s_errors\n    path: ${artifact_dir}/%s-errors.log\n    type: text\n    required: false\n    errors: true\n%s' "$u" "$s" "$tl"
    } > "$PROOT/tool/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/tool/$s/plugin.sh"
    stage_result_write "$ART/$s-result.json" fail fixture "{\"findings\":$f}"
    printf 'SUMMARY-OF-%s\n' "$s" > "$ART/$s-summary.md"
    printf 'ERRORS-OF-%s\n' "$s" > "$ART/$s-errors.log"
    _update_stage_status "$STATE/pipeline-state.json" "$s" complete
    _zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" "$s" fail
}
_takes() { local t; printf 'takes:\n'; for t in "$@"; do printf '  - topic: %s\n    for: x\n' "$t"; done; }
_consumer() {
    local s="$1" takes="$2" u="${1//-/_}"
    mkdir -p "$PROOT/agent/$s"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\n%s\n' "$s" "$s" "$takes"
        printf 'hooks:\n  run: x_run\noutputs:\n'
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n    topic: ask\n' "$u" "$s"
    } > "$PROOT/agent/$s/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/agent/$s/plugin.sh"
}

# ft-accept: a requirement-findings output; one finding carries a tag of its own.
_producer ft-accept requirement-findings '[{"n":1,"text":"SELF-TAGGED-CODE","topic":"code-findings"},{"n":2,"text":"DESIGN-GAP"}]'
# ft-own: an output with no tag at all.
_producer ft-own - '[{"n":1,"text":"UNTAGGED-OUTPUT-FINDING"}]'
# ft-quoted: a manifest that quotes its tag, as YAML allows.
_producer ft-quoted requirement-findings '[{"n":1,"text":"QUOTED-TOPIC-FINDING"}]'
sed -i.bak 's/topic: requirement-findings/topic: "requirement-findings"/' "$PROOT/tool/ft-quoted/manifest.yaml"
_consumer ft-design "$(_takes ask requirement-findings)"
_consumer ft-coder "$(_takes ask code-findings)"
_TPL_STAGES=(ft-accept ft-own ft-quoted ft-design ft-coder)

_pw() {
    local idx; idx="$(_inputs_resolve_stage "$1" "$PROOT" "$STATE")"
    _stage_block_previous_work "$1" "$STATE" "$PROOT" "$idx" "" "$PROOT/agent/$1/manifest.yaml"
}
_pwd="$(_pw ft-design)"; _pwc="$(_pw ft-coder)"

print_test_section "F2-F4: a finding goes by its output's tag"
assert_contains "[F2] design is shown the self-tagged finding of a requirement-findings output" "$_pwd" "SELF-TAGGED-CODE"
assert_not_contains "[F2] a stage taking only code-findings is not shown it" "$_pwc" "SELF-TAGGED-CODE"
assert_not_contains "[F3] an untagged output's finding reaches no stage" "$_pwd$_pwc" "UNTAGGED-OUTPUT-FINDING"
assert_not_contains "[F3] ...nor its summary" "$_pwd$_pwc" "SUMMARY-OF-ft-own"
assert_not_contains "[F3] ...nor a path to it" "$_pwd$_pwc" "$ART/ft-own-"
assert_contains "[F4] a quoted tag is that tag" "$_pwd" "QUOTED-TOPIC-FINDING"

# ── F5 ───────────────────────────────────────────────────────────────────────
print_test_section "F5: stage_findings_route"
R5="$TEST_TEMP_DIR/route"; mkdir -p "$R5"
printf '{"stale":true}\n' > "$R5/x-change-result.json"
_all="$(printf 'code-findings\tCODE-ONE\nREQ-DEFAULT\ncode-findings\tCODE-TWO\n' | stage_findings_route "$R5" x requirement-findings)"
assert_eq "[F5] the code findings, numbered, in x-code-result.json" "1:CODE-ONE 2:CODE-TWO" \
    "$(jq -r '[.data.findings[] | "\(.n):\(.text)"] | join(" ")' "$R5/x-code-result.json" 2>/dev/null)"
assert_eq "[F5] an untagged line goes by the default tag" "1:REQ-DEFAULT" \
    "$(jq -r '[.data.findings[] | "\(.n):\(.text)"] | join(" ")' "$R5/x-requirement-result.json" 2>/dev/null)"
assert_file_not_exists "[F5] a tag with no findings has no output (an old one is removed)" "$R5/x-change-result.json"
assert_eq "[F5] a routed output carries no verdict" "null" "$(jq -r '.outcome' "$R5/x-code-result.json" 2>/dev/null)"
assert_eq "[F5] every finding, untagged, for the stage's own result" "1:CODE-ONE:null 2:REQ-DEFAULT:null 3:CODE-TWO:null" \
    "$(jq -r '[.[] | "\(.n):\(.text):\(.topic)"] | join(" ")' <<< "$_all")"

# ── F6 / F7 ──────────────────────────────────────────────────────────────────
PLUGIN_DIR="$REPO_ROOT/plugins/agent/issue-acceptance"
export ZBUILD_STAGE_BLOCKS="$TEST_TEMP_DIR/stage-blocks"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$PLUGIN_DIR/plugin.sh" 2>/dev/null
set +e
_IA_ANSWER=""
route_to_model() { printf '%s\n' "$_IA_ANSWER"; return 0; }
resolve_tier() { printf 'T2'; }
_S="$TEST_TEMP_DIR/ia"; _A="$_S/artifacts"; _in="$_S/inputs"
mkdir -p "$_A" "$_in"
printf '{}' > "$_S/pipeline-state.json"
zb_test_issue_output "$_in" "Do it. Acceptance: - [ ] resume skips done stages" >/dev/null
printf '%s\n' '# Design' '```acceptance' 'SPEC-1[code]: resume skips' 'WIRING: none' '```' > "$_in/design.md"
printf '%s\n' 'diff --git a/p.sh b/p.sh' '+x=1' 'diff --git a/tests/t.sh b/tests/t.sh' '+log_checked=1' > "$_in/diff.patch"
zb_test_test_run_output "$_in" fail 1 1 >/dev/null
mkdir -p "$_S/tests"; printf 'x=1\n' > "$_S/p.sh"; printf 'log_checked=1\n' > "$_S/tests/t.sh"
jq -n --arg i "$_in/intake-result.json" --arg d "$_in/design.md" --arg p "$_in/diff.patch" --arg t "$_in/test-results.json" \
    '{inputs: {a: $i, b: $d, c: $p, d: $t}}' > "$_S/stage-inputs.json"
export ZBUILD_STAGE_INPUTS="$_S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_A" ZBUILD_REPO_ROOT="$_S"
_IA_ANSWER=$'UNMET: [fix-code] resume | WHY: intake still runs on resume | QUOTE: "resume skips done stages"\nUNMET: [fix-design] the design | WHY: the design never says only on a resume | QUOTE: "resume skips done stages"\nUNASKED: [fix-test] tests/t.sh | WHY: the test also checks the log | QUOTE: tests/t.sh | log_checked=1\nUNASKED: p.sh | WHY: it sets x | QUOTE: p.sh | x=1'
issue_acceptance_run issue-acceptance "$_S/pipeline-state.json" >/dev/null 2>&1
unset ZBUILD_STAGE_INPUTS
_txt() { jq -r '[.data.findings[]?.text] | join(" || ")' "$_A/issue-acceptance-$1-result.json" 2>/dev/null; }
print_test_section "F6: issue-acceptance writes one output per tag"
assert_contains "[F6] -requirement holds the [fix-design] finding" "$(_txt requirement)" "the design never says only on a resume"
assert_not_contains "[F6] ...and not the [fix-code] one" "$(_txt requirement)" "intake still runs on resume"
assert_contains "[F6] -code holds the [fix-code] finding" "$(_txt code)" "intake still runs on resume"
assert_contains "[F6] ...and the unasked [fix-test] one" "$(_txt code)" "the test also checks the log"
assert_contains "[F6] -change holds the other unasked one" "$(_txt change)" "it sets x"
assert_not_contains "[F6] ...and only it" "$(_txt change)" "intake still runs on resume"
assert_eq "[F6] its own result holds all four, untagged" "4 0" \
    "$(jq -r '"\(.data.findings | length) \([.data.findings[] | select(has("topic"))] | length)"' "$_A/issue-acceptance-result.json" 2>/dev/null)"
assert_eq "[F6] a routed output has no verdict, so no report counts it twice" "null" "$(jq -r '.outcome' "$_A/issue-acceptance-code-result.json" 2>/dev/null)"
_sum="$(cat "$_A/issue-acceptance-summary.md" 2>/dev/null)"
assert_not_contains "[F6] the summary does not list the unmet requirements" "$_sum" "intake still runs on resume"

print_test_section "F7: design is not shown build's finding"
IAS="$TEST_TEMP_DIR/ia-state"; mkdir -p "$IAS/artifacts"
init_state "$IAS/pipeline-state.json" run-2 7 >/dev/null 2>&1
cp "$_A"/issue-acceptance-* "$IAS/artifacts/"
_update_stage_status "$IAS/pipeline-state.json" issue-acceptance complete
_zbuild_state_set_stage_verdict "$IAS/pipeline-state.json" issue-acceptance fail
_TPL_STAGES=(issue-acceptance design build)
_pwr() {
    local idx; idx="$(_inputs_resolve_stage "$1" "$REPO_ROOT/plugins" "$IAS")"
    _stage_block_previous_work "$1" "$IAS" "$REPO_ROOT/plugins" "$idx" "" "$REPO_ROOT/plugins/agent/$1/manifest.yaml"
}
_pd="$(_pwr design)"; _pb="$(_pwr build)"
assert_not_contains "[F7] design is not shown the [fix-code] finding" "$_pd" "intake still runs on resume"
assert_not_contains "[F7] ...nor any issue-acceptance file it could open" "$_pd" "issue-acceptance-result.json"
assert_contains "[F7] design is shown the [fix-design] finding" "$_pd" "the design never says only on a resume"
assert_contains "[F7] build is shown the [fix-code] finding" "$_pb" "intake still runs on resume"

# ── F8 ───────────────────────────────────────────────────────────────────────
print_test_section "F8: the acceptance check writes one output per tag"
# shellcheck source=../../plugins/tool/test/lib/acceptance-reason.sh
source "$REPO_ROOT/plugins/tool/test/lib/acceptance-reason.sh"
R8="$TEST_TEMP_DIR/ag"; mkdir -p "$R8"
_ag_route_findings "$R8/acceptance-gate-result.json" not_passing_at_head:SPEC-2 tautology:SPEC-1 >/dev/null
assert_contains "[F8] a test failing on the new code → acceptance-gate-code-result.json" \
    "$(jq -r '[.data.findings[].text] | join(" ")' "$R8/acceptance-gate-code-result.json" 2>/dev/null)" "does not pass on the new code"
assert_contains "[F8] a test passing on the old code → acceptance-gate-requirement-result.json" \
    "$(jq -r '[.data.findings[].text] | join(" ")' "$R8/acceptance-gate-requirement-result.json" 2>/dev/null)" "already passes on the code from before"

# ── F9 ───────────────────────────────────────────────────────────────────────
print_test_section "F9: no finding_topics"
assert_eq "[F9] no shipped manifest has finding_topics:" "" "$(grep -l 'finding_topics:' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null)"
mkdir -p "$TEST_TEMP_DIR/m9"
printf 'id: m9\nname: m9\nkind: tool\nversion: 0.0.1\nhooks:\n  run: x\noutputs:\n  - id: r\n    path: ${artifact_dir}/m9-result.json\n    type: json\n    topic: code-findings\n    description: "x"\n    finding_topics: code-findings\n' > "$TEST_TEMP_DIR/m9/manifest.yaml"
( source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh" >/dev/null 2>&1
  validate_manifest "$TEST_TEMP_DIR/m9/manifest.yaml" > "$TEST_TEMP_DIR/m9.out" 2>&1; printf '%s' "$?" > "$TEST_TEMP_DIR/m9.rc" )
assert_eq "[F9] validate_manifest refuses an output with finding_topics:" "1" "$(cat "$TEST_TEMP_DIR/m9.rc" 2>/dev/null)"
assert_contains "[F9] ...naming it" "$(cat "$TEST_TEMP_DIR/m9.out" 2>/dev/null)" "finding_topics"

_test_findings_by_owner_stub() { local f t; while IFS=$'\t' read -r f t; do if [[ "$f" == tests/* ]]; then printf '%s\n' "$t"; else printf 'change-findings\t%s\n' "$t"; fi; done; }
# ── F10 ──────────────────────────────────────────────────────────────────────
print_test_section "F10: a skipped acceptance check leaves no old findings"
R10="$TEST_TEMP_DIR/ag10"; mkdir -p "$R10"
printf '{"data":{"findings":[{"n":1,"text":"STALE"}]}}\n' > "$R10/acceptance-gate-code-result.json"
( _ag_noop_precondition_unmet "$R10/acceptance-gate-result.json" design_acceptance_block ) >/dev/null 2>&1
assert_file_not_exists "[F10] the earlier try's code findings are gone" "$R10/acceptance-gate-code-result.json"

# ── F11 / F12 ────────────────────────────────────────────────────────────────
print_test_section "F11/F12: test's summary, and a stage with no takes:"
TS="$TEST_TEMP_DIR/ts"; mkdir -p "$TS/artifacts"
init_state "$TS/pipeline-state.json" run-3 7 >/dev/null 2>&1
printf 'tests/a-test.sh\tA-OWN fails\nlib/x.sh\tOTHER-ONLY-CODE fails\n' \
    | _test_findings_by_owner_stub | stage_findings_route "$TS/artifacts" test code-findings > "$TEST_TEMP_DIR/ts.all"
stage_result_write "$TS/artifacts/test-results.json" fail "2 failed" "{\"findings\":$(cat "$TEST_TEMP_DIR/ts.all")}" >/dev/null
printf '## test — fail\n\n## Failing files\n- lib/x.sh: OTHER-ONLY-CODE fails\n' > "$TS/artifacts/test-failures-summary.md"
_update_stage_status "$TS/pipeline-state.json" test complete
_zbuild_state_set_stage_verdict "$TS/pipeline-state.json" test fail
# The acceptance check's findings too: a result with no topic beside its outputs by topic.
stage_result_write "$TS/artifacts/acceptance-gate-result.json" fail "x" '{"findings":[{"n":1,"text":"AG-REQ-ONCE"}]}' >/dev/null
printf 'AG-REQ-ONCE\n' | stage_findings_route "$TS/artifacts" acceptance-gate requirement-findings >/dev/null
_TPL_STAGES=(test test-author pr-delivery)
_pwt() {
    local idx; idx="$(_inputs_resolve_stage "$1" "$REPO_ROOT/plugins" "$TS")"
    _stage_block_previous_work "$1" "$TS" "$REPO_ROOT/plugins" "$idx" "" "$REPO_ROOT/plugins/agent/$1/manifest.yaml"
}
_pta="$(_pwt test-author)"
assert_contains "[F11] test-author is shown its own failing file" "$_pta" "A-OWN fails"
assert_not_contains "[F11] ...and not the file only the code can fix, from the summary or anywhere" "$_pta" "OTHER-ONLY-CODE"
_ppr="$(_pwt pr-delivery)"
assert_eq "[F12] a stage with no takes: is shown each finding once" "1" "$(grep -cE 'finding [0-9]+ \(opened by test\): OTHER-ONLY-CODE fails' <<< "$_ppr")"
assert_eq "[F12] ...the acceptance check's too (review)" "1" "$(grep -cE 'finding [0-9]+ \(opened by test\): AG-REQ-ONCE' <<< "$_ppr")"
R13="$TEST_TEMP_DIR/r13"; mkdir -p "$R13"; chmod 500 "$R13"
printf 'code-findings\tNEW\n' | stage_findings_route "$R13" t requirement-findings >/dev/null 2>&1
chmod 700 "$R13"
assert_eq "[F5] a routed output that cannot be written leaves no .tmp behind (review)" "" "$(ls "$R13")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
