#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUTATION_DIR="$REPO_ROOT/tests/mutation"

passed=0
failed=0

for doc in "$MUTATION_DIR"/*.md; do
  [[ -f "$doc" ]] || continue
  name="$(basename "$doc")"
  ok=1
  for section in "## File" "## Mutation" "## Expected failing test" "## Result"; do
    if ! grep -qF "$section" "$doc"; then
      echo "FAIL $name: missing section '$section'" >&2
      ok=0
    fi
  done
  if [[ $ok -eq 1 ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

echo "mutation: $passed/$((passed + failed)) passed"
[[ $failed -eq 0 ]]
