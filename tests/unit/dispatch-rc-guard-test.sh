#!/usr/bin/env bash
# Guard: enumerate every engine path that still returns an rc outside {0,1}
# (#1823, ADR-054 §4) — and make the list a RATCHET.
#
# ADR-054 §4 gives #1823 "the narrowing and the designs that re-home each
# signal", with the enforcing check being "no engine path returns or interprets
# an rc outside {0,1}, with a guard test enumerating the call sites". That plain
# assertion cannot hold yet and saying otherwise would be a lie: the legacy
# vocabulary is still in flight during versioned coexistence, and #1850 deletes
# it together with the v1 result reader ("the legacy rc mapping (5, 8, 9, 10,
# 11) is deleted; a guard asserts no engine path returns an rc outside {0,1}").
#
# So this guard enumerates instead of forbidding, and ratchets:
#
#   * a count that RISES fails    — a new engine path grew a private rc
#   * a count that FALLS fails    — progress must be locked in, not left
#                                   as slack for the next one to spend
#
# When #1850 empties these, the pin goes to zero across the board and the
# ratchet becomes the plain rule its own acceptance describes. Until then this
# is the honest version of that assertion: the vocabulary cannot grow.
#
# Counting `return N` / `exit N` textually is deliberately crude. It cannot be
# fooled in the direction that matters — adding a new private rc adds a line —
# and a guard that parsed control flow would be a second implementation of the
# thing under test.
#
# KNOWN BLIND SPOT, verified by running this file against the merge-base: an rc
# behind a named constant (`return "$ZBUILD_HOOK_ABSENT"`) is invisible to a
# literal count, so §1's numbers would have read as clean while ADR-056's rc=3
# was live. Widening the pattern to `return "$VAR"` is not the answer — it would
# flag every legitimate `return $rc` passthrough, of which the engine has many.
# Named sentinels are therefore asserted BY NAME in §2 as they are found. If a
# future one appears, it needs its own named assertion; the count will not catch
# it. Recorded rather than papered over: a guard whose limits are undocumented
# is trusted for more than it checks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "dispatch-rc guard — the legacy rc inventory is a ratchet (#1823)"

# The repo default `grep` may be ugrep; use the system one for stable -cE.
SYSGREP=/usr/bin/grep

# The engine files ADR-054 §4 names. Scoped deliberately: scripts/lib/worktree.sh,
# scripts/lib/git-remote.sh, core/output/stage-io.sh and friends have their own
# unrelated private rc vocabularies that collide numerically but are not the
# engine↔stage contract. Widening this list to "every .sh" would bury the
# signal under ~40 unrelated call sites.
#
# THE PIN. Each number is "legacy rc returns in this file today". Lower it when
# you remove one; you may never raise it.
_PINNED="
core/pipeline/runner.sh|35
core/pipeline/cycle-orchestrator.sh|29
core/pipeline/parallel-orchestrator.sh|4
core/pipeline/strategies/map.sh|6
core/pipeline/strategies/fanout.sh|2
core/pipeline/strategies/sequential.sh|1
core/pipeline/strategies/composite.sh|0
core/plugin-registry/lifecycle.sh|0
scripts/lib/abort-propagation.sh|6
"

_LEGACY_RE='(return|exit)[[:space:]]+(2|3|4|5|6|7|8|9|10|11|124|130|137|143)([[:space:]]|;|$)'

