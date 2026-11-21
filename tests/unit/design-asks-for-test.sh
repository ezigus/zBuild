#!/usr/bin/env bash
# tests/unit/design-asks-for-test.sh — whether a design names a changed file
# (#2575, ADR-036). "Named" is generous: a file the design names anywhere is
# asked for. Only a file it names nowhere is taken out, so a wrong "not asked"
# never deletes real work.
#
# Second review on #2575 (probes d1.md, cov.sh): a partial path, a path in a
# step's description, a markdown link and a shared basename were each read as
# "nothing asks for this", which would tell build to revert asked-for work.
#
# D1 [code]  named in a step's areas: the step's number is given — as a full
#            path, a path suffix on `/` boundaries (build/lib/prompt.sh), in
#            backticks, as file:func, in a markdown link target
# D2 [code]  named in a step's description (not its areas): still the step's
# D3 [code]  a bare basename names every changed file of that name
# D4 [code]  named only outside the steps — a SPEC's words (also a [no-code]
#            SPEC), WIRING, prose, design-steps.json — is named, with no step
# D5 [code]  named nowhere, or by a function name alone, is not named
# D6 [code]  *, ** and *.sh name nothing; config/*.txt names config/a.txt
# D7 [code]  a design with no steps block has no steps (the caller keeps the
#            old rule)
# D8 [code]  the named set must be an associative array; anything else is
#            refused and left as it was
# D9 [code]  design's step writer uses the one parser: a wrapped step's areas
#            reach design-steps.json
# D10 [code] a steps-block line with " | areas:" and no list marker is found
#            (design's check refuses it)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/design-steps.sh
source "$REPO_ROOT/scripts/lib/design-steps.sh"
print_test_header "whether a design names a file (#2575)"
setup_test_env "design-asks-for"

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Rework
We also touch docs/notes.txt along the way.
```steps
- Add the record reader | areas: scripts/lib/stage-notes-version.sh,
  scripts/lib/wrapped.sh
- Wire it into the block | areas: the Previous-work block (stage-previous-work.sh:_stage_block_previous_work)
- Teach build | areas: build/lib/prompt.sh
- Register events | areas: `plugins/tool/test/manifest.yaml`, acceptance_gate_run()
- Update core/router/route.sh and the docs | areas: engine
- Change [the guard](core/pipeline/guard.sh) | areas: [the guard](core/pipeline/guard.sh)
- Lists | areas: config/*.txt
- Tidy | areas: e.sh
- Everything | areas: *, **, *.sh
```
```acceptance
XX-1: When a stage is prompted, Then its notes are marked
XX-2[no-code]: refactor of scripts/lib/digest.sh, no behaviour change
WIRING: scripts/lib/wired.sh
```
MD
printf '{"title":"Rework","steps":[{"id":"step-1","description":"x","areas":["json/only.sh"]}]}\n' \
    > "$TEST_TEMP_DIR/design-steps.json"
declare -a STEPS=(); declare -A WORDS=()
zb_design_named_v STEPS WORDS "$D"
_n() { local v; zb_design_names_v v "$1" STEPS WORDS; printf '%s' "$v"; }

print_test_section "D1/D2: named by a step"
assert_eq "[D1] a full path in the areas" "step:1" "$(_n scripts/lib/stage-notes-version.sh)"
assert_eq "[D1] ...on a wrapped line" "step:1" "$(_n scripts/lib/wrapped.sh)"
assert_eq "[D1] a path suffix, as file:func" "step:2" "$(_n scripts/lib/stage-previous-work.sh)"
assert_eq "[D1] a path suffix on / boundaries" "step:3" "$(_n plugins/agent/build/lib/prompt.sh)"
assert_eq "[D1] ...and not a longer name that only ends the same" "" "$(_n plugins/agent/build/lib/myprompt.sh)"
assert_eq "[D1] in backticks" "step:4" "$(_n plugins/tool/test/manifest.yaml)"
assert_eq "[D1] a markdown link target" "step:6" "$(_n core/pipeline/guard.sh)"
assert_eq "[D2] a path in a step's description" "step:5" "$(_n core/router/route.sh)"

print_test_section "D3: a bare basename"
assert_eq "[D3] names one changed file of that name" "step:8" "$(_n scripts/lib/e.sh)"
assert_eq "[D3] ...and another of the same name" "step:8" "$(_n other/e.sh)"

print_test_section "D4: named outside the steps"
assert_eq "[D4] a [no-code] SPEC's words" "named" "$(_n scripts/lib/digest.sh)"
assert_eq "[D4] WIRING" "named" "$(_n scripts/lib/wired.sh)"
assert_eq "[D4] the design's prose" "named" "$(_n docs/notes.txt)"
assert_eq "[D4] design-steps.json beside the design" "named" "$(_n json/only.sh)"

print_test_section "D5: named nowhere"
assert_eq "[D5] a file the design does not name" "" "$(_n plugins/tool/test/lib/acceptance-check.sh)"
assert_eq "[D5] ...even when one of its functions is named (acceptance_gate_run())" "" \
    "$(_n plugins/tool/test/lib/acceptance-gate.sh)"

print_test_section "D6: patterns"
assert_eq "[D6] *, ** and *.sh name nothing" "" "$(_n other/x.sh)"
assert_eq "[D6] config/*.txt names config/a.txt" "step:7" "$(_n config/a.txt)"

print_test_section "D7: no steps block"
printf '```acceptance\nSPEC-1[code]: x\n```\n' > "$TEST_TEMP_DIR/nosteps.md"
declare -a S7=(); declare -A W7=()
zb_design_named_v S7 W7 "$TEST_TEMP_DIR/nosteps.md"
assert_eq "[D7] no steps are read" "0" "$_ZB_DESIGN_STEP_COUNT"

print_test_section "D8: the named set's type"
declare -a NOTASSOC=(keep)
rc=0; zb_design_named_v STEPS NOTASSOC "$D" || rc=$?
assert_eq "[D8] an indexed array is refused" "2" "$rc"
assert_eq "[D8] ...and left as it was" "keep" "${NOTASSOC[0]}"

print_test_section "D9: one parser"
zb_design_write_steps "$D" "$TEST_TEMP_DIR/written-steps.json"
assert_eq "[D9] the wrapped step's areas reach design-steps.json" \
    "scripts/lib/stage-notes-version.sh,scripts/lib/wrapped.sh" \
    "$(jq -r '.steps[0].areas | join(",")' "$TEST_TEMP_DIR/written-steps.json" 2>/dev/null)"

print_test_section "D10: a step line with no list marker"
printf '# T\n```steps\nAdd a helper | areas: tests/lib/test-helpers.sh\n- do x | areas: a.sh\n```\n' > "$TEST_TEMP_DIR/d2.md"
declare -a UM=()
zb_design_steps_unmarked_v UM "$TEST_TEMP_DIR/d2.md"
assert_eq "[D10] the unmarked line is found" "Add a helper | areas: tests/lib/test-helpers.sh" "${UM[0]:-}"
assert_eq "[D10] ...and only it" "1" "${#UM[@]}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
