#!/usr/bin/env bash
# tests/unit/template-every-stage-io-test.sh — every stage in a shipped
# template declares where its input and output are captured (ADR-015, amended).
#
# A stage with no `io:` block has its capture switched off: no stage-io record,
# nothing in the run log. On #1754's run, test-author's 28 minutes of work left
# no trace in the log while design and build, which declare `io:`, did.
#
#   S1 [change]: in each shipped template, as loaded (inherited stages too),
#                every stage, map group and always-run stage has io.destinations
#   S2 [change]: an always-run stage's destinations are read in block form too,
#                as a flow stage's are (review on #2437)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "every stage in a shipped template declares its capture (ADR-015)"
setup_test_env "template-every-stage-io"

for _tpl in "$REPO_ROOT"/config/templates/*.yaml; do
    _name="$(basename "$_tpl" .yaml)"
    _missing="$(bash -c '
        source "$1/scripts/lib/helpers.sh"; source "$1/core/pipeline/template.sh"
        load_template "$2" >/dev/null 2>&1 || { echo "(the template did not load)"; exit 0; }
        for s in "${_TPL_STAGES[@]}" "${_TPL_ALWAYS_RUN[@]}"; do
            [[ -n "$s" ]] || continue
            [[ -n "$(template_stage_io_dests "$s")" ]] || printf "%s " "$s"
        done' _ "$REPO_ROOT" "$_tpl")"
    assert_eq "S1: $_name.yaml — every stage declares io.destinations" "" "${_missing% }"
done

cat > "$TEST_TEMP_DIR/block.yaml" <<'YAML'
id: block
name: Block
flow:
  - a
always_run:
  - tidy
a:
  roles: [builder]
  io:
    destinations: [file]
tidy:
  roles: [teardown]
  io:
    destinations:
      - file
      - stdout
    tail_lines: 20
YAML
_s2="$(bash -c 'source "$1/scripts/lib/helpers.sh"; source "$1/core/pipeline/template.sh"
    load_template "$2" >/dev/null 2>&1 || { echo "(the template did not load)"; exit 0; }
    printf "%s|%s" "$(template_stage_io_dests tidy | tr "\n" ",")" "$(template_stage_io_tail_lines tidy)"' _ "$REPO_ROOT" "$TEST_TEMP_DIR/block.yaml")"
assert_eq "S2: an always-run stage's block-form destinations are read" "file,stdout,|20" "$_s2"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
