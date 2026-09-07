#!/usr/bin/env bash
# Regression guard for #2062: an empty model reply must not become a passing
# correspondence verdict or disappear from the judgment counts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "spec-correspondence unparseable verdicts (#2062)"
setup_test_env "spec-correspondence-unparseable"

export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"
export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ZBUILD_REPO_ROOT" "$ZBUILD_ARTIFACT_DIR"
printf '%s\n' '# design' > "$ZBUILD_ARTIFACT_DIR/design.md"
route_to_model() { return 0; }

# shellcheck source=../../plugins/agent/spec-correspondence/plugin.sh
source "$REPO_ROOT/plugins/agent/spec-correspondence/plugin.sh"

acceptance_list_spec_ids() { printf '%s\n' SPEC-1; }
acceptance_spec_text() { printf '%s' 'The requirement must hold.'; }
acceptance_list_testfiles_for_spec() { printf '%s' 'tests/example.sh'; }
acceptance_find_assertion_sources() { printf '%s' 'assert_eq "[SPEC-1] requirement" 1 1'; }

spec_correspondence_run spec-correspondence "$TEST_TEMP_DIR/state/pipeline-state.json"

result="$ZBUILD_ARTIFACT_DIR/spec-correspondence-result.json"
assert_eq "empty reply is uncheckable" "uncheckable" "$(jq -r .verdict "$result")"
assert_eq "unparseable reply is counted" "1" "$(jq -r .data.uncheckable "$result")"
assert_eq "judgment count is conserved" \
    "judged 1 SPEC(s): 0 correspond, 0 partial, 0 mismatch, 1 uncheckable" \
    "$(jq -r .reason "$result")"

print_test_results
exit $((FAIL > 0))
