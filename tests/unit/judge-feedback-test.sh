#!/usr/bin/env bash
# tests/unit/judge-feedback-test.sh — design and test-author are told exactly
# which part to fix and where, and the judges answer and keep answers per SPEC
# (#2470, ADR-073, ADR-072 §3 §4, ADR-067 §8).
#
# Why: on #1805 run 41845438073 design used its three tries and never reached
# test-author. Try 1 kept nine old one-line SPECs that only the failing check
# named; findings named parts `Then 1` / `Then 2`, labels design never wrote;
# each finding was shown twice; the coverage judge opened the old design.md
# while judging the draft; and one unchanged part was `ok` in try 2 and `how` in
# try 3, because a one-line edit re-judged everything.
#
# F1 design is told up front which kept SPECs are still on one line
# F2 every model sees a SPEC's parts by the words design wrote — never
#    `Then 1`; a judge names a part by its word and a quote, and the quote
#    picks the line
# F3 a stage's summary does not copy its findings, so each is shown once
# F4 a judge never sees its own stage's earlier output; design's judge is given
#    the draft by its path and, inline, only the SPECs it must judge
# F5 feedback: a failing SPEC shown whole, `[FIX IN DESIGN: …]` or
#    `[FIX IN TEST: …]` on exactly the lines to fix; a SPEC that passed is not
#    shown; Previous work shows such a finding whole
# F6 the judges answer one line for a SPEC that is fine and one per failing
#    part; a SPEC with no line is asked again; each SPEC's answer is kept, so an
#    unchanged SPEC is not judged again, and requirement coverage is asked again
#    whenever any SPEC changes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "each part to fix is shown where it is, and judges answer per SPEC (#2470)"
setup_test_env "judge-feedback"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export _RUNNER_ENGINE_SHA="engine-a"

_N="$TEST_TEMP_DIR/n"; _P="$TEST_TEMP_DIR/p"
_l() { grep "^$2|" "$1" | head -1 | cut -d'|' -f2-; }
assert_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

