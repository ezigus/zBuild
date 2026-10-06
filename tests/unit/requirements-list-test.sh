#!/usr/bin/env bash
# tests/unit/requirements-list-test.sh — one fixed, engine-numbered list of
# requirements per issue (#2306, ADR-070).
#
# Why: every stage read the issue's prose and decided for itself what it asked
# for. On #2035 the issue said "SPEC-2" and "SPEC-3", meaning labels inside a
# test file; design, spec-coverage and issue-acceptance read them as design's own
# SPEC numbers and matched on names instead of content. Identifiers taken from
# prose are not deterministic, so the engine numbers the requirements itself.
#
# Q1 [code] intake writes artifacts/requirements.json from the issue body's
#           checkboxes (under any heading, not inside a code fence), numbered
#           R-1, R-2, … in order by the engine; the text is kept as written. With
#           no checkboxes, R-1 is the title and first paragraph. A goal run writes
#           none (and leaves no stale list). The manifests declare the list as an
#           intake output and an input of design, design-gate, spec-coverage and
#           issue-acceptance.
# Q2 [code] the parser splits ` covers: R-1 R-3` from a requirement's text,
#           before or after the evidence, and acceptance_spec_covers lists the ids.
# Q3 [code] design-gate fails a design that leaves an R uncovered, naming it and
#           its text in plain words; passes when every R is covered (a [done]
#           SPEC counts); skips the check when there is no requirements.json.
# Q4 [code] the design prompt shows the R list and asks for ` covers: ` on each SPEC.
# Q5 [code] the spec-coverage prompt presents the R list to judge.
# Q6 [code] the issue-acceptance prompt presents the R list to judge.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "one engine-numbered requirement list per issue (#2306, ADR-070)"
setup_test_env "requirements-list"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# ─── Q1: intake writes the list ──────────────────────────────────────────────
print_test_section "Q1: intake numbers the issue's checkboxes"
# shellcheck source=../../plugins/agent/intake/tests/intake-test-lib.sh
source "$REPO_ROOT/plugins/agent/intake/tests/intake-test-lib.sh"
export ZBUILD_EVENTS_DB="/dev/null"
set +e
_REQ="$ARTIFACT_DIR/requirements.json"
_q1_body='Some context that is not a requirement.

## What
- [ ] Test: intake writes the list. Fails on main.
- a plain bullet, not a checkbox

```markdown
- [ ] a checkbox inside a code fence is an example, not a requirement
```

## Acceptance (red first)
- [x] already ticked: the SPEC-2 label in tests/x-test.sh still passes
  * [ ] nested checkbox for #2035/SPEC-3'
_set_gh_mock "One list of requirements" "$_q1_body" 0
unset ZBUILD_GOAL 2>/dev/null || true
export ZBUILD_ISSUE="$_ZB_ID"
rm -f "$_REQ"
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
assert_eq "[Q1] intake passes on an issue with checkboxes" "pass" \
    "$(jq -r '.verdict' "$ARTIFACT_DIR/intake-result.json" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] requirements.json carries schema_version 1" "1" "$(jq -r '.schema_version' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] the source is the checkboxes" "checkboxes" "$(jq -r '.source' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] ids are R-1.. in order, assigned by the engine" "R-1 R-2 R-3" \
    "$(jq -r '[.requirements[].id] | join(" ")' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] R-1 is the first checkbox's text" "Test: intake writes the list. Fails on main." \
    "$(jq -r '.requirements[0].text' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] a ticked checkbox is a requirement too; its words are kept as written" \
    "already ticked: the SPEC-2 label in tests/x-test.sh still passes" \
    "$(jq -r '.requirements[1].text' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] a nested checkbox counts" "nested checkbox for #2035/SPEC-3" \
    "$(jq -r '.requirements[2].text' "$_REQ" 2>/dev/null || echo MISSING)"

_set_gh_mock "Make the gate quieter" $'The gate prints every line twice.\nIt should print each once.\n\nMore detail here.' 0
rm -f "$_REQ"
intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
assert_eq "[Q1] with no checkboxes the source is the title" "title" "$(jq -r '.source' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] with no checkboxes there is one requirement, R-1" "R-1" \
    "$(jq -r '[.requirements[].id] | join(" ")' "$_REQ" 2>/dev/null || echo MISSING)"
