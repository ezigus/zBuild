#!/usr/bin/env bash
# Unit (ADR-065 §1): the process census runs on any command, not only the
# budget's mocked run.
#
# The budget (tests/e2e/fork-budget-test.sh) counts one mocked pipeline run:
# 4,808 programs. A single test file can start 20,000 because it runs the same
# engine paths many times, and nothing showed that. `tests/lib/fork-census.sh
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
# SPEC-5: the words inside an assigned value (xtrace quotes them) are data,
#         never commands (#1842; was fork-budget-test.sh SPEC-1b).
# SPEC-6: a line marked `# fork-budget-exempt: <why>` is not counted (listed
#         apart instead); an unmarked line in the same loop still is (#2236).
#         How often a wait loop sleeps measures elapsed time, not code — under
#         load the same tree counted 4,528 and 4,610 (was fork-budget SPEC-5).
# SPEC-7: each process the trace names is named by its id and the time it
#         first traced, so a process id the system reuses during a run (it
#         does under a busy full suite: macOS wrapped its ids every ~30 s)
#         counts as the two processes it is (#2575: 457 a dispatch under load,
#         465 alone); a bash that replaces a process by exec is still that one
#         (was fork-budget SPEC-1c).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "fork census: count the programs any command starts (ADR-065 §1)"
setup_test_env "fork-census"

CENSUS="$REPO_ROOT/tests/lib/fork-census.sh"
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
    # shellcheck source=../../tests/lib/fork-census.sh
    source "$CENSUS"
    fork_census_traced "$TEST_TEMP_DIR/c.trace" bash "$CANARY"
    fork_census_count "$TEST_TEMP_DIR/c.trace" "$TEST_TEMP_DIR/c.sites"
)"
assert_eq "[SPEC-2] fork_census_count of the canary" "1" "$_n"

print_test_section "SPEC-3: one counter"
_budget="$REPO_ROOT/tests/e2e/fork-budget-test.sh"
if grep -q 'tests/lib/fork-census.sh' "$_budget" && ! grep -qE '^_fb_count\(\)' "$_budget"; then
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
    # shellcheck source=../../tests/lib/fork-census.sh
    source "$CENSUS"
    fork_census_traced "$TEST_TEMP_DIR/s.trace" bash "$SUBSH"
    printf '%s|%s' "$(fork_census_count "$TEST_TEMP_DIR/s.trace" "$TEST_TEMP_DIR/s.sites")" \
        "$(fork_census_processes "$TEST_TEMP_DIR/s.trace" 2>/dev/null)"
)"
assert_eq "[SPEC-4] one program; three processes (the script, \$(f), \$(dirname))" "1|3" "$_pr"

# shellcheck source=../../tests/lib/fork-census.sh
source "$CENSUS"

print_test_section "SPEC-5: an assignment's value is not a command"
# xtrace prints `v='review lens: security'` for an assignment whose value has
# spaces. The words inside the quotes are data; `security` is a binary on macOS,
# and 178 phantom execs per site were counted from such values (#1842).
QUOTED="$TEST_TEMP_DIR/quoted.sh"
cat > "$QUOTED" <<'QEOF'
#!/usr/bin/env bash
v="first ls second"
w='x cat y'
z=$'a\tmkdir b'
QEOF
fork_census_traced "$TEST_TEMP_DIR/quoted.trace" bash "$QUOTED"
assert_eq "[SPEC-5] words inside an assigned value are not counted" "0" \
    "$(fork_census_count "$TEST_TEMP_DIR/quoted.trace" "$TEST_TEMP_DIR/quoted.sites")"

print_test_section "SPEC-6: a marked wait is not counted"
WAITER="$TEST_TEMP_DIR/waiter.sh"
cat > "$WAITER" <<'WEOF'
#!/usr/bin/env bash
for _ in 1 2 3; do
    sleep 0  # fork-budget-exempt: canary wait
    sleep 0
done
WEOF
fork_census_traced "$TEST_TEMP_DIR/waiter.trace" bash "$WAITER"
_waiter_n="$(fork_census_count "$TEST_TEMP_DIR/waiter.trace" "$TEST_TEMP_DIR/waiter.sites")"
assert_eq "[SPEC-6] only the unmarked sleep is counted (3 of 6)" "3" "$_waiter_n"
assert_contains "[SPEC-6] …the marked one is listed apart" \
    "$(cat "$TEST_TEMP_DIR/waiter.sites.exempt" 2>/dev/null)" "waiter.sh:3"$'\t'"sleep"

print_test_section "SPEC-7: a process is its id and the time it first traced"
fork_census_traced "$TEST_TEMP_DIR/ids.trace" bash -c 'x=1; ( y=2 ); z=3'
_ids="$(awk '/^\++@/ { p = $0; sub(/@ .*$/, "", p); sub(/^.*#/, "", p); print p }' "$TEST_TEMP_DIR/ids.trace" | sort -u)"
assert_eq "[SPEC-7] the shell and its subshell are two processes" "2" "$(grep -c . <<< "$_ids")"
_short=0
while IFS= read -r _id; do (( ${#_id} > 10 )) || _short=1; done <<< "$_ids"
assert_eq "[SPEC-7] …each named by more than its id (the time it first traced)" "0" "$_short"
fork_census_traced "$TEST_TEMP_DIR/exec.trace" bash -c 'x=1; exec bash -c "y=2"'
assert_eq "[SPEC-7] a bash that replaces a shell by exec is still one process" "1" \
    "$(fork_census_processes "$TEST_TEMP_DIR/exec.trace")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
