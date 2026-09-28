#!/usr/bin/env bash
# tests/unit/review-report-v2-contract-test.sh
# review-report speaks stage contract v2 (#1843; ADR-054 §4/§5/§6/§9, ADR-063 §1/§3,
# ADR-055 §1 name-matched inputs, ADR-028 v1.2 shared reply parser per #2035).
#
# Separate from tests/unit/review-report-plugin-test.sh on purpose: that file's
# [SPEC-n] tags are #972's, and the acceptance gate measures negative controls
# by tag, so a second SPEC-3 in the same file is indistinguishable from the
# first. The pipeline's three CI runs of #1843 died on exactly that collision.
#
# SPEC-1[change]:  manifest — provides.result_contract: 2, config.router.{timeout_s,max_turns},
#                  valid_verdicts covers every verdict the plugin emits, review_report is primary
# SPEC-2[change]:  the PRIMARY (review-report.json) carries result_contract:2 + verdict/disposition/
#                  reason/data on a normal run; merge_readiness/findings/lenses stay top-level
# SPEC-3[change]:  missing state_file → rc=1 (was 2) and an error/broken v2 result at $ZBUILD_ARTIFACT_DIR
# SPEC-4[change]:  missing out_json → rc=1 (was 2) and an error/broken v2 result
# SPEC-5[change]:  a lens subshell that fails → disposition=complete (#2187), verdict stays pass, rc=0
# SPEC-6[guard]:   the contract verdict is never coerced by findings — needs_attention still verdict=pass
# SPEC-7[change]:  every lens prompt carries a TURN BUDGET block sourced from _route_resolve_max_turns
#                  and _route_resolve_timeout (env override → the block says so; never a literal)
# SPEC-8[change]:  a reply whose envelope is followed by a brace-bearing sign-off is recovered, not
#                  lost; a genuinely unparseable reply still emits review_report.lens.unparseable
# SPEC-9[change]:  scope_manifest comes from the ZBUILD_STAGE_INPUTS index; plugin.sh builds no
#                  '$state_dir/scope-manifest.md' path
# SPEC-10[change]: rc ∈ {0,1} — plugin.sh contains no `return 2`
# SPEC-11[change]: ONE result file — no review-report-result.json sidecar declared or written
# SPEC-12[change]: resolve_tier failure is a terminal path too: rc=1 with an error/broken result
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review-report — stage contract v2 (#1843)"
setup_test_env "review-report-v2"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"
# The build_test_cycle exports this while the gate runs (cycle-orchestrator.sh
# ~:1755) and it outranks ZBUILD_ROUTER_MAX_TURNS in _route_resolve_max_turns;
# SPEC-7 sets the knobs it means to test, so neither may leak in from a parent.
unset ZBUILD_ROUTER_MAX_TURNS_OVERRIDE ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_TIMEOUT ZBUILD_CURRENT_STAGE

PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-report"
MANIFEST="$PLUGIN_DIR/manifest.yaml"
# shellcheck source=../../plugins/agent/review-report/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ── stubs ────────────────────────────────────────────────────────────────────
# _RR_REPLY_MODE selects the canned reply shape; _RR_FAIL_LENS makes one lens's
# call return non-zero. Both are exported because each lens runs in a subshell.
export _RR_REPLY_MODE="normal" _RR_FAIL_LENS=""
export _RR_PROMPTS="$TEST_TEMP_DIR/prompts"; mkdir -p "$_RR_PROMPTS"
route_to_model() {
    local prompt="$2" lens="other"
    [[ "$prompt" =~ \"([a-z-]+)\"\ review\ lens ]] && lens="${BASH_REMATCH[1]}"
    printf '%s' "$prompt" > "$_RR_PROMPTS/$lens.txt"
    if [[ -n "$_RR_FAIL_LENS" && "$lens" == "$_RR_FAIL_LENS" ]]; then return 1; fi
    case "$_RR_REPLY_MODE" in
        normal)
            if [[ "$lens" == "security" ]]; then
                printf '%s' '{"score":2,"findings":[{"file":"core/y.sh","category":"injection","severity":"critical","line":10,"message":"shell injection risk"}]}'
            else
                printf '%s' '{"score":9,"findings":[]}'
            fi ;;
        signoff)
            # The real envelope, then a brace-bearing sign-off: LAST-wins alone picks the sign-off.
            printf '%s\n\nDone reviewing. Summary: {"note":"no further issues"}\n' \
                '{"score":4,"findings":[{"file":"core/z.sh","category":"logic","severity":"high","line":7,"message":"recovered finding"}]}' ;;
        garbage)
            printf 'I could not review this change.\n' ;;
    esac
    return 0
}
# shellcheck disable=SC2329  # invoked indirectly by the sourced plugin's fan-out
apply_scope_redaction() { cp "$1" "$2"; return 0; }
export -f route_to_model apply_scope_redaction 2>/dev/null || true

