#!/usr/bin/env bash
# Tests: design plugin v2 result contract (issue #1834).
# SPEC-1 [change]: success path writes design-verdict.json with result_contract:2,
#                  verdict=pass, disposition=complete BEFORE atomic_write of design.md
# SPEC-2 [change]: error path (missing plan.json) writes design-verdict.json with
#                  result_contract:2, verdict=error, disposition=broken
# SPEC-3 [guard]:  timeout path writes verdict=incomplete, disposition=interrupted
# SPEC-4 [change]: manifest declares provides.result_contract:2 and
#                  config.valid_verdicts includes pass, error, and incomplete
# SPEC-5 [change]: design_stage_run reads scope_manifest and plan paths from
#                  ZBUILD_STAGE_INPUTS index when the env var is set
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: v2 result contract — design-verdict.json on all exit paths (#1834)"
setup_test_env "design-v2-result-contract"

# Source the design plugin so real dependencies load, then override mocks.
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH=""

route_to_model_loop() {
    local _bt='```'
    if [[ -n "${_MOCK_DESIGN_WRITE_PATH:-}" ]]; then
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

# Track whether sidecar was present when atomic_write was called for design.md.
# SPEC-1 requires the sidecar is written BEFORE atomic_write of design.md.
_SIDECAR_AT_ATOMIC_WRITE="UNSET"
atomic_write() {
    local dest="$1"
    if [[ "$dest" == *"/design.md" ]]; then
        local _sc="${dest%/*}/design-verdict.json"
        [[ -f "$_sc" ]] && _SIDECAR_AT_ATOMIC_WRITE="PRESENT" || _SIDECAR_AT_ATOMIC_WRITE="ABSENT"
    fi
    cat - > "$dest"
}

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
    _F_SIDECAR="$artifact_dir/design-verdict.json"
    _SIDECAR_AT_ATOMIC_WRITE="UNSET"
}

# ─── SPEC-1: success path writes sidecar with result_contract:2 before atomic_write
_setup_fixture t1
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH="$_F_DESIGN"
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

_sc1_rc2="$(jq -r '.result_contract // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
_sc1_verdict="$(jq -r '.verdict // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
_sc1_disp="$(jq -r '.disposition // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"

assert_eq "[SPEC-1] success → rc=0" "0" "$_rc"
assert_eq "[SPEC-1] success → design-verdict.json result_contract=2" "2" "$_sc1_rc2"
assert_eq "[SPEC-1] success → design-verdict.json verdict=pass" "pass" "$_sc1_verdict"
assert_eq "[SPEC-1] success → design-verdict.json disposition=complete" "complete" "$_sc1_disp"
assert_eq "[SPEC-1] sidecar written before atomic_write of design.md" "PRESENT" "$_SIDECAR_AT_ATOMIC_WRITE"

# ─── SPEC-2: missing plan.json → sidecar verdict=error, disposition=broken ────
_setup_fixture t2
rm -f "$_F_PLAN"
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

_sc2_rc2="$(jq -r '.result_contract // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
_sc2_verdict="$(jq -r '.verdict // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
_sc2_disp="$(jq -r '.disposition // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"

assert_eq "[SPEC-2] missing plan → rc=1" "1" "$_rc"
assert_eq "[SPEC-2] missing plan → design-verdict.json result_contract=2" "2" "$_sc2_rc2"
assert_eq "[SPEC-2] missing plan → design-verdict.json verdict=error" "error" "$_sc2_verdict"
assert_eq "[SPEC-2] missing plan → design-verdict.json disposition=broken" "broken" "$_sc2_disp"

# ─── SPEC-3 [guard]: timeout path writes verdict=incomplete, disposition=interrupted
_setup_fixture t3
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="router_timeout"
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e

_sc3_verdict="$(jq -r '.verdict // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
_sc3_disp="$(jq -r '.disposition // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
_sc3_rc2="$(jq -r '.result_contract // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"

assert_eq "[SPEC-3] timeout → verdict=incomplete (guard)" "incomplete" "$_sc3_verdict"
assert_eq "[SPEC-3] timeout → disposition=interrupted (guard)" "interrupted" "$_sc3_disp"
assert_eq "[SPEC-3] timeout → result_contract=2 (guard)" "2" "$_sc3_rc2"

# ─── SPEC-4 [change]: manifest declares result_contract:2 and valid_verdicts ──
_DM="$REPO_ROOT/plugins/agent/design/manifest.yaml"

_dm_rc2="$(grep -m1 'result_contract:' "$_DM" | awk '{print $2}' || true)"
assert_eq "[SPEC-4] manifest provides.result_contract=2" "2" "$_dm_rc2"

grep -q '^\s*-\s*pass\s*$' "$_DM" 2>/dev/null \
    && assert_pass "[SPEC-4] manifest config.valid_verdicts contains 'pass'" \
    || assert_fail "[SPEC-4] manifest config.valid_verdicts missing 'pass'"
grep -q '^\s*-\s*error\s*$' "$_DM" 2>/dev/null \
    && assert_pass "[SPEC-4] manifest config.valid_verdicts contains 'error'" \
    || assert_fail "[SPEC-4] manifest config.valid_verdicts missing 'error'"
grep -q '^\s*-\s*incomplete\s*$' "$_DM" 2>/dev/null \
    && assert_pass "[SPEC-4] manifest config.valid_verdicts contains 'incomplete'" \
    || assert_fail "[SPEC-4] manifest config.valid_verdicts missing 'incomplete'"

# ─── SPEC-5 [change]: design_stage_run reads paths from ZBUILD_STAGE_INPUTS ──
_setup_fixture t5

# Create inputs at NON-DEFAULT paths — if the fallback is used (default paths),
# the run fails because $_F_SCOPE and $_F_PLAN are deleted.
_CUSTOM_SCOPE="$TEST_TEMP_DIR/t5-custom-scope.md"
_CUSTOM_PLAN="$TEST_TEMP_DIR/t5-custom-plan.json"
printf 'scope: custom\n' > "$_CUSTOM_SCOPE"
cat > "$_CUSTOM_PLAN" <<'EOF'
{"schema_version":1,"title":"custom","goal":"g","steps":[{"id":"step-1","description":"d","files":["bar.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF

_INPUTS_INDEX="$TEST_TEMP_DIR/t5-inputs.json"
printf '{"inputs":{"scope_manifest":"%s","plan":"%s"}}\n' "$_CUSTOM_SCOPE" "$_CUSTOM_PLAN" \
    > "$_INPUTS_INDEX"
export ZBUILD_STAGE_INPUTS="$_INPUTS_INDEX"

# Delete the default-path files so only the ZBUILD_STAGE_INPUTS paths can succeed.
rm -f "$_F_SCOPE" "$_F_PLAN"

_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH="$_F_DESIGN"

_F_STATE_FILE="$_F_STATE/pipeline-state.json"
printf '{}' > "$_F_STATE_FILE"

set +e
design_stage_run "design" "$_F_STATE_FILE"
_rc5=$?
set -e

unset ZBUILD_STAGE_INPUTS

assert_eq "[SPEC-5] design_stage_run uses plan from ZBUILD_STAGE_INPUTS (rc=0)" "0" "$_rc5"
[[ -f "$_F_DESIGN" ]] \
    && assert_pass "[SPEC-5] design.md produced via ZBUILD_STAGE_INPUTS index paths" \
    || assert_fail "[SPEC-5] design.md missing — ZBUILD_STAGE_INPUTS paths not used"

# ─── SPEC-6..9: the remaining four error paths ───────────────────────────────
# SPEC-2 covered missing_plan_json as the representative error path. The issue's
# acceptance says "a conformant v2 result on EVERY exit path", and four paths
# that call _design_write_result had no assertion, so the claim was not
# machine-verifiable. One SPEC each, driving the real _design_stage_run_inner.
#
# Each also asserts design-summary.md, which the manifest declares
# required:true / summary:true — "written on every terminal verdict, so absence
# means something went wrong". stray_conflict was missing that call entirely
# (found in review of this PR); the others already had it and are held still.

# _assert_error_path <spec> <label> <expected_reason>
# Reads the sidecar and summary left by the run the caller just drove.
_assert_error_path() {
    local spec="$1" label="$2" want_reason="$3"
    assert_eq "[$spec] $label → rc=1" "1" "$_rc"
    assert_eq "[$spec] $label → result_contract=2" \
        "2" "$(jq -r '.result_contract // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
    assert_eq "[$spec] $label → verdict=error" \
        "error" "$(jq -r '.verdict // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
    assert_eq "[$spec] $label → disposition=broken" \
        "broken" "$(jq -r '.disposition // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
    assert_eq "[$spec] $label → reason=$want_reason" \
        "$want_reason" "$(jq -r '.reason // "MISSING"' "$_F_SIDECAR" 2>/dev/null || echo MISSING)"
    if [[ -s "$_F_ARTIFACTS/design-summary.md" ]]; then
        assert_pass "[$spec] $label → design-summary.md written (required:true)"
    else
        assert_fail "[$spec] $label → design-summary.md written (required:true)" \
            "missing or empty: $_F_ARTIFACTS/design-summary.md"
    fi
}

# SPEC-6 — router returns cleanly but writes no design.md, and no stray at root.
_setup_fixture t6
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH=""
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e
_assert_error_path "SPEC-6" "no design.md produced" "missing_design_md"

# SPEC-7 — a design.md with no ```scope block.
_setup_fixture t7
_MOCK_ROUTER_RC=0
_MOCK_TERMINATED_REASON="done_sentinel"
_MOCK_DESIGN_WRITE_PATH=""
route_to_model_loop() {
    mkdir -p "$(dirname "$_F_DESIGN")"
    printf '# Design\n\n## Decision\nNo scope block here.\n' > "$_F_DESIGN"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e
_assert_error_path "SPEC-7" "design.md without a scope block" "missing_scope_block"

# SPEC-8 — a design.md with a scope block but no ```acceptance block.
_setup_fixture t8
route_to_model_loop() {
    local _bt='```'
    mkdir -p "$(dirname "$_F_DESIGN")"
    printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\nfoo.sh\n%s\n' "$_bt" "$_bt" > "$_F_DESIGN"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e
_assert_error_path "SPEC-8" "design.md without an acceptance block" "missing_acceptance_block"

# SPEC-9 — the model wrote design.md to the repo root, where a TRACKED file
# already lives. The plugin must refuse to relocate it (operator-owned) rather
# than overwrite, and still report. This is the path whose summary write was
# missing before this PR.
_setup_fixture t9
printf '# operator-owned design\n' > "$_F_DIR/design.md"
git -C "$_F_DIR" add design.md >/dev/null 2>&1
git -C "$_F_DIR" commit -m "operator design" --quiet >/dev/null 2>&1
route_to_model_loop() {
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
set +e
_design_stage_run_inner "$_F_SCOPE" "$_F_PLAN" "$_F_DESIGN" "$_F_ARTIFACTS"
_rc=$?
set -e
_assert_error_path "SPEC-9" "tracked design.md at repo root" "stray_conflict"

# The operator's file is the whole reason this path refuses — it must survive.
assert_eq "[SPEC-9] the tracked repo-root design.md is left untouched" \
    "# operator-owned design" "$(cat "$_F_DIR/design.md" 2>/dev/null || true)"

_test_cleanup_hook() { cleanup_test_env; }
print_test_results
exit $((FAIL > 0))
