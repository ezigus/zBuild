#!/usr/bin/env bash
# tests/unit/lens-task-test.sh — each lens has its own job, kept by the
# review-lens stage; the persona it runs as is only who does it (#2548,
# ADR-038 amended 2026-11-15, ADR-051 §9).
#
# Why: the job of every lens sat in its persona's perspective ("Examine the
# change …", severity examples), so a persona could not be used for any other
# work, and only scope said what is not a finding. On #1700 run 43663836927, 10
# of 15 lens findings had a real quote but a case that cannot happen.
#
# L1 [change] every lens a shipped template runs has its own job text, with
#             what it looks for, what is not a finding, where its problems
#             come from, and its severity examples
# L2 [change] a lens's prompt holds its own job; two lenses' prompts differ
#             by more than their names
# L3 [change] a lens with no job text reviews nothing: it ends misconfigured,
#             and no model is asked
# L4 [change] the correctness lens runs as the developer (#2630: it judges
#             logic), the tests lens as test-strategist and the scope lens as
#             product-owner — personas that are roles, not lens jobs
# L6 [change] (#2567, ADR-038) a lens is told that work the issue or the design
#             asks this change to do, which it does not do, is the change's:
#             introduced true, though the old code behaves the same
# L7 [change] (#2567 review) a lens is shown the design steps build answered
#             not needed that build's check accepted, and is told such a step
#             is not undone work unless it shows the reason is wrong
# L5 [change] the unused security-lens plugin is gone; the security lens in
#             the lens map stays
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "each lens has its own job; its persona is who does it (#2548)"
setup_test_env "lens-task"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../plugins/agent/review-lens/plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh" 2>/dev/null
set +e

LENSES="$REPO_ROOT/plugins/agent/review-lens/lenses"
_lacks() {  # <label> <text> <must-not-hold>
    if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it holds: $3"; else assert_pass "$1"; fi
}
# The lenses a template runs: the `- id:` elements of its review_lenses group.
_tpl_lenses() {
    awk '/^review_lenses:/ { g = 1; next } g && /^[^[:space:]#]/ { g = 0 }
         g && /^[[:space:]]+- id:/ { sub(/^[[:space:]]+- id:[[:space:]]*/, ""); print }' "$1"
}
# _tpl_lens_persona <template> <lens> — the persona the template names for it.
_tpl_lens_persona() {
    awk -v want="$2" '/^review_lenses:/ { g = 1; next } g && /^[^[:space:]#]/ { g = 0 }
        g && /^[[:space:]]+- id:/ { el = $0; sub(/^[[:space:]]+- id:[[:space:]]*/, "", el); next }
        g && el == want && /^[[:space:]]+persona:/ { sub(/^[[:space:]]+persona:[[:space:]]*/, ""); print; exit }' "$1"
}

# ── L1 ───────────────────────────────────────────────────────────────────────
print_test_section "L1: every lens has its own job"
_seen=0
for _t in "$REPO_ROOT"/config/templates/simple.yaml "$REPO_ROOT"/config/templates/deployed.yaml; do
    while IFS= read -r _l; do
        [[ -n "$_l" ]] || continue
        _seen=$((_seen + 1))
        _f="$LENSES/$_l.md"
        if [[ ! -s "$_f" ]]; then
            assert_fail "[L1] ${_t##*/}: $_l has its job text" "no $_f"
            continue
        fi
        _missing=""
        for _part in "What this lens looks for" "Not a finding" "Where these problems come from" "Severity"; do
            grep -qF -- "$_part" "$_f" || _missing+="[$_part] "
        done
        assert_eq "[L1] ${_t##*/}: $_l's job says what it looks for, what is not a finding, where its problems come from, and its severity" "" "$_missing"
    done < <(_tpl_lenses "$_t")
done
assert_eq "[L1] the templates' lenses were read: six in each (fixture live)" "1" "$(( _seen >= 12 ))"

