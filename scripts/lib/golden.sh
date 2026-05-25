#!/usr/bin/env bash
# Golden-file assertion helper. Source this in test files.
# Usage: assert_golden <name> <actual_output>
# Set UPDATE_GOLDEN=1 to regenerate .golden files.

GOLDEN_DIR="${GOLDEN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tests/golden" && pwd)}"

assert_golden() {
  local name="$1"
  local actual="$2"
  local golden_file="$GOLDEN_DIR/${name}.golden"

  if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
    mkdir -p "$(dirname "$golden_file")"
    printf '%s' "$actual" > "$golden_file"
    echo "  [golden] regenerated: $name"
    return 0
  fi

  if [[ ! -f "$golden_file" ]]; then
    echo "  [golden] MISSING: $golden_file (run with UPDATE_GOLDEN=1 to create)" >&2
    return 1
  fi

  local expected
  expected="$(cat "$golden_file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "  [golden] DIFF for $name:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2
    return 1
  fi
}
