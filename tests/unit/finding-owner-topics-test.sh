#!/usr/bin/env bash
# tests/unit/finding-owner-topics-test.sh — every stage result says where its
# findings may go, and the test stage sends a failing test to whoever owns it
# (#2454, ADR-071 §1 §2).
#
# Why: on #1805 (run 41452299475) test-author was handed 27 problems — 12
# failing test files, 7 of them tests it did not write, and 9 shape-check
# findings about other tests — and spent its whole call sorting them. #2452
# let a finding carry its own topic, but only two stages used it, and nothing
# made a stage decide.
#
#   O1 [change]: acceptance_list_testfiles prints each test file once (#2508:
#                the files holding a SPEC's tag, sorted)
#   O2 [change]: validate_manifest refuses a stage result with no
#                finding_topics:, or with a word outside the five; accepts
#                `none` and a list of topics
#   O3 [change]: every shipped stage result declares finding_topics:
#   O4 [change]: Previous work honours a finding's own topic only when its
#                output lists it; otherwise the output's topic decides
#   O5 [change]: _test_findings_by_owner labels a file that is not one of the
#                design's test files `change-findings`, and leaves the design's own
#                test files (#2508: test-folder files holding its tags) unlabelled
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
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
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "every stage result says where its findings may go (#2454)"
setup_test_env "finding-owner-topics"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT 2>/dev/null || true

DESIGN="$TEST_TEMP_DIR/design.md"
printf '%s\n' '# Design' '```acceptance' 'SPEC-1[code]: a' 'SPEC-2[code]: b' 'SPEC-3[code]: c' \
    'WIRING: none' '```' > "$DESIGN"
# #2508: the design's test files are those in the test folders holding its tags.
TREPO="$TEST_TEMP_DIR/repo"; mkdir -p "$TREPO/tests"; git -C "$TREPO" init -q
printf 'assert "%s" ; assert "%s" ; assert "%s"\n' "$(acceptance_spec_tag SPEC-1)" "$(acceptance_spec_tag SPEC-2)" \
    "$(acceptance_spec_tag SPEC-3)" > "$TREPO/tests/a-test.sh"
printf 'assert "%s"\n' "$(acceptance_spec_tag SPEC-2)" > "$TREPO/tests/b-test.sh"
printf 'assert "unrelated"\n' > "$TREPO/tests/other-test.sh"
export ZBUILD_REPO_ROOT="$TREPO"

# ── O1 ───────────────────────────────────────────────────────────────────────
print_test_section "O1: each test file once"
assert_eq "[O1] each test file is listed once, sorted" \
    $'tests/a-test.sh\ntests/b-test.sh' "$(acceptance_list_testfiles "$DESIGN")"

# ── O2 ───────────────────────────────────────────────────────────────────────
print_test_section "O2: validate_manifest and finding_topics"
_mf() {  # <name> <finding_topics line or ""> → manifest path
    local d="$TEST_TEMP_DIR/mf/$1"; mkdir -p "$d"
    {
        printf 'id: %s\nname: Fixture\nkind: tool\nversion: 0.0.1\nsummary: fixture\nhooks:\n  run: f_run\n' "$1"
        printf 'provides:\n  result_contract: 3\noutputs:\n'
        printf '  - id: r\n    path: "${artifact_dir}/%s-result.json"\n    type: json\n    required: true\n    primary: true\n' "$1"
        printf '    topic: code-findings\n    description: "the fixture result"\n'
        [[ -n "$2" ]] && printf '    %s\n' "$2"
    } > "$d/manifest.yaml"
    printf '%s' "$d/manifest.yaml"
}
_valid() { validate_manifest "$1" >/dev/null 2>&1 && echo ok || echo refused; }
assert_eq "[O2] a stage result with no finding_topics is refused" "refused" "$(_valid "$(_mf missing "")")"
assert_eq "[O2] finding_topics: none is accepted" "ok" "$(_valid "$(_mf none 'finding_topics: none')")"
assert_eq "[O2] a list of topics is accepted" "ok" "$(_valid "$(_mf list 'finding_topics: code-findings change')")"
assert_eq "[O2] a word outside the five is refused" "refused" "$(_valid "$(_mf odd 'finding_topics: code-findings everyone')")"
assert_contains "[O2] ...naming the word" "$(validate_manifest "$(_mf odd2 'finding_topics: everyone')" 2>&1)" "everyone"
_o2two="$(validate_manifest "$(_mf odd3 'finding_topics: bad1 bad2')" 2>&1)"
assert_contains "[O2] ...each wrong word is named (the first)" "$_o2two" "bad1"
assert_contains "[O2] ...each wrong word is named (the second)" "$_o2two" "bad2"

