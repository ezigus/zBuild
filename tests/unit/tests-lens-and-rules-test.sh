#!/usr/bin/env bash
# tests/unit/tests-lens-and-rules-test.sh — a tests lens; the correctness lens
# keeps logic; the repository's rules in .zbuild/rules.md (#2630; ADR-040,
# ADR-067 §8).
#
# Why: on #1722 run 45872552515 no lens saw that a test replaced the project's
# own function with a fake: the correctness lens judged logic and tests at once,
# and the repository's test rules (CLAUDE.md) never reached a stage.
#
# L1 [change] the correctness lens's job is logic only: no test checks in it
# L2 [change] a tests lens's job names the five things it judges
# L3 [change] both shipped templates run the tests lens in their lens group, as
#             the test strategist; the correctness lens runs as the developer;
#             every lens runs at once
# R1 [change] the repository's rules are read from .zbuild/rules.md, beside
#             vision.md; .zbuild/prompts/rules.md is not read
# R2 [change] every stage's From the repo part holds their full text, naming
#             the file it came from; with none, it says so
# R3 [change] zBuild's own .zbuild/rules.md holds the rules its CLAUDE.md
#             states, and CLAUDE.md includes it
# R4 [change] the docs say zbuild reads .zbuild/rules.md
# R5 [change] a run on a repository with no .zbuild/rules.md says so on its
#             status comment; one with the file says nothing about it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "a tests lens; the repository's rules in .zbuild/rules.md (#2630)"
setup_test_env "tests-lens-and-rules"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }
_flat() { tr -s '[:space:]' ' ' <<< "$1"; }
LENSES="$REPO_ROOT/plugins/agent/review-lens/lenses"

# ── L1 ───────────────────────────────────────────────────────────────────────
print_test_section "L1: the correctness lens judges logic"
_c="$(_flat "$(cat "$LENSES/correctness.md")")"
assert_contains "[L1] it still judges logic" "$_c" "an off-by-one"
_lacks "[L1] ...not a test that passes whatever the code does" "$_c" "a test that passes whatever the code does"
_lacks "[L1] ...not a test that reaches a real service" "$_c" "a test that reaches a real service"
_lacks "[L1] ...not an Enforced by entry" "$_c" "Enforced by entry"

# ── L2 ───────────────────────────────────────────────────────────────────────
print_test_section "L2: the tests lens"
_t="$(_flat "$(cat "$LENSES/tests.md" 2>/dev/null)")"
assert_contains "[L2] an outside service is faked only at our wrapper around it, never our own code" "$_t" \
    "a test that replaces the project's own code with a fake, rather than faking an outside service at the project's own wrapper around it"
assert_contains "[L2] ...nothing waits on a clock" "$_t" "a test that waits on a clock"
assert_contains "[L2] ...each test proves the path it claims" "$_t" "a test that does not prove the path it claims"
assert_contains "[L2] ...it fails on the old code for the right reason" "$_t" "a test that would not fail on the code from before the change, or would fail there for another reason"
assert_contains "[L2] ...its example input is realistic" "$_t" "an example input no caller really passes"
assert_contains "[L2] ...and an Enforced by entry that names a test which does not check what it says" "$_t" "an Enforced by entry that names a test which does not check what it says"

# ── L3 ───────────────────────────────────────────────────────────────────────
print_test_section "L3: the templates run it"
for _tpl in simple deployed; do
    _y="$REPO_ROOT/config/templates/$_tpl.yaml"
    _els="$(awk '/^review_lenses:/{f=1} f&&/^[a-z_]+:/&&!/^review_lenses:/{f=0} f' "$_y")"
    assert_contains "[L3] $_tpl: the tests lens is in the lens group" "$_els" "- id: tests"
    assert_contains "[L3] $_tpl: ...as the test strategist" "$(grep -A1 -- '- id: tests' <<< "$_els")" "persona: test-strategist"
    assert_contains "[L3] $_tpl: the correctness lens runs as the developer" "$(grep -A1 -- '- id: correctness' <<< "$_els")" "persona: developer"
    _n="$(grep -c -- '- id: ' <<< "$_els")"
    assert_eq "[L3] $_tpl: every lens runs at once" "max_parallel: $_n" "$(grep -oE 'max_parallel: [0-9]+' <<< "$_els")"
done

