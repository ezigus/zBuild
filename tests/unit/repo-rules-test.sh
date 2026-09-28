#!/usr/bin/env bash
# tests/unit/repo-rules-test.sh — a stage that declares `prompt.repo_rules: true`
# is given the TARGET repo's rules, or zBuild's default rules when the repo has
# none. The engine does it, in the router's one prompt funnel, so any stage can
# have it by declaring it and none has to know how.
#
# Why: #1845 run 36274909946 — test-author wrote `grep … | grep -q` into a
# testfile twice; the repo's SIGPIPE guard failed the suite; nothing had told
# the author the rule. ADR-032's overrides are per-stage and opt-in in code
# (4 of the agent stages read one), and there was no repo-wide rule set and no
# default.
#
# R1  declared + repo has .zbuild/prompts/rules.md → its text, under the marker,
#     naming the file; not the default
# R2  declared + repo has none → zBuild's default rules, saying they are the default;
#     <!-- --> maintainer notes in a rules file are not sent
# R3  not declared → nothing (a non-declaring stage's prompt is unchanged)
# R4  a rules.md that symlinks out of the repo is refused → the default, and
#     none of the escaped file's content
# R5  the router injects the block for a declaring stage — once, however many
#     times the prompt is redacted
# R6  the router leaves a non-declaring stage's prompt without it
# R7  test-author declares it; so does the review lens (reviewer framing)
# R8  the declaration is a valid manifest (test-author still validates)
# R9  zBuild's own rules carry the rule #1845's test-author broke
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: repository rules reach the stages that declare them"
setup_test_env "repo-rules"

# shellcheck source=../../scripts/lib/repo-rules.sh
source "$REPO_ROOT/scripts/lib/repo-rules.sh" 2>/dev/null || true

DEFAULT_RULES="$REPO_ROOT/config/prompts/default-rules.md"
_default_first="$(grep -m1 '^- ' "$DEFAULT_RULES" 2>/dev/null || true)"

DECL="$TEST_TEMP_DIR/declaring"; mkdir -p "$DECL"
printf 'id: declaring\nkind: agent\nprompt:\n  repo_rules: true\n' > "$DECL/manifest.yaml"
PLAIN="$TEST_TEMP_DIR/plain"; mkdir -p "$PLAIN"
printf 'id: plain\nkind: agent\n' > "$PLAIN/manifest.yaml"

REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO/.zbuild/prompts"
printf '# Our rules\nREPO_RULE_MARKER never pipe into grep -q\n' > "$REPO/.zbuild/prompts/rules.md"
EMPTY_REPO="$TEST_TEMP_DIR/empty-repo"; mkdir -p "$EMPTY_REPO"

print_test_section "R0: the default rule set exists"
assert_file_exists "[R0] config/prompts/default-rules.md" "$DEFAULT_RULES"
[[ -n "$_default_first" ]] && assert_pass "[R0] and says something" \
    || assert_fail "[R0] and says something" "no non-comment line"

print_test_section "R1–R4: which rules a declaring stage gets"
_b1="$(repo_rules_prompt_block "$DECL/manifest.yaml" "$REPO" 2>/dev/null || true)"
assert_contains "[R1] under the engine marker" "$_b1" "## REPOSITORY RULES (engine-provided)"
assert_contains "[R1] the repo's own rules" "$_b1" "REPO_RULE_MARKER never pipe into grep -q"
assert_contains "[R1] naming where they came from" "$_b1" ".zbuild/prompts/rules.md"
if [[ -n "$_default_first" ]] && grep -qF -- "$_default_first" <<< "$_b1"; then
    assert_fail "[R1] not the default" "the default rule set was included too"
else
    assert_pass "[R1] not the default"
fi

_b2="$(repo_rules_prompt_block "$DECL/manifest.yaml" "$EMPTY_REPO" 2>/dev/null || true)"
assert_contains "[R2] the default rules" "$_b2" "${_default_first:-<no default>}"
assert_contains "[R2] saying they are the default" "$_b2" "zBuild's default rules"
if grep -qF -- '<!--' <<< "$_b2"; then
    assert_fail "[R2] maintainer comments (<!-- -->) are not sent to the model" "comment present"
else
    assert_pass "[R2] maintainer comments (<!-- -->) are not sent to the model"
fi

_b3="$(repo_rules_prompt_block "$PLAIN/manifest.yaml" "$REPO" 2>/dev/null || true)"
assert_eq "[R3] nothing for a stage that does not declare it" "" "$_b3"