# ── O3 ───────────────────────────────────────────────────────────────────────
print_test_section "O3: every shipped stage result declares it"
_missing=""
for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    _miss="$(awk '
        function flush() { if (inb && id != "" && (prim || path ~ /-result\.json/) && !ft) print id; id = ""; path = ""; prim = 0; ft = 0 }
        /^outputs:[[:space:]]*$/ { inb = 1; next }
        inb && /^[a-zA-Z_]/ { flush(); inb = 0 }
        inb && /^[[:space:]]*-[[:space:]]+id:/ { flush(); id = $3 }
        inb && /^[[:space:]]+path:/ { path = $2 }
        inb && /^[[:space:]]+primary:[[:space:]]*true/ { prim = 1 }
        inb && /^[[:space:]]+finding_topics:/ { ft = 1 }
        END { flush() }' "$_m")"
    [[ -n "$_miss" ]] && _missing+="${_m#"$REPO_ROOT/"}: $_miss "
done
assert_eq "[O3] no shipped stage result lacks finding_topics" "" "$_missing"
_ia="$REPO_ROOT/plugins/agent/issue-acceptance/manifest.yaml"
assert_contains "[O3] issue-acceptance may send findings to code-findings" "$(grep 'finding_topics:' "$_ia")" "code-findings"
_tm="$REPO_ROOT/plugins/tool/test/manifest.yaml"
assert_contains "[O3] test's result may send findings to change" "$(awk '/id: test_results/,/finding_topics/' "$_tm" | grep finding_topics)" "change"

# ── O4 ───────────────────────────────────────────────────────────────────────
print_test_section "O4: a finding's own topic counts only when its output lists it"
PROOT="$TEST_TEMP_DIR/plugins"; STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"
mkdir -p "$ART" "$PROOT/tool/fo-check" "$PROOT/agent/fo-design"
init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
cat > "$PROOT/tool/fo-check/manifest.yaml" <<'EOF'
id: fo-check
name: fo-check
kind: tool
version: 0.0.1
hooks:
  run: x_run
outputs:
  - id: fo_check_result
    path: ${artifact_dir}/fo-check-result.json
    type: json
    required: true
    primary: true
    topic: requirement-findings
    finding_topics: code-findings
EOF
printf 'x_run() { return 0; }\n' > "$PROOT/tool/fo-check/plugin.sh"
stage_result_write "$ART/fo-check-result.json" fail fixture \
    '{"findings":[{"n":1,"text":"LISTED-CODE","topic":"code-findings"},{"n":2,"text":"UNLISTED-CHANGE","topic":"change"}]}'
_update_stage_status "$STATE/pipeline-state.json" fo-check complete
cat > "$PROOT/agent/fo-design/manifest.yaml" <<'EOF'
id: fo-design
name: fo-design
kind: agent
version: 0.0.1
takes:
  - topic: ask
    for: x
  - topic: requirement-findings
    for: x
hooks:
  run: x_run
outputs:
  - id: fo_design_result
    path: ${artifact_dir}/fo-design-result.json
    type: json
    required: true
    primary: true
    topic: ask
    finding_topics: none
EOF
printf 'x_run() { return 0; }\n' > "$PROOT/agent/fo-design/plugin.sh"
_TPL_STAGES=(fo-check fo-design)
_idx="$(_inputs_resolve_stage fo-design "$PROOT" "$STATE")"
_pw="$(_stage_block_previous_work fo-design "$STATE" "$PROOT" "$_idx" "" "$PROOT/agent/fo-design/manifest.yaml")"
assert_not_contains "[O4] a finding with a listed topic goes by it (design does not take code-findings)" "$_pw" "LISTED-CODE"
assert_contains "[O4] a finding with an unlisted topic goes by its output's" "$_pw" "UNLISTED-CHANGE"

# ── O5 ───────────────────────────────────────────────────────────────────────
print_test_section "O5: the test stage labels by whose test it is"
# shellcheck source=../../plugins/tool/test/lib/findings.sh
source "$REPO_ROOT/plugins/tool/test/lib/findings.sh"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"
_o5="$(printf 'tests/a-test.sh\tA-FAILS\ntests/other-test.sh\tOTHER-FAILS\n' \
        | _test_findings_by_owner "$DESIGN" | stage_findings_json)"
assert_eq "[O5] the design's own test file keeps the output's topic" "null" \
    "$(jq -r '.[] | select(.text == "A-FAILS") | .topic' <<< "$_o5")"
assert_eq "[O5] any other test file is change-findings" "change-findings" \
    "$(jq -r '.[] | select(.text == "OTHER-FAILS") | .topic' <<< "$_o5")"
_o5b="$(printf 'tests/other-test.sh\tNO-DESIGN\n' | _test_findings_by_owner "" | stage_findings_json)"
assert_eq "[O5] with no design, every file is change-findings" "change-findings" "$(jq -r '.[0].topic' <<< "$_o5b")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
