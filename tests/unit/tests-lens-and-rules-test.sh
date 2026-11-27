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
# R1b [change] (review) the rules file is read only where it is: not one linked
#             or hard-linked out of the repository; a stage's guidance stays in
#             .zbuild/prompts/; zBuild's default rules name no old path
# R2 [change] every stage's From the repo part holds their full text, naming
#             the file it came from; with none, it says so
# R3 [change] zBuild's own .zbuild/rules.md holds the rules its CLAUDE.md
#             states, and CLAUDE.md includes it
# R4 [change] the docs say zbuild reads .zbuild/rules.md
# R5 [change] a run on a repository with no rules in .zbuild/rules.md (none, a link, or
#             an empty file) says so on the
#             status comment it posts, started as the runner starts it (with
#             --repo-root, no ZBUILD_REPO_ROOT); one with the file says nothing
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
_lacks "[L1] ...and names no test it judges (no \"a test that\")" "$_c" "a test that"
_lacks "[L1] ...not an Enforced by entry" "$_c" "Enforced by entry"

# ── L2 ───────────────────────────────────────────────────────────────────────
print_test_section "L2: the tests lens"
_t="$(_flat "$(cat "$LENSES/tests.md" 2>/dev/null)")"
assert_contains "[L2] an outside service is faked only at our wrapper around it, never our own code" "$_t" \
    "a test that replaces the project's own code with a fake, rather than faking an outside service at the project's own wrapper around it"
assert_contains "[L2] ...nor reaches a real service instead of a stand-in" "$_t" "a test that reaches a real service (the network, GitHub, a model) instead of a stand-in"
assert_contains "[L2] ...and reaching one is graded, as a fake of our own code is" "$_t" "medium: a test that fakes the project's own code, reaches a real service,"
assert_contains "[L2] ...nothing waits on a clock" "$_t" "a test that waits on a clock"
assert_contains "[L2] ...each test proves the path it claims" "$_t" "a test that does not prove the path it claims"
assert_contains "[L2] ...it fails on the old code for the right reason" "$_t" "a test that would not fail on the code from before the change, or would fail there for another reason"
assert_contains "[L2] ...its example input is realistic" "$_t" "an example input no caller really passes"
assert_contains "[L2] ...and an Enforced by entry that names a test which does not check what it says" "$_t" "an Enforced by entry that names a test which does not check what it says"

# ── L3 ───────────────────────────────────────────────────────────────────────
print_test_section "L3: the templates run it"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
for _tpl in simple deployed; do
    ( load_template "$REPO_ROOT/config/templates/$_tpl.yaml" >/dev/null 2>&1
      printf '%s\t%s\t%s\t%s\n' "${_TPL_MAP_ELEMENTS_review_lenses:-}" "${_TPL_MAP_MAX_review_lenses:-}" \
          "$(template_map_element_persona review_lenses tests)" "$(template_map_element_persona review_lenses correctness)" ) \
        > "$TEST_TEMP_DIR/l3-$_tpl"
    IFS=$'\t' read -r _els _max _pt _pc < "$TEST_TEMP_DIR/l3-$_tpl"
    assert_contains "[L3] $_tpl: the tests lens is in the lens group" ",$_els," ",tests,"
    assert_eq "[L3] $_tpl: ...as the test strategist" "test-strategist" "$_pt"
    assert_eq "[L3] $_tpl: the correctness lens runs as the developer" "developer" "$_pc"
    _n="$(tr ',' '\n' <<< "$_els" | grep -c .)"
    assert_eq "[L3] $_tpl: every lens runs at once" "$_n" "$_max"
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
assert_contains "[R2] the prompt holds the file's text" "$_p" "RULE-NEW: a rule beside vision.md"
assert_contains "[R2] ...naming the file it came from" "$_p" "These are this repository's rules, from its .zbuild/rules.md."
# Every line of a real, many-line rules file reaches the prompt — zBuild's own.
cp "$REPO_ROOT/.zbuild/rules.md" "$RR/.zbuild/rules.md"
_pz="$(_flat "$(_sp_repo_intent_and_rules "$RR" 2>/dev/null)")"; _miss=""
while IFS= read -r _rl; do
    [[ "$_rl" == "- "* ]] || continue
    grep -qF -- "$(_flat "$_rl")" <<< "$_pz" || _miss+="$_rl"$'\n'
