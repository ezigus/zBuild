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
# L4 [change] the correctness lens runs as test-strategist and the scope lens
#             as product-owner — personas that are roles, not lens jobs
# L5 [change] the unused security-lens plugin is gone; the security lens in
#             the lens map stays
# L6 [change] a target repository's own lens has its job in the repository,
#             .zbuild/lenses/<lens>.md, and one there wins over the install's —
#             zbuild builds any repository, and a repository may add a lens
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
assert_eq "[L1] the templates' lenses were read (fixture live)" "1" "$(( _seen >= 6 ))"

# ── L2 ───────────────────────────────────────────────────────────────────────
print_test_section "L2: a lens's prompt holds its own job"
_p_rt="$(_rl_build_lens_prompt red-team "EVIDENCE" "CONTEXT" 2>/dev/null)"
_p_co="$(_rl_build_lens_prompt correctness "EVIDENCE" "CONTEXT" 2>/dev/null)"
_rt_line="$(awk 'NF && !/^#/ { print; exit }' "$LENSES/red-team.md" 2>/dev/null)"
_co_line="$(awk 'NF && !/^#/ { print; exit }' "$LENSES/correctness.md" 2>/dev/null)"
assert_contains "[L2] red-team's prompt holds red-team's job" "$_p_rt" "${_rt_line:-<no red-team job>}"
assert_contains "[L2] correctness's prompt holds correctness's job" "$_p_co" "${_co_line:-<no correctness job>}"
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

# ── L4 ───────────────────────────────────────────────────────────────────────
print_test_section "L4: the lenses run as roles"
for _t in "$REPO_ROOT"/config/templates/simple.yaml "$REPO_ROOT"/config/templates/deployed.yaml; do
    assert_eq "[L4] ${_t##*/}: correctness runs as test-strategist" "test-strategist" "$(_tpl_lens_persona "$_t" correctness)"
    assert_eq "[L4] ${_t##*/}: scope runs as product-owner" "product-owner" "$(_tpl_lens_persona "$_t" scope)"
done

# ── L5 ───────────────────────────────────────────────────────────────────────
print_test_section "L5: the unused security-lens plugin is gone"
assert_eq "[L5] plugins/agent/security-lens is gone" "gone" \
    "$([[ -e "$REPO_ROOT/plugins/agent/security-lens" ]] && echo there || echo gone)"
assert_eq "[L5] the security lens is still in the lens map" "1" \
    "$(_tpl_lenses "$REPO_ROOT/config/templates/simple.yaml" | grep -cx security)"

# ── L6 ───────────────────────────────────────────────────────────────────────
print_test_section "L6: a repository's own lens"
TGT="$TEST_TEMP_DIR/target"; mkdir -p "$TGT/.zbuild/lenses"
printf 'What this lens looks for: TARGET-A11Y-JOB\n' > "$TGT/.zbuild/lenses/accessibility.md"
printf 'What this lens looks for: TARGET-SECURITY-JOB\n' > "$TGT/.zbuild/lenses/security.md"
_p_a11y="$(ZBUILD_REPO_ROOT="$TGT" _rl_build_lens_prompt accessibility "EVIDENCE" "CONTEXT" 2>/dev/null)"
assert_contains "[L6] a lens only the repository has gets its job from the repository" "$_p_a11y" "TARGET-A11Y-JOB"
_p_sec="$(ZBUILD_REPO_ROOT="$TGT" _rl_build_lens_prompt security "EVIDENCE" "CONTEXT" 2>/dev/null)"
assert_contains "[L6] the repository's job for a shipped lens wins" "$_p_sec" "TARGET-SECURITY-JOB"
_p_rt="$(ZBUILD_REPO_ROOT="$TGT" _rl_build_lens_prompt red-team "EVIDENCE" "CONTEXT" 2>/dev/null)"
assert_contains "[L6] ...and a shipped lens the repository does not have keeps the install's" "$_p_rt" "${_rt_line:-<no red-team job>}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
