#!/usr/bin/env bash
# tests/unit/result-outcome-readers-test.sh — every reader of a result sees a
# contract-3 outcome (#2366, ADR-054 §6).
#
# Until #2364 and #2368 remove them, a few stages read other results' verdicts.
# A stage that moves to contract 3 writes `outcome`, not `verdict`, so each of
# those readers must read the outcome first or it misreads the moved stage.
#
#   R1/R2 retired with gate-aggregator (#2368)
#   R3 [guard]  no stage reads `.verdict` from a result without `.outcome`
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every reader of a result sees a contract-3 outcome (#2366)"
setup_test_env "result-outcome-readers"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

print_test_section "R3: no reader of .verdict without .outcome"
# A stage model's own reply may carry a `verdict` key (monitor's report); that
# is the model's answer, not a result, and is exempt by its line.
_bad="$(cd "$REPO_ROOT" && /usr/bin/grep -rnE "jq[^|]*'[^']*\.verdict\b" plugins --include='*.sh' \
        | /usr/bin/grep -v '/tests/' | /usr/bin/grep -v '\.outcome' \
        | /usr/bin/grep -v 'schema_version == 1 and (.verdict|type=="string")' \
        | /usr/bin/grep -v 'report_json' || true)"
assert_eq "[R3] every .verdict read also reads .outcome" "" "$_bad"

print_test_section "R4: the template tests outcomes, not stage words"
# Every stage reports pass or fail, so a cycle's exit rule tests those and
# nothing else (#2366): `ne uncovered` was always true once spec-coverage wrote
# outcomes, and the design cycle would exit without checking coverage.
for _t in "$REPO_ROOT"/config/templates/*.yaml; do
    _bad_v="$(/usr/bin/grep -oE 'field: verdict, op: (eq|ne), value: [a-z_]+' "$_t" \
        | /usr/bin/grep -vE 'value: (pass|fail)$' || true)"
    assert_eq "[R4] $(basename "$_t"): exit rules test only pass or fail" "" "$_bad_v"
done

print_test_section "R5: a stage whose fail must not stop the run says so in the template"
# hydrate restores earlier work; restoring less than all of it is reported as
# fail, and must not end the run (it was a warning before #2366).
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh" >/dev/null 2>&1
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1 || true
assert_eq "[R5] hydrate does not block" "false" "$(template_stage_blocking hydrate 2>/dev/null)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
