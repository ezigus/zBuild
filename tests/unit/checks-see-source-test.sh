#!/usr/bin/env bash
# tests/unit/checks-see-source-test.sh — every check that judges work against
# a summary is shown what the summary is of (#2579 R2; ADR-072 §3, amended
# 2026-11-21).
#
# Why: on #1764 run 44863026881 build's step check judged build's answer
# against the step alone; the SPEC the step summarized said "only", the step
# did not, and a fallback that broke the SPEC passed. Each check is run here
# through the code that calls it, with the model mocked, and the source it
# judges against must be in the prompt it was given — in its "What you judge
# against" part when it has one.
#
# CS1 design's check (_design_coverage): the issue's requirements
# CS2 test-author's assertion check (_ta_correspondence): each SPEC, with its
#     parts
# CS3 issue-acceptance (issue_acceptance_run): the issue's words and its
#     requirements
# CS4 a lens (_review_lens_run_inner): the issue the change was for
# CS5 build's step check (_build_stage_run_inner): the SPECs each step serves,
#     with their parts
# CS6 intake's requirements check (_intake_write_requirements): the issue
# CS7 test-author's check of untagged lines (test_author_run): every SPEC
# CS8 a lens's knock-down check (_review_lens_run_inner): the findings and the
#     change
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "every check sees the source it judges against (#2579 R2)"
setup_test_env "checks-see-source"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export _RUNNER_ENGINE_SHA="engine-a"

ISSUE='The holder is read only from comments by the authenticated actor.'
REQ='- RQCLA-1: the holder is read only from the actor'"'"'s comments'
SPEC_TEXT='the holder is only read from comments authored by the authenticated GitHub actor'
THEN="the holder read is the actor's"
P="$TEST_TEMP_DIR/prompt"
# _against — the captured prompt's "What you judge against" part, or the whole
# prompt for one written without the three parts.
_against() { local p; p="$(cat "$P" 2>/dev/null)"; [[ "$p" == *"## What you judge against"* ]] && { p="${p#*## What you judge against}"; p="${p%%## What you must not do*}"; }; printf '%s' "$p"; }
_repo() {   # <dir> — a repository with a base on main and a branch
    mkdir -p "$1"
    ( cd "$1" && git init -q -b main . && git config user.email t@t && git config user.name t \
        && printf 'read_holder() { :; }\n' > h.sh && git add -A && git commit -q -m base && git checkout -q -b work ) >/dev/null 2>&1
}
_design_md() {   # <file>
    printf '# Holder\n\n```steps\n- filter by the actor before scanning | areas: h.sh | serves: DSCLA-23\n```\n\n```acceptance\nDSCLA-23[code]: %s covers: RQCLA-1\n  When: another user posts a holder comment\n  Then: %s\nWIRING: none\n```\n' "$SPEC_TEXT" "$THEN" > "$1"
}

print_test_section "CS1: design's check"
(
    # shellcheck source=../../plugins/agent/design/plugin.sh
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$P"; printf 'RQCLA-1: covered\nDSCLA-23: ok\nsteps: ok\n'; }
    export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/cs1/state" ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/cs1/repo"; mkdir -p "$ZBUILD_STATE_DIR"
    _repo "$ZBUILD_REPO_ROOT"
    artifact_dir="$TEST_TEMP_DIR/cs1/art"; mkdir -p "$artifact_dir"; _design_md "$artifact_dir/design-draft.md"
    _design_coverage "$artifact_dir/design-draft.md" "$REQ" T2 >/dev/null 2>&1
)
assert_contains "[CS1] the requirements it judges the design against" "$(_against)" "$REQ"

print_test_section "CS2: test-author's assertion check"
rm -f "$P"
(
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$P"; printf 'DSCLA-23: ok\n'; }
    R="$TEST_TEMP_DIR/cs2/repo"; _repo "$R"; mkdir -p "$R/tests"
    printf '# Given\nh=a\n# When\nread_holder\n# Then\nassert_eq "[DSCLA-23] actor" "a" "$h"\n' > "$R/tests/h-test.sh"
    A="$TEST_TEMP_DIR/cs2/art"; mkdir -p "$A"; _design_md "$A/design.md"
    _ta_correspondence "$A/design.md" "$R" T2 "$A" >/dev/null 2>&1
)
assert_contains "[CS2] the SPEC it judges the test against" "$(_against)" "$SPEC_TEXT"
assert_contains "[CS2] ...with its parts" "$(_against)" "Then: $THEN"