# The design every case below judges: two SPECs, one with a Then and an And.
_spec_design() {  # <file> [DSFRSH-1's last part words]
    cat > "$1" <<MD
# Design
\`\`\`acceptance
DSFRSH-1[code]: a new run starts from the first stage covers: RQRQST-1
  Given: a run whose stages all completed
  When: it is started again
  Then: every stage is dispatched
  And: ${2:-no stage is skipped}
DSWORK-2[code]: the flag is read covers: RQRQST-2
  When: the flag is given
  Then: the run uses it
WIRING: none
\`\`\`
MD
}
REQS='- RQRQST-1: start from the first stage
- RQRQST-2: read the flag'

print_test_section "F2: parts are shown by the words design wrote"
(
    # shellcheck source=../../scripts/lib/acceptance-block.sh
    source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
    D="$TEST_TEMP_DIR/f2.md"; _spec_design "$D"
    b="$(extract_acceptance_block "$D")"
    r=""; acceptance_block_render_v r "$b"; echo "F2a|$(tr '\n' '~' <<< "$r")"
    r=""; acceptance_spec_render_v r "$b" DSFRSH-1; echo "F2b|$(tr '\n' '~' <<< "$r")"
) > "$TEST_TEMP_DIR/f2.out" 2>/dev/null
F="$TEST_TEMP_DIR/f2.out"
assert_contains "[F2] the block is shown with the And as written" "$(_l "$F" F2a)" "  And: no stage is skipped"
assert_contains "[F2] ...and the Then as written" "$(_l "$F" F2a)" "  Then: every stage is dispatched"
assert_lacks "[F2] ...never renumbered" "$(_l "$F" F2a)" "Then 2"
assert_lacks "[F2] ...not even the first" "$(_l "$F" F2a)" "Then 1"
assert_contains "[F2] a SPEC alone is shown the same way" "$(_l "$F" F2b)" "  And: no stage is skipped"

print_test_section "F3-F6: design's check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
    artifact_dir="$TEST_TEMP_DIR/f-art"; mkdir -p "$artifact_dir"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
    D="$artifact_dir/design-draft.md"; _spec_design "$D"
    _cov() { printf 0 > "$_N"; _design_coverage "$D" "$REQS" T2 "${1:-}" >/dev/null 2>&1; }
    _fresh() { rm -f "$artifact_dir/design-judged.json"; }
    OK=$'RQRQST-1: covered\nRQRQST-2: covered\nDSFRSH-1: ok\nDSWORK-2: ok\n'

    # F6: one line per SPEC that is fine.
    _fresh; _R1="$OK"; _R2=""; _cov
    echo "F6a|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(_design_coverage_findings | grep -c .)"
    _p1="$(cat "$_P.1")"
    echo "F4a|$([[ "$_p1" == *"$D"* ]] && echo path)|$([[ "$_p1" == *"Do not open design.md"* ]] && echo told)"
    echo "F2c|$([[ "$_p1" == *"  And: no stage is skipped"* ]] && echo written)|$([[ "$_p1" == *"Then 2"* ]] && echo numbered)"
    # F6: a SPEC with no line is asked again, naming it.
    _fresh; _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSFRSH-1: ok\n'; _R2="$OK"; _cov
    echo "F6b|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    # F2/F5: a part named by its word and a quote; the quote picks the And.
    _fresh; _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSWORK-2: ok\nDSFRSH-1 Then: untestable | WHY: a test cannot see what is skipped from outside | QUOTE: "no stage is skipped"\n'; _R2=""; _cov
    _fx="$(_design_coverage_findings)"
    echo "F5a|$(grep -c . <<< "$_fx")|$(tr '\n\036' '~~' <<< "$_fx")"
    # ...a quote in none of its Thens is asked again.
    _fresh; _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSWORK-2: ok\nDSFRSH-1 Then: how | WHY: x | QUOTE: "it is started again"\n'; _R2="$_R1"; _cov
    echo "F2d|$_DESIGN_COV_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    # F5: a SPEC-level verdict marks the SPEC's own line; an uncovered requirement is one line.
    _fresh; _R1=$'RQRQST-1: covered\nRQRQST-2: uncovered | WHY: nothing reads the flag from the config file | QUOTE: "read the flag"\nDSWORK-2: ok\nDSFRSH-1: needs_cleanup | WHY: the run it sets up stays in the state folder | QUOTE: "a run whose stages all completed"\n'; _R2=""; _cov
    echo "F5b|$(_design_coverage_findings | tr '\n\036' '~~')"

    # F6: answers kept per SPEC.
    _fresh; _R1="$OK"; _R2=""; _cov
    _cov; echo "F6c|$(cat "$_N")"
    _spec_design "$D" "no stage is skipped, not even the last"
    _R1=$'RQRQST-1: covered\nRQRQST-2: covered\nDSFRSH-1: ok\n'; _cov
    _p1="$(cat "$_P.1" 2>/dev/null)"
    echo "F6d|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$([[ "$_p1" == *"  And: no stage is skipped, not even the last"* ]] && echo changed-inline)|$([[ "$_p1" == *"  Then: the run uses it"* ]] && echo unchanged-inline)|$([[ "$_p1" == *"<requirement id>: covered"* ]] && echo reqs-asked)"
    # A dispute on one unchanged SPEC: that SPEC alone, and requirements are not asked again.
    _ta="design finding 1: wrong — DSWORK-2 reads the flag in main()"
    printf '%s\n' '{"result_contract":3,"outcome":"unusable","reason":"r","data":{"findings":[{"n":1,"text":"DSWORK-2: 1 part to fix"}]}}' > "$artifact_dir/design-verdict.json"
    _R1=$'DSWORK-2: ok\n'; _cov "$_ta"
    _p1="$(cat "$_P.1" 2>/dev/null)"
    echo "F6e|$(cat "$_N")|$_DESIGN_COV_OUTCOME|$([[ "$_p1" == *"DSWORK-2 reads the flag in main()"* ]] && echo shown)|$([[ "$_p1" == *"<requirement id>: covered"* ]] && echo reqs-asked)|$([[ "$_p1" == *"  And: no stage is skipped"* ]] && echo other-inline)"
) > "$TEST_TEMP_DIR/f.out" 2>/dev/null
F="$TEST_TEMP_DIR/f.out"
assert_eq "[F6] each SPEC fine on one line: judged, in one call, nothing found" "1||0" "$(_l "$F" F6a)"
assert_eq "[F4] design's judge is given the draft by its path" "path|told" "$(_l "$F" F4a)"
assert_eq "[F2] the judge sees the And as written, never a number" "written|" "$(_l "$F" F2c)"
assert_contains "[F6] a SPEC with no line is asked again" "$(_l "$F" F6b)" "2||"
assert_contains "[F6] ...naming it" "$(_l "$F" F6b)" "no line for DSWORK-2"
assert_contains "[F5] one finding for the failing SPEC" "$(_l "$F" F5a)" "1|"
assert_contains "[F5] ...headed with what to fix" "$(_l "$F" F5a)" "DSFRSH-1: 1 part to fix"
assert_contains "[F5] ...the SPEC shown whole, its first line" "$(_l "$F" F5a)" "~DSFRSH-1[code]: a new run starts from the first stage covers: RQRQST-1~"
assert_contains "[F5] ...its parts as written, unmarked where fine" "$(_l "$F" F5a)" "~  Then: every stage is dispatched~"
assert_contains "[F5] ...the line to fix marked with where and why" "$(_l "$F" F5a)" "  And: no stage is skipped [FIX IN DESIGN: a test cannot see what is skipped from outside"
assert_lacks "[F5] ...a SPEC that passed is not shown" "$(_l "$F" F5a)" "DSWORK-2"
assert_contains "[F2] a quote in none of the parts it names is asked again" "$(_l "$F" F2d)" "unusable|"
assert_contains "[F2] ...saying so" "$(_l "$F" F2d)" "DSFRSH-1 Then's quote is not in any of its Then lines"
assert_contains "[F5] a SPEC-level verdict marks the SPEC's own line" "$(_l "$F" F5b)" "DSFRSH-1[code]: a new run starts from the first stage covers: RQRQST-1 [FIX IN DESIGN: the run it sets up stays in the state folder"
assert_contains "[F5] an uncovered requirement is one line, marked" "$(_l "$F" F5b)" "RQRQST-2 is not covered: nothing reads the flag from the config file"
assert_contains "[F5] ...with where it is fixed" "$(_l "$F" F5b)" "[FIX IN DESIGN: add or widen a SPEC"
assert_eq "[F6] unchanged: no call" "0" "$(_l "$F" F6c)"
assert_eq "[F6] one SPEC changed: judged, that SPEC inline, the other not, requirements asked again" "1||changed-inline||reqs-asked" "$(_l "$F" F6d)"
assert_eq "[F6] a dispute on an unchanged SPEC: that SPEC alone, the answer shown, requirements kept" "1||shown||" "$(_l "$F" F6e)"

print_test_section "F5-F6: test-author's check"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh"
    route_to_model() {
        local n; n=$(( $(cat "$_N") + 1 )); printf '%s' "$n" > "$_N"; printf '%s' "$2" > "$_P.$n"
        if [[ $n -eq 1 ]]; then printf '%s' "$_R1"; else printf '%s' "${_R2:-$_R1}"; fi
    }
    R="$TEST_TEMP_DIR/t-repo"; mkdir -p "$R/tests"; git -C "$R" init -q; D="$TEST_TEMP_DIR/t.md"; _spec_design "$D"
    printf '# Given\nrun=done\n# When\nstart\n# Then\nassert_eq "[DSFRSH-1] first" "1" "$s"\nassert_eq "[DSWORK-2] flag" "1" "$f"\n' > "$R/tests/a-test.sh"
    A="$TEST_TEMP_DIR/t-art"; mkdir -p "$A"
    _j() { printf 0 > "$_N"; rm -f "$A/test-author-judged.json"; _ta_correspondence "$D" "$R" T2 "$A" >/dev/null 2>&1; }
    _R1=$'DSFRSH-1: ok\nDSWORK-2: ok\n'; _R2=""; _j
    echo "T6a|$(cat "$_N")|${#_TA_CORR_FINDINGS[@]}|$_TA_CORR_OUTCOME"
    _p1="$(cat "$_P.1")"
    echo "T2a|$([[ "$_p1" == *"  And: no stage is skipped"* ]] && echo written)|$([[ "$_p1" == *"Then 2"* ]] && echo numbered)"
    _R1=$'DSFRSH-1: ok\n'; _R2=$'DSWORK-2: ok\n'; _j
    echo "T6b|$(cat "$_N")|$_TA_CORR_OUTCOME|$(tr -s '[:space:]' ' ' < "$_P.2" 2>/dev/null)"
    _R1=$'DSWORK-2: ok\nDSFRSH-1 And: missing | WHY: nothing asserts that no stage was skipped | QUOTE: "no stage is skipped"\n'; _R2=""; _j
    echo "T5a|${#_TA_CORR_FINDINGS[@]}|$(printf '%s~' "${_TA_CORR_FINDINGS[@]}" | tr '\n\036' '~~')"
    _R1=$'DSWORK-2: ok\nDSFRSH-1 sections: missing | WHY: there is no Then section\n'; _R2=""; _j
    echo "T5b|$(printf '%s~' "${_TA_CORR_FINDINGS[@]}" | tr '\n\036' '~~')"
    _R1=$'DSWORK-2: ok\nDSFRSH-1: untestable | WHY: nothing outside can see a skip | QUOTE: "no stage is skipped"\n'; _R2=""; _j
    echo "T5c|$(tr '\n\036' '~~' <<< "${_TA_CORR_UNTESTABLE:-}")"
) > "$TEST_TEMP_DIR/t.out" 2>/dev/null
T="$TEST_TEMP_DIR/t.out"
assert_eq "[F6] test-author's check: each SPEC fine on one line" "1|0|" "$(_l "$T" T6a)"
assert_eq "[F2] ...it sees the And as written" "written|" "$(_l "$T" T2a)"
assert_contains "[F6] ...a SPEC with no line is asked again" "$(_l "$T" T6b)" "2||"
assert_contains "[F6] ...naming it" "$(_l "$T" T6b)" "no line for DSWORK-2"
# #2480: headed with the part and why, not how many parts.
assert_contains "[F5] a part the test misses: the SPEC whole" "$(_l "$T" T5a)" "1|DSFRSH-1 And: nothing asserts that no stage was skipped~DSFRSH-1[code]: a new run starts from the first stage covers: RQRQST-1~"
assert_contains "[F5] ...the line marked [FIX IN TEST: …]" "$(_l "$T" T5a)" "  And: no stage is skipped [FIX IN TEST: nothing asserts that no stage was skipped"
assert_contains "[F5] ...other parts unmarked" "$(_l "$T" T5a)" "~  Then: every stage is dispatched~"
assert_lacks "[F5] ...a SPEC that passed is not shown" "$(_l "$T" T5a)" "DSWORK-2"
assert_contains "[F5] missing sections mark the SPEC's own line" "$(_l "$T" T5b)" "covers: RQRQST-1 [FIX IN TEST: lay the test out in Given, When and Then sections — there is no Then section"
assert_contains "[F5] a SPEC no test can prove is marked for design" "$(_l "$T" T5c)" "[FIX IN DESIGN: nothing outside can see a skip"

print_test_section "F3-F5: what the next stage is shown"
(
    # shellcheck source=../../scripts/lib/stage-prompt.sh
    source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
    # shellcheck source=../../scripts/lib/stage-result.sh
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    # shellcheck source=../../scripts/lib/stage-summary.sh
    source "$REPO_ROOT/scripts/lib/stage-summary.sh"
    # shellcheck source=../../core/pipeline/state_helpers.sh
    source "$REPO_ROOT/core/pipeline/state_helpers.sh"
    sd="$TEST_TEMP_DIR/pw-state"; mkdir -p "$sd/artifacts"
    _TPL_STAGES=(design)
    init_state "$sd/pipeline-state.json" run-1 7 >/dev/null 2>&1
    _update_stage_status "$sd/pipeline-state.json" design complete
    _f=$'DSFRSH-1: 1 part to fix\x1eFRSH-1[code]: a new run starts from the first stage\x1e  Then: every stage is dispatched [FIX IN DESIGN: say what a test can see]'
    stage_result_write "$sd/artifacts/design-verdict.json" unusable "the design fails 1 of its checks" \
        "$(jq -nc --argjson f "$(printf '%s\n' "$_f" | stage_findings_json)" '{findings: $f}')" >/dev/null
    printf '# x\n' > "$sd/artifacts/design.md"
    # shellcheck source=../../core/pipeline/input-resolve.sh
    source "$REPO_ROOT/core/pipeline/input-resolve.sh"
    # The producer index, as the engine resolves it for a dispatch of design.
    idx="$(_inputs_resolve_stage design "$REPO_ROOT/plugins" "$sd")"
    b=""; stage_blocks_write_v b design "$sd" "$REPO_ROOT/plugins/agent/design/manifest.yaml" "$REPO_ROOT/plugins" "$idx" "$TEST_TEMP_DIR" >/dev/null 2>&1
    full="$(cat "$b/previous-work.md" 2>/dev/null)"; fresh="$(cat "$b/previous-work-fresh.md" 2>/dev/null)"
    echo "F5c|$(tr '\n' '~' <<< "$full")"
    echo "F4b|$([[ "$full" == *"### design"* ]] && echo full-has)|$([[ "$fresh" == *"### design"* ]] && echo fresh-has)|$([[ "$fresh" == *"FIX IN DESIGN"* ]] && echo fresh-finding)"
) > "$TEST_TEMP_DIR/pw.out" 2>/dev/null
W="$TEST_TEMP_DIR/pw.out"
assert_contains "[F5] Previous work shows a finding whole, line by line" "$(_l "$W" F5c)" "DSFRSH-1: 1 part to fix~"
assert_contains "[F5] ...its marked line on a line of its own" "$(_l "$W" F5c)" "~      Then: every stage is dispatched [FIX IN DESIGN: say what a test can see]"
assert_eq "[F4] a building call sees its stage's earlier output; a judging call does not" "full-has||" "$(_l "$W" F4b)"

print_test_section "F1, F3: design's stage"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh"
    apply_scope_redaction() { cp "$1" "$2"; return 0; }
    BT='```'
    DRAFT="# Design

${BT}scope
foo.sh
${BT}

${BT}acceptance
DSLEGC-1[code]: an old one-line requirement covers: RQDOCS-1
  When: the docs are built
  Then: the page says so
DSDOCW-1[no-code]: the docs say so covers: RQDOCS-1
WIRING: none
${BT}
"
    route_to_model() {
        local _t; _t="$(zb_test_prompt_write_path "$2")"
        if [[ -n "$_t" ]]; then printf '%s\n' "$2" > "$TEST_TEMP_DIR/f1-design-prompt"; printf '%s' "$DRAFT" > "$_t"; return 0; fi
        printf 'RQDOCS-1: uncovered | WHY: the docs say nothing yet | QUOTE: "the docs say so"\nDSDOCW-1: ok\nDSLEGC-1: ok\n'
    }
    d="$TEST_TEMP_DIR/f1"; mkdir -p "$d/state/artifacts"; git -C "$d" init -q >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$d" ZBUILD_EVENTS_JSONL="$d/state/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    A="$d/state/artifacts"; printf 'scope: all\n' > "$d/state/scope-manifest.md"
    jq -nc '{requirements: [{id: "RQDOCS-1", text: "the docs say so"}]}' > "$A/requirements.json"
    jq -nc '{result_contract: 3, outcome: "pass", reason: "r", data: {issue_text: "Write the docs."}}' > "$A/intake-result.json"
    printf '# Design\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nDSLEGC-1[code]: an old one-line requirement covers: RQDOCS-1\nDSDOCW-1[no-code]: the docs say so covers: RQDOCS-1\nWIRING: none\n%s\n' "$BT" "$BT" "$BT" "$BT" > "$A/design.md"
    _design_stage_run_inner "$d/state/scope-manifest.md" "$A/design.md" "$A" >/dev/null 2>&1
    p="$(tr -s '[:space:]' ' ' < "$TEST_TEMP_DIR/f1-design-prompt")"
    echo "F1a|$([[ "$p" == *"still written on one line"* ]] && echo told)|$([[ "$p" == *"- DSLEGC-1"* ]] && echo legc)|$([[ "$p" == *"- DSDOCW-1"* ]] && echo docw)"
    echo "F3a|$(jq -r '.data.findings | length' "$A/design-verdict.json" 2>/dev/null)|$(grep -c 'the docs say nothing yet' "$A/design-summary.md" 2>/dev/null)"
) > "$TEST_TEMP_DIR/f1.out" 2>/dev/null
G="$TEST_TEMP_DIR/f1.out"
assert_eq "[F1] design is told which kept SPECs are still on one line — a [no-code] one is not named" "told|legc|" "$(_l "$G" F1a)"
assert_eq "[F3] the finding is in design's result, and not copied into its summary" "1|0" "$(_l "$G" F3a)"

cleanup_test_env
print_test_results
