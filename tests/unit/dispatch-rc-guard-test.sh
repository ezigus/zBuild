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
# #1850 emptied these: the pin is zero across the board and §SPEC-16 below
# states the plain rule its acceptance describes. The ratchet stays so a raise
# names the file that grew.
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

# #1850 added the strategies' shared helpers, stage-scratch, disposition, the
# contract validator and the orch backends' collect, all now 0.
# The engine files ADR-054 §4 names. Scoped deliberately: scripts/lib/worktree.sh,
# scripts/lib/git-remote.sh, core/output/stage-io.sh and friends have their own
# unrelated private rc vocabularies that collide numerically but are not the
# engine↔stage contract. Widening this list to "every .sh" would bury the
# signal under ~40 unrelated call sites.
#
# THE PIN. Each number is "legacy rc returns in this file today". Lower it when
# you remove one; you may never raise it.
#
# #2111 raised runner.sh 35→36 and cycle-orchestrator.sh 29→30: NOT a new word —
# rc=9 is the llm-abort channel #1024 declared and _zbuild_propagate_abort has
# carried since then. These two are the enforcing callers it never had (the
# disposition table's `halt_unavailable` was announced, not acted on), and the
# orchestrator arm that stops the generic catch-all collapsing 9 into 4.
# #1835 removed the leaf-path rc=10 block from runner.sh (scope_too_large is
# now a v2 disposition, not a special rc), lowering the count back to 35.
# #1850 deletes them with the rest of the vocabulary.
_PINNED="
core/pipeline/runner.sh|0
core/pipeline/cycle-orchestrator.sh|0
core/pipeline/parallel-orchestrator.sh|0
core/pipeline/strategies/map.sh|0
core/pipeline/strategies/fanout.sh|0
core/pipeline/strategies/sequential.sh|0
core/pipeline/strategies/composite.sh|0
core/plugin-registry/lifecycle.sh|0
scripts/lib/abort-propagation.sh|0
core/pipeline/strategies/common.sh|0
core/pipeline/stage-scratch.sh|0
core/pipeline/disposition.sh|0
core/pipeline/contract-validator.sh|0
core/orch/local_engine.sh|0
plugins/tool/orch-mock/plugin.sh|0
plugins/tool/orch-sequential/plugin.sh|0
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

# Both stage-dispatch boundaries narrow (unconditionally since #1850). A rule that held at one
# of them would make a stage's rc depend on which kind of group it was
# composed into — and "the rule wired into one of two call sites" is the exact
# defect this PR hit three times.
_cyc_narrow="$($SYSGREP -c '_cd_rc="$(dispatch_rc_narrow "$_cd_rc")"' "$_runner" 2>/dev/null)" || _cyc_narrow=0
_par_narrow="$($SYSGREP -c '_pd_rc="$(dispatch_rc_narrow "$_pd_rc")"' "$_runner" 2>/dev/null)" || _par_narrow=0
assert_eq "[SPEC-3] cycle_dispatch_stage narrows the rc" "1" "${_cyc_narrow//[$'\n\r ']/}"
assert_eq "[SPEC-3] parallel_dispatch_stage applies it too" "1" "${_par_narrow//[$'\n\r ']/}"

# And both clear the throttle marker before dispatching.
_clear_count="$($SYSGREP -c '_router_clear_throttle_marker' "$_runner" 2>/dev/null)" || _clear_count=0
assert_eq "[SPEC-3] both dispatch boundaries clear the throttle marker" "2" "${_clear_count//[$'\n\r ']/}"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "4. The version gate cannot be fed by a subshell global"

