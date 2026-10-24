#!/usr/bin/env bash
# tests/unit/run-tests-schedule-test.sh — how a tier's pool orders its work
# (ADR-065; the suite took 519s locally, set by integration's tail).
#
# Integration ran its serial-pinned files first, one after another (141s), and
# only then started the pool, which took files alphabetically, so a 180s file
# could start last. Simulated from the timing log: 521s → about 330s.
#
# SPEC-1 CHANGE  the pool starts files longest-first by tests/test-durations.tsv
#                (ZBUILD_TEST_DURATIONS_FILE); a file with no recorded time
#                starts before every recorded one
# SPEC-2 CHANGE  serial-pinned files run in their own lane while the pool runs
# SPEC-3 GUARD   …still one at a time
# SPEC-4 GUARD   the summary and FAIL lines are what they were: counts, and FAIL
#                lines in file order, not start order
# SPEC-5 GUARD   with no durations file the pool takes files in file order
# SPEC-6 CHANGE  scripts/lib/test-durations.sh <timing-log> <out> writes the file
#                from a ZBUILD_TEST_TIMING_FILE log: whole seconds, repo-relative,
#                longest first, the slowest record kept when a file ran twice
# SPEC-7 CHANGE  every file of a run sees one ZBUILD_DISCOVERY_MEMO_DIR, so a
#                plugin-discovery walk is paid once per run, not once per file;
#                the directory is gone after the run
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-tests.sh pool order: longest first, pinned files in their own lane"
setup_test_env "run-tests-schedule"

FAKE="$TEST_TEMP_DIR/fake-tests"; EMPTY="$TEST_TEMP_DIR/empty"
LOG="$TEST_TEMP_DIR/events.log"
mkdir -p "$FAKE/unit" "$EMPTY"
# Each fixture file logs `start <name>` and `end <name>` with a clock, sleeping
# its given seconds in between; a `fail` file exits 1.
_mk() {   # <name> <sleep> [fail]
    local rc=0; [[ "${3:-}" == fail ]] && rc=1
    cat > "$FAKE/unit/$1-test.sh" <<EOF
#!/usr/bin/env bash
printf 'start %s %s\n' "$1" "\$EPOCHREALTIME" >> '$LOG'
sleep $2
printf 'end %s %s\n' "$1" "\$EPOCHREALTIME" >> '$LOG'
exit $rc
EOF
    chmod +x "$FAKE/unit/$1-test.sh"
}
_mk a 0; _mk b 0; _mk c 0; _mk d 0 fail; _mk new 0
_mk p1 1.5; _mk p2 0.5 fail

DUR="$TEST_TEMP_DIR/durations.tsv"
printf '10\t%s\n30\t%s\n20\t%s\n5\t%s\n' \
    "$FAKE/unit/a-test.sh" "$FAKE/unit/c-test.sh" "$FAKE/unit/b-test.sh" "$FAKE/unit/d-test.sh" > "$DUR"

_run() {   # [env assignments...]
    : > "$LOG"
    env -u ZBUILD_TEST_PARALLEL_JOBS -u ZBUILD_SERIAL_TESTS -u ZBUILD_TEST_DURATIONS_FILE -u ZBUILD_DISCOVERY_MEMO_DIR \
        ZBUILD_TESTS_DIR="$FAKE" ZBUILD_PLUGINS_DIR="$EMPTY" ZBUILD_CORE_DIR="$EMPTY" \
        ZBUILD_TEST_PARALLEL_JOBS=1 ZBUILD_SERIAL_TESTS='p1-test.sh p2-test.sh' \
        "$@" bash "$RUN_TESTS" --tier unit > "$TEST_TEMP_DIR/out" 2> "$TEST_TEMP_DIR/err" || true
}
# Pool start order: the non-pinned names in the order they started.
_pool_order() { awk '$1 == "start" && $2 !~ /^p[0-9]/ { printf "%s ", $2 }' "$LOG" | sed 's/ $//'; }
_t() { awk -v e="$1" -v n="$2" '$1 == e && $2 == n { print $3 }' "$LOG"; }