# `grep -c` prints 0 AND returns rc=1 when there are no matches, so the naive
# `grep -c ... || printf 0` prints "00" for an empty file — the antipattern
# tests/unit/lint-grep-c-test.sh exists to catch (#1751). Capture, then default.
_count_legacy() {
    local f="$1" n=""
    [[ -f "$f" ]] || { printf 'MISSING'; return 0; }
    n="$($SYSGREP -cE "$_LEGACY_RE" "$f" 2>/dev/null)" || n="0"
    printf '%s' "${n:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "1. The inventory matches the pin exactly"

while IFS='|' read -r _file _pin; do
    [[ -z "$_file" ]] && continue
    _actual="$(_count_legacy "$REPO_ROOT/$_file")"
    _actual="${_actual//[$'\n\r ']/}"
    if [[ "$_actual" == "$_pin" ]]; then
        assert_pass "[SPEC-1] $_file holds $_pin legacy rc returns"
    elif [[ "$_actual" == "MISSING" ]]; then
        assert_fail "[SPEC-1] $_file is in the pin but not on disk" \
            "update _PINNED in $(basename "${BASH_SOURCE[0]}")"
    elif [[ "$_actual" -gt "$_pin" ]]; then
        assert_fail "[SPEC-1] $_file GREW a private rc ($_pin → $_actual)" \
            "A new engine path returns an rc outside {0,1}. rc carries two facts (ADR-054 §4): result on disk (0), failed (1). Put what you were encoding on a declared channel — disposition (core/pipeline/disposition.sh) for recoverability, routing state (ADR-045) for the backward edge."
    else
        assert_fail "[SPEC-1] $_file SHRANK ($_pin → $_actual) — lower the pin" \
            "Progress must be locked in: set $_file to $_actual in _PINNED so the next change cannot spend the slack."
    fi
done <<< "$_PINNED"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "2. The contract boundary itself is clean"

# The plugin↔engine boundary is where rc is a CONTRACT rather than an engine
# implementation detail, so it is held to the plain rule with no ratchet. This
# is what #1823 actually narrows; the ratchet above is the coexistence residue.
_lifecycle="$REPO_ROOT/core/plugin-registry/lifecycle.sh"
_hook_legacy="$(_count_legacy "$_lifecycle")"
_hook_legacy="${_hook_legacy//[$'\n\r ']/}"
assert_eq "[SPEC-2] plugin_hook_call returns nothing outside {0,1}" "0" "$_hook_legacy"

# ADR-056's rc=3 sentinel is gone (#1823). It was a SECOND channel for a fact
# `plugin.cleanup.absent` already carried, justified in ADR-056 §3 against
# ADR-001's "0=ok, 1=recoverable, 2=fatal" — the very table ADR-054 §4
# supersedes. Nothing in the engine ever read it.
if $SYSGREP -q 'ZBUILD_HOOK_ABSENT' "$_lifecycle" 2>/dev/null; then
    assert_fail "[SPEC-2] the ZBUILD_HOOK_ABSENT sentinel is gone" \
        "rc=3 came back; an absent optional hook is rc=0 + plugin.cleanup.absent"
else
    assert_pass "[SPEC-2] the ZBUILD_HOOK_ABSENT sentinel is gone"
fi

# The absence must still be RECORDED — removing the rc without the event would
# be the pre-ADR-056 regression, where an absent hook was indistinguishable
# from one that ran. #1828's acceptance asked for "distinguishable in the
# engine's records", and this is that record.
if $SYSGREP -q 'plugin.\$hook_name.absent\|plugin\.cleanup\.absent' "$_lifecycle" 2>/dev/null; then
    assert_pass "[SPEC-2] an absent optional hook is still recorded on the event stream"
else
    assert_fail "[SPEC-2] an absent optional hook is still recorded on the event stream" \
        "dropping the event with the rc would restore the pre-ADR-056 ambiguity"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "3. The stage dispatch boundary narrows before reading"

# Behavioural coverage for the narrowing lives in
# tests/integration/dispatch-rc-signal-boundary-test.sh (a real signalled
# subshell). What is checked here is the ORDER, which no behavioural test can
# see: the observation must be taken from the RAW status BEFORE narrowing, or
# the one fact worth keeping is already gone.
_runner="$REPO_ROOT/core/pipeline/runner.sh"
_obs_line="$($SYSGREP -n 'dispatch_rc_observation "\$_cd_rc"' "$_runner" | head -1 | cut -d: -f1)"
_narrow_line="$($SYSGREP -n '_cd_rc="\$(dispatch_rc_narrow "\$_cd_rc")"' "$_runner" | head -1 | cut -d: -f1)"

if [[ -n "$_obs_line" && -n "$_narrow_line" ]]; then
    assert_pass "[SPEC-3] the cycle dispatch boundary both observes and narrows"
    if [[ "$_obs_line" -lt "$_narrow_line" ]]; then
        assert_pass "[SPEC-3] it observes the RAW status before narrowing it away"
    else
        assert_fail "[SPEC-3] it observes the RAW status before narrowing it away" \
            "observation at line $_obs_line comes after narrowing at line $_narrow_line — the raw status is already {0,1} and every signal death reads as broken"
    fi
else
    assert_fail "[SPEC-3] the cycle dispatch boundary both observes and narrows" \
        "observation=${_obs_line:-absent} narrow=${_narrow_line:-absent}"
fi

# The marker must be cleared BEFORE the dispatch, not after. Clearing after
# would leave this member's own rate limit invisible to its own classification;
# not clearing at all would leak an earlier member's marker into this one, and
# `throttled` retries — one rate limit becoming a retry loop on a real defect.
_clear_line="$($SYSGREP -n '_router_clear_throttle_marker' "$_runner" | head -1 | cut -d: -f1)"
_hook_line="$($SYSGREP -n 'plugin_hook_call "\$_cd_plugin_dir" run' "$_runner" | head -1 | cut -d: -f1)"
if [[ -n "$_clear_line" && -n "$_hook_line" && "$_clear_line" -lt "$_hook_line" ]]; then
    assert_pass "[SPEC-3] the throttle marker is cleared before the dispatch"
else
    assert_fail "[SPEC-3] the throttle marker is cleared before the dispatch" \
        "clear=${_clear_line:-absent} dispatch=${_hook_line:-absent}"
fi

# Both stage-dispatch boundaries apply the v2 gate. A contract that held at one
# of them would make a v2 stage's rc depend on which kind of group it was
# composed into — and "the rule wired into one of two call sites" is the exact
# defect this PR hit three times.
_cyc_narrow="$($SYSGREP -c '_cd_rc="$(dispatch_rc_narrow "$_cd_rc")"' "$_runner" 2>/dev/null)" || _cyc_narrow=0
_par_narrow="$($SYSGREP -c '_pd_rc="$(dispatch_rc_narrow "$_pd_rc")"' "$_runner" 2>/dev/null)" || _par_narrow=0
assert_eq "[SPEC-3] cycle_dispatch_stage applies the v2 narrowing gate" "1" "${_cyc_narrow//[$'\n\r ']/}"
assert_eq "[SPEC-3] parallel_dispatch_stage applies it too" "1" "${_par_narrow//[$'\n\r ']/}"

# And both clear the throttle marker before dispatching.
_clear_count="$($SYSGREP -c '_router_clear_throttle_marker' "$_runner" 2>/dev/null)" || _clear_count=0
assert_eq "[SPEC-3] both dispatch boundaries clear the throttle marker" "2" "${_clear_count//[$'\n\r ']/}"

print_test_results
exit $((FAIL > 0))