# #1823 shipped this bug for one commit: the gate read a global set inside
# _verdict_read_result, which every public reader invokes from within `$(...)`.
# A `$()` is a subshell, so the assignment never reached the caller — the gate
# saw its default forever and v2 narrowing NEVER FIRED. Green, and inert.
#
# Nothing caught it. The unit tests called the readers directly; the integration
# helper called a reader directly; and section 3's assertions above only check
# that the gate LINES exist, which a line that does nothing satisfies perfectly.
#
# This is a source-level check, and deliberately so: `cycle_dispatch_stage` is
# defined INSIDE `main()` in runner.sh, so no test can invoke the real one — a
# behavioural test can only exercise a reproduction of it, which is exactly how
# the bug slipped through. What can be enforced is that the broken MECHANISM
# never comes back.
if $SYSGREP -q '_ZBUILD_LAST_RESULT_CONTRACT' "$_runner" "$REPO_ROOT/core/pipeline/verdict.sh" 2>/dev/null; then
    assert_fail "[SPEC-4] no gate reads a contract global" \
        "_ZBUILD_LAST_RESULT_CONTRACT is back; a global assigned inside \$() never reaches the caller, so the gate would read its default and never fire"
else
    assert_pass "[SPEC-4] no gate reads a contract global"
fi

# #1850: there is no version gate any more — every stage speaks v2, so BOTH
# boundaries narrow unconditionally, and the probe that fed the gate is gone.
_narrow_uses="$($SYSGREP -cE '^[[:space:]]+_(cd|pd)_rc="\$\(dispatch_rc_narrow "\$_(cd|pd)_rc"\)"$' "$_runner" 2>/dev/null)" || _narrow_uses=0
assert_eq "[SPEC-4] both boundaries narrow unconditionally (#1850)" "2" "${_narrow_uses//[$'\n\r ']/}"
_probe_left="$(cat "$_runner" "$REPO_ROOT/core/pipeline/verdict.sh" | $SYSGREP -c '_verdict_probe_contract' 2>/dev/null)" || _probe_left=0
assert_eq "[SPEC-4] the contract probe is gone (#1850)" "0" "$_probe_left"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "5. the cycle.complete fan-in reads the reason word, not an rc"

# ADR-054 §4 recorded the asymmetry: _cycle_handle_terminal_rc had a 130) arm
# but no 143) arm, so SIGTERM fell to *) reason="error"; #1860 merged them into
# a combined 130|143) arm. #1850 removes the reason for the arms: the loop
# returns 0/1 and says why on _CYCLE_LAST_TERMINATED_REASON, so the fan-in is
# _cycle_handle_terminal <cycle_id> <state_file>, which reads that word. An arm
# keyed on a number can no longer go missing for one signal, because there is
# no number to key on.
_orch="$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# The rc-keyed helper is gone, from the orchestrator and from its caller.
_old_left="$(cat "$_orch" "$_runner" | $SYSGREP -c '_cycle_handle_terminal_rc' 2>/dev/null)" || _old_left=0
assert_eq "[SPEC-5] no _cycle_handle_terminal_rc remains (orchestrator + runner)" \
    "0" "${_old_left//[$'\n\r ']/}"

# Bound the window to the function's own body, not a fixed line count: a
# `-A N` window silently starts missing lines once the function grows past N.
_func_block="$(awk '/^_cycle_handle_terminal\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$_orch")"
if [[ -n "$_func_block" ]]; then
    assert_pass "[SPEC-5] _cycle_handle_terminal is defined in the orchestrator"
else
    assert_fail "[SPEC-5] _cycle_handle_terminal is defined in the orchestrator" \
        "no '_cycle_handle_terminal() {' in $_orch"
fi

# It reads the reason word — the one channel that names a SIGINT and a SIGTERM
# end alike (reason=aborted) — instead of mapping an rc to a reason.
if $SYSGREP -q '_CYCLE_LAST_TERMINATED_REASON' <<< "$_func_block"; then
    assert_pass "[SPEC-5] _cycle_handle_terminal reads _CYCLE_LAST_TERMINATED_REASON"
else
    assert_fail "[SPEC-5] _cycle_handle_terminal reads _CYCLE_LAST_TERMINATED_REASON" \
        "the fan-in does not read the reason word"
fi

# And no signal-number arm survives inside it.
if $SYSGREP -qE '(^|[^0-9])(130|143)([^0-9]|$)' <<< "$_func_block"; then
    assert_fail "[SPEC-5] _cycle_handle_terminal keys on no signal rc" \
        "130/143 still appears in the fan-in: $($SYSGREP -nE '(^|[^0-9])(130|143)([^0-9]|$)' <<< "$_func_block" | tr '\n' ' ')"
