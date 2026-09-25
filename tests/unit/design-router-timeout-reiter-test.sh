#!/usr/bin/env bash
# Tests: design plugin router-timeout → recoverable RE-ITERATE path (#945).
#
# ADR-021 Amendment #945: route_to_model_loop absorbs a persistent router
# timeout as a non-fatal YIELD — it RETURNS 0 with
# _ROUTE_LOOP_TERMINATED_REASON=router_timeout (core/router/route.sh; the #1208
# contract), NOT rc=124. _design_stage_run_inner detects that signal and must
# NOT converge on a gate-passing stub: it overwrites design.md with a MINIMAL
# marker that carries NO ```acceptance block, so the design-gate REJECTS it (C2
# ACCEPTANCE_MISSING) and design_verify_cycle RE-ITERATES rather than accepting
# an incomplete design. Genuine infra failures (rc=137 OOM) stay terminal.
#
# #2186: a timeout is judged on what THIS call did to design.md, never by
# fabricating a design. #1849 run 35949629759: the model wrote a complete design
# 9s before the kill and the marker overwrote it.
#
# SPEC coverage:
#   SPEC-1[change]: timeout, design.md unchanged by this call → the stale design
#                   is removed (no fabricated marker) and the gate fails → re-iterate
#   SPEC-2[guard]:  timeout yield → _design_stage_run_inner returns rc=0 (non-terminal)
#   SPEC-3[guard]:  timeout yield → plugin.result emitted with reason=router_timeout
#   SPEC-4[change]: timeout, nothing written → design.timeout.no_design emitted
#   SPEC-5[guard]:  rc=137 (OOM) → returns rc=1 (terminal, unchanged)
#   SPEC-6[guard]:  rc=137 (OOM) → plugin.result emitted with reason=router_oom_kill
#   SPEC-7[guard]:  rc=137 (OOM) → no design.md written (terminal, unchanged)
#   SPEC-8[guard]:  rc=0 with valid design.md → returns rc=0 (happy path unchanged)
#   SPEC-9[change]: timeout, the stale design cannot be removed → returns rc=1
#                   (terminal), reason=stale_design_not_removed
#   SPEC-12[change]: timeout AFTER this call wrote a new design → that design is
#                   kept as written, the gate judges it, design.timeout.design_kept
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: router-loop persistent timeout (return 0 + reason=router_timeout) → recoverable re-iterate path (#945)"
setup_test_env "design-router-timeout-reiter"

# ─── Mock setup ──────────────────────────────────────────────────────────────

# Source design plugin first so real route.sh/redaction get loaded, then
# override with mocks (same ordering as design-stray-file-recovery-test.sh).
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"
# Source the REAL design-gate so SPEC-1 asserts against its actual verdict
# (verdict-in-artifact convention, ADR-040) rather than the marker's shape.
# shellcheck source=../../plugins/tool/design-gate/plugin.sh
source "$REPO_ROOT/plugins/tool/design-gate/plugin.sh"

# _MOCK_ROUTER_RC controls what route_to_model_loop returns.
_MOCK_ROUTER_RC=0
# _MOCK_TERMINATED_REASON: the signal route_to_model_loop leaves in
# _ROUTE_LOOP_TERMINATED_REASON. This mirrors the REAL production contract
# (core/router/route.sh): a persistent timeout YIELDS as `return 0` +
# reason=router_timeout (NOT rc=124); a genuine error returns rc>=2; a normal
# finish returns 0 + reason=done_sentinel. The design plugin detects the
# recoverable timeout via THIS signal, so the mock must set it — a mock that
# returned 124 would never exercise the real branch.
_MOCK_TERMINATED_REASON="done_sentinel"
# _MOCK_DESIGN_WRITE_PATH: where the mock LLM writes design.md (empty = no write).
_MOCK_DESIGN_WRITE_PATH=""

route_to_model_loop() {
    local _bt='```'
    if [[ -n "$_MOCK_DESIGN_WRITE_PATH" ]]; then
        mkdir -p "$(dirname "$_MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[guard]: works\nWIRING: none\nTESTFILES:\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" > "$_MOCK_DESIGN_WRITE_PATH"
    fi
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="$_MOCK_TERMINATED_REASON"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return "$_MOCK_ROUTER_RC"
}

apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write()          { local dest="$1"; cat - > "$dest"; }

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

# _run_design_gate — run the REAL design-gate over the fixture's design.md and
# echo the resulting verdict (design-gate reads $(dirname state_file)/artifacts,
# which is _F_ARTIFACTS). Returns the verdict on stdout.
_run_design_gate() {
    design_gate_run "design-gate" "$_F_STATE/state.json" >/dev/null 2>&1 || true
    jq -r '.verdict // "MISSING"' "$_F_ARTIFACTS/design-gate-result.json" 2>/dev/null || echo "MISSING"
}

# ─── SPEC-1,2,3,4: router timeout YIELD → recoverable, gate-FAILING marker ────
# Real contract: the loop RETURNS 0 with _ROUTE_LOOP_TERMINATED_REASON=
# router_timeout (it does NOT return 124). The mock reproduces that exact signal
# so this exercises the PRODUCTION detection branch, not a dead rc=124 path.
_setup_fixture t1
# A design from an EARLIER pass is on disk: it must not survive a call that
# timed out without rewriting it (it would be judged as this pass's design).
printf '# Design\n\nstale from an earlier pass\n' > "$_F_DESIGN"
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="router_timeout"
_MOCK_DESIGN_WRITE_PATH=""    # LLM writes nothing (timed out)
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

# SPEC-1: no design is published — the stale one is gone and nothing is
# fabricated in its place — and the real gate fails, so the cycle re-iterates.
_verdict="$(_run_design_gate)"
if [[ ! -e "$_F_DESIGN" ]]; then
    assert_pass "[SPEC-1] timeout with design.md unchanged → no design published (stale removed, nothing fabricated)"
else
    assert_fail "[SPEC-1] a design was published for a call that wrote none" \
        "design.md=$(head -5 "$_F_DESIGN" 2>/dev/null)"
fi
if [[ "$_verdict" != "pass" ]]; then
    assert_pass "[SPEC-1b] the design-gate does not pass without a design → re-iterate"
else
    assert_fail "[SPEC-1b] the design-gate passed with no design"
fi

assert_eq "[SPEC-2] timeout yield → _design_stage_run_inner returns rc=0 (non-terminal)" "0" "$_rc"

_ev_to="$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q '"reason":"router_timeout"' <<< "$_ev_to"; then
    assert_pass "[SPEC-3] timeout yield → plugin.result emitted with reason=router_timeout"
else
    assert_fail "[SPEC-3] timeout yield → plugin.result reason=router_timeout missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

if grep -q '"design.timeout.no_design"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-4] timeout, nothing written → design.timeout.no_design emitted"
else
    assert_fail "[SPEC-4] timeout, nothing written → design.timeout.no_design missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

# [SPEC-8] (#1832, ADR-054): timeout yield writes verdict=incomplete +
# disposition=interrupted in the sidecar (was verdict=did_not_finish).
# Fails at baseline where sidecar had verdict=did_not_finish.
# [SPEC-9] (#1832): sidecar verdict=incomplete is the new timeout signal.
_sidecar="$_F_ARTIFACTS/design-verdict.json"
_sidecar_verdict="$(jq -r '.verdict // "MISSING"' "$_sidecar" 2>/dev/null || echo MISSING)"
_sidecar_disp="$(jq -r '.disposition // "MISSING"' "$_sidecar" 2>/dev/null || echo MISSING)"
if [[ -s "$_sidecar" ]] && [[ "$_sidecar_verdict" == "incomplete" ]]; then
    assert_pass "[SPEC-8] timeout yield → design-verdict.json sidecar verdict=incomplete (ADR-054, #1832)"
else
    assert_fail "[SPEC-8] timeout yield → sidecar should have verdict=incomplete" \
        "sidecar=$(cat "$_sidecar" 2>/dev/null || echo ABSENT)"
fi
assert_eq "[SPEC-9] design sidecar disposition=interrupted for router-timeout (#1832)" \
    "interrupted" "$_sidecar_disp"

# SPEC-10 (#1261, updated #1832): the sidecar exists and carries the right shape.
if [[ -s "$_sidecar" ]] && [[ "$_sidecar_verdict" == "incomplete" ]] \
    && [[ "$_sidecar_disp" == "interrupted" ]]; then
    assert_pass "[SPEC-10] timeout yield → design-verdict.json sidecar verdict=incomplete + disposition=interrupted"
else
    assert_fail "[SPEC-10] timeout yield → incomplete+interrupted sidecar missing/wrong" \
        "sidecar=$(cat "$_sidecar" 2>/dev/null || echo ABSENT)"
fi

# SPEC-11 (#1261, updated #1832): the REAL verdict readers surface incomplete for
# the design stage from the sidecar (design.md is non-JSON → would otherwise read "pass").
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
_dm="$REPO_ROOT/plugins/agent/design/manifest.yaml"
_raw="$(runner_read_stage_verdict_raw "$_F_STATE" "$_dm" "design" 0)"
assert_eq "[SPEC-11] runner_read_stage_verdict_raw(design) reads incomplete from sidecar (#1832)" \
    "incomplete" "$_raw"
_cls="$(runner_read_stage_verdict "$_F_STATE" "$_dm" "design" 0)"
assert_eq "[SPEC-11b] runner_read_stage_verdict(design) classifies incomplete → warn" \
    "warn" "$_cls"

_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH=""

# ─── SPEC-5,6,7: rc=137 (OOM) → terminal path (guard — genuine infra error) ──
# A genuine loop error surfaces as a non-zero rc with reason != router_timeout,
# so it must hit the classify → terminal branch, NOT the recoverable timeout.
_setup_fixture t2
_MOCK_ROUTER_RC=137
_MOCK_TERMINATED_REASON=""    # not router_timeout → must be treated as terminal
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

assert_eq "[SPEC-5] rc=137 → _design_stage_run_inner returns rc=1 (terminal)" "1" "$_rc"

_ev137="$(grep '"plugin.result"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q '"reason":"router_oom_kill"' <<< "$_ev137"; then
    assert_pass "[SPEC-6] rc=137 → plugin.result emitted with reason=router_oom_kill"
else
    assert_fail "[SPEC-6] rc=137 → plugin.result reason=router_oom_kill missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

# Confirm no marker was written on the terminal path.
[[ ! -f "$_F_DESIGN" ]] \
    && assert_pass "[SPEC-7] rc=137 → no design.md written (terminal)" \
    || assert_fail "[SPEC-7] rc=137 → design.md unexpectedly written on terminal path"

_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"

# ─── SPEC-8: rc=0 with valid design.md → rc=0 (happy-path guard) ─────────────
_setup_fixture t3
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH="$_F_DESIGN"
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

assert_eq "[SPEC-8] rc=0 with valid design.md → _design_stage_run_inner returns rc=0" "0" "$_rc"

# Confirm no spurious timeout event on happy path.
if ! grep -qE '"design\.timeout\.(no_design|design_kept)"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-8-guard] no design.timeout.* event on happy path"
else
    assert_fail "[SPEC-8-guard] spurious design.timeout.* event on happy path"
fi

# SPEC-10-guard (#1261): a converging design must NOT write an incomplete/interrupted
# sidecar (v2 contract writes verdict=pass,disposition=complete on happy path — that is
# fine; only did_not_finish / interrupted sidecars would trip the exhaustion halt).
_sc10_verdict="$(jq -r '.verdict // "MISSING"' "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null || echo ABSENT)"
_sc10_disp="$(jq -r '.disposition // "MISSING"' "$_F_ARTIFACTS/design-verdict.json" 2>/dev/null || echo ABSENT)"
if [[ "$_sc10_verdict" == "incomplete" || "$_sc10_disp" == "interrupted" ]]; then
    assert_fail "[SPEC-10-guard] spurious did_not_finish sidecar on happy path" \
        "verdict=$_sc10_verdict disposition=$_sc10_disp"
