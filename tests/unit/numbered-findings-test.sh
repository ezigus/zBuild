#!/usr/bin/env bash
# tests/unit/numbered-findings-test.sh — each check lists its findings as
# numbered items, and later stages see each one with who opened it (#2271).
#
# Why: every stage will answer every finding it receives (`done` / `nothing to
# do`), and only the stage that opened a finding can close it (`satisfied`).
# That needs findings to be separate items with a stable reference. Today a
# check's findings reach later stages as one block of text, so one acceptance-
# gate report holding a design-owned problem and a test-author-owned one could
# only be answered as a whole. Identity comes from where the finding already
# lives (Eric, 2026-10-04): the stage's result, item n — "acceptance-gate
# finding 2".
#
# N1 [change] stage_findings_json turns one finding per line into
#             [{n, text}], skipping blank lines
# N2 [change] a check's result carries its findings as numbered items, in the
#             same plain sentences its feedback uses (design-gate)
# N3 [change] later stages see each finding on its own line, naming the stage
#             that opened it: "- design-gate finding 1 (opened by design-gate): …"
# N4 [guard]  a check with nothing to report lists no findings
# N5 [change] every check in the default design and build loops writes its
#             findings through stage_findings_json
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "each check lists its findings as numbered items (#2271)"
setup_test_env "numbered-findings"
export ZBUILD_EVENTS_DB="/dev/null"
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"

print_test_section "N1: the helper"
_j="$(printf 'first problem\n\n  \nsecond problem\n' | stage_findings_json 2>/dev/null)"
assert_eq "[N1] two findings, numbered from 1" \
    '[{"n":1,"text":"first problem"},{"n":2,"text":"second problem"}]' "$(jq -c . <<< "$_j" 2>/dev/null)"
assert_eq "[N1] no input → an empty list" "[]" "$(printf '' | stage_findings_json 2>/dev/null | jq -c . 2>/dev/null)"

print_test_section "N2/N4: design-gate's result"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
# shellcheck source=../../plugins/tool/design-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"
ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ROOT/tests" "$ROOT/lib"; : > "$ROOT/lib/a.sh"; export ZBUILD_REPO_ROOT="$ROOT"
_dg() {   # _dg <dir> <design.md>
    mkdir -p "$1/artifacts"; printf '%s' "$2" > "$1/artifacts/design.md"
    printf '{"schema_version":1}' > "$1/pipeline-state.json"
    design_gate_run "design-gate" "$1/pipeline-state.json" >/dev/null 2>&1 || true
}
D1="$TEST_TEMP_DIR/dg1"
_dg "$D1" $'# Design\n\n```scope\nlib/a.sh\n```\n\n```acceptance\nSPEC-1[code]: a\nSPEC-2: b\nTESTFILES:\n```\n'
_f="$(jq -c '.data.findings // empty' "$D1/artifacts/design-gate-result.json" 2>/dev/null)"
assert_eq "[N2] the findings are numbered from 1" "1" "$(jq -r '.[0].n // empty' <<< "$_f" 2>/dev/null)"
assert_contains "[N2] a finding is the plain sentence" "$(jq -r '.[].text' <<< "$_f" 2>/dev/null)" "SPEC-2 has no status"
if grep -qE 'NO_STATUS|MISSING_TESTFILE' <<< "$_f"; then
    assert_fail "[N2] a finding never carries the internal code" "$_f"
else
    assert_pass "[N2] a finding never carries the internal code"
fi
D2="$TEST_TEMP_DIR/dg2"
_dg "$D2" $'# Design\n\n```scope\nlib/a.sh\n```\n\n```acceptance\nSPEC-1[code]: a\nWIRING: none\nTESTFILES:\nSPEC-1: tests/a-test.sh\n```\n'
assert_eq "[N4] a passing check lists no findings" "0" \
    "$(jq -r '(.data.findings // []) | length' "$D2/artifacts/design-gate-result.json" 2>/dev/null)"

print_test_section "N3: later stages see each finding and who opened it"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh" >/dev/null 2>&1 || true
S="$TEST_TEMP_DIR/state"; PR="$TEST_TEMP_DIR/plugins"; mkdir -p "$S/artifacts" "$PR/tool/chk"
cat > "$PR/tool/chk/manifest.yaml" <<'MF'
id: chk
kind: tool
provides:
  role: chk
  result_contract: 2
outputs:
  - id: chk-result
    path: ${artifact_dir}/chk-result.json
    format: json
    required: true
    primary: true
  - id: chk-summary
    path: ${artifact_dir}/chk-summary.md
    format: markdown
    required: false
    summary: true
MF
jq -n '{result_contract:2, verdict:"fail", disposition:"complete", reason:"two problems",
        data:{findings:[{n:1,text:"config/event-schema.json is not the file that calls the new code"},
                        {n:2,text:"SPEC-3s test already passes on the old code"}]}}' > "$S/artifacts/chk-result.json"
printf '## chk — fail\n\n- two problems\n' > "$S/artifacts/chk-summary.md"
printf '{"stage_statuses":{"chk":"failed"},"stage_verdicts":{"chk":"fail"}}\n' > "$S/pipeline-state.json"
_blk="$( _TPL_STAGES=(chk); export ZBUILD_CURRENT_STAGE=later
         stage_summaries_prompt_block "$S/pipeline-state.json" "$PR" 2>/dev/null )"
assert_contains "[N3] finding 1 is listed with who opened it" "$_blk" \
    "- chk finding 1 (opened by chk): config/event-schema.json is not the file that calls the new code"
assert_contains "[N3] finding 2 is listed on its own line" "$_blk" \
    "- chk finding 2 (opened by chk): SPEC-3s test already passes on the old code"

print_test_section "N5: every check writes numbered findings"
_missing=""
for _p in plugins/agent/spec-coverage plugins/tool/design-gate plugins/agent/spec-correspondence \
          plugins/tool/test plugins/tool/shape-floor plugins/agent/spec-acceptance \
          plugins/tool/secret-scan plugins/tool/assertion-integrity plugins/agent/issue-acceptance; do
    _hit=0
    for _f in "$REPO_ROOT/$_p"/*.sh "$REPO_ROOT/$_p"/lib/*.sh; do
        [[ -f "$_f" ]] && grep -q 'stage_findings_json' "$_f" && { _hit=1; break; }
    done
    [[ $_hit -eq 1 ]] || _missing+="$_p "
done
assert_eq "[N5] every check uses stage_findings_json" "" "$_missing"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