assert_eq "[Q1] R-1 is the title and the first paragraph" \
    "Make the gate quieter: The gate prints every line twice. It should print each once." \
    "$(jq -r '.requirements[0].text' "$_REQ" 2>/dev/null || echo MISSING)"

# A goal run has no issue to number; a list left by an earlier run is removed.
printf '{"schema_version":1,"requirements":[{"id":"R-1","text":"stale"}]}\n' > "$_REQ"
_clear_gh_mock
ZBUILD_GOAL="A goal with no issue" ZBUILD_ISSUE=0 intake_run "intake" "$STATE_FILE" >/dev/null 2>&1
if [[ -e "$_REQ" ]]; then
    assert_fail "[Q1] a goal run leaves no requirements.json" "$(cat "$_REQ")"
else
    assert_pass "[Q1] a goal run leaves no requirements.json"
fi

_out="$(awk '/^outputs:/{o=1;next} o&&/^[a-z_]+:/{exit} o' "$PLUGIN_DIR/manifest.yaml")"
assert_contains "[Q1] intake declares the requirements output" "$_out" '- id: requirements'
assert_contains "[Q1] at artifacts/requirements.json" "$_out" 'path: "${artifact_dir}/requirements.json"'
for _m in agent/design tool/design-gate agent/spec-coverage agent/issue-acceptance; do
    _in="$(awk '/^inputs:/{o=1;next} o&&/^[a-z_]+:/{exit} o' "$REPO_ROOT/plugins/$_m/manifest.yaml")"
    assert_contains "[Q1] $_m declares the requirements input" "$_in" '- id: requirements'
done
unset ZBUILD_ISSUE ZBUILD_STAGE_INPUTS

# ─── Q2: the parser ──────────────────────────────────────────────────────────
print_test_section "Q2: covers is split from the requirement's words"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
_DM="$TEST_TEMP_DIR/q2-design.md"
printf '%s\n' '# Design' '```acceptance' \
    'SPEC-1[code]: the gate fails an uncovered requirement covers: R-1 R-3' \
    'SPEC-2[done]: the loader reads the file covers: R-2 evidence: scripts/x.sh:3' \
    'SPEC-3[done]: the loader reads it evidence: scripts/x.sh:4 covers: R-4' \
    'SPEC-4[no-code]: the docs say so' \
    'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_DM"
assert_eq "[Q2] the text stops before covers" "the gate fails an uncovered requirement" "$(acceptance_spec_text "$_DM" SPEC-1)"
assert_eq "[Q2] acceptance_spec_covers lists the ids" $'R-1\nR-3' "$(acceptance_spec_covers "$_DM" SPEC-1)"
assert_eq "[Q2] covers before evidence: text" "the loader reads the file" "$(acceptance_spec_text "$_DM" SPEC-2)"
assert_eq "[Q2] covers before evidence: ids" "R-2" "$(acceptance_spec_covers "$_DM" SPEC-2)"
assert_eq "[Q2] covers before evidence: the evidence is still read" "scripts/x.sh:3" "$(acceptance_spec_evidence "$_DM" SPEC-2)"
assert_eq "[Q2] covers after evidence: the evidence stops before covers" "scripts/x.sh:4" "$(acceptance_spec_evidence "$_DM" SPEC-3)"
assert_eq "[Q2] covers after evidence: ids" "R-4" "$(acceptance_spec_covers "$_DM" SPEC-3)"
assert_eq "[Q2] no covers part: no ids" "" "$(acceptance_spec_covers "$_DM" SPEC-4)"

