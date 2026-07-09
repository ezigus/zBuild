#!/usr/bin/env bash
# Tests: runner.sh unconverged-rescue reads the ADR-047 manifest verdict channel
# of the unconverged cycle's exit_when TARGET stage, not a hardcoded artifact
# path (#1298 / EPIC #1277).
#
# #796 intent: when a cycle exhausts max_iterations with on_max=continue, the run
# is rescued to success ONLY if the cycle's own convergence-decision stage (its
# `exit_when` target — the stage-agnostic analog of the retired single `review`
# stage) emitted an explicit merge-APPROVAL verdict (`approve`) via the ADR-047 §3
# verdict channel. A mechanical `pass` does NOT rescue (an unconverged cycle never
# satisfied its exit_when at check time, so a bare gate pass is not a late
# merge-approval). Absent/other verdict → not rescued (safe default).
#
# The rescue names NO stage: the target is derived from the cycle's declared
# exit_when (_TPL_CYCLE_UNTIL_STAGE_<id>), and its verdict is read via
# runner_read_stage_verdict_raw over the target's resolved manifest.
#
# Pinned assertions (drive the extracted rescue helper _rescue_success directly
# with a synthetic exit_when target + verdict, mirroring runner.sh exactly):
#
#   T1: exit_when target verdict == approve → rescued (downstream_success=1)
#   T2: exit_when target verdict == pass    → NOT rescued (mechanical gate, #979)
#   T3: exit_when target verdict == fail    → NOT rescued
#   T4: exit_when target verdict absent/""  → NOT rescued (safe default; #1298
#       regression guard — a passing NON-target artifact never rescues)
#   T5: no exit_when target declared for the cycle → NOT rescued (safe default)
#   T6: a DIFFERENT stage's approve artifact is present but the TARGET is pass →
#       NOT rescued (proves the rescue reads only the cycle's exit_when target,
#       not "any approve in the artifacts dir" — the any-pass/any-approve bug guard)
#   T7: exit_when target declared but does NOT resolve to a manifest → NOT rescued
#       (empty-resolution guard — never read a root-anchored "/manifest.yaml")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# verdict.sh provides runner_read_stage_verdict_raw (the ADR-047 §3 channel read).
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

print_test_header "runner unconverged-rescue: exit_when-target verdict channel, no stage name (#1298)"
setup_test_env "runner-unconverged-rescue-verdict-channel"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PLUGINS_ROOT"

# Stub resolver: map a stage id to its plugin dir under the given plugins_root
# (id-first). Mirrors resolve_stage_plugin's id-match path without the full
# dispatch.sh. Honors the plugins_root ARGUMENT (not a hardcoded global) so a
# caller passing a different root is actually exercised.
resolve_stage_plugin() {
    local _id="$1" _root="${2:-$PLUGINS_ROOT}"
    local _dir="$_root/$_id"
    [[ -d "$_dir" ]] && { printf '%s' "$_dir"; return 0; }
    return 1
}

# ─── Helper: _rescue_success <cycle_id> <state_dir> <plugins_root> → 0 rescued ─
# Extracts the exact rescue logic from runner.sh (the unconverged on_max=continue
# branch). Derives the exit_when target from _TPL_CYCLE_UNTIL_STAGE_<id> (names no
# stage), resolves its manifest, reads its raw verdict via the ADR-047 §3 channel,
# and rescues ONLY on `approve`. Returns 0 when downstream_success would be 1.
_rescue_success() {
    local _uc_id="$1" _state_dir="$2" _plugins_root="$3"
    local _downstream_success=0
    local _uc_until_var="_TPL_CYCLE_UNTIL_STAGE_${_uc_id//-/_}"
    local _uc_until="${!_uc_until_var:-}"
    if [[ -n "$_uc_until" ]]; then
        local _uc_plugin_dir _uc_manifest _uc_verdict
        _uc_plugin_dir="$(resolve_stage_plugin "$_uc_until" "$_plugins_root" 2>/dev/null || true)"
        # Guard the empty-resolution case (mirrors runner.sh): only read the
        # verdict when the target resolved to a real manifest file, else no-rescue.
        if [[ -n "$_uc_plugin_dir" && -f "$_uc_plugin_dir/manifest.yaml" ]]; then
            _uc_manifest="$_uc_plugin_dir/manifest.yaml"
            _uc_verdict="$(runner_read_stage_verdict_raw "$_state_dir" "$_uc_manifest" "$_uc_until" 0 2>/dev/null || true)"
            [[ "$_uc_verdict" == "approve" ]] && _downstream_success=1
        fi
    fi
    [[ "$_downstream_success" == "1" ]]
}

