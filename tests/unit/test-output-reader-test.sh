#!/usr/bin/env bash
# tests/unit/test-output-reader-test.sh — every failing test file in a suite's
# output reaches a stage, through one shared reader (#2573 R1/R2; ADR-054
# amendment 2026-11-20).
#
# Why: on #1764 run 44782866204, tests/e2e/claim-race-test.sh and the parity
# golden failed in both rounds and no stage was told. The test stage's reader
# matched `^[a-z]+: (FAIL|TIMEOUT)`, so round 1's `e2e: FAIL <path>` (a digit in
# the suite name) was dropped; round 2's targeted rerun printed
# `unit: FAIL tests/e2e/...` (a relative path), which it also dropped.
#
# TR1 [R1] round 1: every failing file (unit + two e2e, absolute staging paths
#          in each of the staging dir's spellings) is a finding, with its reason
# TR2 [R1] round 2: both relative-path failing files are findings
# TR3 [R1] the red set (the files the next rerun targets) holds every failing
#          file of both rounds, repo-relative
# TR4 [R1] the failing files' own output reaches the error channel for all of them
# TR5 [R1] a forgiving read: FAIL/TIMEOUT in any case, colour codes, a carriage
#          return, leading spaces and a ✗ marker, a suite name with digits, `_`
#          and `-`; a TIMEOUT's suffix is not part of the path; a FAIL with no
#          path (`lint: FAIL (npm run lint)`) names no file
# TR6 [R1] the runner summary counts every failing file of the forgiving output
# TR7 [R2] no code outside the shared reader reads `<suite>: FAIL <path>` or
#          `<suite>: N/M passed` with a pattern of its own
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "every failing test file reaches a stage (#2573)"
setup_test_env "test-output-reader"

# shellcheck source=../../plugins/tool/test/lib/parse.sh
source "$REPO_ROOT/plugins/tool/test/lib/parse.sh"
# shellcheck source=../../plugins/tool/test/lib/findings.sh
source "$REPO_ROOT/plugins/tool/test/lib/findings.sh"
# shellcheck source=../../plugins/tool/test/lib/report.sh
source "$REPO_ROOT/plugins/tool/test/lib/report.sh"

T="$TEST_TEMP_DIR/stage"; mkdir -p "$T"
T_PHYS="$(cd "$T" && pwd -P)"
U=plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh
RACE=tests/e2e/claim-race-test.sh
PAR=tests/e2e/parity-local-vs-ci-test.sh

# #1764 run 44782866204, iter-1 test-output.log: the lines a reader needs, the
# staging path replaced — by the logical, physical and doubled-slash spellings.
ROUND1="$(cat <<EOF

> zbuild@0.1.0 test
> bash tests/run-all.sh

unit: FAIL $T/$U

  plugin: claim-coordinator/github-labels — local-fs backend

  ✓ claim_coordinator_claim → rc=0
  ✗ claimed label contains 'claimed:' prefix
    zbuild:claimed

  1 of 36 tests failed

unit: 615/616 passed (5 skipped)
integration: 264/264 passed
e2e: FAIL $T_PHYS/$RACE

  claim-coordinator race (ADR-005, issue #308)

  ✓ 3-way race: no backend errors
  ✗ 3-way race must produce ≤1 winner
    got 3 winners

  1 of 9 tests failed

e2e: FAIL ${T}//$PAR

  CI/CLI parity — engine behavior is environmentally agnostic (ADR-010)

  ✓ artifact filename list matches golden snapshot

  1 of 15 tests failed

  ✗ event sequence matches golden snapshot

e2e: 8/10 passed
golden: 1/1 passed
lint: 1/1 passed

total: 914/917 passed (5 skipped)
EOF
)"

# iter-2 test-output.log: the targeted rerun prints relative paths.
ROUND2="$(cat <<EOF
unit: FAIL $RACE

  claim-coordinator race (ADR-005, issue #308)

  ✗ 3-way race must produce ≤1 winner
    got 3 winners

  1 of 9 tests failed

unit: FAIL $PAR

  ✓ stage_statuses identical in local and CI modes
  ✗ event sequence matches golden snapshot
    golden mismatch (run UPDATE_GOLDEN=1 to regenerate)

  1 of 15 tests failed

unit: 14/16 passed
EOF
)"

