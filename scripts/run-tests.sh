#!/usr/bin/env bash
# Per-tier test runner. Usage: scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,all}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
PLUGINS_DIR="$REPO_ROOT/plugins"

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
    if bash "$f" >"$out" 2>&1; then
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
    for t in unit integration e2e golden; do
      run_tier "$t" || overall_rc=1
    done
    bash "$SCRIPT_DIR/run-mutation.sh" || overall_rc=1
    exit $overall_rc
    ;;
  *)
    echo "Usage: $0 --tier {unit,integration,e2e,golden,mutation,all}" >&2
    exit 1
    ;;
esac
