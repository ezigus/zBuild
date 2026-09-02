#!/usr/bin/env bash
# tests/unit/build-prompt-spec-text-test.sh — the prompt states what each SPEC
# REQUIRES, not just its id (#1978, ADR-036).
#
# Every section that demanded SPEC compliance named SPECs by id only:
#
#   - SPEC-7: plugins/tool/test/tests/test-test.sh
#   - [SPEC-7] needs a `[SPEC-7]`-tagged assertion (change → fails at baseline)
#
# What SPEC-7 *required* appeared once, ~130 lines earlier, buried in a plan
# step. So the stated requirement — "an assertion tagged [SPEC-7] that fails at
# the merge-base" — is a SHAPE requirement, satisfiable by an assertion about
# any field at all. Observed: a SPEC reading "fields live under data:{} not at
# the top level" was satisfied by an assertion checking exit_code IS at the top
# level — the literal opposite — and it passed, because the gate checks
# discrimination, never correspondence.
#
#   SPEC-1 [change]: acceptance_spec_text returns a SPEC's requirement text
#   SPEC-2 [change]: the ACCEPTANCE TESTS section renders that text with the id
#   SPEC-3 [change]: the SPEC IDS section renders it too — it is the section
#                    that says "you MUST cover"
#   SPEC-4 [guard] : a SPEC whose text cannot be resolved degrades to id-only
#                    rather than dropping the id or crashing the stage
#   SPEC-6 [change]: context.sh actually BUILDS the id+text list — a formatter
#                    that can render text nothing feeds it is inert
#   SPEC-5 [change]: build does not author or modify assertions at all (#2022).
#                    The branching rule this SPEC once described still let build
#                    decide an assertion did not test its SPEC and rewrite it —
#                    self-certified correspondence, which is the defect
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"

print_test_header "build prompt — SPECs state their requirement (#1978)"
setup_test_env "build-prompt-spec-text"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh" 2>/dev/null || true

DESIGN="$TEST_TEMP_DIR/design.md"
cat > "$DESIGN" <<'EOF'
# Design: a worked example

## Decision summary

Some prose the acceptance block does not own.

```acceptance
SPEC-1[change]: test-results.json emits result_contract=2 at the top level
SPEC-7[change]: plugin-specific fields live under data:{} not at the top level
SPEC-9[guard]: _test_write_result does not construct artifact paths internally
TESTFILES:
SPEC-1: plugins/tool/test/tests/test-test.sh
SPEC-7: plugins/tool/test/tests/test-test.sh
SPEC-9: plugins/tool/test/tests/test-test.sh
```
EOF

# ─── SPEC-1: the requirement text is retrievable ─────────────────────────────
print_test_section "1. a SPEC's requirement text is retrievable by id"

if declare -F acceptance_spec_text >/dev/null 2>&1; then
    assert_eq "[SPEC-1] the text is returned without the id or classifier" \
        "plugin-specific fields live under data:{} not at the top level" \
        "$(acceptance_spec_text "$DESIGN" SPEC-7)"
    assert_eq "[SPEC-1] a guard SPEC's text resolves the same way" \
        "_test_write_result does not construct artifact paths internally" \
        "$(acceptance_spec_text "$DESIGN" SPEC-9)"
    assert_eq "[SPEC-1] an unknown id yields empty, not garbage" "" \
        "$(acceptance_spec_text "$DESIGN" SPEC-42)"
    # The TESTFILES section reuses the `SPEC-n:` shape; its paths must never be
    # mistaken for requirement text.
    if [[ "$(acceptance_spec_text "$DESIGN" SPEC-1)" == *test-test.sh* ]]; then
        assert_fail "[SPEC-1] TESTFILES paths are not mistaken for SPEC text" \
            "the binding line leaked into the requirement text"
    else
        assert_pass "[SPEC-1] TESTFILES paths are not mistaken for SPEC text"
    fi
else
    assert_fail "[SPEC-1] acceptance_spec_text exists" "function not defined"
fi

# ─── Compose a prompt the way the build stage does ───────────────────────────
# context.sh gathers, prompt.sh formats — the existing split (_design_decisions
# is passed in the same way). The spec-id list carries "SPEC-n<TAB>text"; a line
# with no tab is an id whose text could not be resolved (SPEC-4).
_SPEC_LINES="$(printf '%s\n' \
    "$(printf 'SPEC-1\ttest-results.json emits result_contract=2 at the top level')" \
    "$(printf 'SPEC-7\tplugin-specific fields live under data:{} not at the top level')" \
    "$(printf 'SPEC-9\t_test_write_result does not construct artifact paths internally')")"

_compose() {
    local out="$TEST_TEMP_DIR/prompt.txt"
    _build_compose_prompt_body \
        "$out" \
        "== HEADER ==" \
        "PLAN PAYLOAD" \
        "INSTRUCTIONS BODY" \
        "" \
        "plugins/tool/test/tests/test-test.sh" \
        "$_SPEC_LINES" \
        "" "" "" 1 "" "" >/dev/null 2>&1 || true
    cat "$out" 2>/dev/null
}

