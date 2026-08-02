#!/usr/bin/env bash
# Per-tier test runner. Usage: scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,lint,all}
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
# #1157: default 300→480. The spawn-heavy core-pipeline-runner suite (un-gated
# onto macOS) legitimately needs ~300s on the slow shared macOS runner, leaving
# no headroom for runner-speed variance. 480 gives margin without masking a real
# hang (a genuinely wedged file still fails, just later). Overridable as before.
_RT_FILE_TIMEOUT="${ZBUILD_TEST_FILE_TIMEOUT:-480}"
# #1660: plain `timeout` sends TERM only, so a file that traps or ignores TERM
# outruns its bound entirely. `-k` escalates to KILL after a grace period
# (ZBUILD_TEST_KILL_GRACE, default 10s), making the bound real; worst-case
# per-file wall-clock becomes _RT_FILE_TIMEOUT + the grace. The flag is probed,
# not assumed — a `timeout` that lacks it would exit 125 on every single file
# rather than running it, so an unsupporting binary degrades to the TERM-only
# bound instead of failing the suite.
_RT_KILL_GRACE="${ZBUILD_TEST_KILL_GRACE:-10}"
_rt_tout=()
if [[ "$_RT_FILE_TIMEOUT" != "0" ]]; then
  _rt_tout_bin=""
  if   command -v gtimeout >/dev/null 2>&1; then _rt_tout_bin="gtimeout"
  elif command -v timeout  >/dev/null 2>&1; then _rt_tout_bin="timeout"
  fi
  if [[ -n "$_rt_tout_bin" ]]; then
    if "$_rt_tout_bin" -k 1 1 true >/dev/null 2>&1; then
      _rt_tout=("$_rt_tout_bin" "-k" "$_RT_KILL_GRACE" "$_RT_FILE_TIMEOUT")
    else
      _rt_tout=("$_rt_tout_bin" "$_RT_FILE_TIMEOUT")
    fi
  fi
fi

# _rt_is_timeout_rc <rc> — true when the rc is the shape a killed file exits
# with (#1613). 124 = GNU timeout/gtimeout gave up; 137 = SIGKILL (128+9);
# 143 = SIGTERM (128+15), which is what the file sees when `timeout` signals it.
# A test that deliberately exits one of these is indistinguishable — accepted:
# the bound is the far likelier cause, and mislabelling a hang as an assertion
# failure is the failure mode this exists to stop.
_rt_is_timeout_rc() {
  case "${1:-}" in 124|137|143) return 0 ;; *) return 1 ;; esac
}

# _rt_report_failure <tier> <file> <rc> <out_file> — emit the one-line marker for
# a non-passing file, then replay its captured output (#1613).
#
# A bound-exceeded file gets `TIMEOUT` naming the bound instead of `FAIL`, and its
# output is fenced with a warning: those assertions ran against a process being
# torn down, so they are noise, not findings. Conflating the two is what made
# #1609 unsolvable — two investigations chased fabricated assertion failures that
# were only a timeout, one of them filing a bogus durability bug against
# core/state/atomic.sh.
#
# The marker SHAPE is load-bearing: plugins/tool/test/lib/parse.sh matches
# `^<tier>: (FAIL|TIMEOUT) <path>` for its failure count, its failing-suite list,
# and the red set that drives targeted rerun. Changing either side alone breaks
# the other.
_rt_report_failure() {
  local _name="$1" _file="$2" _rc="$3" _out="$4"
  if _rt_is_timeout_rc "$_rc"; then
    echo "$_name: TIMEOUT $_file (exceeded ${_RT_FILE_TIMEOUT}s, rc=$_rc)" >&2
    echo "--- output below ran against a process being killed at its time bound;" >&2
    echo "--- any assertion failures in it are UNTRUSTWORTHY (#1613) ---" >&2
  else
    echo "$_name: FAIL $_file" >&2
  fi
  [[ -n "$_out" && -f "$_out" ]] && { cat "$_out" >&2 || true; }
  return 0
}