# ── L2 ───────────────────────────────────────────────────────────────────────
print_test_section "L2: a lens's prompt holds its own job"
_p_rt="$(_rl_build_lens_prompt red-team "EVIDENCE" "CONTEXT" 2>/dev/null)"
_p_co="$(_rl_build_lens_prompt correctness "EVIDENCE" "CONTEXT" 2>/dev/null)"
_rt_line="$(awk 'NF && !/^#/ { print; exit }' "$LENSES/red-team.md" 2>/dev/null)"
_co_line="$(awk 'NF && !/^#/ { print; exit }' "$LENSES/correctness.md" 2>/dev/null)"
assert_contains "[L2] red-team's prompt holds red-team's job" "$_p_rt" "${_rt_line:-<no red-team job>}"
assert_contains "[L2] correctness's prompt holds correctness's job" "$_p_co" "${_co_line:-<no correctness job>}"
# The whole job reaches the prompt, not only its first line: what is not a
# finding, and each severity example, for every lens.
for _l in security performance red-team correctness scope sre; do
    _pl="$(_rl_build_lens_prompt "$_l" "EVIDENCE" "CONTEXT" 2>/dev/null)"
    _miss=""
    while IFS= read -r _line; do
        case "$_line" in
            "Not a finding:"|"- critical: "*|"- high: "*|"- medium: "*|"- low: "*|"Where these problems come from: "*)
                [[ "$_pl" == *"$_line"* ]] || _miss+="[${_line:0:30}] " ;;
        esac
    done < "$LENSES/$_l.md"
    assert_eq "[L2] $_l's prompt holds its whole job: not a finding, where problems come from, each severity" "" "$_miss"
done
if [[ "${_p_rt//red-team/LENS}" == "${_p_co//correctness/LENS}" ]]; then
    assert_fail "[L2] two lenses' prompts differ by more than their names" "they are the same"
else
    assert_pass "[L2] two lenses' prompts differ by more than their names"
fi

# ── L3 ───────────────────────────────────────────────────────────────────────
print_test_section "L3: a lens with no job reviews nothing"
AD="$TEST_TEMP_DIR/art"; mkdir -p "$AD"
CALLS="$TEST_TEMP_DIR/calls"; : > "$CALLS"
route_to_model() { printf 'x\n' >> "$CALLS"; printf '{"score":10,"findings":[]}\n'; }
resolve_tier() { printf 'T2'; }
printf 'diff --git a/foo.sh b/foo.sh\n+echo hi\n' > "$AD/bundle.txt"
( export ZBUILD_ARTIFACT_DIR="$AD" ZBUILD_STATE_DIR="$TEST_TEMP_DIR"
  _review_lens_run_inner no-such-lens "" "$AD/bundle.txt" "$AD/lens-no-such-lens.json" "$AD" ) >/dev/null 2>&1
assert_eq "[L3] no model was asked" "0" "$(grep -c . "$CALLS")"
assert_eq "[L3] the lens ended misconfigured" "misconfigured" \
    "$(jq -r '.disposition // .outcome // empty' "$AD/lens-no-such-lens.json" 2>/dev/null)"

# A lens name that is not a plain name is no lens: a path does not reach a file.
# A job file where ../x would land from the lens folder: only the name check
# keeps it out.
mkdir -p "$TEST_TEMP_DIR/t3/lenses"; printf 'What this lens looks for: TRAVERSAL\n' > "$TEST_TEMP_DIR/t3/x.md"
: > "$CALLS"
( export ZBUILD_ARTIFACT_DIR="$AD" ZBUILD_STATE_DIR="$TEST_TEMP_DIR"; _RL_LENSES_DIR="$TEST_TEMP_DIR/t3/lenses"
  _review_lens_run_inner "../x" "" "$AD/bundle.txt" "$AD/lens-trav.json" "$AD" ) >/dev/null 2>&1
assert_eq "[L3] a lens named ../x asks no model" "0" "$(grep -c . "$CALLS")"
assert_eq "[L3] ...and ends misconfigured" "misconfigured" "$(jq -r '.outcome // empty' "$AD/lens-trav.json" 2>/dev/null)"

# The prompt that cannot be composed: the lens reviews nothing, and says so.
: > "$CALLS"
( export ZBUILD_ARTIFACT_DIR="$AD" ZBUILD_STATE_DIR="$TEST_TEMP_DIR"
  stage_prompt_compose_parts() { return 1; }
  _review_lens_run_inner security "" "$AD/bundle.txt" "$AD/lens-nocompose.json" "$AD" ) >/dev/null 2>&1
assert_eq "[L3] a prompt that cannot be composed asks no model" "0" "$(grep -c . "$CALLS")"
assert_eq "[L3] ...and ends misconfigured" "misconfigured" "$(jq -r '.outcome // empty' "$AD/lens-nocompose.json" 2>/dev/null)"