PROMPT="$(_compose)"

# ─── SPEC-2 / SPEC-3: both demanding sections carry the text ─────────────────
print_test_section "2. the ACCEPTANCE TESTS section states each requirement"

assert_contains "[SPEC-2] SPEC-7's requirement text is in the prompt" \
    "$PROMPT" "live under data:{} not at the top level"
assert_contains "[SPEC-2] SPEC-1's requirement text is in the prompt" \
    "$PROMPT" "result_contract=2 at the top level"

print_test_section "3. the SPEC IDS section states them too"

# The id-only line is what let the drift through; the text must sit ON the line
# that says "you MUST cover", not merely somewhere in the file.
_ids_section="$(awk '/SPEC IDS YOU MUST COVER/,/^## /' <<< "$PROMPT")"
assert_contains "[SPEC-3] the must-cover list names what SPEC-7 requires" \
    "$_ids_section" "live under data:{} not at the top level"
assert_contains "[SPEC-3] and what SPEC-9 requires" \
    "$_ids_section" "does not construct artifact paths internally"

# ─── SPEC-4: unresolvable text degrades, never drops or crashes ──────────────
print_test_section "4. an unresolvable SPEC degrades to id-only"

# Bare ids, no tab — what context.sh emits when the design has no acceptance
# block, or a SPEC line it cannot parse.
_out2="$TEST_TEMP_DIR/prompt2.txt"
_build_compose_prompt_body \
    "$_out2" "== H ==" "PLAN" "INSTR" "" \
    "plugins/tool/test/tests/test-test.sh" \
    "$(printf 'SPEC-1\nSPEC-7\n')" "" "" "" 1 "" "" >/dev/null 2>&1 || true
PROMPT2="$(cat "$_out2" 2>/dev/null)"

assert_contains "[SPEC-4] the id still appears when its text cannot be resolved" \
    "$PROMPT2" "SPEC-7"
assert_contains "[SPEC-4] the tagged-assertion requirement still appears" \
    "$PROMPT2" "tagged assertion"
if [[ -s "$_out2" ]]; then
    assert_pass "[SPEC-4] the stage still produces a prompt"
else
    assert_fail "[SPEC-4] the stage still produces a prompt" "prompt file empty"
fi

# ─── SPEC-5: build does not author assertions (#2022) ────────────────────────
# This SPEC used to assert a BRANCHING rule: correct the assertion when it does
# not test its SPEC, else fix the code. Build was still the one judging which
# branch applied, and still the one rewriting — self-certified correspondence,
# and the defect two runs shipped (ADR-036:512, #1978). Assertion authorship now
# belongs to test-author, so the branch is gone: a failing assertion means the
# CODE is wrong, full stop.
print_test_section "5. build does not author or modify assertions"

assert_contains "[SPEC-5] build is told it does not author assertions" \
    "$PROMPT" "do NOT author or modify acceptance assertions"
assert_contains "[SPEC-5] a failing assertion means the code is wrong" \
    "$PROMPT" "fix the code"
assert_contains "[SPEC-5] and the testfiles are off limits" \
    "$PROMPT" "must not edit the testfiles"

if grep -qF 'correct the assertion' <<< "$PROMPT"; then
    assert_fail "[SPEC-5] the licence to correct an assertion is gone" \
        "the old 'correct the assertion' wording is still present"
else
    assert_pass "[SPEC-5] the licence to correct an assertion is gone"
fi

if grep -qF 'which you MUST re-author' <<< "$PROMPT"; then
    assert_fail "[SPEC-5] the unconditional re-author licence is gone" \
        "the old 'which you MUST re-author' wording is still present"
else
    assert_pass "[SPEC-5] the unconditional re-author licence is gone"
fi

# ─── SPEC-6: the gatherer actually feeds it ──────────────────────────────────
# A formatter that CAN render text is inert if nothing supplies it. This is the
# #1919 lesson: assert the wiring, not just the renderer.
print_test_section "6. context.sh builds the id+text list from the design"

if declare -F _build_gather_acceptance_specs >/dev/null 2>&1; then
    _gathered="$(_build_gather_acceptance_specs "$DESIGN" 2>/dev/null || true)"
    assert_contains "[SPEC-6] the gathered list pairs SPEC-7 with its text" \
        "$_gathered" "live under data:{} not at the top level"
    assert_contains "[SPEC-6] every declared id is present" "$_gathered" "SPEC-9"
    _no_block="$TEST_TEMP_DIR/no-block.md"
    printf '# no acceptance block\n' > "$_no_block"
    assert_eq "[SPEC-6] a design with no block yields nothing, not an error" "" \
        "$(_build_gather_acceptance_specs "$_no_block" 2>/dev/null || true)"
else
    assert_fail "[SPEC-6] _build_gather_acceptance_specs exists" "function not defined"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
