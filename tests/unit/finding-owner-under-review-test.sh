#!/usr/bin/env bash
# tests/unit/finding-owner-under-review-test.sh — a judge's finding is owned by
# the stage that authored what it judged, even when that author never writes
# the repository.
#
# Why: #1847 run 20260928070345-90197. spec-coverage said three times that the
# design kept hardcoded artifact paths the issue says to delete. design was
# shown each finding as "context only: your job is to read and report, not to
# fix this" (resolve=0 on every call), because the rule for "may fix" was
# "declares capabilities.writes_repository" — and design writes design.md, not
# the repository. It argued with the finding instead of acting on it.
#
# The judge DECLARES which input it judges (`under_review: true`); the engine
# resolves that input's producer as the finding's owner. No stage names.
#
# U1 [change] the author of the judged input is told the findings are its to fix
# U2 [guard]  another non-writer reading the same finding is told whose it is
# U3 [change] the RESOLVE count follows: 1 for the author, 0 for anyone else
# U4 [guard]  an explicit `about` in the judge's result still wins
# U5 [guard]  an input NOT marked under_review makes no owner — nothing guessed
# U6 [change] a non-writer holding a finding it owns is not told "do not fix anything"
# U7 [change] the router's scope line for a non-writer is true for an author too:
#             no repository changes, write only the named outputs — not "read and report"
# U8 [change] every real judge whose judged input has ONE author marks it, and it
#             resolves: spec-coverage and design-gate → design; validate →
#             deploy_result, whose producer depends on the flow (deploy or
#             deploy-release both declare it), so it resolves within a flow and
#             to nobody without one
# U9 [guard]  every `under_review` input in the tree names an output some plugin
#             produces — a typo would silently make no owner
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "a judge's finding belongs to the author of what it judged"
setup_test_env "finding-owner-under-review"
unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART"

# _mf <id> <inputs-yaml> <extra-outputs-yaml>
_mf() {
    local id="$1" d="$PROOT/agent/$1"
    mkdir -p "$d"
    {
        printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\nhooks:\n  run: run_it\n' "$id" "$id"
        if [[ -n "$2" ]]; then printf 'inputs:\n%s\n' "$2"; else printf 'inputs: []\n'; fi
        printf 'outputs:\n  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n    type: json\n    required: true\n    primary: true\n' "${id//-/_}" "$id"
        printf '  - id: %s_summary\n    path: ${artifact_dir}/%s-summary.md\n    type: text\n    format: text\n    required: false\n    summary: true\n' "${id//-/_}" "$id"
        [[ -n "$3" ]] && printf '%s\n' "$3"
    } > "$d/manifest.yaml"
    printf 'run_it() { return 0; }\n' > "$d/plugin.sh"
    printf '%s-SUMMARY-BODY\n' "$id" > "$ART/$id-summary.md"
}
_result() { printf '%s\n' "$2" > "$ART/$1-result.json"; }

# ur-author writes an artifact (ur-doc.md), never the repository.
_mf ur-author "" '  - id: ur_doc
    path: ${artifact_dir}/ur-doc.md
    type: text
    required: true'
# ur-other: another non-writer that owns a different artifact.
_mf ur-other "" '  - id: ur_notes
    path: ${artifact_dir}/ur-notes.md
    type: text
    required: true'
# ur-judge judges ur_doc and says so.
_mf ur-judge '  - id: ur_doc
    required: true
    under_review: true' ""
_result ur-author '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"x"}'
_result ur-other  '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"x"}'
_result ur-judge  '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"uncovered"}'
printf 'doc\n' > "$ART/ur-doc.md"; printf 'notes\n' > "$ART/ur-notes.md"

cat > "$STATE/pipeline-state.json" <<'EOF'
{"schema_version":1,"run_id":"ur","stage_statuses":{"ur-author":"complete","ur-other":"complete","ur-judge":"failed"},
 "stage_verdicts":{"ur-author":"pass","ur-other":"pass","ur-judge":"fail"}}
EOF
SF="$STATE/pipeline-state.json"

_block() { ZBUILD_CURRENT_STAGE="$1" ZBUILD_PLUGIN_DIR="$PROOT/agent/$1" stage_summaries_prompt_block "$SF" "$PROOT" 2>/dev/null || true; }
_count() { ZBUILD_CURRENT_STAGE="$1" ZBUILD_PLUGIN_DIR="$PROOT/agent/$1" stage_summaries_count "$SF" "$PROOT" 2>/dev/null | cut -d' ' -f2; }

print_test_section "U1–U3: the judged input's author owns the finding"
_author="$(_block ur-author)"
assert_contains "[U1] the author is told the judge's findings are its to fix" \
    "$_author" "### ur-judge (verdict: fail) — about work you authored: these findings are yours to fix"
_other="$(_block ur-other)"
assert_contains "[U2] another non-writer is told whose they are" \
    "$_other" "### ur-judge (verdict: fail) — context only: about work owned by ur-author, not yours to fix"
assert_eq "[U3] the author has one finding to resolve" "1" "$(_count ur-author)"
assert_eq "[U3] nobody else does" "0" "$(_count ur-other)"

