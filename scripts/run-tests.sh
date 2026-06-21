#!/usr/bin/env bash
# Per-tier test runner. Usage: scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,all}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="${ZBUILD_TESTS_DIR:-$REPO_ROOT/tests}"
PLUGINS_DIR="${ZBUILD_PLUGINS_DIR:-$REPO_ROOT/plugins}"
CORE_DIR="${ZBUILD_CORE_DIR:-$REPO_ROOT/core}"

# #929: per-file isolation so a non-test or hanging file can never wedge the run
# (a markdown mutation spec executed as bash blocked on stdin for 3.5h in a
# #911 dogfood). Bounds EACH individual test-file invocation in both the
# --files and tier loops — NOT the mutation orchestrator, which is a separate
# long-running invocation. Override the bound via ZBUILD_TEST_FILE_TIMEOUT
# (seconds; 0 disables). Degrades to no-timeout when neither gtimeout nor
# timeout is installed (best-effort, same convention as core/router/route.sh).
_RT_FILE_TIMEOUT="${ZBUILD_TEST_FILE_TIMEOUT:-300}"
_rt_tout=()
if [[ "$_RT_FILE_TIMEOUT" != "0" ]]; then
  if   command -v gtimeout >/dev/null 2>&1; then _rt_tout=("gtimeout" "$_RT_FILE_TIMEOUT")
  elif command -v timeout  >/dev/null 2>&1; then _rt_tout=("timeout"  "$_RT_FILE_TIMEOUT")
  fi
fi

# _rt_run <test_file> <out_file> — run one test file in isolation:
#   - stdin from /dev/null  → a file that reads stdin gets EOF, never blocks
#   - fd 3 → /dev/null      → #586 stage-io load-time guard (LOAD-BEARING)
#   - time-bounded          → a hung/looping file is killed (rc 124/137/143),
#                             which lands in the caller's failure branch (the
#                             honest outcome for a hang), never an infinite wait
# Returns the child's exit code.
_rt_run() {
  "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null >"$2" 2>&1
}

# #846: targeted subset mode — run ONLY the given files (each in its own process,
# so a failing file never blocks the rest — no `&&` short-circuit), emitting the
# same `unit: N/M passed` + `unit: FAIL <f>` format run_tier uses. This keeps the
# build_test_cycle targeted re-run's output format identical to the full run, so
# the test plugin's verdict parser and red-set extractor recognise it.
if [[ "${1:-}" == "--files" ]]; then
  shift
  _tf_passed=0; _tf_failed=0; _tf_total=0
  for _tf in "$@"; do
    [[ -n "$_tf" ]] || continue
    # #929: only execute *-test.sh files. The targeted-rerun list can include
    # grep-referenced non-tests (mutation *.md specs, fixtures, sourced helpers)
    # that error or HANG when run as bash. Skip them BEFORE the count so the
    # `unit: N/M passed` denominator only reflects real tests.
    if [[ "$_tf" != *-test.sh ]]; then
      echo "skip non-test: $_tf" >&2
      continue
    fi
    _tf_total=$((_tf_total + 1))
    _tf_out="$(mktemp -t zbuild-test-targeted.XXXXXX)"
    if _rt_run "$_tf" "$_tf_out"; then
      _tf_passed=$((_tf_passed + 1)); rm -f "$_tf_out"
    else
      _tf_failed=$((_tf_failed + 1)); echo "unit: FAIL $_tf" >&2; cat "$_tf_out" >&2 || true; rm -f "$_tf_out"
    fi
  done
  echo "unit: $_tf_passed/$_tf_total passed"
  [[ $_tf_failed -eq 0 ]] && exit 0 || exit 1
fi

# #983 re-entrancy guard: refuse a nested REAL-tier run (no fixture override)
# while already inside a run-tests.sh invocation. A test that runs the real suite
# would otherwise fork-bomb the run (the #983 dogfood failure mode). Fixture-
# isolated nested calls set ZBUILD_TESTS_DIR and are exempt. The var name has NO
# leading underscore so env-scrub's ^(ZBUILD_|_TPL_) clears it at every fresh-
# user-shell boundary (the pipeline test stage) — avoiding a stale-value false
# refusal. The --files targeted path above is exempt (it exits before here).
if [[ -n "${ZBUILD_RUN_TESTS_ACTIVE:-}" && -z "${ZBUILD_TESTS_DIR:-}" ]]; then
  echo "run-tests.sh: refusing nested real-tier invocation (re-entrancy guard #983)" >&2
  exit 2
