#!/usr/bin/env bash
# Per-tier test runner. Usage: scripts/run-tests.sh --tier {unit,integration,e2e,golden,mutation,all}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

tier="${1:-}"
if [[ "$tier" == "--tier" ]]; then
  tier="${2:-all}"
fi

run_tier() {
  local name="$1"
  local dir="$TESTS_DIR/$name"
  local passed=0 failed=0 total=0

  if [[ ! -d "$dir" ]]; then
    echo "$name: 0/0 passed (no tests)"
    return 0
  fi

  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -name '*-test.sh' -print0 2>/dev/null)

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "$name: 0/0 passed (empty tier)"
    return 0
  fi

  for f in "${files[@]}"; do
    total=$((total + 1))
    if bash "$f" > /dev/null 2>&1; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      echo "$name: FAIL $f" >&2
      bash "$f" >&2 || true
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