print_test_section "SPEC-1: longest first"
_run ZBUILD_TEST_DURATIONS_FILE="$DUR"
assert_eq "[SPEC-1] with one worker the pool starts the unrecorded file, then 30s, 20s, 10s, 5s" \
    "new c b a d" "$(_pool_order)"

print_test_section "SPEC-2/3: the pinned lane"
_p1s="$(_t start p1)"; _p1e="$(_t end p1)"; _p2s="$(_t start p2)"
_first_pool="$(awk '$1 == "start" && $2 !~ /^p[0-9]/ { print $3; exit }' "$LOG")"
if [[ -n "$_p1e" && -n "$_first_pool" ]] && awk -v a="$_first_pool" -v b="$_p1e" 'BEGIN { exit !(a < b) }'; then
    assert_pass "[SPEC-2] the pool starts while a pinned file is still running"
else
    assert_fail "[SPEC-2] the pool starts while a pinned file is still running" "$(cat "$LOG")"
fi
if [[ -n "$_p2s" && -n "$_p1e" ]] && awk -v a="$_p2s" -v b="$_p1e" 'BEGIN { exit !(a >= b) }'; then
    assert_pass "[SPEC-3] the second pinned file starts only after the first ends"
else
    assert_fail "[SPEC-3] the second pinned file starts only after the first ends" "$(cat "$LOG")"
fi

print_test_section "SPEC-4: what it reports"
assert_contains "[SPEC-4] the summary counts every file" "$(cat "$TEST_TEMP_DIR/out")" "unit: 5/7 passed"
assert_eq "[SPEC-4] FAIL lines are in file order, whatever order the files ran in" \
    "d-test.sh p2-test.sh" "$(grep -oE 'FAIL [^ ]+' "$TEST_TEMP_DIR/err" | sed 's|.*/||' | tr '\n' ' ' | sed 's/ $//')"

print_test_section "SPEC-5: no durations file"
_run ZBUILD_TEST_DURATIONS_FILE="$TEST_TEMP_DIR/absent.tsv"
assert_eq "[SPEC-5] the pool takes files in file order" "a b c d new" "$(_pool_order)"

print_test_section "SPEC-6: the durations file is written from a timing log"
_tl="$TEST_TEMP_DIR/timing.log"
printf 'file 1500 %s/tests/unit/x-test.sh\ncpu 1 2 %s/tests/unit/x-test.sh\nfile 120400 %s/tests/integration/y-test.sh\ntier 900 unit\nfile 2600 %s/tests/unit/x-test.sh\nfile 300 /elsewhere/z-test.sh\n' \
    "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" "$REPO_ROOT" > "$_tl"
bash "$REPO_ROOT/scripts/lib/test-durations.sh" "$_tl" "$TEST_TEMP_DIR/gen.tsv" 2>/dev/null
assert_eq "[SPEC-6] seconds, repo-relative, longest first, slowest record per file, others dropped" \
    "$(printf '120\ttests/integration/y-test.sh\n2\ttests/unit/x-test.sh')" "$(cat "$TEST_TEMP_DIR/gen.tsv" 2>/dev/null)"

print_test_section "SPEC-7: one discovery memo for the run"
for _n in m1 m2; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${ZBUILD_DISCOVERY_MEMO_DIR:-unset}" >> "%s"\n' "$TEST_TEMP_DIR/memo.log" > "$FAKE/unit/$_n-test.sh"
    chmod +x "$FAKE/unit/$_n-test.sh"
done
: > "$TEST_TEMP_DIR/memo.log"
_run ZBUILD_TEST_DURATIONS_FILE="$DUR"
_md="$(sort -u "$TEST_TEMP_DIR/memo.log")"
assert_eq "[SPEC-7] both files saw the same, set memo directory" "1|set" \
    "$(grep -c . <<< "$_md" || true)|$([[ -n "$_md" && "$_md" != unset ]] && echo set || echo "$_md")"
assert_eq "[SPEC-7] …which is removed after the run" "gone" "$([[ -n "$_md" && "$_md" != unset && ! -e "$_md" ]] && echo gone || echo "present:$_md")"
rm -f "$FAKE/unit/m1-test.sh" "$FAKE/unit/m2-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
