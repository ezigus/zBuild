#!/usr/bin/env bash
# Unit (#1219, ADR-045/ADR-046): design splices the prior_gate_feedback payload
# (design-feedback.md, written by the gate-aggregator on a route_design verdict)
# into its prompt on a route_back REPLAY, so the re-authoring design pass sees the
# named tautological [change] SPECs. On the FIRST design pass the file is absent
# (required:false) → the prompt is byte-identical to the no-feedback case (no-op).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: design prior_gate_feedback splice (#1219, ADR-046)"
setup_test_env "design-prior-gate-feedback-1219"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Mock the router loop to a no-op success — we only inspect the prompt the inner
# function writes to <artifact_dir>/design-prompt.txt before routing.
route_to_model_loop() {
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]] && {
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$MOCK_DESIGN_WRITE_PATH"
    }
    _ROUTE_LOOP_FINAL_OUTPUT="ok"; _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0; _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }
_route_loop_close_final_banner() { return 0; }

_setup_fixture() {  # → echoes ARTIFACT_DIR
    local fix; fix="$(mktemp -d "$TEST_TEMP_DIR/fix.XXXXXX")"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local ad="$fix/state/artifacts"; mkdir -p "$ad"
    printf 'scope: all\n' > "$fix/state/scope-manifest.md"
    cat > "$ad/plan.json" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    export ZBUILD_REPO_ROOT="$fix"
    printf '%s' "$ad"
}

# ── T1: design-feedback.md present → its body is spliced into the prompt ──────
AD1="$(_setup_fixture)"
cat > "$AD1/design-feedback.md" <<'EOF'
# Design-rooted gate feedback
SPEC-7 is tautological (pass at baseline) — re-author the assertion.
EOF
export MOCK_DESIGN_WRITE_PATH="$AD1/design.md"
_design_stage_run_inner "$(dirname "$AD1")/scope-manifest.md" "$AD1/plan.json" "$AD1/design.md" "$AD1" >/dev/null 2>&1 || true
PROMPT1="$AD1/design-prompt.txt"
assert_file_exists "T1: design prompt written" "$PROMPT1"
assert_contains "T1: prompt carries the design-rooted gate feedback body" \
    "$(cat "$PROMPT1")" "SPEC-7 is tautological"
assert_contains_regex "T1: prompt instructs re-authoring the tautological SPEC" \
    "$(cat "$PROMPT1")" "[Rr]e-author"

# ── T2: design-feedback.md absent → prompt has NO gate-feedback section (no-op) ─
AD2="$(_setup_fixture)"
export MOCK_DESIGN_WRITE_PATH="$AD2/design.md"
_design_stage_run_inner "$(dirname "$AD2")/scope-manifest.md" "$AD2/plan.json" "$AD2/design.md" "$AD2" >/dev/null 2>&1 || true
PROMPT2="$AD2/design-prompt.txt"
assert_file_exists "T2: design prompt written (no feedback)" "$PROMPT2"
if grep -qi 'PRIOR GATE FEEDBACK' "$PROMPT2"; then
    assert_fail "T2: first pass (no design-feedback.md) must NOT add a gate-feedback section" \
        "$(grep -i 'PRIOR GATE FEEDBACK' "$PROMPT2")"
else
    assert_pass "T2: first pass omits the gate-feedback section (no-op when file absent)"
fi

cleanup_test_env
print_test_results
