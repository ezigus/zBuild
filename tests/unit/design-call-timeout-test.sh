#!/usr/bin/env bash
# Tests: design's one model call runs out of time, or dies (#945, #2186,
# ADR-068 §8 amended).
#
# design makes ONE route_to_model call per run (ADR-068 §8). The call returns
# rc=124 when its time runs out (core/router/route.sh, the verbatim-124 path)
# and rc=137 when it is killed. What design does next depends only on what the
# call left in the working copy (#2186: never a fabricated design):
#   - nothing new → no design to check: design.md stays the last good design
#     (it was deleted before, so the next try started from nothing — #1944 run
#     38883031887: 12 calls, none of which wrote anything), and the result says
#     why, so the engine runs design again (the template's retry:).
#   - a new design written before the cut-off → it counts: checked like any.
#
# SPEC coverage:
#   SPEC-1[change]: timeout, nothing written → the last good design.md is kept
#                   and design does not pass
#   SPEC-2[change]: ...→ returns rc=1, and the result is timed_out, which the
#                   engine re-runs (contract 3)
#   SPEC-3[guard]:  ...→ plugin.result emitted with reason=router_timeout
#   SPEC-4[change]: ...→ the summary says design ran out of time before writing
#                   a design, without blaming the infrastructure
#   SPEC-5[guard]:  rc=137 (OOM) → returns rc=1
#   SPEC-6[guard]:  rc=137 (OOM) → plugin.result emitted with reason=router_oom_kill
#   SPEC-7[guard]:  rc=137 (OOM) with no earlier design → no design.md written
#   SPEC-8[guard]:  rc=0 with a valid design → returns rc=0, outcome pass
#   SPEC-11[guard]: the engine's readers see timed_out / router_timeout
#   SPEC-12[guard]: timeout AFTER the call wrote a new design → that design is
#                   checked and, passing, becomes design.md
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: its one model call runs out of time or dies (ADR-068 §8)"
setup_test_env "design-call-timeout"

# ─── Mock setup ──────────────────────────────────────────────────────────────

# Source design plugin first so real route.sh/redaction get loaded, then
# override with mocks (same ordering as design-stray-file-recovery-test.sh).
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# _MOCK_ROUTER_RC: what the call returns (124 = out of time, 137 = killed).
# _MOCK_WRITE: 1 = the model writes a complete design where its prompt says
# before it returns, 0 = it writes nothing.
_MOCK_ROUTER_RC=0
_MOCK_WRITE=0
route_to_model() {
    local _bt='```' _t; _t="$(zb_test_prompt_write_path "$2")"
    if [[ "$_MOCK_WRITE" == 1 && -n "$_t" ]]; then
        mkdir -p "$(dirname "$_t")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[no-code]: works\nWIRING: none\nTESTFILES:\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" > "$_t"
    fi
    return "$_MOCK_ROUTER_RC"
}

apply_scope_redaction() { cp "$1" "$2"; return 0; }
# Through a temp file, as the real atomic_write does.
atomic_write()          { local dest="$1"; cat - > "$dest.tmp" && mv -f "$dest.tmp" "$dest"; }

# ─── Per-test fixture helper ──────────────────────────────────────────────────
_setup_fixture() {
    local test_id="$1"
    local dir="$TEST_TEMP_DIR/$test_id"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init --quiet >/dev/null 2>&1
    git -C "$dir" config user.email 'test@example.com' >/dev/null 2>&1
    git -C "$dir" config user.name  'test' >/dev/null 2>&1
    local state_dir="$dir/state"
    local artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"
    printf 'scope: all\n' > "$state_dir/scope-manifest.md"
    cat > "$artifact_dir/plan.json" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    export ZBUILD_REPO_ROOT="$dir"
    export ZBUILD_EVENTS_JSONL="$state_dir/events.jsonl"
    export ZBUILD_EVENTS_DIR="$state_dir"
    : > "$ZBUILD_EVENTS_JSONL"
    _F_DIR="$dir"
    _F_STATE="$state_dir"
    _F_ARTIFACTS="$artifact_dir"
    _F_SCOPE="$state_dir/scope-manifest.md"
    _F_PLAN="$artifact_dir/plan.json"
    _F_DESIGN="$artifact_dir/design.md"
}

# _run_design_gate — design's own outcome for this call.
_run_design_gate() {
    jq -r '.outcome // "MISSING"' "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null || echo "MISSING"
}

# ─── SPEC-1..4: out of time, nothing written ─────────────────────────────────
_setup_fixture t1
LAST_GOOD='# Design

the last good design'
printf '%s\n' "$LAST_GOOD" > "$_F_DESIGN"
_MOCK_ROUTER_RC=124; _MOCK_WRITE=0
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set +e