# ── R1 / R2 ──────────────────────────────────────────────────────────────────
print_test_section "R1 R2: the repository's rules"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh" 2>/dev/null || true
RR="$TEST_TEMP_DIR/repo"; mkdir -p "$RR/.zbuild/prompts"
printf -- '- RULE-NEW: a rule beside vision.md\n' > "$RR/.zbuild/rules.md"
printf -- '- RULE-OLD: a rule in the old place\n' > "$RR/.zbuild/prompts/rules.md"
assert_contains "[R1] the rules are read from .zbuild/rules.md" "$(load_repo_rules "$RR" 2>/dev/null)" "RULE-NEW"
_lacks "[R1] ...not from .zbuild/prompts/rules.md" "$(load_repo_rules "$RR" 2>/dev/null)" "RULE-OLD"
_p="$(_flat "$(_sp_repo_intent_and_rules "$RR" 2>/dev/null)")"
assert_contains "[R2] the prompt holds their full text" "$_p" "RULE-NEW: a rule beside vision.md"
assert_contains "[R2] ...naming the file it came from" "$_p" "These are this repository's rules, from its .zbuild/rules.md."
rm -f "$RR/.zbuild/rules.md"
_p0="$(_flat "$(_sp_repo_intent_and_rules "$RR" 2>/dev/null)")"
assert_contains "[R2] with none, it says so" "$_p0" "This repository has no .zbuild/rules.md, so these are zBuild's default rules."
_lacks "[R2] ...and the old place is not read" "$_p0" "RULE-OLD"

# ── R3 ───────────────────────────────────────────────────────────────────────
print_test_section "R3: zBuild's own rules file"
_zr="$(_flat "$(cat "$REPO_ROOT/.zbuild/rules.md" 2>/dev/null)")"
for _w in "A remote service is faked at the project's own wrapper around it, never the project's own code." \
          "Never wait on a clock in a test" \
          "Write the test first" \
          "If the code drifts from the spec, the spec wins" \
          "Every issue cites the ADR and section it implements" \
          "Every ADR statement has a test, named in the ADR's Enforced by section" \
          "Keep files under 500 lines" \
          "Process and exec budgets only go down" \
          "Never pipe anything into \`grep -q\`" \
          "Never name a model" \
          "Never edit anything under \`legacy-DoNotUse/\`"; do
    assert_contains "[R3] .zbuild/rules.md: $_w" "$_zr" "$_w"
done
assert_contains "[R3] CLAUDE.md includes it, so there is one source" "$(cat "$REPO_ROOT/CLAUDE.md")" "@.zbuild/rules.md"
if [[ -e "$REPO_ROOT/.zbuild/prompts/rules.md" ]]; then assert_fail "[R3] the old file is gone" "$REPO_ROOT/.zbuild/prompts/rules.md"
else assert_pass "[R3] the old file is gone"; fi

# ── R4 ───────────────────────────────────────────────────────────────────────
print_test_section "R4: the docs"
assert_contains "[R4] the configuration page says zbuild reads .zbuild/rules.md" \
    "$(cat "$REPO_ROOT/docs/wiki/Configuration.md")" "### Repository rules (\`.zbuild/rules.md\`)"
_lacks "[R4] ...and names no old path" "$(cat "$REPO_ROOT/docs/wiki/Configuration.md" "$REPO_ROOT/docs/wiki/Writing-Plugins.md")" ".zbuild/prompts/rules.md"

# ── R5 ───────────────────────────────────────────────────────────────────────
print_test_section "R5: the status comment"
# shellcheck source=../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"
_model='{"header":{"run_id":"r-2630","issue":"2630","engine_sha":"abcdef1234","engine_branch":"main","started":"2026-11-26T01:16:58Z"},"rows":{},"order":[],"terminal":{},"pr":{}}'
_h_none="$(ZBUILD_REPO_ROOT="$RR" ZBUILD_STATUS_NOW=2026-11-26T01:20:00Z rsc_render_header "$_model" "$TEST_TEMP_DIR" 2>/dev/null)"
assert_contains "[R5] no .zbuild/rules.md: the status comment says so" "$_h_none" \
    "This repository has no \`.zbuild/rules.md\`: every stage was given zBuild's default rules."
printf -- '- a rule\n' > "$RR/.zbuild/rules.md"
_h_has="$(ZBUILD_REPO_ROOT="$RR" ZBUILD_STATUS_NOW=2026-11-26T01:20:00Z rsc_render_header "$_model" "$TEST_TEMP_DIR" 2>/dev/null)"
_lacks "[R5] ...with the file, nothing is said" "$_h_has" "rules.md"

print_test_results
exit $((FAIL > 0))