_fixture() {  # _fixture <dir> → writes a diff and echoes nothing
    mkdir -p "$1"
    printf 'diff --git a/core/y.sh b/core/y.sh\n+ exec user input at line 10\n' > "$1/diff.patch"
}
_v2() { jq -r --arg k "$1" '.[$k] // empty' "$2" 2>/dev/null; }

# ── SPEC-1: manifest declarations ────────────────────────────────────────────
assert_contains_regex "[SPEC-1] provides.result_contract: 2" "$(cat "$MANIFEST")" '^  result_contract: 2$'
assert_contains_regex "[SPEC-1] config.router.timeout_s declared" "$(cat "$MANIFEST")" '^    timeout_s: [0-9]+$'
assert_contains_regex "[SPEC-1] config.router.max_turns declared" "$(cat "$MANIFEST")" '^    max_turns: [0-9]+$'
_vv="$(sed -n 's/^  valid_verdicts: *//p' "$MANIFEST" | head -1)"
assert_contains "[SPEC-1] valid_verdicts declares pass"  "$_vv" "pass"
assert_contains "[SPEC-1] valid_verdicts declares error" "$_vv" "error"
_prim="$(awk '/^  - id: review_report$/{f=1; next} f && /primary: true/{print "yes"; exit} f && /^  - id:/{exit}' "$MANIFEST")"
assert_eq "[SPEC-1] review_report output is primary: true" "yes" "$_prim"

# ── SPEC-2: normal run — the primary IS the v2 result ────────────────────────
_d2="$TEST_TEMP_DIR/s2"; _fixture "$_d2"
_RR_REPLY_MODE=normal _rr_run_inner "$_d2/scope.md" "$_d2/diff.patch" "$_d2/review-report.json" "$_d2/review-report.md"; _rc=$?
assert_eq "[SPEC-2] normal run rc=0" "0" "$_rc"
assert_eq "[SPEC-2] primary result_contract is 2" "2" "$(_v2 result_contract "$_d2/review-report.json")"
assert_eq "[SPEC-2] primary verdict=pass" "pass" "$(_v2 verdict "$_d2/review-report.json")"
assert_eq "[SPEC-2] primary disposition=complete" "complete" "$(_v2 disposition "$_d2/review-report.json")"
assert_contains_regex "[SPEC-2] primary reason is non-empty text" "$(_v2 reason "$_d2/review-report.json")" '[a-z]'
assert_eq "[SPEC-2] primary carries a data object" "object" "$(jq -r '.data | type' "$_d2/review-report.json" 2>/dev/null)"
assert_eq "[SPEC-2] merge_readiness still top-level (pr-open reads it)" "needs_attention" "$(_v2 merge_readiness "$_d2/review-report.json")"
assert_eq "[SPEC-2] lenses still top-level" "11" "$(jq '.lenses | length' "$_d2/review-report.json" 2>/dev/null)"
assert_eq "[SPEC-2] findings still top-level" "1" "$(jq '.findings | length' "$_d2/review-report.json" 2>/dev/null)"

# ── SPEC-6[guard]: advisory — findings never move the contract verdict ───────
assert_eq "[SPEC-6] needs_attention report still verdict=pass (no coercion)" "pass" "$(_v2 verdict "$_d2/review-report.json")"

# ── SPEC-3: missing state_file ───────────────────────────────────────────────
_d3="$TEST_TEMP_DIR/s3"; mkdir -p "$_d3"
ZBUILD_ARTIFACT_DIR="$_d3" review_report_run "review" "" 2>/dev/null; _rc=$?
assert_eq "[SPEC-3] missing state_file → rc=1 (ADR-054 §4: rc ∈ {0,1})" "1" "$_rc"
assert_eq "[SPEC-3] missing state_file → result_contract 2 at \$ZBUILD_ARTIFACT_DIR" "2" "$(_v2 result_contract "$_d3/review-report.json")"
assert_eq "[SPEC-3] missing state_file → verdict=error" "error" "$(_v2 verdict "$_d3/review-report.json")"
assert_eq "[SPEC-3] missing state_file → disposition=broken" "broken" "$(_v2 disposition "$_d3/review-report.json")"
assert_file_exists "[SPEC-3] missing state_file → summary written (ADR-055 §9)" "$_d3/review-report-summary.md"

