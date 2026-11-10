#!/usr/bin/env bash
# tests/unit/design-block-multiline-test.sh — a requirement or a work step that
# wraps onto the next line is read whole (#2460).
#
# Why: the design's blocks were read one line at a time. A wrapped SPEC lost
# its second line — so ` covers: R-3` or ` evidence: …` there was missed and the
# design failed a check it met — and a wrapped step lost its areas, sending a
# test-file step to build. (#2508: design names no test files, so there are no
# bindings to wrap — B2 and B3 went with them.)
#
# B1 [change] a SPEC whose words carry on to the next line is read whole: its
#             text, its covers and its evidence
# B4 [change] a step whose words or areas carry on to the next line is read whole
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"
print_test_header "a design block's lines that carry on are read whole (#2460)"
setup_test_env "design-block-multiline"
_lacks() { if [[ "$2" == *"$3"* ]]; then assert_fail "$1" "it has: $3"; else assert_pass "$1"; fi; }

D="$TEST_TEMP_DIR/design.md"
cat > "$D" <<'MD'
# Design

```acceptance
SPEC-1[code]: the runner exits 2 when the state file is missing
  and names the file in its error covers: R-3
SPEC-2[done]: results are written atomically
  evidence: scripts/lib/helpers.sh
WIRING: none
```

```steps
- guard the read in the runner and
  report the file | areas: core/a.sh,
  tests/a-test.sh
- update the golden | areas: tests/golden/g.golden
```
MD

assert_eq "[B1] a wrapped SPEC's text is read whole" "the runner exits 2 when the state file is missing and names the file in its error" \
    "$(acceptance_spec_text "$D" SPEC-1)"
assert_eq "[B1] ...its covers on the next line count" "R-3" "$(acceptance_spec_covers "$D" SPEC-1 | xargs)"
assert_eq "[B1] ...and its evidence on the next line" "scripts/lib/helpers.sh" "$(acceptance_spec_evidence "$D" SPEC-2 | xargs)"

(
    source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
    _design_write_steps "$D" "$TEST_TEMP_DIR/steps.json"
)
assert_eq "[B4] a wrapped step's words are read whole" "guard the read in the runner and report the file" \
    "$(jq -r '.steps[0].description' "$TEST_TEMP_DIR/steps.json" 2>/dev/null)"
assert_contains "[B4] ...and its areas on the next line" "$(jq -r '[.steps[].areas[]] | join(",")' "$TEST_TEMP_DIR/steps.json" 2>/dev/null)" "tests/a-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