# ─── Q3: design-gate ─────────────────────────────────────────────────────────
print_test_section "Q3: design-gate fails a requirement no SPEC covers"
# shellcheck source=../../plugins/tool/design-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"
_ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$_ROOT/scripts"
printf 'one\ntwo\nthree\n' > "$_ROOT/scripts/x.sh"
export ZBUILD_REPO_ROOT="$_ROOT"
_q3() {   # _q3 <name> <covers-for-SPEC-1> <covers-for-SPEC-2> [no-req] [R-3 text as JSON]
    _S="$TEST_TEMP_DIR/q3-$1"; _A="$_S/artifacts"; mkdir -p "$_A"
    printf '{}' > "$_S/pipeline-state.json"
    printf '%s\n' '# Design' '```scope' 'scripts/x.sh' '```' '```acceptance' \
        "SPEC-1[code]: the gate fails on a missing file$2" \
        "SPEC-2[done]: the loader reads the file$3 evidence: scripts/x.sh:2" \
        'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_A/design.md"
    [[ "${4:-}" == "no-req" ]] || printf '%s\n' '{"schema_version":1,"source":"checkboxes","requirements":[' \
        '{"id":"R-1","text":"fail on a missing file"},{"id":"R-2","text":"read the file"},' \
        "{\"id\":\"R-3\",\"text\":\"${5:-say which file is missing}\"}]}" > "$_A/requirements.json"
    design_gate_run "design-gate" "$_S/pipeline-state.json" >/dev/null 2>&1
    _V="$(jq -r '.verdict' "$_A/design-gate-result.json" 2>/dev/null || echo MISSING)"
    _VIOL="$(jq -r '.violations[]' "$_A/design-gate-result.json" 2>/dev/null || true)"
    _FB="$(cat "$_A/design-gate-feedback.md" 2>/dev/null || true)"
}
_q3 uncovered " covers: R-1" " covers: R-2"
assert_eq "[Q3] a design that leaves R-3 uncovered fails" "fail" "$_V"
assert_contains "[Q3] the violation names R-3 and its text" "$_VIOL" "REQUIREMENT_NOT_COVERED R-3 (say which file is missing)"
assert_eq "[Q3] only the uncovered requirement is named" "1" "$(grep -c 'REQUIREMENT_NOT_COVERED' <<< "$_VIOL")"
assert_contains "[Q3] the feedback says it in plain words" "$_FB" \
    'requirement R-3 from the issue is not covered by any SPEC: say which file is missing.'
# review #2320: a requirement whose text has double quotes still reads as one sentence.
_q3 quoted " covers: R-1" " covers: R-2" "" 'say \"which\" file is missing'
assert_contains "[Q3] (fixture) the quoted requirement is read" "$_VIOL" 'REQUIREMENT_NOT_COVERED R-3 (say "which" file is missing)'
assert_contains "[Q3] a requirement with quotes in it is quoted once, unbroken" "$_FB" \
    'requirement R-3 from the issue is not covered by any SPEC: say "which" file is missing.'
# review #2320 round 2: a backslash in a requirement reaches design as written, not doubled.
_q3 backslash " covers: R-1" " covers: R-2" "" 'see C:\\tmp'
assert_contains "[Q3] (fixture) the backslash requirement is read" "$_VIOL" 'REQUIREMENT_NOT_COVERED R-3 (see C:'
assert_contains "[Q3] a backslash in a requirement is not doubled" "$_FB" \
    'requirement R-3 from the issue is not covered by any SPEC: see C:\tmp.'
_q3 covered " covers: R-1 R-3" " covers: R-2"
assert_eq "[Q3] every requirement covered (one by a [done] SPEC) passes" "pass" "$_V"
_q3 nolist "" "" no-req
assert_eq "[Q3] with no requirements.json (a goal run) the check is skipped" "pass" "$_V"