# _rt_run <test_file> <out_file> — run one test file in isolation:
#   - stdin from /dev/null  → a file that reads stdin gets EOF, never blocks
#   - fd 3 → /dev/null      → #586 stage-io load-time guard (LOAD-BEARING)
#   - time-bounded          → a hung/looping file is killed (rc 124/137/143),
#                             which lands in the caller's failure branch (the
#                             honest outcome for a hang), never an infinite wait
#                             — reported as TIMEOUT, not FAIL (#1613)
# Returns the child's exit code.
# Optional 3rd arg: a per-invocation trace file. When set, fd 9 is opened to it
# so a child bash with BASH_XTRACEFD=9 (coverage mode — see --coverage-trace
# below) writes its xtrace there. One file per test means parallel workers never
# share one fd-9 handle, which is what corrupted coverage before (#993).
_rt_run() {
  # #1058 Phase A: per-test-file wall-clock instrumentation. Entirely gated on
  # ZBUILD_TEST_TIMING_FILE being set+non-empty — when unset this function's
  # behavior + output is byte-identical to the pre-#1058 version (the parallel
  # path's byte-identical-output guarantee depends on this). EPOCHREALTIME is a
  # bash builtin (free, no fork) so the unset-path cost is two var reads. The
  # timing append never affects the test rc (`|| true`) — instrumentation must
  # never turn a green run red.
  if [[ -z "${ZBUILD_TEST_TIMING_FILE:-}" ]]; then
    if [[ -n "${3:-}" ]]; then
      "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null 9>"$3" >"$2" 2>&1
    else
      "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null >"$2" 2>&1
    fi
    return
  fi
  local _t0 _t1 _rc=0
  _t0="$EPOCHREALTIME"
  if [[ -n "${3:-}" ]]; then
    "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null 9>"$3" >"$2" 2>&1 || _rc=$?
  else
    "${_rt_tout[@]}" bash "$1" </dev/null 3>/dev/null >"$2" 2>&1 || _rc=$?
  fi
  _t1="$EPOCHREALTIME"
  # One small line per file → atomic under POSIX (< PIPE_BUF) so concurrent
  # pool workers `>>`-appending the shared file never interleave a line.
  awk -v t0="$_t0" -v t1="$_t1" -v p="$1" \
    'BEGIN { d = (t1 - t0) * 1000; if (d < 0) d = 0; printf "file %d %s\n", d, p }' \
    >> "$ZBUILD_TEST_TIMING_FILE" 2>/dev/null || true
  return "$_rc"
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
  _tf_passed=0; _tf_failed=0; _tf_total=0; _tf_timedout=0
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
    # #1239: the targeted-rerun list is an ADVISORY hint. A path that does not
    # resolve against the current tree (e.g. a stale absolute path into a
    # destroyed per-iter temp dir) must be SKIPPED — executing `bash <missing>`
    # would surface a bogus "No such file" FAIL and inflate the failure count
    # (the #945 dogfood 5->10 phantom-failure bug). Skip before the count so the
    # denominator reflects only resolvable tests.
    if [[ ! -f "$_tf" ]]; then
      echo "skip missing: $_tf" >&2
      continue
    fi
    _tf_total=$((_tf_total + 1))
    _tf_out="$(mktemp -t zbuild-test-targeted.XXXXXX)"
    _tf_rc=0
    _rt_run "$_tf" "$_tf_out" || _tf_rc=$?
    if [[ "$_tf_rc" -eq 0 ]]; then
      _tf_passed=$((_tf_passed + 1)); rm -f "$_tf_out"
    else
      _tf_failed=$((_tf_failed + 1))
      _rt_is_timeout_rc "$_tf_rc" && _tf_timedout=$((_tf_timedout + 1))
      _rt_report_failure "unit" "$_tf" "$_tf_rc" "$_tf_out"
      rm -f "$_tf_out"
    fi
  done
  echo "unit: $_tf_passed/$_tf_total passed$( [[ $_tf_timedout -gt 0 ]] && printf ' (%d timed out)' "$_tf_timedout" )"
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

# #991 serial-pin escape hatch: basename globs of integration tests that MUST
# stay serial even though the tier is parallel-safe by default. EMPTY by default
# — the #989/#990 hermeticity work made all 150 integration tests parallel-safe.
# Populate ONLY when the 10× stability run proves a specific file flakes under
# concurrency, each entry with a one-line reason comment. ZBUILD_SERIAL_TESTS
# (space/newline-separated basename globs) merges with this array at runtime so
# an operator can pin a file without editing source.
# #991: these integration tests assert a TIGHT wall-clock budget (signal-abort
# latency / kill-mid-run timing, 4–8s) that is only reliable on an un-saturated
# host. They pass serially (the 170/170 baseline) but fail when the parallel pool
# runs 8 heavy tests at once and CPU saturation stretches signal delivery + runner
# startup past the budget. Pinned to the serial bucket so they run un-loaded after
# the pool. (Follow-up: make the budgets load-tolerant so they can parallelize.)
_ZBUILD_SERIAL_PIN=(
  'core-pipeline-runner-test.sh'        # sleep-stub + kill-mid-run timing (~193s)
  'compound-quality-pipeline-test.sh'   # heavy full-pipeline timing under load
  'full-pipeline-sigint-test.sh'        # asserts pipeline halts within 6–8s
  'sigint-aborts-pipeline-test.sh'      # asserts total wall-clock < 4s
  'sigterm-aborts-pipeline-test.sh'     # asserts wall-clock <= 5s
  'manifest-sync-similarity-test.sh'    # MS5 asserts manifest mtime preserved — wall-clock/mtime sensitive under load (CI #1047)
  'gh-automation-idempotency-log-test.sh' # #1425: unconditional sleep 1 in G8 mtime assertion — load-sensitive under a saturated unit pool
)

# _rt_is_serial_pinned <basename> — true if the basename matches any pin glob
# from _ZBUILD_SERIAL_PIN or the ZBUILD_SERIAL_TESTS env override.
_rt_is_serial_pinned() {
    local base="$1" glob
    # `set -f` for the loop word-split: ZBUILD_SERIAL_TESTS is intentionally
    # split on whitespace into globs, but must NOT undergo pathname expansion —
    # an unquoted pin like `*-test.sh` would otherwise expand to matching files
    # in the CWD before being used as a pattern. noglob disables that expansion
    # only; it does NOT affect the `[[ "$base" == $glob ]]` pattern match below.
    local _had_noglob=0
    [[ $- == *f* ]] && _had_noglob=1
    set -f
    for glob in "${_ZBUILD_SERIAL_PIN[@]+"${_ZBUILD_SERIAL_PIN[@]}"}" ${ZBUILD_SERIAL_TESTS:-}; do
        [[ -n "$glob" ]] || continue
        # shellcheck disable=SC2053
        if [[ "$base" == $glob ]]; then
            [[ "$_had_noglob" -eq 0 ]] && set +f
            return 0
        fi
    done
    [[ "$_had_noglob" -eq 0 ]] && set +f
    return 1
}

# _rt_run_serial_file <tier> <file> <cov_dir> — run one test file serially,
# updating the caller's passed/failed/total. Factored so both the serial path
# and the parallel path's serial-pin bucket share one body (#991).
_rt_run_serial_file() {
    local name="$1" f="$2" cov_dir="$3"
    total=$((total + 1))
    local out rc=0
    out="$(mktemp -t "zbuild-test-$name.XXXXXX")"
    _rt_run "$f" "$out" "${cov_dir:+$cov_dir/s$total.trace}" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        passed=$((passed + 1))
        rm -f "$out"
    else
        failed=$((failed + 1))
        _rt_is_timeout_rc "$rc" && timedout=$((timedout + 1))
        _rt_report_failure "$name" "$f" "$rc" "$out"
        rm -f "$out"
    fi
}

# #1063 follow-up: emit a tier summary, appending "(N skipped)" when test files
# reported platform/capability skips during this tier (e.g. #996's
# skip_on_platform macos). A skipped file exits 0 and is tallied as a pass, so
# without this the gating is invisible ("172/172 passed" on every platform). The
# suffix is appended AFTER the "P/T passed" token so existing parsers (the
# build_test_cycle verdict parser, the --tier all aggregation) are unaffected.
# Reads and clears the per-tier ZBUILD_TEST_SKIP_LOG.
# #1613: a 4th arg carries the tier's timeout count. Appended to the SAME
# parenthetical as the skip note, AFTER the "P/T passed" token, so the
# `^<name>: N/M passed` anchor every parser keys on is untouched — a timed-out
# file must never be mistakable for an ordinary assertion failure in the summary.
_rt_emit_summary() {
    local _name="$1" _passed="$2" _total="$3" _to="${4:-0}" _sk=0 _note=""
    if [[ -n "${ZBUILD_TEST_SKIP_LOG:-}" && -f "${ZBUILD_TEST_SKIP_LOG}" ]]; then
        # NB: `grep -c` PRINTS "0" and EXITS non-zero on zero matches, so the old
        # `|| echo 0` appended a SECOND "0" → "0\n0" → an arithmetic syntax error
        # below whenever the skip log existed but was empty (0 skips in the tier,
        # e.g. once core-pipeline-runner stopped skipping on macOS, #1157). Use
        # `|| true` (grep already emitted the "0") + a default for a missing read.
        _sk="$(grep -c . "$ZBUILD_TEST_SKIP_LOG" 2>/dev/null || true)"
        rm -f "$ZBUILD_TEST_SKIP_LOG"
    fi
    # Built by concatenation, NOT `IFS=', '` + "${arr[*]}": that join uses only
    # the FIRST character of IFS, so two notes rendered as "(1 skipped,1 timed out)"
    # with no space. Only observable when a tier has both in one run.
    [[ "${_sk:-0}" -gt 0 ]] && _note="$_sk skipped"
    [[ "${_to:-0}" -gt 0 ]] && _note="${_note:+$_note, }$_to timed out"
    [[ -n "$_note" ]] && _note=" ($_note)"
    echo "$_name: $_passed/$_total passed$_note"
}

# #1058 Phase A: append one `tier <ms> <name>` line for a finished tier. Gated on
# ZBUILD_TEST_TIMING_FILE; no-op + zero output when unset (preserves byte-identical
# default behavior). Never affects the caller's rc (`|| true`). <t0> is the
# EPOCHREALTIME captured at run_tier entry.
_rt_emit_tier_time() {
    local _name="$1" _t0="$2"
    [[ -n "${ZBUILD_TEST_TIMING_FILE:-}" ]] || return 0
    local _t1="$EPOCHREALTIME"
    awk -v t0="$_t0" -v t1="$_t1" -v n="$_name" \
        'BEGIN { d = (t1 - t0) * 1000; if (d < 0) d = 0; printf "tier %d %s\n", d, n }' \
        >> "$ZBUILD_TEST_TIMING_FILE" 2>/dev/null || true
}

run_tier() {
  local name="$1"
  local dir="$TESTS_DIR/$name"
  local passed=0 failed=0 total=0 timedout=0

  # #1058 Phase A: per-tier wall-clock. Captured at entry, emitted just before
  # each return (parallel + serial paths) via _rt_emit_tier_time. Gated on
  # ZBUILD_TEST_TIMING_FILE so the unset-path is byte-identical to pre-#1058.
  local _rt_tier_t0="$EPOCHREALTIME"

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
    _rt_emit_tier_time "$name" "$_rt_tier_t0"
    return 0
  fi

  # #1063 follow-up: per-tier skip log. Each test file's print_test_results
  # appends its basename here when it ends in a SKIP (skip_on_platform / capability
  # gate). Exported so the spawned test processes inherit it; read + cleared by
  # _rt_emit_summary at the end of this tier. Per-tier (not global) so concurrent
  # tiers in `--tier all` don't cross-count.
  export ZBUILD_TEST_SKIP_LOG; ZBUILD_TEST_SKIP_LOG="$(mktemp -t "zbuild-skip-$name.XXXXXX")"

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
  # #983: parallelism is gated to a per-tier allow-list. Non-safe tiers stay
  # serial even when ZBUILD_TEST_PARALLEL_JOBS is set.
  #
  # #991: the integration tier is now parallel-safe and is in the default
  # allow-list. The #983 fork-bomb (route.sh/claude-spawning tests deadlocking
  # under concurrency) is resolved by per-test isolation: #989 gives every test
  # its own HOME/state/events dir, and #990 fixes the repo-write/tmp/worktree
  # races. A static survey found all 150 integration tests safe; the empirical
  # 10× stability proof gates the merge. The _ZBUILD_SERIAL_PIN escape hatch
  # (top of file) re-pins any file that later proves flaky.
  #
  # #984: safe tiers run parallel BY DEFAULT. Distinguish UNSET (→ computed
  # default job count) from an EXPLICIT value (honored as-is; 0 = serial escape
  # hatch) via ${VAR+x}. The default lives here (not in CI/env) so the tiers also
  # parallelize in the pipeline test stage, which scrubs ZBUILD_* before npm test.
  local _par_safe_tiers="${ZBUILD_PARALLEL_SAFE_TIERS:-unit integration}"
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
    # #991: partition out serial-pinned files (basename matches an escape-hatch
    # glob). The pinned ones run serially FIRST — on an UNLOADED machine, before
    # the pool saturates all cores — because they are pinned precisely for being
    # wall-clock/timing sensitive (running them after the pool stressed a slow CI
    # runner is what flaked full-pipeline-sigint on #1047). The rest run through
    # the FIFO pool. With no pins (default) _serial_files is empty → all files run
    # parallel and output is byte-identical to the pre-#991 behaviour.
    local -a _parallel_files=() _serial_files=()
    for f in "${files[@]}"; do
      if _rt_is_serial_pinned "$(basename "$f")"; then
        _serial_files+=("$f")
      else
        _parallel_files+=("$f")
      fi
    done
    # Serial-pin bucket FIRST (unloaded). Trace files use the `s<n>` prefix; the
    # pool uses `p<n>` — distinct namespaces, so order never collides traces.
    for f in "${_serial_files[@]+"${_serial_files[@]}"}"; do
      # Test hook (#991): record serial-bucket routing so a test can prove a
      # pinned file ran HERE, not in the pool. Mirrors _ZBUILD_PAR_ACTIVE_FILE.
      [[ -n "${_ZBUILD_SERIAL_ACTIVE_FILE:-}" ]] && printf '%s\n' "$(basename "$f")" >> "${_ZBUILD_SERIAL_ACTIVE_FILE}"
      _rt_run_serial_file "$name" "$f" "$_cov_dir"
    done
    local _job_dir
    _job_dir="$(mktemp -d -t "zbuild-par-$name.XXXXXX")"
    local -a _pids=()
    local _slot=0
    local _inflight=0
    # #991: reap ANY finished slot via `wait -n` (bash 4.3+) instead of draining
    # the OLDEST. A long test in the oldest slot (e.g. core-pipeline-runner ~193s)
    # otherwise head-of-line-blocks the whole pool — capping the integration tier's
    # parallel speedup at ~1.85x instead of ~5.5x. Falls back to drain-oldest on
    # bash < 4.3. Aggregation below reads results BY SUBMISSION SLOT, so completion
    # order never changes the output (#1011 review; this repo floors at bash 5).
    local _waitn=0
    if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 ) )); then
      _waitn=1
    fi
    for f in "${_parallel_files[@]+"${_parallel_files[@]}"}"; do
      _slot=$((_slot + 1))
      local _base="$_job_dir/$_slot"
      printf '%s' "$f" > "${_base}.file"
      (
        if _rt_run "$f" "${_base}.out" "${_cov_dir:+$_cov_dir/p$_slot.trace}"; then
          printf '0' > "${_base}.rc"
          # Success: aggregation only reads .out for FAILED slots, so drop it now
          # — parity with the serial path, keeps the job dir small (#1011 review).
          rm -f "${_base}.out"
        else
          printf '%s' "$?" > "${_base}.rc"
        fi
      ) &
      _inflight=$((_inflight + 1))
      # Track pids only on the fallback path; `wait -n` needs no pid bookkeeping.
      if [[ "$_waitn" -eq 0 ]]; then
        _pids+=($!)
      fi
      if [[ "$_inflight" -ge "$_par_jobs" ]]; then
        if [[ "$_waitn" -eq 1 ]]; then
          wait -n 2>/dev/null || true
        else
          wait "${_pids[0]}" 2>/dev/null || true
          _pids=("${_pids[@]:1}")
        fi
        _inflight=$((_inflight - 1))
      fi
    done
    # drain remaining background jobs
    if [[ "$_waitn" -eq 1 ]]; then
      wait 2>/dev/null || true
    else
      for _pid in "${_pids[@]+"${_pids[@]}"}"; do
        wait "$_pid" 2>/dev/null || true
      done
    fi
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
        _rt_is_timeout_rc "$_rc" && timedout=$((timedout + 1))
        _rt_report_failure "$name" "$_file" "$_rc" "$_job_dir/$_i.out"
      fi
    done
    rm -rf "$_job_dir"
    if [[ -n "$_cov_dir" ]]; then
      cat "$_cov_dir"/*.trace > "$_RT_COVERAGE_TRACE" 2>/dev/null || :
      rm -rf "$_cov_dir"
    fi
    _rt_emit_summary "$name" "$passed" "$total" "$timedout"
    _rt_emit_tier_time "$name" "$_rt_tier_t0"
    [[ $failed -eq 0 ]]
    return
  fi

  # Serial path: capture each file's output once into a tempfile (replayed on
  # failure) to avoid the double-execution side effects (state writes, event
  # emits) of the old "run silent, re-run on fail" pattern. _rt_run keeps fd 3 →
  # /dev/null so a sourced module honoring ZBUILD_STAGE_IO_FD=3 (the production
  # runner default, core/pipeline/runner.sh:869) finds it open for write —
  # otherwise stage-io.sh's load-time guard aborts sourcing under the unit
  # harness (#586) — and bounds the run with a per-file timeout + stdin guard
  # (#929). The body is shared with the #991 serial-pin bucket via the helper.
  for f in "${files[@]}"; do
    _rt_run_serial_file "$name" "$f" "$_cov_dir"
  done

  if [[ -n "$_cov_dir" ]]; then
    cat "$_cov_dir"/*.trace > "$_RT_COVERAGE_TRACE" 2>/dev/null || :
    rm -rf "$_cov_dir"
  fi
  _rt_emit_summary "$name" "$passed" "$total" "$timedout"
  _rt_emit_tier_time "$name" "$_rt_tier_t0"
  [[ $failed -eq 0 ]]
}

# run_lint_tier — fold `npm run lint` into the suite as a first-class tier (#1129
# Change C / ADR-012). simple.yaml's `lint` read-out gate is removed as a cycle
# member, so the suite now owns lint enforcement: a lint failure fails `--tier all`
# (what `npm test` runs), the same way the mutation tier already does. Reuses the
# shared framework-result helper (ADR-040, #1133) so the ZBUILD_LINT_CMD override
# (ADR-032/033) keeps working. Emits the same `name: P/T passed` summary line so
# the --tier all aggregator and external parsers treat it like any other tier.
run_lint_tier() {
  local _t0="$EPOCHREALTIME"
  local block status
  # Run from REPO_ROOT in a subshell so sourcing the helper and `npm run lint`
  # never pollute the caller and always resolve repo-relative paths.
  block="$(cd "$REPO_ROOT" && source "$SCRIPT_DIR/lib/framework-result.sh" && framework_run_lint)"
  status="$(printf '%s' "$block" | jq -r '.status' 2>/dev/null)"
  if [[ "$status" == "pass" ]]; then
    echo "lint: 1/1 passed"
    _rt_emit_tier_time "lint" "$_t0"
    return 0
  fi
  # An explicit skip (ZBUILD_LINT_CMD="" — a target with no linter, ADR-032/033)
  # ran zero checks: report 0/0 so the --tier all totals don't credit a phantom
  # pass. Still rc=0 — a skip never fails the suite.
  if [[ "$status" == "skipped" ]]; then
    echo "lint: 0/0 passed"
    _rt_emit_tier_time "lint" "$_t0"
    return 0
  fi
  echo "lint: FAIL (npm run lint)" >&2
  printf '%s\n' "$block" | jq -r '.summary // empty' >&2 2>/dev/null || true
  echo "lint: 0/1 passed"
  _rt_emit_tier_time "lint" "$_t0"
  return 1
}

case "$tier" in
  unit|integration|e2e|golden)
    run_tier "$tier"
    ;;
  mutation)
    bash "$SCRIPT_DIR/run-mutation.sh"
    ;;
  lint)
    run_lint_tier
    ;;
  all)
    overall_rc=0
    total_passed=0
    total_count=0
    total_skipped=0
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
    # Single authoritative tier list: first 4 are file-tiers (run concurrently as
    # background subshells AND in the serial fallback), last 2 are mutation and lint.
    # Every subsequent roster enumeration (launch loop, replay, presence check)
    # references this array rather than hand-repeated word lists.
    _TIER_ALL_MANIFEST=(unit integration e2e golden mutation lint)
    # Also clean the coverage BASH_ENV temp file here: this EXIT trap replaces the
    # one the --coverage-trace setup installed above, so fold its cleanup in to
    # avoid leaking that temp file on the `--tier all --coverage-trace` path (#993
    # review). buf_dir cleanup folds in for the #997 concurrent path.
    # Guard the buf_dir cleanup: on the serial path buf_dir is "" and an
    # unguarded `rm -rf ""` errors (and could perturb the trap's exit). The
    # `[[ -z ]] ||` form is a no-op (rc 0) when buf_dir is empty.
    _tier_pids=()
    trap 'rm -f "$rc_file" "${_RT_BASH_ENV_FILE:-}"; [[ -z "${buf_dir:-}" ]] || rm -rf "$buf_dir"; for _ep in "${_tier_pids[@]+"${_tier_pids[@]}"}"; do kill -TERM "$_ep" 2>/dev/null || true; done' EXIT
    # INT/TERM handler: send TERM to all tracked tier PIDs, wait, then re-raise so
    # the caller sees a proper signal-exit status (#1662). Idempotency flag prevents
    # double-print when a signal arrives while we are already inside the handler.
    _rt_abort_fired=0
    _rt_signal_abort() {
      [[ "$_rt_abort_fired" -eq 1 ]] && return
      _rt_abort_fired=1
      local _p; for _p in "${_tier_pids[@]+"${_tier_pids[@]}"}"; do kill -TERM "$_p" 2>/dev/null || true; done
      wait 2>/dev/null || true
      overall_rc=1
      echo "total: ABORTED — interrupted" >&2
      trap - INT TERM
      kill -TERM $$ 2>/dev/null || exit 143
    }
    trap '_rt_signal_abort' INT TERM
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
      for t in "${_TIER_ALL_MANIFEST[@]:0:4}"; do
        (
          # Test hook: simulate a tier subshell killed before rc_file write (#1662).
          [[ "${_ZBUILD_TEST_ABORT_TIER:-}" == "$t" ]] && exit 137
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
        _tier_pids+=($!)
      done
      (
        [[ "${_ZBUILD_TEST_ABORT_TIER:-}" == "mutation" ]] && exit 137
        export TMPDIR="$buf_dir/tmp-mutation"; mkdir -p "$TMPDIR"
        export ZBUILD_MUTATION_PARALLEL_JOBS=$_mjobs
        if bash "$SCRIPT_DIR/run-mutation.sh"; then rc=0; else rc=$?; fi
        echo "mutation $rc" >> "$rc_file"
      ) > "$buf_dir/mutation.out" 2> "$buf_dir/mutation.err" &
      _tier_pids+=($!)
      # #1129 Change C: lint as a concurrent suite tier (ADR-012). Cheap (shellcheck)
      # so no job-budget split — runs alongside the file tiers and mutation.
      (
        [[ "${_ZBUILD_TEST_ABORT_TIER:-}" == "lint" ]] && exit 137
        export TMPDIR="$buf_dir/tmp-lint"; mkdir -p "$TMPDIR"
        if run_lint_tier; then rc=0; else rc=$?; fi
        echo "lint $rc" >> "$rc_file"
      ) > "$buf_dir/lint.out" 2> "$buf_dir/lint.err" &
      _tier_pids+=($!)
      wait
      # Presence check (#1662): any tier killed before writing its rc_file entry is
      # reported as ABORTED — silently exiting 0 when a tier never ran is the bug.
      _rt_abort_found=0
      for _t in "${_TIER_ALL_MANIFEST[@]}"; do
        if ! /usr/bin/grep -q "^$_t " "$rc_file" 2>/dev/null; then
          echo "$_t: ABORTED (killed before summary)" >&2
          _rt_abort_found=1
        fi
      done
      if [[ "$_rt_abort_found" -eq 1 ]]; then
        echo
        echo "total: ABORTED — one or more tiers did not complete"
        exit 1
      fi
    fi
    while IFS= read -r line; do
      echo "$line"
      if [[ "$line" =~ ^[a-z][a-z0-9-]*:\ ([0-9]+)/([0-9]+)\ passed(\ \(([0-9]+)\ skipped\))? ]]; then
        total_passed=$((total_passed + BASH_REMATCH[1]))
        total_count=$((total_count + BASH_REMATCH[2]))
        total_skipped=$((total_skipped + ${BASH_REMATCH[4]:-0}))
      fi
    done < <(
      if [[ $_tier_conc -eq 1 ]]; then
        # Replay captured STDOUT in canonical tier order so summary lines + the
        # accumulator sums are byte-identical to the serial path.
        for _t in "${_TIER_ALL_MANIFEST[@]}"; do cat "$buf_dir/$_t.out"; done
      else
        for t in "${_TIER_ALL_MANIFEST[@]:0:4}"; do
          if run_tier "$t"; then rc=0; else rc=$?; fi
          echo "$t $rc" >> "$rc_file"
        done
        if bash "$SCRIPT_DIR/run-mutation.sh"; then rc=0; else rc=$?; fi
        echo "mutation $rc" >> "$rc_file"
        # #1129 Change C: lint tier (ADR-012), last in canonical order.
        if run_lint_tier; then rc=0; else rc=$?; fi
        echo "lint $rc" >> "$rc_file"
      fi
    )
    if [[ $_tier_conc -eq 1 ]]; then
      # Replay captured STDERR (FAIL lines + child output) to fd 2 in canonical
      # order — these streamed live in the serial path and were never buffered.
      for t in "${_TIER_ALL_MANIFEST[@]}"; do
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
    _ts_note=""; [[ "${total_skipped:-0}" -gt 0 ]] && _ts_note=" (${total_skipped} skipped)"
    echo "total: $total_passed/$total_count passed${_ts_note}"
    exit $overall_rc
    ;;
  *)
    echo "Usage: $0 --tier {unit,integration,e2e,golden,mutation,lint,all}" >&2
    exit 1
    ;;
esac