print_test_section "CS3: issue-acceptance"
rm -f "$P"
(
    S="$TEST_TEMP_DIR/cs3"; A="$S/artifacts"; IN="$S/inputs"; mkdir -p "$A" "$IN"; printf '{}' > "$S/pipeline-state.json"
    export ZBUILD_REPO_ROOT="$S/repo"; _repo "$ZBUILD_REPO_ROOT"
    zb_test_issue_output "$IN" "$ISSUE" >/dev/null
    (
        # shellcheck source=../../plugins/agent/intake/plugin.sh
        source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
        route_to_model() {
            if [[ "$2" == *"check a list of requirements"* ]]; then printf 'MISSING: none\n'
            else printf "REQUIREMENT: RQCLA-1 the holder is read only from the actor's comments\n"; fi
        }
        _intake_write_requirements "$IN" "$(jq -nc --arg b "$ISSUE" '{title: "Holder", body: $b}')"
    ) >/dev/null 2>&1
    _design_md "$IN/design.md"
    printf '%s\n' 'diff --git a/h.sh b/h.sh' '+read_holder' > "$IN/diff.patch"
    zb_test_test_run_output "$IN" pass 1 0 >/dev/null
    jq -n --arg i "$IN/intake-result.json" --arg r "$IN/requirements.json" --arg d "$IN/design.md" \
        --arg p "$IN/diff.patch" --arg t "$IN/test-results.json" \
        '{inputs: {a: $i, r: $r, b: $d, c: $p, d: $t}}' > "$S/stage-inputs.json"
    export ZBUILD_STAGE_INPUTS="$S/stage-inputs.json" ZBUILD_ARTIFACT_DIR="$A"
    # shellcheck source=../../plugins/agent/issue-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/issue-acceptance/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '%s' "$2" > "$P"; printf 'MET: RQCLA-1\nUNASKED: none\n'; }
    resolve_tier() { printf 'T2'; }
    issue_acceptance_run issue-acceptance "$S/pipeline-state.json" >/dev/null 2>&1
)
assert_contains "[CS3] the issue's words" "$(_against)" "$ISSUE"
assert_contains "[CS3] ...and its requirements" "$(_against)" "RQCLA-1: the holder is read only from the actor's comments"

print_test_section "CS4 / CS8: a lens and its knock-down check"
rm -f "$P" "$P.check"
(
    XR="$TEST_TEMP_DIR/cs4/repo"; _repo "$XR"
    ( cd "$XR" && printf 'body="$(list_any)"\n' >> h.sh && git commit -qam change ) >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$XR"
    ART="$TEST_TEMP_DIR/cs4/art"; mkdir -p "$ART"
    zb_test_issue_output "$ART" "$ISSUE" >/dev/null
    printf 'diff --git a/h.sh b/h.sh\n+body="$(list_any)"\n' > "$ART/diff.patch"
    printf 'scope: all\n' > "$TEST_TEMP_DIR/cs4/scope.md"
    # shellcheck source=../../core/plugin-registry/registry.sh
    source "$REPO_ROOT/core/plugin-registry/registry.sh"
    # shellcheck source=../../plugins/agent/review-lens/plugin.sh
    source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" >/dev/null 2>&1
    route_to_model() {
        if zb_test_lens_check_answer "$2" >/dev/null; then printf '%s' "$2" > "$P.check"; zb_test_lens_check_answer "$2"; return 0; fi
        printf '%s' "$2" > "$P"
        zb_test_lens_lines "$(printf '{"score":5,"findings":[{"accepted_if":"only the actor is read","trigger":"another commenter","quote":"body=\\"$(list_any)\\"","file":"h.sh","severity":"high","message":"the fallback reads any commenter","introduced":true,"fix":"code"}]}')"
    }
    artifact_dir="$ART" ZBUILD_CURRENT_STAGE=review_lenses ZBUILD_REVIEW_LENS_ID=red-team _TPL_STAGE_FAIL_ON_review_lenses="high critical" \
        _review_lens_run_inner red-team "$TEST_TEMP_DIR/cs4/scope.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1
)
assert_contains "[CS4] the issue the change was for" "$(_against)" "$ISSUE"
cp "$P.check" "$P" 2>/dev/null || : > "$P"
assert_contains "[CS8] the knock-down check: the findings" "$(_against)" "the fallback reads any commenter"
assert_contains "[CS8] ...and the change" "$(_against)" "THE CHANGE"

