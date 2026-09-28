#!/usr/bin/env bash
# Leaf resolvability must warm the manifest cache in the CALLER's shell first.
#
# yaml_get is memoised, but 56 of its 82 call sites sit inside `$( )`, and an
# associative-array write in a command substitution dies with that subshell. So
# a lazily-filled cache is never inherited and saves nothing — which is why
# yaml_cache_prewarm exists and why runner.sh main() calls it (#1614: "6,338 awk
# spawns per run, ~13s of 27s").
#
# Tests never reach main(). They source runner.sh and call its helpers directly,
# so the prewarm never runs and every lookup forks awk. Measured in
# template-resolvability-preflight-test.sh — the slowest unit file, and the one
# that times out the Coverage job (#2090):
#
#   28,068 yaml_get calls -> 28,068 parses, 0 cache hits
#   real 150s / user 52s / sys 81s   (kernel time 1.55x user: fork cost)
#
# Adding one prewarm call took it to 82.75s with sys 81s -> 45s.
#
# The prewarm belongs HERE rather than in setup_test_env: it costs 1.32s, and
# 570 test files x 1.32s would add ~747s to the suite to benefit the handful of
# files that resolve plugins. Measured before choosing.
#
# _runner_validate_leaf_resolvability is the right seam because callers invoke
# it directly — not through `$( )` — so a cache filled here survives into every
# subshell the resolution below spawns.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/dispatch.sh
source "$REPO_ROOT/core/pipeline/dispatch.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"

print_test_header "leaf resolvability warms the manifest cache"
setup_test_env "leaf-resolvability-prewarm"

# Cache must start cold, or the assertion proves nothing about this function.
yaml_cache_flush 2>/dev/null || true
assert_eq "[SPEC-1] GUARD: the manifest cache starts empty" \
    "0" "${#_ZBUILD_YAML_RC[@]}"

_leaves=(build test)
_runner_validate_leaf_resolvability _leaves "$REPO_ROOT/plugins" >/dev/null 2>&1 || true

# ─── SPEC-1: the call leaves a warm cache behind in THIS shell ─────────────
assert_gt "[SPEC-1] resolvability leaves the manifest cache populated" \
    "${#_ZBUILD_YAML_RC[@]}" "0"

# ─── SPEC-2: GUARD — it still resolves correctly ──────────────────────────
# A prewarm that broke resolution would be a worse bug than the slowness.
_ok_leaves=(build)
_rc=0
_runner_validate_leaf_resolvability _ok_leaves "$REPO_ROOT/plugins" >/dev/null 2>&1 || _rc=$?
assert_eq "[SPEC-2] GUARD: a resolvable leaf still passes" "0" "$_rc"

_bad_leaves=(no_such_stage_xyz)
_rc=0
_runner_validate_leaf_resolvability _bad_leaves "$REPO_ROOT/plugins" >/dev/null 2>&1 || _rc=$?
assert_gt "[SPEC-2] GUARD: an unresolvable leaf still fails closed" "$_rc" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