else
    assert_pass "[SPEC-10-guard] no spurious did_not_finish sidecar on happy path"
fi

_MOCK_DESIGN_WRITE_PATH=""

# ─── SPEC-9: timeout, the stale design cannot be removed → terminal ─────────
# Leaving it would publish an earlier pass's design as this one's. Force the
# removal to fail by making design.md a non-empty directory.
_setup_fixture t4
mkdir -p "$_F_DESIGN/x"
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="router_timeout"
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e
assert_eq "[SPEC-9] timeout + stale design not removable → returns rc=1 (terminal)" "1" "$_rc"
if grep -q '"reason":"stale_design_not_removed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-9b] → plugin.result reason=stale_design_not_removed"
else
    assert_fail "[SPEC-9b] → reason=stale_design_not_removed missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
rm -rf "$_F_DESIGN"

# ─── SPEC-12: timeout AFTER this call wrote a new design → kept, gate judges ─
_setup_fixture t5
printf '# Design\n\nstale from an earlier pass\n' > "$_F_DESIGN"
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="router_timeout"
_MOCK_DESIGN_WRITE_PATH="$_F_DESIGN"      # the model wrote its design, then was killed
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e
assert_eq "[SPEC-12] timeout after a new design → returns rc=0" "0" "$_rc"
if grep -q '^SPEC-1\[guard\]: works' "$_F_DESIGN" 2>/dev/null; then
    assert_pass "[SPEC-12] the design this call wrote is kept as written"
else
    assert_fail "[SPEC-12] the design this call wrote was replaced" \
        "design.md=$(head -5 "$_F_DESIGN" 2>/dev/null)"
fi
assert_eq "[SPEC-12] the gate judges the kept design (it is complete → pass)" "pass" "$(_run_design_gate)"
if grep -q '"design.timeout.design_kept"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-12] design.timeout.design_kept emitted"
else
    assert_fail "[SPEC-12] design.timeout.design_kept missing" "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
_MOCK_DESIGN_WRITE_PATH=""
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"

# ─── Schema registration check ────────────────────────────────────────────────
# #1717: design.* is the design plugin's own namespace, so the event is declared
# in the design manifest's provides.events and reaches the known set through
# composition — not through the engine's config/event-schema.json.
# shellcheck source=../../core/event-bus/known-types.sh
source "$REPO_ROOT/core/event-bus/known-types.sh"
for _ev in design.timeout.no_design design.timeout.design_kept; do
    grep -qxF "$_ev" <<< "$(eb_manifest_events "$REPO_ROOT/plugins/agent/design/manifest.yaml")" \
        && assert_pass "schema: $_ev declared in the design manifest" \
        || assert_fail "schema: $_ev missing from provides.events"
done

_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