print_test_section "CS5: build's step check"
rm -f "$P"
(
    AD="$TEST_TEMP_DIR/cs5/art"; mkdir -p "$AD"; _design_md "$TEST_TEMP_DIR/cs5/design.md"
    # shellcheck source=../../plugins/agent/design/plugin.sh
    ( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1; _design_write_steps "$TEST_TEMP_DIR/cs5/design.md" "$AD/design-steps.json" )
    R="$TEST_TEMP_DIR/cs5/repo"; _repo "$R"
    ( cd "$R" && printf 'body="$(by_actor)"\n' >> h.sh && git commit -qam step ) >/dev/null 2>&1
    export ZBUILD_REPO_ROOT="$R" ZBUILD_RUN_ID="cs5-$$" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    apply_scope_redaction() { cp "$1" "$2"; }
    _route_loop_close_final_banner() { return 0; }
    route_to_model_loop() {
        _ROUTE_LOOP_ITERATIONS=1; _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; _ROUTE_LOOP_INPUT_TOKENS=1; _ROUTE_LOOP_OUTPUT_TOKENS=1
        _ROUTE_LOOP_LAST_RESPONSE=$'step 1: done — QUOTE: h.sh | body="$(by_actor)"\nLOOP_COMPLETE'
    }
    route_to_model() { printf '%s' "$2" > "$P"; printf '1: does\n'; }
    _build_stage_run_inner "" "$AD/design-steps.json" "$AD/diff.patch" "$AD/build-summary.json" "$AD" >/dev/null 2>&1
)
assert_contains "[CS5] the SPEC the step serves" "$(_against)" "DSCLA-23: $SPEC_TEXT"
assert_contains "[CS5] ...with its parts" "$(_against)" "Then: $THEN"
assert_contains "[CS5] ...which the answer must not break" "$(_against)" "must not break any of these"

print_test_section "CS6: intake's requirements check"
rm -f "$P"
(
    # shellcheck source=../../plugins/agent/intake/plugin.sh
    source "$REPO_ROOT/plugins/agent/intake/plugin.sh" >/dev/null 2>&1
    route_to_model() {
        if [[ "$2" == *"check a list of requirements"* ]]; then printf '%s' "$2" > "$P"; printf 'MISSING: none\n'
        else printf "REQUIREMENT: RQCLA-1 the holder is read only from the actor's comments\n"; fi
    }
    _intake_write_requirements "$TEST_TEMP_DIR/cs6" "$(jq -nc --arg b "$ISSUE" '{title: "Holder", body: $b}')"
) >/dev/null 2>&1
assert_contains "[CS6] the issue it checks the list against" "$(_against)" "$ISSUE"

print_test_section "CS7: test-author's check of untagged lines"
rm -f "$P"
(
    d="$TEST_TEMP_DIR/cs7"; R="$d/repo"; A="$d/state/artifacts"; mkdir -p "$A"
    _repo "$R"; mkdir -p "$R/tests"; printf '{"schema_version":1}' > "$d/state/pipeline-state.json"
    _design_md "$A/design.md"
    # shellcheck source=../../plugins/agent/test-author/plugin.sh
    source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
    route_to_model_loop() {
        printf '#!/usr/bin/env bash\nprintf "  ✗ %%s it holds\\n" "[DSCLA-23]"\nassert_eq "pins the list" "a" "$(cat list.txt)"\nexit 1\n' > "$R/tests/h-test.sh"
        _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"; _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    }
    route_to_model() {
        if [[ "$2" == *"carry no requirement's tag"* ]]; then printf '%s' "$2" > "$P"; printf -- '- tests/h-test.sh line 3: not an assertion\n'; return 0; fi
        zb_test_check_ok "$2"
    }
    export ZBUILD_REPO_ROOT="$R" ZBUILD_EVENTS_JSONL="$d/events.jsonl"
    test_author_run test-author "$d/state/pipeline-state.json" >/dev/null 2>&1
)
assert_contains "[CS7] the SPECs it judges the lines against" "$(_against)" "DSCLA-23: $SPEC_TEXT"
assert_contains "[CS7] ...and the design's steps" "$(_against)" "filter by the actor before scanning"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
