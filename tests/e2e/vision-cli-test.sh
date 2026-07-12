#!/usr/bin/env bash
# Tests: `zbuild vision init` CLI dispatch (scripts/zbuild -> lib/vision-init.sh).
# E2E — invokes the REAL scripts/zbuild subprocess so the CLI wiring is
# load-bearing: reverting the scripts/zbuild `vision` dispatch block breaks this
# test (closes the inert-wiring gap the acceptance-gate flagged on #1360).
# ADR-049 / VIS-B (#1360).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZBUILD_CLI="$REPO_ROOT/scripts/zbuild"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/vision.sh"

print_test_header "zbuild vision init — CLI dispatch (E2E, ADR-049 #1360)"
setup_test_env "e2e-vision-cli"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_STATE_DIR"
mock_claude
mock_gh
mock_git

out_doc="$TEST_TEMP_DIR/.zbuild/vision.md"

# ── CLI-1: `zbuild vision init --blank` writes a conforming skeleton through the
#    real scripts/zbuild dispatch (--blank needs no LLM). ──────────────────────
rc=0
out="$(cd "$TEST_TEMP_DIR" && bash "$ZBUILD_CLI" vision init --blank --output "$out_doc" 2>&1)" || rc=$?
assert_eq "[CLI-1] zbuild vision init --blank exits 0" "0" "$rc"
created=0; [[ -f "$out_doc" ]] && created=1
assert_eq "[CLI-1] blank vision document created via CLI" "1" "$created"

# ── CLI-2: the CLI-produced document passes the validator (round-trip). ────────
vrc=0
validate_vision_doc "$out_doc" >/dev/null 2>&1 || vrc=$?
assert_eq "[CLI-2] CLI-written blank vision passes validate_vision_doc" "0" "$vrc"
body="$(cat "$out_doc")"
assert_contains "[CLI-2] document has ## Intent" "$body" "## Intent"
assert_contains "[CLI-2] document has ## Principles" "$body" "## Principles"

# ── CLI-3: unknown vision subcommand is rejected (dispatch is real, not a stub). ─
rc=0
bash "$ZBUILD_CLI" vision bogus >/dev/null 2>&1 || rc=$?
badrc=0; [[ "$rc" -ne 0 ]] && badrc=1
assert_eq "[CLI-3] unknown 'vision' subcommand exits non-zero" "1" "$badrc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