# ── SPEC-4: missing out_json ─────────────────────────────────────────────────
_d4="$TEST_TEMP_DIR/s4"; _fixture "$_d4"
ZBUILD_ARTIFACT_DIR="$_d4" _rr_run_inner "$_d4/scope.md" "$_d4/diff.patch" "" "$_d4/x.md" 2>/dev/null; _rc=$?
assert_eq "[SPEC-4] missing out_json → rc=1" "1" "$_rc"
assert_eq "[SPEC-4] missing out_json → verdict=error" "error" "$(_v2 verdict "$_d4/review-report.json")"
assert_eq "[SPEC-4] missing out_json → disposition=broken" "broken" "$(_v2 disposition "$_d4/review-report.json")"

# ── SPEC-5: a failed lens → exhausted (ADR-063 §3), still advisory ───────────
_d5="$TEST_TEMP_DIR/s5"; _fixture "$_d5"
_RR_FAIL_LENS=performance _rr_run_inner "$_d5/scope.md" "$_d5/diff.patch" "$_d5/review-report.json" "$_d5/review-report.md" 2>/dev/null; _rc=$?
assert_eq "[SPEC-5] failed lens → rc=0 (advisory never aborts)" "0" "$_rc"
assert_eq "[SPEC-5] failed lens → disposition=complete, the report covers the lenses that ran (#2187)" "complete" "$(_v2 disposition "$_d5/review-report.json")"
assert_eq "[SPEC-5] failed lens → verdict stays pass" "pass" "$(_v2 verdict "$_d5/review-report.json")"
assert_contains "[SPEC-5] reason names the lens that failed" "$(_v2 reason "$_d5/review-report.json")" "performance"

# ── SPEC-7: budget block from the resolvers, never a literal ─────────────────
_d7="$TEST_TEMP_DIR/s7"; _fixture "$_d7"
ZBUILD_ROUTER_MAX_TURNS=77 ZBUILD_ROUTER_TIMEOUT=123 \
    _rr_run_inner "$_d7/scope.md" "$_d7/diff.patch" "$_d7/review-report.json" "$_d7/review-report.md" 2>/dev/null
_p7="$(cat "$_RR_PROMPTS/correctness.txt" 2>/dev/null)"
assert_contains "[SPEC-7] lens prompt carries a TURN BUDGET block" "$_p7" "TURN BUDGET"
assert_contains "[SPEC-7] block reflects ZBUILD_ROUTER_MAX_TURNS=77 (from _route_resolve_max_turns)" "$_p7" "77"
assert_contains "[SPEC-7] block reflects ZBUILD_ROUTER_TIMEOUT=123 (from _route_resolve_timeout)" "$_p7" "123"
_d7b="$TEST_TEMP_DIR/s7b"; _fixture "$_d7b"
ZBUILD_ROUTER_MAX_TURNS_OVERRIDE=13 ZBUILD_ROUTER_MAX_TURNS=77 \
    _rr_run_inner "$_d7b/scope.md" "$_d7b/diff.patch" "$_d7b/review-report.json" "$_d7b/review-report.md" 2>/dev/null
assert_contains "[SPEC-7] the engine's escalation override wins in the block too" \
    "$(cat "$_RR_PROMPTS/correctness.txt" 2>/dev/null)" "13 tool-call"

# ── SPEC-8: shared reply parser (#2035) — recover, but never go quiet ────────
_d8="$TEST_TEMP_DIR/s8"; _fixture "$_d8"
_RR_REPLY_MODE=signoff _rr_run_inner "$_d8/scope.md" "$_d8/diff.patch" "$_d8/review-report.json" "$_d8/review-report.md" 2>/dev/null
assert_eq "[SPEC-8] envelope followed by a brace-bearing sign-off is recovered (finding kept)" \
    "recovered finding" "$(jq -r '.findings[0].messages[0] // empty' "$_d8/review-report.json" 2>/dev/null)"
assert_eq "[SPEC-8] recovered lens keeps its score" "4" "$(jq -r '.lenses[] | select(.name=="correctness") | .score' "$_d8/review-report.json" 2>/dev/null)"
: > "$ZBUILD_EVENTS_JSONL"
_d8b="$TEST_TEMP_DIR/s8b"; _fixture "$_d8b"
_RR_REPLY_MODE=garbage _rr_run_inner "$_d8b/scope.md" "$_d8b/diff.patch" "$_d8b/review-report.json" "$_d8b/review-report.md" 2>/dev/null; _rc=$?
assert_eq "[SPEC-8] unparseable reply → rc=0" "0" "$_rc"
assert_contains "[SPEC-8] unparseable reply still emits review_report.lens.unparseable (visible failure kept)" \
    "$(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)" "review_report.lens.unparseable"