_files() { jq -r '[.[].file] | sort | join(",")' <<< "$1" 2>/dev/null; }
_reason() { jq -r --arg f "$2" '.[] | select(.file == $f) | .reason' <<< "$1" 2>/dev/null; }

print_test_section "TR1: round 1 — every failing file is a finding"
F1="$(_test_failure_findings "$ROUND1" "$T")"
assert_eq "[TR1] the unit file and both e2e files" "$U,$RACE,$PAR" "$(_files "$F1")"
assert_contains "[TR1] claim-race's reason is its failing check" "$(_reason "$F1" "$RACE")" "3-way race must produce"
assert_contains "[TR1] parity's reason is its failing check" "$(_reason "$F1" "$PAR")" "event sequence matches golden snapshot"

print_test_section "TR2: round 2 — relative paths are findings"
F2="$(_test_failure_findings "$ROUND2" "$T")"
assert_eq "[TR2] both relative-path files" "$RACE,$PAR" "$(_files "$F2")"
assert_contains "[TR2] claim-race's reason is its failing check" "$(_reason "$F2" "$RACE")" "3-way race must produce"

print_test_section "TR3: the red set holds every failing file"
assert_eq "[TR3] round 1, repo-relative" "$(printf '%s\n' "$U" "$RACE" "$PAR" | sort)" "$(_test_extract_failing_files "$ROUND1" "$T")"
assert_eq "[TR3] round 2" "$(printf '%s\n' "$RACE" "$PAR" | sort)" "$(_test_extract_failing_files "$ROUND2" "$T")"

print_test_section "TR4: every failing file's own output reaches the error channel"
B1="$(_test_extract_failing_blocks "$ROUND1")"
assert_contains "[TR4] claim-race's output" "$B1" "got 3 winners"
assert_contains "[TR4] parity's output" "$B1" "event sequence matches golden snapshot"

print_test_section "TR5: a forgiving read"
ESC=$'\033'
FORGIVE="$(printf '%s\n' \
    "${ESC}[31mE2E: fail $RACE${ESC}[0m"$'\r' \
    "  ✗ 3-way race must produce ≤1 winner" \
    "   ✗ integration_2-x: FAIL $T/$PAR" \
    "  ✗ event sequence matches golden snapshot" \
    "unit: Timeout $U (exceeded 480s, rc=124)" \
    "lint: FAIL (npm run lint)" \
    "unit: 1/4 passed")"
F5="$(_test_failure_findings "$FORGIVE" "$T")"
assert_eq "[TR5] every failing file, whatever the case, colour, marker or suite name" "$U,$RACE,$PAR" "$(_files "$F5")"
assert_contains "[TR5] the TIMEOUT says it timed out" "$(_reason "$F5" "$U")" "timed out"
assert_eq "[TR5] the red set of the forgiving output" "$(printf '%s\n' "$U" "$RACE" "$PAR" | sort)" "$(_test_extract_failing_files "$FORGIVE" "$T")"

print_test_section "TR6: the summary counts every failing file"
IFS='|' read -r _v _p _f _s <<< "$(_test_pattern_runall "$FORGIVE" 1)"
assert_eq "[TR6] four failing markers (three files and lint)" "4" "$_f"
IFS='|' read -r _v _p _f _s <<< "$(_test_pattern_runall "$ROUND1" 1)"
assert_eq "[TR6] round 1: three failing files" "3" "$_f"

print_test_section "TR7: no stage reads test output with a pattern of its own"
_off=""
while IFS= read -r _path; do
    case "$_path" in
        scripts/lib/test-output-read.sh|scripts/run-tests.sh) continue ;;  # the reader; the writer
        tests/*|plugins/*/*/tests/*|legacy-DoNotUse/*) continue ;;
    esac
    while IFS= read -r _l; do
        [[ "$_l" =~ ^[0-9]+:[[:space:]]*# ]] && continue
        _off+="$_path:$_l"$'\n'
    done < <(/usr/bin/grep -nF -e 'FAIL|TIMEOUT' -e '/[0-9]+ passed' "$REPO_ROOT/$_path" 2>/dev/null || true)
done < <(git -C "$REPO_ROOT" ls-files -- 'core/*.sh' 'scripts/*.sh' 'plugins/*.sh')
assert_eq "[TR7] no reader of its own outside scripts/lib/test-output-read.sh" "" "$_off"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