# ─── Q4: the design prompt ───────────────────────────────────────────────────
print_test_section "Q4: the design prompt shows the list"
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
route_to_model_loop() {
    local _bt='```'
    printf '# Design\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[code]: x covers: R-1\nTESTFILES:\nSPEC-1: tests/t.sh\nWIRING: none\n%s\n' \
        "$_bt" "$_bt" "$_bt" "$_bt" > "$_Q4_OUT"
    _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
_Q4="$TEST_TEMP_DIR/q4"; _Q4A="$_Q4/state/artifacts"; mkdir -p "$_Q4A"
/usr/bin/git -C "$_Q4" init -q >/dev/null 2>&1
printf 'scope: all\n' > "$_Q4/state/scope-manifest.md"
printf '%s\n' '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}' > "$_Q4A/plan.json"
printf '%s\n' '{"schema_version":1,"source":"checkboxes","requirements":[{"id":"R-1","text":"fail on a missing file"},{"id":"R-2","text":"name the missing file"}]}' > "$_Q4A/requirements.json"
_Q4_OUT="$_Q4A/design.md"
ZBUILD_REPO_ROOT="$_Q4" ZBUILD_EVENTS_JSONL="$_Q4/events.jsonl" \
    _design_stage_run_inner "$_Q4/state/scope-manifest.md" "$_Q4A/plan.json" "$_Q4_OUT" "$_Q4A" >/dev/null 2>&1
_P4="$(cat "$_Q4A/design-prompt.txt" 2>/dev/null || true)"
assert_contains "[Q4] the design prompt lists R-1 with its text" "$_P4" "- R-1: fail on a missing file"
assert_contains "[Q4] and R-2" "$_P4" "- R-2: name the missing file"
assert_contains "[Q4] and asks each SPEC to say which it covers" "$_P4" "covers: R-1 R-2"
assert_contains "[Q4] covers comes before any evidence" "$_P4" 'before any ` evidence: `'

# ─── Q5: spec-coverage ───────────────────────────────────────────────────────
print_test_section "Q5: spec-coverage judges the list"
# shellcheck source=../../plugins/agent/spec-coverage/plugin.sh
source "$REPO_ROOT/plugins/agent/spec-coverage/plugin.sh"
_PROMPT="$TEST_TEMP_DIR/prompt.txt"
route_to_model() { printf '%s' "$2" > "$_PROMPT"; printf 'VERDICT: covered\nREASON: ok\n'; return 0; }
resolve_tier() { printf 'T2'; }
_S5="$TEST_TEMP_DIR/q5"; mkdir -p "$_S5/artifacts"; printf '{}' > "$_S5/pipeline-state.json"
printf 'Make the gate fail. See SPEC-2 in the test file.\n' > "$_S5/intake.md"
printf '%s\n' '# Design' '```acceptance' 'SPEC-1[code]: the gate fails covers: R-1' 'TESTFILES:' 'SPEC-1: tests/t.sh' 'WIRING: none' '```' > "$_S5/artifacts/design.md"
printf '%s\n' '{"schema_version":1,"source":"checkboxes","requirements":[{"id":"R-1","text":"the gate fails on a missing file"},{"id":"R-2","text":"the SPEC-2 label still passes"}]}' > "$_S5/artifacts/requirements.json"
: > "$_PROMPT"
ZBUILD_ARTIFACT_DIR="$_S5/artifacts" ZBUILD_STATE_DIR="$_S5" spec_coverage_run spec-coverage "$_S5/pipeline-state.json" >/dev/null 2>&1
_P5="$(cat "$_PROMPT")"
assert_contains "[Q5] the spec-coverage prompt lists R-1 with its text" "$_P5" "- R-1: the gate fails on a missing file"
assert_contains "[Q5] and R-2, whose words mention a SPEC label" "$_P5" "- R-2: the SPEC-2 label still passes"
assert_contains "[Q5] and says the list is what to judge" "$_P5" "Judge every requirement in REQUIREMENTS"

# ─── Q6: issue-acceptance ────────────────────────────────────────────────────
print_test_section "Q6: issue-acceptance judges the list"
# shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh"
route_to_model() { printf '%s' "$2" > "$_PROMPT"; printf 'VERDICT: pass\nREASON: ok\n'; return 0; }
resolve_tier() { printf 'T2'; }
_S6="$TEST_TEMP_DIR/q6"; mkdir -p "$_S6/artifacts" "$_S6/in"; printf '{}' > "$_S6/pipeline-state.json"
printf 'Make the gate fail.\n' > "$_S6/in/issue.md"
cp "$_S5/artifacts/design.md" "$_S6/in/design.md"
cp "$_S5/artifacts/requirements.json" "$_S6/in/requirements.json"
jq -n --arg i "$_S6/in/issue.md" --arg d "$_S6/in/design.md" --arg r "$_S6/in/requirements.json" \
    '{inputs: {intake_goal: $i, design: $d, requirements: $r}}' > "$_S6/stage-inputs.json"
: > "$_PROMPT"
ZBUILD_STAGE_INPUTS="$_S6/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$_S6/artifacts" ZBUILD_REPO_ROOT="$_Q4" \
    issue_acceptance_run issue-acceptance "$_S6/pipeline-state.json" >/dev/null 2>&1
_P6="$(cat "$_PROMPT")"
assert_contains "[Q6] the issue-acceptance prompt lists R-1 with its text" "$_P6" "- R-1: the gate fails on a missing file"
assert_contains "[Q6] and R-2" "$_P6" "- R-2: the SPEC-2 label still passes"
assert_contains "[Q6] and judges each one" "$_P6" "Judge every requirement in ISSUE REQUIREMENTS"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