done < "$REPO_ROOT/.zbuild/rules.md"
assert_eq "[R2] every rule of zBuild's own file is in the prompt" "" "$_miss"
rm -f "${RR:?}/.zbuild/rules.md"
_p0="$(_flat "$(_sp_repo_intent_and_rules "$RR" 2>/dev/null)")"
assert_contains "[R2] with none, it says so" "$_p0" "This repository has no .zbuild/rules.md, so these are zBuild's default rules."
_lacks "[R2] ...and the old place is not read" "$_p0" "RULE-OLD"

# ── R1b: what the rules reader will read ────────────────────────────────────
print_test_section "R1b: the rules file stays in the repository"
OUTSIDE="$TEST_TEMP_DIR/outside-secret.txt"; printf 'SECRET-OUTSIDE\n' > "$OUTSIDE"
ln -s "$OUTSIDE" "$RR/.zbuild/rules.md"
assert_eq "[R1b] a rules.md that links out of the repository is not read" "" "$(load_repo_rules "$RR" 2>/dev/null)"
rm -f "${RR:?}/.zbuild/rules.md"; ln "$OUTSIDE" "$RR/.zbuild/rules.md"
assert_eq "[R1b] ...nor one hard-linked to a file elsewhere" "" "$(load_repo_rules "$RR" 2>/dev/null)"
rm -f "${RR:?}/.zbuild/rules.md"
printf 'VISION-TEXT\n' > "$RR/.zbuild/vision.md"; ln -s ../vision.md "$RR/.zbuild/prompts/design-overrides.md"
assert_eq "[R1b] a stage's guidance links only within .zbuild/prompts/: one to vision.md is refused" "" \
    "$(load_prompt_override design "$RR" 2>/dev/null)"
rm -f "${RR:?}/.zbuild/prompts/design-overrides.md"
_lacks "[R1b] zBuild's default rules name no old path" "$(cat "$REPO_ROOT/config/prompts/default-rules.md")" ".zbuild/prompts/rules.md"

# ── R3 ───────────────────────────────────────────────────────────────────────
print_test_section "R3: zBuild's own rules file"
_zr="$(_flat "$(cat "$REPO_ROOT/.zbuild/rules.md" 2>/dev/null)")"
for _w in "A remote service is faked at the project's own wrapper around it, never the project's own code" \
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
assert_eq "[R3] CLAUDE.md includes it on a line of its own" "1" "$(grep -cx '@.zbuild/rules.md' "$REPO_ROOT/CLAUDE.md")"
_dup=""
while IFS= read -r _rl; do
    [[ "$_rl" == "- "* ]] || continue
    # Each rule's first sentence, its stop left off: a copy reworded after it still repeats it.
    _first="${_rl#- }"; _first="${_first%%. *}"; _first="${_first%.}"
    grep -qF -- "$_first" "$REPO_ROOT/CLAUDE.md" && _dup+="$_first"$'\n'
done < "$REPO_ROOT/.zbuild/rules.md"
assert_eq "[R3] ...and repeats none of its rules: one source" "" "$_dup"
if [[ -e "$REPO_ROOT/.zbuild/prompts/rules.md" ]]; then assert_fail "[R3] the old file is gone" "$REPO_ROOT/.zbuild/prompts/rules.md"
else assert_pass "[R3] the old file is gone"; fi

# ── R4 ───────────────────────────────────────────────────────────────────────
print_test_section "R4: the docs"
assert_contains "[R4] the configuration page says zbuild reads .zbuild/rules.md" \
    "$(cat "$REPO_ROOT/docs/wiki/Configuration.md")" "### Repository rules (\`.zbuild/rules.md\`)"
_lacks "[R4] ...and names no old path" "$(cat "$REPO_ROOT/docs/wiki/Configuration.md" "$REPO_ROOT/docs/wiki/Writing-Plugins.md")" ".zbuild/prompts/rules.md"

