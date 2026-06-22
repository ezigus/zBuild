#!/usr/bin/env bash
# Tests: scripts/run-tests.sh --coverage-trace produces a correct, STABLE merged
# trace under the PARALLEL unit tier (#993, EPIC #982).
#
# Before #993, coverage forced the unit tier serial: parallel workers all
# inherited one fd-9 handle and clobbered the shared trace file, so coverage
# under parallel was corrupt/undercounted. The runner now gives each test its own
# per-worker trace file and merges them. This test proves the merged set of
# traced (file,line) pairs is (1) non-empty, (2) identical across two parallel
# runs (stable, not racy), and (3) identical to the serial baseline (no undercount
# vs serial). It is load-bearing: the --coverage-trace capability does not exist
# at baseline, and a shared-fd implementation would fail SPEC-2/SPEC-3.
#
# SPEC-1  parallel --coverage-trace produces a non-empty traced (file,line) set
# SPEC-2  two parallel runs yield the IDENTICAL traced set (stable, not racy)
# SPEC-3  parallel traced set == serial baseline set (parallel == serial)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_TESTS="$REPO_ROOT/scripts/run-tests.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "coverage trace parallel-safety (#993)"
setup_test_env "coverage-parallel-safety"

# Hermetic fake unit tier: deterministic straight-line tests so every run executes
# the SAME set of lines (the coverage signal). ZBUILD_TESTS_DIR isolates it from
# the real suite AND exempts the #983 re-entrancy guard. 6 files so the parallel
# pool (jobs=4) actually overlaps workers.
FAKE_TESTS="$TEST_TEMP_DIR/fake-tests"
EMPTY_DIR="$TEST_TEMP_DIR/empty"
mkdir -p "$FAKE_TESTS/unit" "$EMPTY_DIR"
for i in 1 2 3 4 5 6; do
  cat > "$FAKE_TESTS/unit/cov-${i}-test.sh" <<'EOF'
#!/usr/bin/env bash
_a=1
_b=$(( _a + 1 ))
_c=$(( _b * 2 ))
printf '%s\n' "$_c" >/dev/null
EOF
  chmod +x "$FAKE_TESTS/unit/cov-${i}-test.sh"
done

# _trace_set <jobs> <out_trace> — run the fake unit tier with --coverage-trace at
# the given parallelism, then emit the SORTED-UNIQUE set of TRACE:<src>:<lineno>
# prefixes for the fake test files (the coverage-relevant attribution; the trailing
# command text is ignored, and the per-run bash-env injector path is excluded by
# matching only cov-N-test.sh).
_trace_set() {
  local jobs="$1" tr="$2"
  env -u ZBUILD_PARALLEL_SAFE_TIERS \
      ZBUILD_TESTS_DIR="$FAKE_TESTS" \
      ZBUILD_PLUGINS_DIR="$EMPTY_DIR" \
      ZBUILD_CORE_DIR="$EMPTY_DIR" \
      ZBUILD_TEST_PARALLEL_JOBS="$jobs" \
      bash "$RUN_TESTS" --tier unit --coverage-trace "$tr" >/dev/null 2>&1 || true
  grep -oE '^TRACE:[^:]*/cov-[0-9]+-test\.sh:[0-9]+:' "$tr" 2>/dev/null | sort -u
}

P1="$TEST_TEMP_DIR/p1.trace"; P2="$TEST_TEMP_DIR/p2.trace"; S0="$TEST_TEMP_DIR/s0.trace"
set_p1="$(_trace_set 4 "$P1")"
set_p2="$(_trace_set 4 "$P2")"
set_s0="$(_trace_set 0 "$S0")"

# ─── [SPEC-1] parallel coverage trace is non-empty (mechanism actually captured) ─
if [[ -n "$set_p1" ]]; then
  assert_pass "[SPEC-1] parallel --coverage-trace produced a non-empty traced set"
else
  assert_fail "[SPEC-1] parallel --coverage-trace produced a non-empty traced set" \
    "no TRACE: lines for cov-*-test.sh in $P1"
fi

# ─── [SPEC-2] two parallel runs produce the IDENTICAL traced set (stable) ──────
assert_eq "[SPEC-2] two parallel coverage runs yield the identical traced (file,line) set" \
  "$set_p1" "$set_p2"

# ─── [SPEC-3] parallel set == serial baseline (parallel is as correct as serial) ─
assert_eq "[SPEC-3] parallel traced set matches the serial baseline (no undercount)" \
  "$set_s0" "$set_p1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
