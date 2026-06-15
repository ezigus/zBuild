#!/usr/bin/env bash
# Per-tier test runner. Usage: scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,all}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
PLUGINS_DIR="$REPO_ROOT/plugins"
CORE_DIR="$REPO_ROOT/core"

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
    _tf_total=$((_tf_total + 1))
    _tf_out="$(mktemp -t zbuild-test-targeted.XXXXXX)"
    if bash "$_tf" 3>/dev/null >"$_tf_out" 2>&1; then
      _tf_passed=$((_tf_passed + 1)); rm -f "$_tf_out"
    else
      _tf_failed=$((_tf_failed + 1)); echo "unit: FAIL $_tf" >&2; cat "$_tf_out" >&2 || true; rm -f "$_tf_out"
    fi
  done
  echo "unit: $_tf_passed/$_tf_total passed"
  [[ $_tf_failed -eq 0 ]] && exit 0 || exit 1
fi

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

  for f in "${files[@]}"; do
    total=$((total + 1))
    # Capture once into a tempfile; replay on failure. Avoids the
    # double-execution side effects (state writes, event emits) of the
    # previous "run silent, then re-run on fail to show output" pattern.
    local out
    out="$(mktemp -t "zbuild-test-$name.XXXXXX")"
    # Open fd 3 to /dev/null so any sourced module that respects
    # ZBUILD_STAGE_IO_FD=3 (the production runner default — see
    # core/pipeline/runner.sh:869) finds the fd open for write. Without this,
    # stage-io.sh's load-time guard would abort sourcing for every test that
    # pulls in that module under the unit harness. (#586)
    if bash "$f" 3>/dev/null >"$out" 2>&1; then
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