# ── L4 ───────────────────────────────────────────────────────────────────────
print_test_section "L4: the lenses run as roles"
for _t in "$REPO_ROOT"/config/templates/simple.yaml "$REPO_ROOT"/config/templates/deployed.yaml; do
    assert_eq "[L4] ${_t##*/}: correctness runs as developer" "developer" "$(_tpl_lens_persona "$_t" correctness)"
    assert_eq "[L4] ${_t##*/}: tests runs as test-strategist" "test-strategist" "$(_tpl_lens_persona "$_t" tests)"
    assert_eq "[L4] ${_t##*/}: scope runs as product-owner" "product-owner" "$(_tpl_lens_persona "$_t" scope)"
done

# ── L5 ───────────────────────────────────────────────────────────────────────
print_test_section "L5: the unused security-lens plugin is gone"
assert_eq "[L5] plugins/agent/security-lens is gone" "gone" \
    "$([[ -e "$REPO_ROOT/plugins/agent/security-lens" ]] && echo there || echo gone)"
for _t in simple deployed; do
    assert_eq "[L5] $_t.yaml: the security lens is still in the lens map" "1" \
        "$(_tpl_lenses "$REPO_ROOT/config/templates/$_t.yaml" | grep -cx security)"
done

# ── L6 ───────────────────────────────────────────────────────────────────────
# #1764 run 44417314654: the scope lens found "plugin.sh still uses
# claimed:<machine>; the design says to change it" and marked it introduced:
# false — the old code did the same — so it never went back to be fixed.
_p6="$(_rl_build_lens_prompt scope "EVIDENCE" "CONTEXT" 2>/dev/null | tr -s '[:space:]' ' ')"
assert_contains "[L6] work asked for and not done is the change's" "$_p6" \
    "Something the issue or the design asks this change to do, and the change does not do, is the change's: introduced is true, even where the code before the change behaved the same way."

# ── L7 ───────────────────────────────────────────────────────────────────────
# Build's summary, made by build's own writer, with step 1 answered not needed
# and its check accepting it; the lens's context then shows that answer.
L7A="$TEST_TEMP_DIR/l7/artifacts"; mkdir -p "$L7A"
(
    # shellcheck source=../../plugins/agent/build/plugin.sh
    source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
    route_to_model() { printf '1: does\n'; }
    # The judging call's prompt needs the engine's blocks, present and not empty.
    export ZBUILD_STAGE_BLOCKS="$TEST_TEMP_DIR/l7/blocks"; mkdir -p "$ZBUILD_STAGE_BLOCKS"
    for _b in from-repo previous-work-fresh rules-fresh; do printf '# %s\n' "$_b" > "$ZBUILD_STAGE_BLOCKS/$_b.md"; done
    _build_steps_load '{"steps":[{"description":"amend plugin.sh to use zbuild:claimed","areas":["plugins/x/plugin.sh"]}]}'
    # shellcheck disable=SC2034  # read by _build_write_build_summary, in its scope
    output_summary_json="$L7A/build-summary.json" output_diff_patch="$L7A/diff.patch"
    # shellcheck disable=SC2034  # read by _build_write_build_summary, in its scope
    terminated_reason=done_sentinel router_rc=0 files_changed_count=0 artifact_dir="$L7A" repo_root="$TEST_TEMP_DIR/l7"
    # shellcheck disable=SC2034  # read by _build_write_build_summary, in its scope
    scope_violations=()
    _ROUTE_LOOP_LAST_RESPONSE=$'step 1: not needed — plugin.sh already adds zbuild:claimed in claim_coordinator_claim\nLOOP_COMPLETE'
    _build_write_build_summary >/dev/null 2>&1
)
assert_contains "[L7] setup: build's summary holds the accepted answer" \
    "$(jq -r '.data.steps[]?' "$L7A/build-summary.json" 2>/dev/null)" "step 1: not needed — plugin.sh already adds zbuild:claimed"
_ctx="$(ZBUILD_ARTIFACT_DIR="$L7A" ZBUILD_STAGE_INPUTS="" artifact_dir="$L7A" _rl_context 2>/dev/null)"
assert_contains "[L7] the lens is shown the accepted not-needed answer" "$_ctx" \
    "step 1: not needed — plugin.sh already adds zbuild:claimed in claim_coordinator_claim"
_p7="$(_rl_build_lens_prompt scope "EVIDENCE" "CONTEXT" 2>/dev/null | tr -s '[:space:]' ' ')"
assert_contains "[L7] ...and told it is not undone work unless the reason is wrong" "$_p7" \
    "A design step build answered not needed, its check accepting the reason (THE DESIGN STEPS BUILD FOUND NOT NEEDED), is not undone work; report it only if you show the reason is wrong, quoting the code that shows it."

cleanup_test_env
print_test_results
exit $((FAIL > 0))
