#!/usr/bin/env bash
# Tests: design plugin rc=124 router timeout → recoverable RE-ITERATE path (#945).
#
# ADR-021 Amendment #945: a rc=124 (gtimeout SIGTERM) router timeout inside
# _design_stage_run_inner must NOT converge on a gate-passing stub. It returns
# rc=0 (non-terminal, #1208) but overwrites design.md with a MINIMAL marker that
# carries NO ```acceptance block, so the design-gate REJECTS it (C2
# ACCEPTANCE_MISSING) and design_verify_cycle RE-ITERATES rather than accepting
# an incomplete design. Genuine infra failures (rc=137 OOM) stay terminal.
#
# SPEC coverage:
#   SPEC-1[change]: rc=124 → the produced design.md FAILS the real design-gate
#                   (verdict=fail, ACCEPTANCE_MISSING) → the cycle re-iterates
#   SPEC-2[change]: rc=124 → _design_stage_run_inner returns rc=0 (non-terminal)
#   SPEC-3[change]: rc=124 → plugin.run.error emitted with reason=router_timeout
#   SPEC-4[change]: rc=124 → design.timeout.stub_written event emitted
#   SPEC-5[guard]:  rc=137 → returns rc=1 (terminal, unchanged)
#   SPEC-6[guard]:  rc=137 → plugin.run.error emitted with reason=router_oom_kill
#   SPEC-7[guard]:  rc=137 → no design.md written (terminal, unchanged)
#   SPEC-8[guard]:  rc=0 with valid design.md → returns rc=0 (happy path unchanged)
#   SPEC-9[change]: rc=124 but the marker write FAILS → returns rc=1 (terminal),
#                   reason=marker_write_failed, no design.timeout.stub_written
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: router timeout rc=124 → recoverable re-iterate path (#945)"
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
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
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

# ─── SPEC-1,2,3,4: rc=124 → recoverable, gate-FAILING marker → re-iterate ─────
_setup_fixture t1
_MOCK_ROUTER_RC=124
_MOCK_DESIGN_WRITE_PATH=""    # LLM writes nothing (timed out)
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

# SPEC-1: the marker must exist AND be REJECTED by the real design-gate, so the
# design_verify_cycle re-iterates rather than converging on it. (Red at the
# merge-base — where rc=124 wrote no design.md — and red at the prior stub
# baseline, where the stub PASSED the gate.)
_verdict="$(_run_design_gate)"
_gate_fb="$_F_ARTIFACTS/design-gate-feedback.md"
if [[ -f "$_F_DESIGN" ]] && [[ "$_verdict" == "fail" ]] \
    && grep -q 'ACCEPTANCE_MISSING' "$_gate_fb" 2>/dev/null; then
    assert_pass "[SPEC-1] rc=124 timeout marker FAILS the design-gate (ACCEPTANCE_MISSING) → re-iterate"
else
    assert_fail "[SPEC-1] rc=124 timeout marker did NOT fail the design-gate" \
        "verdict=$_verdict design.md=$(cat "$_F_DESIGN" 2>/dev/null | head -20)"
fi

assert_eq "[SPEC-2] rc=124 → _design_stage_run_inner returns rc=0 (non-terminal)" "0" "$_rc"

_ev124="$(grep '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q '"reason":"router_timeout"' <<< "$_ev124"; then
    assert_pass "[SPEC-3] rc=124 → plugin.run.error emitted with reason=router_timeout"
else
    assert_fail "[SPEC-3] rc=124 → plugin.run.error reason=router_timeout missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

if grep -q '"design.timeout.stub_written"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-4] rc=124 → design.timeout.stub_written event emitted"
else
    assert_fail "[SPEC-4] rc=124 → design.timeout.stub_written event missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

_MOCK_ROUTER_RC=0
_MOCK_DESIGN_WRITE_PATH=""

# ─── SPEC-5,6,7: rc=137 → terminal path (guard — unchanged behavior) ─────────
_setup_fixture t2
_MOCK_ROUTER_RC=137
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

assert_eq "[SPEC-5] rc=137 → _design_stage_run_inner returns rc=1 (terminal)" "1" "$_rc"

_ev137="$(grep '"plugin.run.error"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if grep -q '"reason":"router_oom_kill"' <<< "$_ev137"; then
    assert_pass "[SPEC-6] rc=137 → plugin.run.error emitted with reason=router_oom_kill"
else
    assert_fail "[SPEC-6] rc=137 → plugin.run.error reason=router_oom_kill missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

# Confirm no marker was written on the terminal path.
[[ ! -f "$_F_DESIGN" ]] \
    && assert_pass "[SPEC-7] rc=137 → no design.md written (terminal)" \
    || assert_fail "[SPEC-7] rc=137 → design.md unexpectedly written on terminal path"

_MOCK_ROUTER_RC=0

# ─── SPEC-8: rc=0 with valid design.md → rc=0 (happy-path guard) ─────────────
_setup_fixture t3
_MOCK_ROUTER_RC=0
_MOCK_DESIGN_WRITE_PATH="$_F_DESIGN"
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

assert_eq "[SPEC-8] rc=0 with valid design.md → _design_stage_run_inner returns rc=0" "0" "$_rc"

# Confirm no spurious timeout event on happy path.
if ! grep -q '"design.timeout.stub_written"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-8-guard] no design.timeout.stub_written on happy path"
else
    assert_fail "[SPEC-8-guard] spurious design.timeout.stub_written on happy path"
fi

_MOCK_DESIGN_WRITE_PATH=""

# ─── SPEC-9: rc=124 but the marker write FAILS → terminal (return 1) ──────────
# A failed filesystem write on the recovery path is a genuine infra error, not a
# recoverable timeout: it must NOT mask as rc=0 with no artifact. Force the
# redirect to fail by making the output path a directory (`printf > dir` → rc=1).
_setup_fixture t4
mkdir -p "$_F_DESIGN"        # design.md is a directory → the marker redirect fails
_MOCK_ROUTER_RC=124
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

assert_eq "[SPEC-9] rc=124 + failed marker write → returns rc=1 (terminal)" "1" "$_rc"

if grep -q '"reason":"marker_write_failed"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-9b] failed marker write → plugin.run.error reason=marker_write_failed"
else
    assert_fail "[SPEC-9b] failed marker write → reason=marker_write_failed missing" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi

if ! grep -q '"design.timeout.stub_written"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "[SPEC-9c] failed marker write → no design.timeout.stub_written (write never landed)"
else
    assert_fail "[SPEC-9c] failed marker write → spurious design.timeout.stub_written"
fi

_MOCK_ROUTER_RC=0

# ─── Schema registration check ────────────────────────────────────────────────
SCHEMA="$REPO_ROOT/config/event-schema.json"
grep -q '"design.timeout.stub_written"' "$SCHEMA" \
    && assert_pass "schema: design.timeout.stub_written registered in event-schema.json" \
    || assert_fail "schema: design.timeout.stub_written missing from event-schema.json"

_test_cleanup_hook() { cleanup_test_env; }

print_test_results
exit $((FAIL > 0))
