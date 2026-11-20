#!/usr/bin/env bash
# tests/unit/design-asks-for-test.sh — what a design asks the change to touch,
# read the one way (#2575, ADR-036): its steps through design's own step parser,
# and its acceptance block's words.
#
# Review on #2575: covers missed real steps (a wrapped line, `file:func`, a path
# inside prose, a bare file name, a path in backticks with a note after it) and
# then told build to take asked-for work out; a bare `*` area covered every file.
#
# D1 [code]  a step's areas cover a file named on a wrapped line, as file:func,
#            anywhere in the area's words, in backticks with a note after it
# D2 [code]  a bare file name covers the one changed file of that name, and
#            none when two changed files share it
# D3 [code]  an acceptance-block word covers a file, with :func and 's taken off;
#            the answer says a SPEC covers it, not a step
# D4 [code]  an area that is only a wildcard, or a pattern with no literal path
#            before it (*, **, *.sh), covers nothing; scripts/*.sh and
#            scripts/[ab].sh cover what they match
# D5 [code]  a step's answer names its number
# D6 [code]  a design with no steps block has no steps: the caller keeps the old
#            rule, and does not guess
# D7 [code]  the asked-for set must be an associative array: anything else is
#            refused, and nothing is written into it
# D8 [code]  design's step writer and every reader use the one parser: the
#            wrapped step's areas reach design-steps.json too
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/design-steps.sh
source "$REPO_ROOT/scripts/lib/design-steps.sh"
print_test_header "what a design asks for (#2575)"
setup_test_env "design-asks-for"

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Rework
```steps
- rework the claim | areas: scripts/lib/a.sh,
  scripts/lib/b.sh
- tidy | areas: scripts/lib/c.sh:zb_fn, the zb_g function in scripts/lib/d.sh, e.sh
- prompt | areas: `plugins/agent/build/lib/prompt.sh` (_build_compose_instructions)
- everything | areas: *, **, *.sh
- some scripts | areas: tools/*.sh, gen/[ab].sh
```
```acceptance
SPEC-1[code]: `scripts/lib/f.sh:zb_f` returns 1; scripts/lib/g.sh's reader works
```
MD
CHANGED=(scripts/lib/a.sh scripts/lib/b.sh scripts/lib/c.sh scripts/lib/d.sh scripts/lib/e.sh
         plugins/agent/build/lib/prompt.sh scripts/lib/f.sh scripts/lib/g.sh other/x.sh tools/t.sh
         gen/a.sh gen/c.sh)
declare -a STEPS=(); declare -A WORDS=()
zb_design_asked_v STEPS WORDS "$D"
_cov() { local v; zb_design_covered_v v "$1" STEPS WORDS CHANGED; printf '%s' "$v"; }

print_test_section "D1/D5: a step's areas"
assert_eq "[D1] a wrapped step line" "step:1" "$(_cov scripts/lib/b.sh)"
assert_eq "[D1] file:func" "step:2" "$(_cov scripts/lib/c.sh)"
assert_eq "[D1] a path inside the area's words" "step:2" "$(_cov scripts/lib/d.sh)"
assert_eq "[D1] in backticks, with a note after it" "step:3" "$(_cov plugins/agent/build/lib/prompt.sh)"
assert_eq "[D5] the first line of step 1" "step:1" "$(_cov scripts/lib/a.sh)"

print_test_section "D2: a bare file name"
assert_eq "[D2] covers the one changed file of that name" "step:2" "$(_cov scripts/lib/e.sh)"
CHANGED+=(other/e.sh)
assert_eq "[D2] ...and none when two changed files share it" "" "$(_cov scripts/lib/e.sh)"

print_test_section "D3: the acceptance block's words"
assert_eq "[D3] a SPEC naming file:func covers the file" "spec" "$(_cov scripts/lib/f.sh)"
assert_eq "[D3] a SPEC naming the file's reader ('s)" "spec" "$(_cov scripts/lib/g.sh)"

print_test_section "D4: wildcards"
assert_eq "[D4] *, ** and *.sh cover nothing" "" "$(_cov other/x.sh)"
assert_eq "[D4] tools/*.sh covers what it matches" "step:5" "$(_cov tools/t.sh)"
assert_eq "[D4] gen/[ab].sh covers gen/a.sh" "step:5" "$(_cov gen/a.sh)"
assert_eq "[D4] ...and not gen/c.sh" "" "$(_cov gen/c.sh)"

print_test_section "D6: no steps block"
printf '```acceptance\nSPEC-1[code]: x\n```\n' > "$TEST_TEMP_DIR/nosteps.md"
declare -a S6=(); declare -A W6=()
zb_design_asked_v S6 W6 "$TEST_TEMP_DIR/nosteps.md"
assert_eq "[D6] no steps are read" "0" "${#S6[@]}"

print_test_section "D7: the asked-for set's type"
declare -a NOTASSOC=(keep)
rc=0; zb_design_asked_v STEPS NOTASSOC "$D" || rc=$?
assert_eq "[D7] an indexed array is refused" "2" "$rc"
assert_eq "[D7] ...and left as it was" "keep" "${NOTASSOC[0]}"

print_test_section "D8: one parser"
zb_design_write_steps "$D" "$TEST_TEMP_DIR/design-steps.json"
assert_eq "[D8] the wrapped step's areas reach design-steps.json" "scripts/lib/a.sh,scripts/lib/b.sh" \
    "$(jq -r '.steps[0].areas | join(",")' "$TEST_TEMP_DIR/design-steps.json" 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