# _install_target <id> <primary_artifact_basename>
# Writes a manifest declaring a JSON primary output so runner_read_stage_verdict_raw
# reads .verdict from ${artifact_dir}/<basename>.
_install_target() {
    local _id="$1" _base="$2"
    local _dir="$PLUGINS_ROOT/$_id"
    mkdir -p "$_dir"
    cat > "$_dir/manifest.yaml" <<EOF
id: $_id
name: Test $_id
kind: agent
version: 0.0.1
hooks:
  run: ${_id//-/_}_run
requires:
  core:
    - redaction
outputs:
  - id: out
    path: \${artifact_dir}/$_base
    type: json
    required: true
    primary: true
EOF
}

# ─── T1: exit_when target verdict == approve → rescued ──────────────────────
t1="$TEST_TEMP_DIR/t1"; mkdir -p "$t1/artifacts"
export _TPL_CYCLE_UNTIL_STAGE_build_review_cycle="review"
_install_target "review" "review.json"
printf '{"verdict":"approve"}' > "$t1/artifacts/review.json"
if _rescue_success "build_review_cycle" "$t1" "$PLUGINS_ROOT"; then
    assert_pass "T1: exit_when target verdict=approve → rescued"
else
    assert_fail "T1: exit_when target verdict=approve → rescued" "not rescued"
fi

# ─── T2: exit_when target verdict == pass → NOT rescued (#979) ──────────────
t2="$TEST_TEMP_DIR/t2"; mkdir -p "$t2/artifacts"
export _TPL_CYCLE_UNTIL_STAGE_build_test_cycle="gate-aggregator"
_install_target "gate-aggregator" "gate-aggregator-result.json"
printf '{"verdict":"pass"}' > "$t2/artifacts/gate-aggregator-result.json"
if _rescue_success "build_test_cycle" "$t2" "$PLUGINS_ROOT"; then
    assert_fail "T2: exit_when target verdict=pass → NOT rescued (mechanical gate)" \
        "incorrectly rescued on mechanical pass"
else
    assert_pass "T2: exit_when target verdict=pass → NOT rescued (mechanical gate)"
fi

# ─── T3: exit_when target verdict == fail → NOT rescued ─────────────────────
t3="$TEST_TEMP_DIR/t3"; mkdir -p "$t3/artifacts"
export _TPL_CYCLE_UNTIL_STAGE_design_verify_cycle="design-gate"
_install_target "design-gate" "design-gate.json"
printf '{"verdict":"fail"}' > "$t3/artifacts/design-gate.json"
if _rescue_success "design_verify_cycle" "$t3" "$PLUGINS_ROOT"; then
    assert_fail "T3: exit_when target verdict=fail → NOT rescued" "incorrectly rescued"
else
    assert_pass "T3: exit_when target verdict=fail → NOT rescued"
fi

# ─── T4: exit_when target artifact absent → NOT rescued (#1298 guard) ───────
t4="$TEST_TEMP_DIR/t4"; mkdir -p "$t4/artifacts"
# design-gate target installed (from T3), but no artifact written for this run.
if _rescue_success "design_verify_cycle" "$t4" "$PLUGINS_ROOT"; then
    assert_fail "T4: exit_when target artifact absent → NOT rescued (safe default)" \
        "incorrectly rescued with absent target verdict"
else
    assert_pass "T4: exit_when target artifact absent → NOT rescued (safe default)"
fi

# ─── T5: no exit_when target declared for the cycle → NOT rescued ───────────
t5="$TEST_TEMP_DIR/t5"; mkdir -p "$t5/artifacts"
# _TPL_CYCLE_UNTIL_STAGE_nameless_cycle is unset.
if _rescue_success "nameless_cycle" "$t5" "$PLUGINS_ROOT"; then
    assert_fail "T5: no exit_when target → NOT rescued (safe default)" "incorrectly rescued"
else
    assert_pass "T5: no exit_when target → NOT rescued (safe default)"
fi

# ─── T6: a DIFFERENT stage approves but the TARGET is pass → NOT rescued ─────
# any-approve bug guard: the rescue reads ONLY the cycle's exit_when target, not
# any approving artifact in the dir. Here gate-aggregator (the target) is pass,
# and a stray review.json says approve — the run must NOT be rescued.
t6="$TEST_TEMP_DIR/t6"; mkdir -p "$t6/artifacts"
printf '{"verdict":"pass"}' > "$t6/artifacts/gate-aggregator-result.json"
printf '{"verdict":"approve"}' > "$t6/artifacts/review.json"
if _rescue_success "build_test_cycle" "$t6" "$PLUGINS_ROOT"; then
    assert_fail "T6: stray approve artifact + target=pass → NOT rescued (any-approve bug guard)" \
        "incorrectly rescued off a non-target artifact"
else
    assert_pass "T6: stray approve artifact + target=pass → NOT rescued (any-approve bug guard)"
fi

# ─── T7: exit_when target declared but does NOT resolve → NOT rescued ────────
# Copilot guard: an unresolvable target would make the manifest path a bare
# "/manifest.yaml" (filesystem root). The empty-resolution guard must treat this
# as no-rescue (→ failed), the safe default — never read a root-anchored path.
t7="$TEST_TEMP_DIR/t7"; mkdir -p "$t7/artifacts"
export _TPL_CYCLE_UNTIL_STAGE_ghost_cycle="no-such-stage"   # not installed → unresolvable
# Even a stray approving artifact must not rescue when the target can't resolve.
printf '{"verdict":"approve"}' > "$t7/artifacts/review.json"
if _rescue_success "ghost_cycle" "$t7" "$PLUGINS_ROOT"; then
    assert_fail "T7: unresolvable exit_when target → NOT rescued (empty-resolution guard)" \
        "incorrectly rescued when the target did not resolve"
else
    assert_pass "T7: unresolvable exit_when target → NOT rescued (empty-resolution guard)"
fi

# Clean up the exported template vars so they don't leak.
unset _TPL_CYCLE_UNTIL_STAGE_build_review_cycle \
      _TPL_CYCLE_UNTIL_STAGE_build_test_cycle \
      _TPL_CYCLE_UNTIL_STAGE_design_verify_cycle \
      _TPL_CYCLE_UNTIL_STAGE_ghost_cycle 2>/dev/null || true

# ─── Shape guard: runner.sh rescue block names no stage + reads exit_when ────
# ADR-047 stage-agnostic invariant: the rescue path names no stage and derives
# its target from the cycle's declared exit_when. Assert the rescue block (1)
# does NOT contain the literal "review.json" and (2) DOES derive the target via
# _TPL_CYCLE_UNTIL_STAGE (proves it reads the exit_when target, not a hardcode).
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
rescue_block="$(awk '
    /Determine downstream success\. Two paths:/ { in_block=1 }
    in_block && /_runner_compute_final_status/ { in_block=0 }
    in_block { print }
' "$RUNNER" 2>/dev/null || true)"

if [[ "$rescue_block" == *"review.json"* ]]; then
    assert_fail "Shape: runner.sh rescue block must not reference review.json by name (ADR-047)" \
        "Forbidden literal found in rescue block"
else
    assert_pass "Shape: runner.sh rescue block names no stage (ADR-047 invariant)"
fi

if [[ "$rescue_block" == *"_TPL_CYCLE_UNTIL_STAGE_"* ]]; then
    assert_pass "Shape: runner.sh rescue derives target from the cycle's exit_when"
else
    assert_fail "Shape: runner.sh rescue derives target from the cycle's exit_when" \
        "rescue block does not reference _TPL_CYCLE_UNTIL_STAGE_"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
