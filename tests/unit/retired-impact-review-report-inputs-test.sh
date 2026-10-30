#!/usr/bin/env bash
# tests/unit/retired-impact-review-report-inputs-test.sh — what is no longer
# part of zBuild stays gone.
#
#   RT1 [change]: impact is retired — no plugin, no impact-only library, no
#                 renderer, no template entry (ADR-068 §1, amended 2026-10-12)
#   RT2 [change]: review-report is retired — review_lenses (#2368: the engine
#                 sums them up; review-aggregator is retired too)
#                 replaced it (ADR-040 §3)
#   RT3 [change]: a lens is a stage like any other: the review-lens stage writes
#                 one job for every lens and gives every lens the same evidence,
#                 and the lens's question is its persona's (ADR-051 §3); no lens
#                 text table, no per-lens evidence
#   RT4 [change]: declared inputs are retired — every stage gets every stage's
#                 latest output (ADR-068 §8): no manifest declares `inputs:`, no
#                 template wires `feedback:`, and a manifest that still declares
#                 inputs is refused at startup (ADR-055 §1, amended 2026-10-12)
#   RT5 [change]: Previous work does not list other stages' notes files; a
#                 stage's own notes still come back to it (ADR-067 §8)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "retired: impact, review-report, declared inputs, others' notes paths"
setup_test_env "retired-impact-review-report-inputs"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

_absent() { [[ -e "$REPO_ROOT/$1" ]] && echo present || echo absent; }
_code_refs() {
    /usr/bin/grep -rnE "$1" "$REPO_ROOT/core" "$REPO_ROOT/scripts" "$REPO_ROOT/plugins" "$REPO_ROOT/config" \
        --include='*.sh' --include='*.yaml' --include='*.json' 2>/dev/null \
        | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}

# ─── RT1 ─────────────────────────────────────────────────────────────────────
print_test_section "RT1: impact is retired"
assert_eq "[RT1] no impact plugin" "absent" "$(_absent plugins/agent/impact)"
assert_eq "[RT1] no impact-only library" "absent" "$(_absent scripts/lib/impact-prefilter.sh)"
assert_eq "[RT1] no code names impact's functions, renderer or feedback" "" \
    "$(_code_refs '_impact_|render_impact_md|impact-prefilter|prior_impact_feedback|"impact"')"
assert_eq "[RT1] no template names impact" "" \
    "$(/usr/bin/grep -nE '^[[:space:]]*-?[[:space:]]*impact[[:space:]]*$|^impact:' "$REPO_ROOT"/config/templates/*.yaml || true)"

# ─── RT2 ─────────────────────────────────────────────────────────────────────
print_test_section "RT2: review-report is retired"
assert_eq "[RT2] no review-report plugin" "absent" "$(_absent plugins/agent/review-report)"
assert_eq "[RT2] nothing calls it or binds its role" "" "$(_code_refs 'review_report_run|role: review_report|review-report/lib')"
assert_eq "[RT2] its call-graph evidence, which only it produced, is gone" "absent" "$(_absent scripts/lib/call-graph.sh)"
assert_eq "[RT2] review-aggregator is retired too (#2368)" "absent" "$(_absent plugins/agent/review-aggregator)"

# ─── RT3 ─────────────────────────────────────────────────────────────────────
print_test_section "RT3: a lens is a stage like any other"
# shellcheck source=../../plugins/agent/review-lens/lib/charters.sh
source "$REPO_ROOT/plugins/agent/review-lens/lib/charters.sh"
assert_eq "[RT3] no lens picks its own evidence by name" "" \
    "$(_code_refs '_review_lens_evidence_path|call-graph.json|coverage-map.json|reachability-ablation.json')"
assert_eq "[RT3] no lens text table" "absent" "$(declare -F _rl_lens_charter >/dev/null 2>&1 && echo present || echo absent)"
# red-team, not security: the shared severity scale says "a security hole" (#2433).
_p_sec="$(_rl_build_lens_prompt red-team "EVIDENCE" "CONTEXT" 2>/dev/null)"
_p_cor="$(_rl_build_lens_prompt correctness "EVIDENCE" "CONTEXT" 2>/dev/null)"
assert_eq "[RT3] the lens prompt was built" "1" "$([[ -n "$_p_sec" ]] && echo 1 || echo 0)"
assert_eq "[RT3] every lens gets the same job, but for its name" "${_p_sec//red-team/LENS}" "${_p_cor//correctness/LENS}"
_persp="$(awk '/^[[:space:]]+perspective:/ { sub(/^[[:space:]]+perspective:[[:space:]]*"?/, ""); print substr($0, 1, 40); exit }' \
    "$REPO_ROOT/plugins/persona/correctness/manifest.yaml")"
