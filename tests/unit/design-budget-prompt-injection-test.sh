#!/usr/bin/env bash
# Tests: design plugin ADR-063 §1/§2 — budget guidance injected into the prompt.
# SPEC-6 [change]: prompt file contains a WALL CLOCK BUDGET block with timeout_s
#                  value sourced from _route_resolve_timeout
# SPEC-7 [change]: prompt file contains a TURN BUDGET block with max_turns value
#                  sourced from _route_resolve_max_turns
# SPEC-8 [guard]:  existing prompt body instructions (scope charter, acceptance
#                  contract, tools section) are present and unaltered when budget
#                  blocks are injected
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: ADR-063 §1/§2 — budget guidance injected into prompt (#1834)"
setup_test_env "design-budget-prompt-injection"

# Source the design plugin so real route.sh / redaction get loaded, then override.
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Override budget resolvers with known sentinel values so the assertions can be
# precise: any appearance of "777" for timeout or "99" for max_turns proves the
# live resolver output reached the prompt.
_route_resolve_max_turns() { printf '99'; }
_route_resolve_timeout()   { printf '777'; }

_MOCK_DESIGN_WRITE_PATH=""
route_to_model_loop() {
    local _bt='```'
    if [[ -n "${_MOCK_DESIGN_WRITE_PATH:-}" ]]; then
        mkdir -p "$(dirname "$_MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[guard]: works\nWIRING: none\nTESTFILES:\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" > "$_MOCK_DESIGN_WRITE_PATH"
    fi
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }

FIX="$TEST_TEMP_DIR/fixture"
mkdir -p "$FIX"
git -C "$FIX" init --quiet >/dev/null 2>&1
git -C "$FIX" config user.email 'test@example.com' >/dev/null 2>&1
git -C "$FIX" config user.name  'test' >/dev/null 2>&1
ARTIFACT_DIR="$FIX/state/artifacts"; mkdir -p "$ARTIFACT_DIR"
SCOPE_MANIFEST="$FIX/state/scope-manifest.md"; printf 'scope: all\n' > "$SCOPE_MANIFEST"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
OUTPUT_MD="$ARTIFACT_DIR/design.md"
export ZBUILD_REPO_ROOT="$FIX"
export ZBUILD_EVENTS_JSONL="$FIX/state/events.jsonl"
export ZBUILD_EVENTS_DIR="$FIX/state"
: > "$ZBUILD_EVENTS_JSONL"
_MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"

_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1 || true

PROMPT="$ARTIFACT_DIR/design-prompt.txt"

# ─── SPEC-6 [change]: WALL CLOCK BUDGET block with timeout_s from _route_resolve_timeout
if [[ -f "$PROMPT" ]] && grep -q "WALL CLOCK BUDGET" "$PROMPT" && grep -q "777" "$PROMPT"; then
    assert_pass "[SPEC-6] prompt contains WALL CLOCK BUDGET block with timeout_s=777"
else
    _dbg_wc=""
    [[ -f "$PROMPT" ]] || _dbg_wc="prompt file absent"
    grep -q "WALL CLOCK BUDGET" "$PROMPT" 2>/dev/null \
        || _dbg_wc="${_dbg_wc:+$_dbg_wc; }WALL CLOCK BUDGET header missing"
    grep -q "777" "$PROMPT" 2>/dev/null \
        || _dbg_wc="${_dbg_wc:+$_dbg_wc; }timeout value 777 missing"
    assert_fail "[SPEC-6] prompt missing WALL CLOCK BUDGET block with timeout_s=777" "$_dbg_wc"
fi

# ─── SPEC-7 [change]: TURN BUDGET block with max_turns from _route_resolve_max_turns
if [[ -f "$PROMPT" ]] && grep -q "TURN BUDGET" "$PROMPT" && grep -q "99" "$PROMPT"; then
    assert_pass "[SPEC-7] prompt contains TURN BUDGET block with max_turns=99"
else
    _dbg_tb=""
    [[ -f "$PROMPT" ]] || _dbg_tb="prompt file absent"
    grep -q "TURN BUDGET" "$PROMPT" 2>/dev/null \
        || _dbg_tb="${_dbg_tb:+$_dbg_tb; }TURN BUDGET header missing"
    grep -q "99" "$PROMPT" 2>/dev/null \
        || _dbg_tb="${_dbg_tb:+$_dbg_tb; }max_turns value 99 missing"
    assert_fail "[SPEC-7] prompt missing TURN BUDGET block with max_turns=99" "$_dbg_tb"
fi

# ─── SPEC-8 [guard]: existing prompt instructions are present and unaltered ─────
# The scope charter instructs exhaustive scope discovery (design's core contract).
grep -q 'MUST actively search the repo' "$PROMPT" 2>/dev/null \
    && assert_pass "[SPEC-8] scope charter instruction present and unaltered (guard)" \
    || assert_fail "[SPEC-8] scope charter missing from prompt" \
        "expected 'MUST actively search the repo'"

# The acceptance contract instructs the fenced ```acceptance block format.
grep -q '```acceptance' "$PROMPT" 2>/dev/null \
    && assert_pass "[SPEC-8] acceptance contract instruction present and unaltered (guard)" \
    || assert_fail "[SPEC-8] acceptance contract instruction missing from prompt" \
        "expected backtick-triple acceptance in prompt"

# The tools section names which tools are allowed.
grep -q '## Tools (read-only' "$PROMPT" 2>/dev/null \
    && assert_pass "[SPEC-8] tools section present and unaltered (guard)" \
    || assert_fail "[SPEC-8] tools section missing from prompt" \
        "expected '## Tools (read-only' in prompt"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