# ── R5 ───────────────────────────────────────────────────────────────────────
print_test_section "R5: the status comment, as the runner starts it"
LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"; GH_BODIES="$TEST_TEMP_DIR/bodies"; mkdir -p "$GH_BODIES" "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; cp "\$f" "$GH_BODIES/body.txt" ;; esac
case "\$args" in
  "auth status"*) exit 0 ;;
  *--paginate*) echo '[]'; exit 0 ;;
  *"-X PATCH"*) echo '{}'; exit 0 ;;
  *issues/*/comments*) echo 4242; exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"; export PATH="$TEST_TEMP_DIR/bin:$PATH"; unset NO_GITHUB
_r5() {   # <repo> — the body the runner's --once posts for <repo>
    local sd="$TEST_TEMP_DIR/r5-state"; rm -rf "${sd:?}" "${GH_BODIES:?}/body.txt"; mkdir -p "$sd"
    # The run's first event, as the engine writes it.
    ( export ZBUILD_EVENTS_DIR="$sd" ZBUILD_EVENTS_JSONL="$sd/events.jsonl" ZBUILD_RUN_ID=r-2630 ZBUILD_ISSUE=90000042 \
          ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
      : > "$ZBUILD_EVENTS_JSONL"
      # shellcheck source=../../core/event-bus/event-bus.sh
      source "$REPO_ROOT/core/event-bus/event-bus.sh"
      emit_event pipeline.start ) >/dev/null 2>&1
    env -u ZBUILD_REPO_ROOT bash "$LIB" --events "$sd/events.jsonl" --state-dir "$sd" --parent-pid $$ \
        --slug testuser/testrepo --issue 90000042 --run-id r-2630 --repo-root "$1" --once >/dev/null 2>&1
    cat "$GH_BODIES/body.txt" 2>/dev/null
}
_b_none="$(_r5 "$RR")"
assert_contains "[R5] (fixture) a body was posted" "$_b_none" "zbuild run"
assert_contains "[R5] no .zbuild/rules.md: the posted comment says so" "$_b_none" \
    "This repository has no rules in \`.zbuild/rules.md\`: every stage was given zBuild's default rules."
: > "$RR/.zbuild/rules.md"
assert_contains "[R5] an empty one: said in the same words, never that the file is missing" "$(_r5 "$RR")" \
    "This repository has no rules in \`.zbuild/rules.md\`: every stage was given zBuild's default rules."
printf -- '- a rule\n' > "$RR/.zbuild/rules.md"
_lacks "[R5] ...with the file, nothing is said" "$(_r5 "$RR")" "rules.md"
# A link is not followed (load_repo_rules: the file must be .zbuild/rules.md
# itself), so the stages got no rules: said so, never silence.
mkdir -p "$RR/docs"; printf -- '- a shared rule\n' > "$RR/docs/rules.md"; rm -f "${RR:?}/.zbuild/rules.md"
ln -s ../docs/rules.md "$RR/.zbuild/rules.md"
# shellcheck source=../../scripts/lib/prompt-overrides.sh
assert_eq "[R5] (fixture) the stages are given no rules from a linked rules.md" "" "$(source "$REPO_ROOT/scripts/lib/prompt-overrides.sh"; load_repo_rules "$RR")"
assert_contains "[R5] a linked rules.md: the posted comment says it was not read" "$(_r5 "$RR")" \
    "This repository's \`.zbuild/rules.md\` is a link, which zBuild does not follow: every stage was given zBuild's default rules."
rm -f "${RR:?}/.zbuild/rules.md"; printf -- '- a rule\n' > "$RR/.zbuild/rules.md"
# The same for a .zbuild that is a link: with a rules.md there, it is not read
# (the file must be .zbuild/rules.md itself); with none, it has no rules.
RR2="$TEST_TEMP_DIR/r5-linked"; mkdir -p "$RR2" "$TEST_TEMP_DIR/shared-zb"; git -C "$RR2" init -q
printf -- '- a shared rule\n' > "$TEST_TEMP_DIR/shared-zb/rules.md"; ln -s "$TEST_TEMP_DIR/shared-zb" "$RR2/.zbuild"
assert_eq "[R5] (fixture) the stages are given no rules from a linked .zbuild" "" "$(source "$REPO_ROOT/scripts/lib/prompt-overrides.sh"; load_repo_rules "$RR2")"
assert_contains "[R5] a linked .zbuild with a rules.md: the comment says it was not read" "$(_r5 "$RR2")" \
    "This repository's \`.zbuild/rules.md\` is a link, which zBuild does not follow: every stage was given zBuild's default rules."
rm -f "${TEST_TEMP_DIR:?}/shared-zb/rules.md"
assert_contains "[R5] a linked .zbuild with none: the comment says it has no rules" "$(_r5 "$RR2")" \
    "This repository has no rules in \`.zbuild/rules.md\`: every stage was given zBuild's default rules."
_lacks "[R5] ...never that it is a link" "$(_r5 "$RR2")" "is a link"

print_test_results
exit $((FAIL > 0))