assert_eq "[SPEC-8] unparseable reply → lens reports nothing, not a fabricated score" "0" \
    "$(jq -r '.lenses[] | select(.name=="correctness") | .score' "$_d8b/review-report.json" 2>/dev/null)"

# ── SPEC-9: name-matched inputs (ADR-055 §1) ─────────────────────────────────
_d9="$TEST_TEMP_DIR/s9"; mkdir -p "$_d9/artifacts"; _fixture "$_d9/artifacts"
printf 'x' > "$_d9/pipeline-state.json"
printf '# declared scope\n' > "$_d9/from-index.md"
printf '{"inputs":{"scope_manifest":"%s"}}\n' "$_d9/from-index.md" > "$_d9/stage-inputs.json"
_rr_seen_scope=""
# Full-fidelity post-conditions (rc files) so the run's disposition is `complete`,
# not an accidental `exhausted` from every rc read falling back to 1.
_rr_fanout_lenses() {
    printf '%s' "$1" > "$_d9/seen-scope.txt"
    local l; for l in "${_RR_LENSES[@]}"; do printf '0' > "$3/lens-$l.rc"; done
    printf '[]' > "$_d9/lenses.json"; printf '%s' "$_d9/lenses.json"
}
ZBUILD_STAGE_INPUTS="$_d9/stage-inputs.json" review_report_run "review" "$_d9/pipeline-state.json" >/dev/null 2>&1
assert_eq "[SPEC-9] scope_manifest resolved from the ZBUILD_STAGE_INPUTS index" "$_d9/from-index.md" "$(cat "$_d9/seen-scope.txt" 2>/dev/null)"
assert_eq "[SPEC-9] hook path writes a complete v2 primary" "complete" "$(_v2 disposition "$_d9/artifacts/review-report.json")"
unset -f _rr_fanout_lenses; unset _ZBUILD_RR_LENSES_LOADED; source "$PLUGIN_DIR/lib/lenses.sh"  # the load guard would otherwise make this a no-op
assert_eq "[SPEC-9] real fan-out restored after the mock (11 lens calls again)" "11" \
    "$(_d9c="$TEST_TEMP_DIR/s9c"; _fixture "$_d9c"; rm -f "$_RR_PROMPTS"/*.txt; _rr_run_inner "$_d9c/scope.md" "$_d9c/diff.patch" "$_d9c/review-report.json" "$_d9c/review-report.md" >/dev/null 2>&1; ls "$_RR_PROMPTS" | wc -l | tr -d ' ')"
assert_eq "[SPEC-9] plugin.sh constructs no scope-manifest.md path" "0" \
    "$(grep -c 'scope-manifest.md' "$PLUGIN_DIR/plugin.sh" || true)"

# ── SPEC-10: rc ∈ {0,1} ──────────────────────────────────────────────────────
assert_eq "[SPEC-10] plugin.sh contains no 'return 2'" "0" "$(grep -cE 'return 2\b' "$PLUGIN_DIR/plugin.sh" || true)"

# ── SPEC-11: one result file (ADR-054 §5) — no sidecar ───────────────────────
assert_eq "[SPEC-11] manifest declares no review-report-result.json output" "0" "$(grep -c 'review-report-result' "$MANIFEST" || true)"
assert_eq "[SPEC-11] plugin.sh writes no review-report-result.json" "0" "$(grep -c 'review-report-result' "$PLUGIN_DIR/plugin.sh" || true)"
assert_file_not_exists "[SPEC-11] normal run leaves no sidecar" "$_d2/review-report-result.json"

# ── SPEC-12: resolve_tier failure is a terminal path with a result ───────────
_d12="$TEST_TEMP_DIR/s12"; _fixture "$_d12"
resolve_tier() { return 1; }
_rr_run_inner "$_d12/scope.md" "$_d12/diff.patch" "$_d12/review-report.json" "$_d12/review-report.md" 2>/dev/null; _rc=$?
unset -f resolve_tier
assert_eq "[SPEC-12] tier unresolved → rc=1" "1" "$_rc"
assert_eq "[SPEC-12] tier unresolved → verdict=error" "error" "$(_v2 verdict "$_d12/review-report.json")"
assert_eq "[SPEC-12] tier unresolved → disposition=misconfigured (#2187)" "misconfigured" "$(_v2 disposition "$_d12/review-report.json")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
