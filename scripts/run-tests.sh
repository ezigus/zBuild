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
# Optional 3rd arg: a per-invocation trace file. When set, fd 9 is opened to it
# so a child bash with BASH_XTRACEFD=9 (coverage mode — see --coverage-trace
# below) writes its xtrace there. One file per test means parallel workers never
# share one fd-9 handle, which is what corrupted coverage before (#993).
_rt_run() {
  if [[ -n "${3:-}" ]]; then
    "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null 9>"$3" >"$2" 2>&1
  else
    "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null >"$2" 2>&1
  fi
}

# _zb_default_jobs — portable CPU-count for the #984 parallel-by-default path.
# Linux has `nproc`; macOS does not (uses `sysctl -n hw.ncpu`). Falls back to 4
# and caps at 8 so a many-core host doesn't oversubscribe the bounded pool.
_zb_default_jobs() {
  local n
  n="$( { nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null; } | head -1 )"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=4
  (( n > 8 )) && n=8
  printf '%s' "$n"
}

# _rt_tier_budget — total job budget the cross-tier-concurrency path (#997) splits
# between the parallel unit tier and the parallel mutation tier. Defaults to the
# CPU-count budget; ZBUILD_TIER_BUDGET overrides it so the floor/ceil split is
# deterministic in tests regardless of host CPU count.
_rt_tier_budget() {
  if [[ "${ZBUILD_TIER_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$ZBUILD_TIER_BUDGET"
  else
    _zb_default_jobs
  fi
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

# #993: coverage-trace ownership. check-coverage.sh delegates tracing to the
# runner via `--coverage-trace <path>` instead of wiring PS4/BASH_XTRACEFD/
# BASH_ENV itself. When set, the runner turns on xtrace line-tracing for each
# child test bash (PS4 emits `TRACE:<src>:<lineno>:`; BASH_ENV injects `set -x`
# into every child; BASH_XTRACEFD=9 routes it to fd 9), gives EACH test its own
# trace file (so parallel workers never share one fd-9 handle), and merges them
# into <path> at the end. The coverage script stays a dumb consumer.
_RT_COVERAGE_TRACE=""
_rt_expect_cov=0
for _rt_arg in "$@"; do
  if [[ $_rt_expect_cov -eq 1 ]]; then
    # Fail fast on a missing/flag-like value rather than silently mis-parsing
    # `--coverage-trace --tier` as a path, or ignoring a dangling flag (#993 review).
    if [[ -z "$_rt_arg" || "$_rt_arg" == --* ]]; then
      echo "run-tests.sh: --coverage-trace requires a file path argument" >&2
      exit 1
    fi
    _RT_COVERAGE_TRACE="$_rt_arg"; _rt_expect_cov=0; continue
  fi
  [[ "$_rt_arg" == "--coverage-trace" ]] && _rt_expect_cov=1
done
if [[ $_rt_expect_cov -eq 1 ]]; then
  echo "run-tests.sh: --coverage-trace requires a file path argument" >&2
  exit 1
fi
if [[ -n "$_RT_COVERAGE_TRACE" ]]; then
  _RT_BASH_ENV_FILE="$(mktemp -t zbuild-cov-bashenv.XXXXXX)"
  printf 'set -x\n' > "$_RT_BASH_ENV_FILE"
  # shellcheck disable=SC2064
  trap "rm -f '$_RT_BASH_ENV_FILE'" EXIT
  export PS4='TRACE:${BASH_SOURCE[0]-}:${LINENO}:'
  export BASH_XTRACEFD=9
  export BASH_ENV="$_RT_BASH_ENV_FILE"
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

  # #993: in coverage mode each test writes its own per-test trace into this dir;
  # they are merged into $_RT_COVERAGE_TRACE at the end of the tier. Kept separate
  # from the parallel job dir, so it works for both the parallel and serial paths.
  local _cov_dir=""
  if [[ -n "${_RT_COVERAGE_TRACE:-}" ]]; then
    _cov_dir="$(mktemp -d -t "zbuild-cov-$name.XXXXXX")"
  fi

  # Bounded parallel execution when ZBUILD_TEST_PARALLEL_JOBS is set to N > 0.
  # Each job writes its rc and output to a private slot; aggregation is serial
  # after all jobs finish so FAIL lines and the summary stay in a stable order.
  #
  # #983: parallelism is gated to a per-tier allow-list. The integration tier is
  # NOT parallel-safe yet — its route.sh/claude-spawning tests deadlock when run
  # concurrently (the #983 dogfood fork-bomb). #991 makes it safe and widens the
  # list. Non-safe tiers stay serial even when ZBUILD_TEST_PARALLEL_JOBS is set.
  #
  # #984: safe tiers run parallel BY DEFAULT. Distinguish UNSET (→ computed
  # default job count) from an EXPLICIT value (honored as-is; 0 = serial escape
  # hatch) via ${VAR+x}. The default lives here (not in CI/env) so unit also
  # parallelizes in the pipeline test stage, which scrubs ZBUILD_* before npm test.
  local _par_safe_tiers="${ZBUILD_PARALLEL_SAFE_TIERS:-unit}"
  local _par_jobs
  if [[ -z "${ZBUILD_TEST_PARALLEL_JOBS+x}" ]]; then
    _par_jobs="$(_zb_default_jobs)"
  else
    _par_jobs="$ZBUILD_TEST_PARALLEL_JOBS"
  fi
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
        if _rt_run "$f" "${_base}.out" "${_cov_dir:+$_cov_dir/$_slot.trace}"; then
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
    if [[ -n "$_cov_dir" ]]; then
      cat "$_cov_dir"/*.trace > "$_RT_COVERAGE_TRACE" 2>/dev/null || :
      rm -rf "$_cov_dir"
    fi
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
    if _rt_run "$f" "$out" "${_cov_dir:+$_cov_dir/$total.trace}"; then
      passed=$((passed + 1))
      rm -f "$out"
    else
      failed=$((failed + 1))
      echo "$name: FAIL $f" >&2
      cat "$out" >&2 || true
      rm -f "$out"
    fi
  done

  if [[ -n "$_cov_dir" ]]; then
    cat "$_cov_dir"/*.trace > "$_RT_COVERAGE_TRACE" 2>/dev/null || :
    rm -rf "$_cov_dir"
  fi
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
    # #997: concurrency gate. The 5 tiers run concurrently by default so the
    # ~8min mutation tier overlaps the others. ZBUILD_TIER_CONCURRENCY=0 is the
    # serial escape hatch; UPDATE_GOLDEN forces serial because golden-snapshot
    # regeneration mutates shared fixtures and must not race the other tiers.
    _tier_conc=1
    [[ "${ZBUILD_TIER_CONCURRENCY:-1}" == 0 ]] && _tier_conc=0
    [[ "${UPDATE_GOLDEN:-0}" == 1 ]] && _tier_conc=0
    # buf_dir holds each tier's separately-captured stdout/stderr/trace for the
    # concurrent path; empty (and never created) on the serial path.
    buf_dir=""
    # Also clean the coverage BASH_ENV temp file here: this EXIT trap replaces the
    # one the --coverage-trace setup installed above, so fold its cleanup in to
    # avoid leaking that temp file on the `--tier all --coverage-trace` path (#993
    # review). buf_dir cleanup folds in for the #997 concurrent path.
    # Guard the buf_dir cleanup: on the serial path buf_dir is "" and an
    # unguarded `rm -rf ""` errors (and could perturb the trap's exit). The
    # `[[ -z ]] ||` form is a no-op (rc 0) when buf_dir is empty.
    trap 'rm -f "$rc_file" "${_RT_BASH_ENV_FILE:-}"; [[ -z "${buf_dir:-}" ]] || rm -rf "$buf_dir"' EXIT
    if [[ $_tier_conc -eq 1 ]]; then
      # Split the job budget: unit gets floor(B/2), mutation gets the rest. The
      # other three file-tiers run serial within themselves (JOBS=0) — they are
      # short and overlap each other at the tier level, so spending the budget on
      # the two genuinely parallelizable tiers maximizes throughput.
      _B="$(_rt_tier_budget)"
      _ujobs=$(( _B / 2 )); (( _ujobs < 1 )) && _ujobs=1
      _mjobs=$(( _B - _ujobs )); (( _mjobs < 1 )) && _mjobs=1
      buf_dir="$(mktemp -d -t zbuild-tier-buf.XXXXXX)"
      # Launch each tier in its own background subshell. Each writes stdout and
      # stderr to SEPARATE files so they can be replayed to their ORIGINAL fds —
      # run_tier writes its summary to stdout but `name: FAIL <f>` to stderr, so a
      # 2>&1 merge would corrupt byte-parity with the serial path (the #997
      # make-or-break detail). A private TMPDIR per tier avoids cross-tier temp
      # collisions now that tiers run at once — nested UNDER buf_dir so it is
      # portable (mkdir -p, no templateless `mktemp -d` which fails on BSD/macOS)
      # and swept by the EXIT trap (no leak).
      for t in unit integration e2e golden; do
        (
          export TMPDIR="$buf_dir/tmp-$t"; mkdir -p "$TMPDIR"
          if [[ "$t" == unit ]]; then
            export ZBUILD_TEST_PARALLEL_JOBS=$_ujobs
          else
            export ZBUILD_TEST_PARALLEL_JOBS=0
          fi
          # #993: give each tier its OWN private trace file so concurrent tiers
          # never share the merged-trace fd. run_tier merges its per-test traces
          # into this path; the parent concatenates them in canonical order below.
          [[ -n "$_RT_COVERAGE_TRACE" ]] && _RT_COVERAGE_TRACE="$buf_dir/$t.trace"
          if run_tier "$t"; then rc=0; else rc=$?; fi
          echo "$t $rc" >> "$rc_file"
        ) > "$buf_dir/$t.out" 2> "$buf_dir/$t.err" &
      done
      (
        export TMPDIR="$buf_dir/tmp-mutation"; mkdir -p "$TMPDIR"
        export ZBUILD_MUTATION_PARALLEL_JOBS=$_mjobs
        if bash "$SCRIPT_DIR/run-mutation.sh"; then rc=0; else rc=$?; fi
        echo "mutation $rc" >> "$rc_file"
      ) > "$buf_dir/mutation.out" 2> "$buf_dir/mutation.err" &
      wait
    fi
    while IFS= read -r line; do
      echo "$line"
      if [[ "$line" =~ ^[a-z][a-z0-9-]*:\ ([0-9]+)/([0-9]+)\ passed ]]; then
        total_passed=$((total_passed + BASH_REMATCH[1]))
        total_count=$((total_count + BASH_REMATCH[2]))
      fi
    done < <(
      if [[ $_tier_conc -eq 1 ]]; then
        # Replay captured STDOUT in canonical tier order so summary lines + the
        # accumulator sums are byte-identical to the serial path.
        cat "$buf_dir/unit.out" "$buf_dir/integration.out" "$buf_dir/e2e.out" \
            "$buf_dir/golden.out" "$buf_dir/mutation.out"
      else
        for t in unit integration e2e golden; do
          if run_tier "$t"; then rc=0; else rc=$?; fi
          echo "$t $rc" >> "$rc_file"
        done
        if bash "$SCRIPT_DIR/run-mutation.sh"; then rc=0; else rc=$?; fi
        echo "mutation $rc" >> "$rc_file"
      fi
    )
    if [[ $_tier_conc -eq 1 ]]; then
      # Replay captured STDERR (FAIL lines + child output) to fd 2 in canonical
      # order — these streamed live in the serial path and were never buffered.
      for t in unit integration e2e golden mutation; do
        cat "$buf_dir/$t.err" >&2 2>/dev/null || true
      done
      # Concatenate per-tier coverage traces in canonical order (mutation has no
      # trace). Each tier wrote its own private trace → no shared-fd race (#993).
      if [[ -n "$_RT_COVERAGE_TRACE" ]]; then
        cat "$buf_dir"/unit.trace "$buf_dir"/integration.trace \
            "$buf_dir"/e2e.trace "$buf_dir"/golden.trace \
            > "$_RT_COVERAGE_TRACE" 2>/dev/null || :
      fi
    fi
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