if grep -qF -- "$_persp" <<< "$_p_cor"; then
    assert_fail "[RT3] the lens's question is its persona's, not in the stage's text" "found: $_persp"
else
    assert_pass "[RT3] the lens's question is its persona's, not in the stage's text"
fi

# ─── RT4 ─────────────────────────────────────────────────────────────────────
print_test_section "RT4: declared inputs are retired"
assert_eq "[RT4] no manifest declares inputs:" "" \
    "$(/usr/bin/grep -lE '^inputs:' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"
assert_eq "[RT4] no template wires feedback:" "" \
    "$(/usr/bin/grep -nE '^[[:space:]]+feedback:' "$REPO_ROOT"/config/templates/*.yaml || true)"
assert_eq "[RT4] no check reads declared inputs" "" \
    "$(_code_refs 'INPUT_UNRESOLVED|INPUT_AMBIGUOUS|SELF_REF|CYCLE_FB_UNDECLARED|GATE_REFERENCE_UNPROVEN|GATE_REFERENCE_MUTABLE|manifest_graph_get_inputs')"
# A template that still wires feedback — block or inline form — is refused at load.
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
printf 'id: fb\nflow:\n  - c\nc:\n  type: cycle\n  flow: [x]\n  max_iterations: 1\n  feedback: []\n' > "$TEST_TEMP_DIR/fb-inline.yaml"
_fb_rc=0; load_template "$TEST_TEMP_DIR/fb-inline.yaml" >/dev/null 2>&1 || _fb_rc=$?
assert_eq "[RT4] an inline 'feedback: []' is refused at load" "1" "$([[ $_fb_rc -ne 0 ]] && echo 1 || echo 0)"
assert_contains "[RT4] …saying feedback is retired" "$(load_template "$TEST_TEMP_DIR/fb-inline.yaml" 2>&1)" "'feedback:' is retired"
# A third-party stage that still declares inputs is told, not silently ignored.
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
set +e   # runner.sh turns errexit on; a refusal here is the expected result
PROOT="$TEST_TEMP_DIR/plugins"; mkdir -p "$PROOT/agent/rt-stage"
cat > "$PROOT/agent/rt-stage/manifest.yaml" <<'EOF'
id: rt-stage
name: rt-stage
kind: agent
version: 0.1.0
hooks:
  run: x_run
provides:
  result_contract: 3
  role: rt_stage
inputs:
  - id: plan
outputs:
  - id: rt_stage_result
    path: ${artifact_dir}/rt-stage-result.json
    type: rt-stage-result.json@1
    format: json
    required: true
    primary: true
    summary: true
EOF
printf 'x_run() { return 0; }\n' > "$PROOT/agent/rt-stage/plugin.sh"
mkdir -p "$TEST_TEMP_DIR/cv"; _out="$(ZBUILD_CONTRACT_VALIDATOR=enforce _contract_validate_pipeline rt-stage "$PROOT" "$TEST_TEMP_DIR/cv/pipeline-state.json" 2>&1)"; _rc=$?
assert_eq "[RT4] a manifest declaring inputs: is refused" "1" "$([[ $_rc -ne 0 ]] && echo 1 || echo 0)"
assert_contains "[RT4] …saying inputs are retired" "$_out" "INPUTS_RETIRED"

# ─── RT5 ─────────────────────────────────────────────────────────────────────
print_test_section "RT5: no notes paths of other stages"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE/artifacts/notes"
printf '{"schema_version":1,"stage_statuses":{"other":"complete","me":"complete"},"stage_verdicts":{}}\n' > "$STATE/pipeline-state.json"
printf 'OTHER-NOTES\n' > "$(stage_notes_path "$STATE" other)"
printf 'MY-NOTES\n' > "$(stage_notes_path "$STATE" me)"
_pw="$(_stage_block_previous_work me "$STATE" "$PROOT" "" "$TEST_TEMP_DIR" 2>/dev/null)"
assert_not_contains_rt() { if grep -qF -- "$3" <<< "$2"; then assert_fail "$1" "found: $3"; else assert_pass "$1"; fi; }
assert_not_contains_rt "[RT5] another stage's notes path is not listed" "$_pw" "$(stage_notes_path "$STATE" other)"
assert_contains "[RT5] the stage's own notes come back to it" "$_pw" "MY-NOTES"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
