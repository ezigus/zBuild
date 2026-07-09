#!/usr/bin/env bash
# Unit: design's prompt charters EXHAUSTIVE scope discovery and invites
# Read/Grep tools (#841). Pre-#841 design reasoned blind from plan.json and
# emitted a scope block identical to the seed — it must instead enumerate
# every repo file the change touches (tests/configs/docs/goldens/constants).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: design prompt exhaustive-scope charter + tools (#841)"
setup_test_env "design-prompt-scope-charter-841"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Mock the router loop to a no-op success — we only inspect the prompt the
# inner function writes to <artifact_dir>/design-prompt.txt before routing.
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

FIX="$TEST_TEMP_DIR/fix"
mkdir -p "$FIX"
git -C "$FIX" init --quiet >/dev/null 2>&1
git -C "$FIX" config user.email 'test@example.com' >/dev/null
git -C "$FIX" config user.name 'test' >/dev/null
ARTIFACT_DIR="$FIX/state/artifacts"; mkdir -p "$ARTIFACT_DIR"
SCOPE_MANIFEST="$FIX/state/scope-manifest.md"; printf 'scope: all\n' > "$SCOPE_MANIFEST"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
OUTPUT_MD="$ARTIFACT_DIR/design.md"
export ZBUILD_REPO_ROOT="$FIX"
export MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"

_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1 || true

PROMPT="$ARTIFACT_DIR/design-prompt.txt"
assert_file_exists "design prompt written" "$PROMPT"

# T1: invites Read + Grep tools.
if grep -qiE 'Read tool|Grep tool|use .*Read.*Grep|Read and Grep' "$PROMPT"; then
    assert_pass "T1: prompt invites Read/Grep tool use"
else
    assert_fail "T1: prompt must invite Read/Grep" "got (head): $(head -40 "$PROMPT" | tr '\n' ' ' | cut -c1-200)"
fi

# T2: exhaustive-enumeration charter (not 'superset of seed').
if grep -qi 'exhaustive' "$PROMPT"; then
    assert_pass "T2: prompt states an exhaustive-enumeration charter"
else
    assert_fail "T2: prompt must demand exhaustive enumeration"
fi

# T3: old-value-pinning instruction (grep repo for files pinning old values).
if grep -qiE 'old value|pin|hardcode|grep .*repo|references|assumes' "$PROMPT"; then
    assert_pass "T3: prompt instructs finding files that pin/reference what changes"
else
    assert_fail "T3: prompt must instruct old-value/pinned-reference discovery"
fi

# T4: 'superset' framing dropped.
if grep -qi 'superset' "$PROMPT"; then
    assert_fail "T4: prompt should NOT use 'superset' framing anymore"
else
    assert_pass "T4: 'superset' framing removed"
fi

# T5: design stays read-only (must NOT invite Edit/Write/Bash for impl).
if grep -qiE 'do not .*(Edit|Write|Bash)|MUST NOT .*(Edit|Write)|forbidden.*Edit' "$PROMPT"; then
    assert_pass "T5: prompt keeps design read-only (no Edit/Write/Bash for impl)"
else
    assert_fail "T5: prompt must forbid Edit/Write/Bash (design is read-only enumeration)"
fi

# T6: simple.yaml design timeout raised to 600 (repo-wide grep headroom).
tmo="$(grep -A14 '^design:' "$REPO_ROOT/config/templates/simple.yaml" | grep -oE 'timeout_s:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "T6: design timeout_s raised to 600" "600" "${tmo:-unset}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
