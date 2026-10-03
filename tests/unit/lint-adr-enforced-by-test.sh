#!/usr/bin/env bash
# tests/unit/lint-adr-enforced-by-test.sh — every ADR names the tests that
# enforce it (#2268).
#
# Why: #1844 run 37066147994 passed every gate with a stage the engine never
# reads as v2. The rule it broke (ADR-054 §5) existed only as ADR prose — no
# test enforced it. Rule (Eric, 2026-10-03): every ADR statement has a test. This
# lint makes the rule mechanical: a live ADR carries an `## Enforced by` section
# naming its tests, and every test it names exists. The ADRs written before the
# rule are listed in a baseline that may only shrink.
#
# A1 [change] a live ADR with no `## Enforced by` section, not in the baseline → fail, named
# A2 [change] an `## Enforced by` section naming a test file that does not exist → fail, named
# A3 [guard]  a live ADR whose section names existing tests → pass
# A4 [guard]  a Superseded / Deprecated ADR needs no section
# A5 [change] a baseline entry for an ADR that now has its section → fail (the
#             baseline only shrinks — remove the entry)
# A6 [change] an ADR in the baseline but missing from docs/adr → fail (stale entry)
# A7 [guard]  the real tree passes
# A8 [guard]  the issue form requires the ADR § an issue is based on (written
#             after the form, so no red step is claimed)
# A9 [guard]  an `## Enforced by` section that names no test fails (review on #2281)
# A10 [guard] a superseded ADR still listed in the baseline fails (review on #2281)
# A11 [change] a missing `.github/` or `config/` file named in the section fails
#             too (review on #2281: those were silently skipped)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "every ADR names the tests that enforce it (#2268)"
setup_test_env "lint-adr-enforced-by"

LINT="$REPO_ROOT/scripts/lib/lint-adr-enforced-by.sh"
R="$TEST_TEMP_DIR/repo"
mkdir -p "$R/docs/adr" "$R/tests/unit" "$R/config"
: > "$R/tests/unit/real-test.sh"

_adr() {   # _adr <name> <status> [enforced-by body]
    {
        printf '# %s\n\n**Status:** %s\n\n## Decision\n\nThe engine MUST do X.\n' "$1" "$2"
        [[ $# -ge 3 ]] && printf '\n## Enforced by\n\n%s\n' "$3"
    } > "$R/docs/adr/$1.md"
}
_lint() { out="$(bash "$LINT" "$R" 2>&1)"; rc=$?; }
_reset() { rm -f "$R/docs/adr/"*.md; : > "$R/config/adr-enforcement-baseline.txt"; }

_reset; _adr ADR-901-x "Accepted"; _lint
assert_eq "[A1] a live ADR with no section fails" "1" "$rc"
assert_contains "[A1] the failure names the ADR" "$out" "ADR-901-x"

_reset; _adr ADR-902-x "Accepted" '- §1 → `tests/unit/missing-test.sh`'; _lint
assert_eq "[A2] a named test that does not exist fails" "1" "$rc"
assert_contains "[A2] the failure names the missing file" "$out" "tests/unit/missing-test.sh"

_reset; _adr ADR-903-x "Accepted" '- §1 → `tests/unit/real-test.sh`'; _lint
assert_eq "[A3] a section naming existing tests passes" "0" "$rc"

_reset; _adr ADR-904-x "Superseded by ADR-903"; _adr ADR-905-x "Deprecated"; _lint
assert_eq "[A4] superseded and deprecated ADRs need no section" "0" "$rc"

_reset; _adr ADR-906-x "Accepted" '- §1 → `tests/unit/real-test.sh`'
printf 'ADR-906-x.md\n' > "$R/config/adr-enforcement-baseline.txt"; _lint
assert_eq "[A5] a baseline entry for an ADR that now has its section fails" "1" "$rc"
assert_contains "[A5] it says to remove the entry" "$out" "ADR-906-x.md"

_reset; _adr ADR-907-x "Accepted"
printf 'ADR-907-x.md\nADR-999-gone.md\n' > "$R/config/adr-enforcement-baseline.txt"; _lint
assert_eq "[A6] a baseline entry with no ADR fails" "1" "$rc"
assert_contains "[A6] it names the stale entry" "$out" "ADR-999-gone.md"

_lint_real="$(bash "$LINT" "$REPO_ROOT" 2>&1)"; rc=$?
assert_eq "[A7] the real tree passes" "0" "$rc"
[[ $rc -eq 0 ]] || printf '%s\n' "$_lint_real" | tail -5

# A8: within the form's `id: adr` entry (up to the next `- type:`), `required: true`.
# Plain awk — no YAML library the suite does not already depend on.
FORM="$REPO_ROOT/.github/ISSUE_TEMPLATE/change.yml"
_a8="$(awk '/^[[:space:]]*- type:/{inb=0} /^[[:space:]]*id:[[:space:]]*adr[[:space:]]*$/{inb=1} inb&&/^[[:space:]]*required:[[:space:]]*true/{print "yes"; exit}' "$FORM" 2>/dev/null)"
assert_eq "[A8] the issue form requires the ADR § field" "yes" "$_a8"

_reset; _adr ADR-908-x "Accepted" 'Covered by the unit tests, see the suite.'; _lint
assert_eq "[A9] a section that names no test fails" "1" "$rc"
assert_contains "[A9] it says the section names no test" "$out" "names no test"

_reset; _adr ADR-910-x "Accepted" '- §1 → `tests/unit/real-test.sh`, `.github/ISSUE_TEMPLATE/gone.yml`'; _lint
assert_eq "[A11] a missing .github file named in the section fails" "1" "$rc"
assert_contains "[A11] it names the missing file" "$out" ".github/ISSUE_TEMPLATE/gone.yml"

_reset; _adr ADR-909-x "Superseded by ADR-903"; printf 'ADR-909-x.md\n' > "$R/config/adr-enforcement-baseline.txt"; _lint
assert_eq "[A10] a superseded ADR left in the baseline fails" "1" "$rc"
assert_contains "[A10] it says to remove the entry" "$out" "ADR-909-x.md"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