fi
export ZBUILD_RUN_TESTS_ACTIVE=1

tier="${1:-}"
if [[ "$tier" == "--tier" ]]; then
  tier="${2:-all}"
fi

run_tier() {
  local name="$1"
  local dir="$TESTS_DIR/$name"
  local passed=0 failed=0 total=0

  local files=()

  # Collect tests from the flat tests/<tier>/ directory (if it exists)
  if [[ -d "$dir" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$dir" -maxdepth 1 -name '*-test.sh' -print0 2>/dev/null)
  fi

  # Collect co-located plugin tests from plugins/*/*/tests/
  # Convention: *-unit-test.sh => unit tier; other *-test.sh => integration tier
  if [[ "$name" == "unit" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$PLUGINS_DIR" -path '*/tests/*-unit-test.sh' -print0 2>/dev/null | sort -z)
  elif [[ "$name" == "integration" ]]; then
    while IFS= read -r -d '' f; do
      [[ "$f" == *-unit-test.sh ]] && continue
      files+=("$f")
    done < <(find "$PLUGINS_DIR" -path '*/tests/*-test.sh' -print0 2>/dev/null | sort -z)
  fi

  # Collect co-located core/ module tests from core/*/tests/
  # Same tier convention: *-unit-test.sh => unit; other *-test.sh => integration
  if [[ "$name" == "unit" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$CORE_DIR" -path '*/tests/*-unit-test.sh' -print0 2>/dev/null | sort -z)
  elif [[ "$name" == "integration" ]]; then
    while IFS= read -r -d '' f; do
      [[ "$f" == *-unit-test.sh ]] && continue
      files+=("$f")
    done < <(find "$CORE_DIR" -path '*/tests/*-test.sh' -print0 2>/dev/null | sort -z)
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "$name: 0/0 passed (empty tier)"
    return 0
  fi

  # Bounded parallel execution when ZBUILD_TEST_PARALLEL_JOBS is set to N > 0.
  # Each job writes its rc and output to a private slot; aggregation is serial
  # after all jobs finish so FAIL lines and the summary stay in a stable order.
  #
  # #983: parallelism is gated to a per-tier allow-list. The integration tier is
  # NOT parallel-safe yet — its route.sh/claude-spawning tests deadlock when run
  # concurrently (the #983 dogfood fork-bomb). #991 makes it safe and widens the
  # list. Non-safe tiers stay serial even when ZBUILD_TEST_PARALLEL_JOBS is set.
  local _par_safe_tiers="${ZBUILD_PARALLEL_SAFE_TIERS:-unit}"
  local _par_jobs="${ZBUILD_TEST_PARALLEL_JOBS:-0}"
  case " $_par_safe_tiers " in *" $name "*) : ;; *) _par_jobs=0 ;; esac
  if [[ "$_par_jobs" =~ ^[1-9][0-9]*$ ]]; then
    # Test hook (#983): signal the parallel path was taken so tests can assert
    # activation directly rather than infer it from counts. Never set in production.
    [[ -n "${_ZBUILD_PAR_ACTIVE_FILE:-}" ]] && printf '%s\n' "$name" >> "${_ZBUILD_PAR_ACTIVE_FILE}"
    local _job_dir
    _job_dir="$(mktemp -d -t "zbuild-par-$name.XXXXXX")"
    local -a _pids=()
    local _slot=0
    for f in "${files[@]}"; do
      _slot=$((_slot + 1))
      local _base="$_job_dir/$_slot"
      printf '%s' "$f" > "${_base}.file"
      (
        if _rt_run "$f" "${_base}.out"; then
          printf '0' > "${_base}.rc"
          # Success: aggregation only reads .out for FAILED slots, so drop it now
          # — parity with the serial path, keeps the job dir small (#1011 review).
          rm -f "${_base}.out"
        else
          printf '%s' "$?" > "${_base}.rc"
        fi
      ) &
      _pids+=($!)
      # Drain the OLDEST slot when the pool is full (FIFO). #1011 review suggested
      # `wait -n` for tighter utilization, but that needs bash 4.3+ and macOS ships
      # bash 3.2 — FIFO drain is the portable choice and still bounds concurrency
      # to $_par_jobs. Test files are short + uniform, so head-of-line stall is
      # negligible here; revisit with `wait -n` if a bash-4 floor is adopted.
      if [[ ${#_pids[@]} -ge $_par_jobs ]]; then
        wait "${_pids[0]}" 2>/dev/null || true
        _pids=("${_pids[@]:1}")
      fi
    done
    # drain remaining background jobs
    for _pid in "${_pids[@]}"; do
      wait "$_pid" 2>/dev/null || true
    done
    # serial aggregation in submission order
    local _i
    for _i in $(seq 1 $_slot); do
      total=$((total + 1))
      local _rc _file
      _rc=$(cat "$_job_dir/$_i.rc" 2>/dev/null || printf '1')
      _file=$(cat "$_job_dir/$_i.file" 2>/dev/null || printf 'unknown')
      if [[ "$_rc" -eq 0 ]]; then
        passed=$((passed + 1))
      else
        failed=$((failed + 1))
        echo "$name: FAIL $_file" >&2
        cat "$_job_dir/$_i.out" >&2 || true
      fi
    done
    rm -rf "$_job_dir"
    echo "$name: $passed/$total passed"
    [[ $failed -eq 0 ]]
    return
  fi

  for f in "${files[@]}"; do
    total=$((total + 1))
    # Capture once into a tempfile; replay on failure. Avoids the
    # double-execution side effects (state writes, event emits) of the
    # previous "run silent, then re-run on fail to show output" pattern.
    local out
    out="$(mktemp -t "zbuild-test-$name.XXXXXX")"
    # _rt_run keeps fd 3 → /dev/null so any sourced module that respects
    # ZBUILD_STAGE_IO_FD=3 (the production runner default — see
    # core/pipeline/runner.sh:869) finds the fd open for write. Without this,
    # stage-io.sh's load-time guard would abort sourcing for every test that
    # pulls in that module under the unit harness (#586). It also bounds the
    # run with a per-file timeout + stdin guard (#929).
    if _rt_run "$f" "$out"; then
      passed=$((passed + 1))
      rm -f "$out"
    else
      failed=$((failed + 1))
      echo "$name: FAIL $f" >&2
      cat "$out" >&2 || true
      rm -f "$out"
    fi
  done

  echo "$name: $passed/$total passed"
  [[ $failed -eq 0 ]]
}

case "$tier" in
  unit|integration|e2e|golden)
    run_tier "$tier"
    ;;
  mutation)
    bash "$SCRIPT_DIR/run-mutation.sh"
    ;;
  all)
    overall_rc=0
    total_passed=0
    total_count=0
    # Per-tier rc is written to this file from inside the subshell so an
    # aborted runner (no summary line emitted) is still reflected in the
    # overall exit code — relying only on parsed totals would mask infra
    # errors that crash before the "name: P/T passed" line prints.
    rc_file="$(mktemp -t zbuild-tier-rc.XXXXXX)"
    trap 'rm -f "$rc_file"' EXIT
    while IFS= read -r line; do
      echo "$line"
      if [[ "$line" =~ ^[a-z][a-z0-9-]*:\ ([0-9]+)/([0-9]+)\ passed ]]; then
        total_passed=$((total_passed + BASH_REMATCH[1]))
        total_count=$((total_count + BASH_REMATCH[2]))
      fi
    done < <(
      for t in unit integration e2e golden; do
        if run_tier "$t"; then rc=0; else rc=$?; fi
        echo "$t $rc" >> "$rc_file"
      done
      if bash "$SCRIPT_DIR/run-mutation.sh"; then rc=0; else rc=$?; fi
      echo "mutation $rc" >> "$rc_file"
    )
    while read -r _name rc; do
      [[ "$rc" -ne 0 ]] && overall_rc=1
    done < "$rc_file"
    if [[ $total_passed -ne $total_count ]]; then
      overall_rc=1
    fi
    echo
    echo "total: $total_passed/$total_count passed"
    exit $overall_rc
    ;;
  *)
    echo "Usage: $0 --tier {unit,integration,e2e,golden,mutation,all}" >&2
    exit 1
    ;;
esac
