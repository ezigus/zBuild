#!/usr/bin/env bash
# Guard: a test that force-kills a runner must not undercut the engine's own
# teardown budget (#2029).
#
# `runner-release-exit-paths-test.sh` SPEC-5 sends SIGTERM, then force-kills the
# runner after a grace period, then asserts every stage wrote its release line.
# The grace was a hardcoded `sleep 3`.
#
# The engine bounds each release hook at ZBUILD_RELEASE_TIMEOUT, default **30s**
# (`core/pipeline/runner.sh:2025`), PER STAGE. Three stages release in that case,
# so teardown is entitled to take far longer than three seconds. When it did, the
# test killed the very thing it was about to assert on, and the marker came back
# EMPTY — both stages missing, not one:
#
#     ✗ [SPEC-5] cleanup dispatched with scope=release for: intake build
#       no release from: intake build | marker=
#
# Reproduced deterministically by shortening the grace to 0.2s: identical
# signature. That is the mechanism — not machine load, though load is what made
# teardown slow enough to hit it.
#
# The durable invariant is not a bigger number. It is that the grace must be
# DERIVED from the budget it is protecting, so the two cannot drift apart again.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "exit-path tests do not undercut the engine's teardown budget (#2029)"
setup_test_env "exit-path-teardown-budget"

T="$REPO_ROOT/tests/integration/runner-release-exit-paths-test.sh"
assert_file_exists "SPEC-0: the integration test exists" "$T"

# ── SPEC-1: the hard-kill case pins the engine's release budget ────────────
# Unpinned, it is the 30s default and the test is racing a number it does not
# control. Pinning makes teardown's worst case knowable.
_spec5_block="$(sed -n '/SPEC-5: exit path = external hard kill/,/SPEC-6/p' "$T")"
if grep -q 'ZBUILD_RELEASE_TIMEOUT' <<< "$_spec5_block"; then
    assert_pass "SPEC-1: the hard-kill case pins ZBUILD_RELEASE_TIMEOUT"
else
    assert_fail "SPEC-1: the hard-kill case pins ZBUILD_RELEASE_TIMEOUT" \
        "unpinned — teardown may take the 30s default per stage while the test force-kills far sooner"
fi

# ── SPEC-2: the force-kill grace is derived, not a literal ─────────────────
# The bug in one line. A literal cannot track the budget it is meant to outlast,
# and this one was 10x too small.
if grep -qE '\(\s*sleep\s+[0-9.]+\s*;\s*kill\s+-KILL' <<< "$_spec5_block"; then
    assert_fail "SPEC-2: the force-kill grace is derived from the release budget" \
        "hardcoded literal in \`( sleep N; kill -KILL ... )\` — cannot track the budget it protects"
else
    assert_pass "SPEC-2: the force-kill grace is derived from the release budget"
fi

# ── SPEC-3: and the derivation actually clears the worst case ─────────────
# Derived is not sufficient if the arithmetic is wrong. Three stages release on
# this path, each bounded independently, so the grace must clear 3x the per-hook
# bound. Evaluated rather than pattern-matched: the grace is an expression, and a
# guard that only recognised a literal would pass the moment someone wrote one.
_pinned="$(grep -oE '_SPEC5_RELEASE_TIMEOUT=[0-9]+' <<< "$_spec5_block" | head -1 | cut -d= -f2)"
_expr="$(grep -oE '_SPEC5_KILL_GRACE=\$\(\([^)]*\)\)' <<< "$_spec5_block" | head -1 | sed -E 's/^_SPEC5_KILL_GRACE=\$\(\((.*)\)\)$/\1/')"
_graceval=""
if [[ -n "$_pinned" && -n "$_expr" ]]; then
    # Only our own arithmetic reaches here, and only after the two greps above
    # matched the exact shapes; nothing external is evaluated.
    _SPEC5_RELEASE_TIMEOUT="$_pinned"
    _graceval="$(( _expr ))" 2>/dev/null || _graceval=""
fi
if [[ -n "$_graceval" ]] && (( _graceval >= _pinned * 3 )); then
    assert_pass "SPEC-3: grace ${_graceval}s clears 3 stages x ${_pinned}s"
else
    assert_fail "SPEC-3: grace clears 3 stages x the per-hook bound" \
        "pinned='${_pinned:-none}' grace='${_graceval:-unevaluatable}' — need grace >= 3x pinned"
fi

print_test_results