ESC="$TEST_TEMP_DIR/escape-repo"; mkdir -p "$ESC/.zbuild/prompts"
printf 'SECRET_OUTSIDE_THE_REPO\n' > "$TEST_TEMP_DIR/outside.md"
ln -s "$TEST_TEMP_DIR/outside.md" "$ESC/.zbuild/prompts/rules.md"
_b4="$(repo_rules_prompt_block "$DECL/manifest.yaml" "$ESC" 2>/dev/null || true)"
if grep -qF "SECRET_OUTSIDE_THE_REPO" <<< "$_b4"; then
    assert_fail "[R4] an escaping symlink is refused" "the out-of-repo file's content was injected"
else
    assert_pass "[R4] an escaping symlink is refused"
fi
assert_contains "[R4] and the default is used instead" "$_b4" "${_default_first:-<no default>}"

print_test_section "R5/R6: the router injects it, once, only for a declaring stage"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true
if declare -F _route_redact_prompt >/dev/null 2>&1; then
    IN="$TEST_TEMP_DIR/prompt.in"; OUT="$TEST_TEMP_DIR/prompt.out"
    printf 'Write the testfile.\n' > "$IN"
    ZBUILD_PLUGIN_DIR="$DECL" ZBUILD_REPO_ROOT="$REPO" ZBUILD_SCOPE_MANIFEST="" \
        _route_redact_prompt "$IN" "$OUT" 0 "" >/dev/null 2>&1 || true
    ZBUILD_PLUGIN_DIR="$DECL" ZBUILD_REPO_ROOT="$REPO" ZBUILD_SCOPE_MANIFEST="" \
        _route_redact_prompt "$IN" "$OUT" 1 "" >/dev/null 2>&1 || true
    _n="$(grep -c 'REPO_RULE_MARKER' "$OUT" 2>/dev/null || true)"
    assert_eq "[R5] the declaring stage's prompt carries the repo rules exactly once" "1" "${_n:-0}"

    IN2="$TEST_TEMP_DIR/prompt2.in"; OUT2="$TEST_TEMP_DIR/prompt2.out"
    printf 'Judge the change.\n' > "$IN2"
    ZBUILD_PLUGIN_DIR="$PLAIN" ZBUILD_REPO_ROOT="$REPO" ZBUILD_SCOPE_MANIFEST="" \
        _route_redact_prompt "$IN2" "$OUT2" 0 "" >/dev/null 2>&1 || true
    if grep -qF "## REPOSITORY RULES" "$OUT2" 2>/dev/null; then
        assert_fail "[R6] a non-declaring stage's prompt has no rules block" "block injected"
    else
        assert_contains "[R6] (and the prompt itself survived)" "$(cat "$OUT2" 2>/dev/null)" "Judge the change."
    fi
else
    assert_fail "[R5] _route_redact_prompt is available" "not defined after sourcing route.sh"
fi

print_test_section "R7/R8: who declares it"
_ta_mf="$REPO_ROOT/plugins/agent/test-author/manifest.yaml"
assert_eq "[R7] test-author declares prompt.repo_rules" "true" \
    "$(yaml_get "$_ta_mf" "prompt.repo_rules" 2>/dev/null || true)"
_lens_decl=""
for _mf in "$REPO_ROOT"/plugins/agent/*lens*/manifest.yaml; do
    [[ -f "$_mf" ]] || continue
    [[ "$(yaml_get "$_mf" "prompt.repo_rules" 2>/dev/null || true)" == "true" ]] && _lens_decl+="$_mf "
done
# Since the lens-context change, the review lens declares it too — framed for a
# reviewer (review-lens-context-unit-test.sh C8).
assert_contains "[R7] the review lens declares it" "$_lens_decl" "plugins/agent/review-lens/manifest.yaml"

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
if declare -F validate_manifest >/dev/null 2>&1; then
    _vrc=0; validate_manifest "$_ta_mf" >/dev/null 2>&1 || _vrc=$?
    assert_eq "[R8] test-author's manifest still validates" "0" "$_vrc"
else
    assert_fail "[R8] validate_manifest is available" "not defined after sourcing the registry"
fi

print_test_section "R9: zBuild's own rules"
_own="$(cat "$REPO_ROOT/.zbuild/prompts/rules.md" 2>/dev/null || true)"
assert_contains "[R9] the SIGPIPE rule (#1845's test-author broke it twice)" "$_own" "grep -q PATTERN <<<"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