print_test_section "U6: the block's header does not contradict an owned finding"
if grep -qF "do not fix anything" <<< "$_author"; then
    assert_fail "[U6] an author holding its own finding is not told to fix nothing" \
        "$(grep -F 'do not fix anything' <<< "$_author")"
else
    assert_pass "[U6] an author holding its own finding is not told to fix nothing"
fi
assert_contains "[U6] a reader with nothing of its own is still told to read and report" \
    "$_other" "do not fix anything"

print_test_section "U4: an explicit about still wins"
_result ur-judge '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"x","about":"'"$ART"'/ur-notes.md"}'
assert_contains "[U4] about names ur-other's artifact → ur-other owns it" \
    "$(_block ur-other)" "### ur-judge (verdict: fail) — about work you authored"
assert_contains "[U4] ...and the under_review author is told it is not its" \
    "$(_block ur-author)" "context only: about work owned by ur-other"
_result ur-judge '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"uncovered"}'

print_test_section "U5: no declaration, no owner"
_mf ur-judge '  - id: ur_doc
    required: true' ""
_result ur-judge '{"result_contract":2,"verdict":"fail","disposition":"complete","reason":"uncovered"}'
_author5="$(_block ur-author)"
if grep -qF "about work you authored" <<< "$_author5"; then
    assert_fail "[U5] an undeclared input makes no owner" "the author was handed the finding"
else
    assert_contains "[U5] an undeclared input makes no owner" "$_author5" "### ur-judge (verdict: fail) — context only"
fi

print_test_section "U7: the router's scope line"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true
if declare -F _route_redact_prompt >/dev/null 2>&1; then
    IN="$TEST_TEMP_DIR/p.in"; OUT="$TEST_TEMP_DIR/p.out"
    printf 'Author the design.\n' > "$IN"
    ZBUILD_PLUGIN_DIR="$PROOT/agent/ur-author" ZBUILD_SCOPE_MANIFEST="" _route_redact_prompt "$IN" "$OUT" 0 "" >/dev/null 2>&1 || true
    _o="$(cat "$OUT" 2>/dev/null || true)"
    if grep -qF "Your job is to read and report" <<< "$_o"; then
        assert_fail "[U7] a non-writer is not told its whole job is to read and report" \
            "$(grep -F 'Your job is to read and report' <<< "$_o")"
    else
        assert_pass "[U7] a non-writer is not told its whole job is to read and report"
    fi
    assert_contains "[U7] it is still told to change nothing in the repository" "$_o" \
        "Do not create, modify or delete any file in the repository"
    assert_contains "[U7] ...and to write only its named outputs" "$_o" \
        "Write only the outputs your instructions below name."
else
    assert_fail "[U7] _route_redact_prompt is available" "not defined after sourcing route.sh"
fi

print_test_section "U8: the real judges"
for _j in spec-coverage design-gate; do
    assert_eq "[U8] $_j's finding is owned by design" "design" \
        "$(_summaries_under_review_owner "$_j" "$REPO_ROOT/plugins" 2>/dev/null || true)"
done
assert_eq "[U8] validate's finding, in a flow with deploy, is owned by deploy" "deploy" \
    "$(ZBUILD_INPUTS_FLOW="deploy validate" _summaries_under_review_owner validate "$REPO_ROOT/plugins" 2>/dev/null || true)"
assert_eq "[U8] ...in a flow with deploy-release, by deploy-release" "deploy-release" \
    "$(ZBUILD_INPUTS_FLOW="deploy-release validate" _summaries_under_review_owner validate "$REPO_ROOT/plugins" 2>/dev/null || true)"
assert_eq "[U8] ...and with no flow, two candidate producers make no owner" "" \
    "$(ZBUILD_INPUTS_FLOW="" _summaries_under_review_owner validate "$REPO_ROOT/plugins" 2>/dev/null || true)"

print_test_section "U9: every declaration resolves"
_declared=0
while IFS= read -r _m; do
    while IFS= read -r _in; do
        [[ -n "$_in" ]] || continue
        _declared=$((_declared + 1))
        if awk -v id="$_in" '/^outputs:/{o=1;next} /^[a-z]/{o=0} o && $0 ~ ("^[[:space:]]+-[[:space:]]+id:[[:space:]]*" id "[[:space:]]*$") {f=1} END{exit !f}' \
                "$REPO_ROOT"/plugins/*/*/manifest.yaml; then
            assert_pass "[U9] ${_m#"$REPO_ROOT"/}: under_review input '$_in' has a producer"
        else
            assert_fail "[U9] ${_m#"$REPO_ROOT"/}: under_review input '$_in' has a producer" "no manifest outputs '$_in'"
        fi
    done <<< "$(_summaries_under_review_inputs "$_m" 2>/dev/null || true)"
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -not -path '*/tests/*')
if [[ "$_declared" -ge 3 ]]; then
    assert_pass "[U9] the scan saw the declarations ($_declared)"
else
    assert_fail "[U9] the scan saw the declarations" "found $_declared (expected ≥3) — the guard is vacuous"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
