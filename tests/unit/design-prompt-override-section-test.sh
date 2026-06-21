#!/usr/bin/env bash
# Unit: design appends a per-repo prompt override AFTER its core contract and
# BEFORE redaction (ADR-032, #854), and states the generic enumerated-set
# principle. Mirrors design-prompt-scope-charter-test.sh's mock scaffold.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: design prompt per-repo override section (#854)"
setup_test_env "design-prompt-override-section-854"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Passthrough mocks: redaction = cp so we can prove the override survives into
# design-prompt.redacted.txt (i.e. it was appended BEFORE redaction ran).
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

# Shared fixture builder: a git repo with an optional override file.
_run_design() {
    local fix="$1"
    mkdir -p "$fix"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local artifact_dir="$fix/state/artifacts"; mkdir -p "$artifact_dir"
    local scope_manifest="$fix/state/scope-manifest.md"; printf 'scope: all\n' > "$scope_manifest"
    local plan_json="$artifact_dir/plan.json"
    cat > "$plan_json" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    local output_md="$artifact_dir/design.md"
    ZBUILD_REPO_ROOT="$fix" MOCK_DESIGN_WRITE_PATH="$output_md" \
        _design_stage_run_inner "$scope_manifest" "$plan_json" "$output_md" "$artifact_dir" >/dev/null 2>&1 || true
    printf '%s' "$artifact_dir"
}

# ── Case group A: override PRESENT ──────────────────────────────────────────
FIX_A="$TEST_TEMP_DIR/fix_present"
mkdir -p "$FIX_A/.zbuild/prompts"
printf '# repo overlay\nRULE_MARKER_D2 enumerate the roster\n' > "$FIX_A/.zbuild/prompts/design-overrides.md"
ART_A="$(_run_design "$FIX_A")"
PROMPT_A="$ART_A/design-prompt.txt"
REDACTED_A="$ART_A/design-prompt.redacted.txt"
assert_file_exists "design prompt written (present case)" "$PROMPT_A"

# D1: generic enumerated-set / absence principle present (target-agnostic).
if grep -qiE 'enumerat|by OMISSION|absence' "$PROMPT_A"; then
    assert_pass "D1: generic enumerated-set principle present"
else
    assert_fail "D1: prompt must state the generic enumerated-set principle"
fi

# D1b: the generic charter carries NO zbuild-self-hosting vocabulary.
if grep -qE '_make_plugin|mock_plugin_factory|_make_role_plugin' "$PROMPT_A"; then
    # It is allowed ONLY inside the operator-override section, never in the charter.
    charter_only="$(awk '/## Project-specific guidance/{exit} {print}' "$PROMPT_A")"
    if grep -qE '_make_plugin|mock_plugin_factory' <<< "$charter_only"; then
        assert_fail "D1b: shipped charter must contain ZERO target vocabulary"
    else
        assert_pass "D1b: target tokens appear only in the override section, not the charter"
    fi
else
    assert_pass "D1b: no target tokens in prompt charter"
fi

# D2: override section header + content present when file exists.
assert_contains "D2: override delimiter present" "$(cat "$PROMPT_A")" "## Project-specific guidance (operator override)"
assert_contains "D2: override content present" "$(cat "$PROMPT_A")" "RULE_MARKER_D2"

# D3: override section appears AFTER the core contract (ordering invariant).
hdr_line="$(grep -n '## Project-specific guidance (operator override)' "$PROMPT_A" | head -1 | cut -d: -f1)"
scope_line="$(grep -n '```scope' "$PROMPT_A" | head -1 | cut -d: -f1)"
loop_line="$(grep -n 'LOOP_COMPLETE' "$PROMPT_A" | head -1 | cut -d: -f1)"
if [[ -n "$hdr_line" && -n "$scope_line" && "$hdr_line" -gt "$scope_line" ]]; then
    assert_pass "D3: override section is after the scope-format contract"
else
    assert_fail "D3: override must follow the core contract" "hdr=$hdr_line scope=$scope_line"
fi
if [[ -n "$hdr_line" && -n "$loop_line" && "$hdr_line" -gt "$loop_line" ]]; then
    assert_pass "D3b: override section is after the LOOP_COMPLETE instruction"
else
    assert_fail "D3b: override must follow LOOP_COMPLETE" "hdr=$hdr_line loop=$loop_line"
fi

# D4: override survives into the redacted prompt (proves append happened BEFORE
# redaction on prompt_input_file, not after on redacted_file).
assert_file_exists "D4: redacted prompt written" "$REDACTED_A"
assert_contains "D4: override is redaction-covered" "$(cat "$REDACTED_A")" "RULE_MARKER_D2"

# ── Case group B: override ABSENT ───────────────────────────────────────────
FIX_B="$TEST_TEMP_DIR/fix_absent"
ART_B="$(_run_design "$FIX_B")"
PROMPT_B="$ART_B/design-prompt.txt"
assert_file_exists "design prompt written (absent case)" "$PROMPT_B"

# D5: no override file → no delimiter noise, contract intact.
if grep -q '## Project-specific guidance (operator override)' "$PROMPT_B"; then
    assert_fail "D5: must NOT emit override delimiter when no override file"
else
    assert_pass "D5: no override delimiter when override absent"
fi
assert_contains "D5b: core contract intact when no override" "$(cat "$PROMPT_B")" "LOOP_COMPLETE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