else
    assert_pass "[SPEC-5] _cycle_handle_terminal keys on no signal rc"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "6. write-boundary wiring leaves lifecycle.sh rc-clean"

# [SPEC-7] GUARD: #1809 adds write_boundary_mark and write_boundary_check calls
# to lifecycle.sh. Both are invoked via `declare -F` guards and return 0 or 1
# only. This assertion verifies that the write-boundary wiring introduces no new
# legacy rc code into lifecycle.sh — the _PINNED count must stay at 0.
_wb_lc="$(_count_legacy "$REPO_ROOT/core/plugin-registry/lifecycle.sh")"
_wb_lc="${_wb_lc//[$'\n\r ']/}"
assert_eq "[SPEC-7] lifecycle.sh still has 0 legacy rc returns after write-boundary wiring (#1809)" \
    "0" "$_wb_lc"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "[#1850/SPEC-16] the plain rule: no engine path returns or reads a legacy rc"

# #1850 emptied the inventory, so the ratchet is now the rule ADR-054 §4 states:
# every pin above is 0. Asserted on its own so a later raise of one pin cannot
# quietly turn the rule back into a ratchet.
_s16_bad=""
while IFS='|' read -r _file _pin; do
    [[ -z "$_file" ]] && continue
    [[ "$_pin" == "0" ]] || _s16_bad+="$_file=$_pin "
done <<< "$_PINNED"
assert_eq "[#1850/SPEC-16] every guarded engine file is pinned at 0" "" "$_s16_bad"

# The other half of "returns or interprets": a reader comparing an rc against a
# legacy number (`[[ $rc -eq 9 ]]`, `case "$rc" in 130|143)`) is the vocabulary
# kept alive on the receiving side. Crude on purpose, like the count above.
_INTERP_RE='(rc|_rc|rc_[a-z0-9_]*)"?[[:space:]]+-(eq|ne)[[:space:]]+(2|3|4|5|6|7|8|9|10|11|124|130|137|143)([^0-9]|$)'
_CASE_RE='^[[:space:]]*(2|3|4|5|6|7|8|9|10|11|124|130|137|143)(\|[0-9]+)*\)'
_s16_reads=""
while IFS='|' read -r _file _pin; do
    [[ -z "$_file" || ! -f "$REPO_ROOT/$_file" ]] && continue
    _hits="$($SYSGREP -nE "$_INTERP_RE|$_CASE_RE" "$REPO_ROOT/$_file" 2>/dev/null | $SYSGREP -vE '^[0-9]+:[[:space:]]*#' || true)"
    [[ -n "$_hits" ]] && _s16_reads+="$_file: ${_hits//$'\n'/; } "
done <<< "$_PINNED"
assert_eq "[#1850/SPEC-16] no guarded engine file reads an rc as a legacy number" "" "$_s16_reads"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "[#1850/SPEC-17] every dispatch boundary checks for an abort before it dispatches"

# ADR-025's pre-flight belongs at the hook call itself, not only in the caller's
# loop: cycle_dispatch_stage re-dispatches a retryable stage (after a wait), and
# parallel_dispatch_stage runs each member — a Ctrl-C recorded meanwhile must
# stop the next model call, not be read after it (#1850 review).
for _fn in cycle_dispatch_stage parallel_dispatch_stage; do
    _body="$(awk -v f="    ${_fn}() {" '$0 == f {p=1} p {print} p && /^    }$/ {exit}' "$_runner")"
    _hook_ln="$($SYSGREP -n 'plugin_hook_call ' <<< "$_body" | head -1 | cut -d: -f1 || true)"
    _chk_ln="$($SYSGREP -n '_zbuild_check_abort' <<< "$_body" | head -1 | cut -d: -f1 || true)"
    if [[ -n "$_hook_ln" && -n "$_chk_ln" && "$_chk_ln" -lt "$_hook_ln" ]]; then
        assert_pass "[SPEC-17] $_fn checks for an abort before plugin_hook_call"
    else
        assert_fail "[SPEC-17] $_fn checks for an abort before plugin_hook_call" \
            "check at line ${_chk_ln:-absent}, hook call at line ${_hook_ln:-absent} of the function"
    fi
done

print_test_results
exit $((FAIL > 0))
