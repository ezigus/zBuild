#!/usr/bin/env bash
# tests/unit/lint-verdict-words-test.sh — every verdict word a plugin writes is
# one its manifest declares (#2242), checked before anything runs.
#
# Why: #1838's impact plugin wrote `verdict: broken` on two exits while its
# manifest declared complete|incomplete|error; nothing caught it. The runtime
# reader now fails the stage; this lint catches it in CI, the way
# lint-disposition-words does for dispositions.
#
# W1 [change] a literal verdict the manifest does not declare is refused — in a
#             JSON literal, a jq object, an assignment, and a result writer's
#             second argument
# W2 [guard]  a declared literal passes
# W3 [change] `# verdict-ok: <why>` on the line or the 3 above excuses a literal
#             that is not this plugin's own verdict
# W4 [guard]  a manifest with no declared list is skipped (lint-verdict-classify
#             owns that)
# W5 [change] the real tree passes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "every literal verdict is one the manifest declares (#2242)"
setup_test_env "lint-verdict-words"
LINT="$REPO_ROOT/scripts/lib/lint-verdict-words.sh"

P="$TEST_TEMP_DIR/plugins/agent/x"; mkdir -p "$P"
printf 'id: x\nconfig:\n  valid_verdicts:\n    - pass\n    - fail\n' > "$P/manifest.yaml"
_lint() { bash "$LINT" "$TEST_TEMP_DIR/plugins" >/dev/null 2>&1; echo $?; }

printf '%s\n' "printf '{\"verdict\":\"broken\"}'" > "$P/plugin.sh"
assert_eq "[W1] an undeclared verdict in a JSON literal is refused" "1" "$(_lint)"
printf '%s\n' "jq -n '{result_contract:2,verdict:\"broken\",disposition:\"broken\",reason:\"r\"}'" > "$P/plugin.sh"
assert_eq "[W1] ...in a jq object" "1" "$(_lint)"
printf '%s\n' 'verdict="broken"' > "$P/plugin.sh"
assert_eq "[W1] ...in an assignment" "1" "$(_lint)"
printf '%s\n' '_x_write_result "$dir" "broken" "broken" "input_missing"' > "$P/plugin.sh"
assert_eq "[W1] ...as a result writer's second argument" "1" "$(_lint)"
printf '%s\n' "printf '{\"verdict\":\"fail\"}'" '_x_write_result "$dir" "pass" "complete" "ok"' > "$P/plugin.sh"
assert_eq "[W2] declared literals pass" "0" "$(_lint)"
printf '%s\n' '# verdict-ok: a lens verdict this stage aggregates, not its own' "jq -r 'select(.verdict==\"approve\")'" "printf '{\"verdict\":\"approve\"}'" > "$P/plugin.sh"
assert_eq "[W3] an annotated literal passes" "0" "$(_lint)"
printf 'id: x\nconfig:\n  tier_default: T1\n' > "$P/manifest.yaml"
printf '%s\n' "printf '{\"verdict\":\"broken\"}'" > "$P/plugin.sh"
assert_eq "[W4] a manifest with no declared list is skipped" "0" "$(_lint)"

_real="$(bash "$LINT" 2>&1)"; _real_rc=$?
assert_eq "[W5] the real tree passes" "0" "$_real_rc"
[[ "$_real_rc" -eq 0 ]] || printf '%s\n' "$_real" >&2

cleanup_test_env
print_test_results
exit $((FAIL > 0))
