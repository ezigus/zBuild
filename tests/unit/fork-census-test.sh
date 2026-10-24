#!/usr/bin/env bash
# Unit (ADR-065 §1): the process census runs on any command, not only the
# budget's mocked run.
#
# The budget (tests/e2e/fork-budget-test.sh) counts one mocked pipeline run:
# 4,808 programs. A single test file can start 20,000 because it runs the same
# engine paths many times, and nothing showed that. `scripts/lib/fork-census.sh
# <cmd...>` runs a command under the same trace and prints its count, its top
# call sites and its per-file totals, so a slow test can be measured before and
# after a fix.
#
# SPEC-1: the census of a script with exactly one external program says 1 and
#         names its line.
# SPEC-2: a library function can be counted on its own: fork_census_traced and
#         fork_census_count are callable after sourcing the file.
# SPEC-3: the budget test counts with this file, so there is one counter.
# SPEC-4: fork_census_processes counts every process the command ran bash in —
#         the command itself, each `$( )` subshell (a copy of the whole shell,
#         which fork_census_count cannot see) and each subshell that execs a
#         program — and the program count is unchanged by it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "fork census: count the programs any command starts (ADR-065 §1)"
setup_test_env "fork-census"

CENSUS="$REPO_ROOT/scripts/lib/fork-census.sh"
CANARY="$TEST_TEMP_DIR/canary.sh"
cat > "$CANARY" <<'EOF'
#!/usr/bin/env bash
x="$(dirname /a/b)"
y="${x%/*}"
printf '%s\n' "$y" >/dev/null
EOF

print_test_section "SPEC-1: the census of a command"
_out="$(bash "$CENSUS" bash "$CANARY" 2>&1)" || true
assert_contains "[SPEC-1] the canary's one dirname is the whole count" "$_out" "external execs: 1 "
assert_contains "[SPEC-1] …and its line is named" "$_out" "canary.sh:2"

print_test_section "SPEC-2: the functions, sourced"
_n="$(
    # shellcheck source=../../scripts/lib/fork-census.sh
    source "$CENSUS"
    fork_census_traced "$TEST_TEMP_DIR/c.trace" bash "$CANARY"
    fork_census_count "$TEST_TEMP_DIR/c.trace" "$TEST_TEMP_DIR/c.sites"
)"
assert_eq "[SPEC-2] fork_census_count of the canary" "1" "$_n"

print_test_section "SPEC-3: one counter"
_budget="$REPO_ROOT/tests/e2e/fork-budget-test.sh"
if grep -q 'scripts/lib/fork-census.sh' "$_budget" && ! grep -qE '^_fb_count\(\)' "$_budget"; then
    assert_pass "[SPEC-3] the budget test sources the census and keeps no copy of the counter"
else
    assert_fail "[SPEC-3] the budget test sources the census and keeps no copy of the counter" "$_budget"
fi

print_test_section "SPEC-4: shell processes"
SUBSH="$TEST_TEMP_DIR/subsh.sh"
cat > "$SUBSH" <<'EOF'
#!/usr/bin/env bash
f() { printf 'x'; }
a="$(f)"
b="$(dirname /a/b)"
c="${a}${b}"
EOF
_pr="$(
    # shellcheck source=../../scripts/lib/fork-census.sh
    source "$CENSUS"
    fork_census_traced "$TEST_TEMP_DIR/s.trace" bash "$SUBSH"
    printf '%s|%s' "$(fork_census_count "$TEST_TEMP_DIR/s.trace" "$TEST_TEMP_DIR/s.sites")" \
        "$(fork_census_processes "$TEST_TEMP_DIR/s.trace" 2>/dev/null)"
)"
assert_eq "[SPEC-4] one program; three processes (the script, \$(f), \$(dirname))" "1|3" "$_pr"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