assert_eq "[SPEC-1] timeout, nothing written → the last good design.md is kept" \
    "$LAST_GOOD" "$(cat "$_F_DESIGN" 2>/dev/null)"
if [[ "$(_run_design_gate)" != "pass" ]]; then
    assert_pass "[SPEC-1b] design does not pass without a new design"
else
    assert_fail "[SPEC-1b] design passed with no new design"
fi
assert_eq "[SPEC-2] → returns rc=1" "1" "$_rc"
_sidecar="$_F_ARTIFACTS/design-verdict.json"
assert_eq "[SPEC-2] → the result is contract 3" "3" "$(jq -r '.result_contract // "MISSING"' "$_sidecar" 2>/dev/null)"
assert_eq "[SPEC-2] → its outcome is timed_out (the engine re-runs it)" "timed_out" "$(_run_design_gate)"

_ev_to="$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q '"reason":"router_timeout"' <<< "$_ev_to"; then
    assert_pass "[SPEC-3] → plugin.result emitted with reason=router_timeout"
else
    assert_fail "[SPEC-3] → plugin.result reason=router_timeout missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

_summ="$(cat "$_F_ARTIFACTS/design-summary.md" 2>/dev/null)"
assert_contains "[SPEC-4] the summary says design ran out of time before writing a design" "$_summ" \
    "Design ran out of time before writing a design."
assert_contains "[SPEC-4] ...and that design.md is still the last good design" "$_summ" \
    "it stays the last good design"
if grep -qi "infrastructure" <<< "$_summ"; then
    assert_fail "[SPEC-4] the summary does not blame the infrastructure" "$_summ"
else
    assert_pass "[SPEC-4] the summary does not blame the infrastructure"
fi

# SPEC-11 (#1261, #2366): the engine's readers see that design did not finish.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
_dm="$REPO_ROOT/plugins/agent/design/manifest.yaml"
assert_eq "[SPEC-11] runner_read_stage_disposition(design) reads timed_out" \
    "timed_out" "$(runner_read_stage_disposition "$_F_STATE" "$_dm" "design" 1)"
_raw="$(runner_read_stage_verdict_raw "$_F_STATE" "$_dm" "design" 1)"
if [[ -n "$_raw" && "$_raw" != pass ]]; then
    assert_pass "[SPEC-11] runner_read_stage_verdict_raw(design): not a pass ($_raw)"
else
    assert_fail "[SPEC-11] runner_read_stage_verdict_raw(design): not a pass" "got: ${_raw:-<empty>}"
fi
assert_eq "[SPEC-11b] ...with reason router_timeout" \
    "router_timeout" "$(runner_read_stage_reason "$_F_STATE" "$_dm" "design" 1)"

# ─── SPEC-5,6,7: rc=137 (OOM) ────────────────────────────────────────────────
_setup_fixture t2
_MOCK_ROUTER_RC=137; _MOCK_WRITE=0
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set +e
assert_eq "[SPEC-5] rc=137 → returns rc=1" "1" "$_rc"
if grep -q '"reason":"router_oom_kill"' <<< "$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"; then
    assert_pass "[SPEC-6] rc=137 → plugin.result emitted with reason=router_oom_kill"
else
    assert_fail "[SPEC-6] rc=137 → plugin.result reason=router_oom_kill missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
[[ ! -f "$_F_DESIGN" ]] \
    && assert_pass "[SPEC-7] rc=137 → no design.md written" \
    || assert_fail "[SPEC-7] rc=137 → design.md unexpectedly written"

# ─── SPEC-8: rc=0 with a valid design ────────────────────────────────────────
_setup_fixture t3
_MOCK_ROUTER_RC=0; _MOCK_WRITE=1
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set +e
assert_eq "[SPEC-8] rc=0 with a valid design → returns rc=0" "0" "$_rc"
assert_eq "[SPEC-8] → outcome pass" "pass" "$(_run_design_gate)"

# ─── SPEC-12: out of time AFTER the call wrote a new design ──────────────────
_setup_fixture t5
printf '%s\n' "$LAST_GOOD" > "$_F_DESIGN"
_MOCK_ROUTER_RC=124; _MOCK_WRITE=1     # the model wrote its design, then was cut off
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set +e
assert_eq "[SPEC-12] timeout after a new design → returns rc=0" "0" "$_rc"
if grep -q '^SPEC-1\[no-code\]: works' "$_F_DESIGN" 2>/dev/null; then
    assert_pass "[SPEC-12] the design this call wrote becomes design.md"
else
    assert_fail "[SPEC-12] the design this call wrote did not become design.md" \
        "design.md=$(head -5 "$_F_DESIGN" 2>/dev/null)"
fi
assert_eq "[SPEC-12] design checked it (it is complete → pass)" "pass" "$(_run_design_gate)"
_MOCK_ROUTER_RC=0; _MOCK_WRITE=0

_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
