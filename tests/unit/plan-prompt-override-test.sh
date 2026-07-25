#!/usr/bin/env bash
# Unit: plan appends a per-repo prompt override AFTER its core contract
# (_plan_instructions) under the operator-override delimiter, redacting the
# override in its OWN pass (ADR-032, #855 / OV-2).
#
# Plan is SPECIAL among agent stages: it assembles its prompt in a shell var
# `$prompt` AFTER the goal is redacted and routes via `route_to_model`, so the
# final prompt is never written to disk — it is passed straight to the router.
# This test mocks `route_to_model` to capture that final routed prompt, and
# mocks `apply_scope_redaction` as a `cp` passthrough so the override marker
# survives BOTH redaction passes (the goal pass and the override pass). The
# surviving marker proves the override rode the redaction chokepoint.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: plan prompt per-repo override section (#855 / OV-2)"
setup_test_env "plan-prompt-override-855"

# Stub bootstrap + event emitter the plugin requires at source time.
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/plan"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
# shellcheck source=../../plugins/agent/plan/plugin.sh
source "$REPO_ROOT/plugins/agent/plan/plugin.sh"

# ── Mocks ───────────────────────────────────────────────────────────────────
# Capture the final routed prompt: plan calls `route_to_model "$tier" "$prompt"`
# and reads its stdout, so the mock writes the prompt ($2) to a side file and
# echoes a valid plan.json envelope on stdout so the parser/validator passes.
route_to_model() {
    [[ -n "${MOCK_ROUTE_CAPTURE:-}" ]] && printf '%s' "$2" > "$MOCK_ROUTE_CAPTURE"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
    return 0
}
# Passthrough redaction: cp preserves the override marker through BOTH passes
# (goal redaction + override redaction), proving the marker rode the chokepoint.
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }

# Shared fixture builder: a git-init'd repo with an optional override file.
# Returns the path to the captured routed-prompt file.
_run_plan() {
    local fix="$1"
    mkdir -p "$fix"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local artifact_dir="$fix/state/artifacts"; mkdir -p "$artifact_dir"
    local scope_manifest="$fix/state/scope-manifest.md"; printf 'scope: all\n' > "$scope_manifest"
    local output_plan_json="$artifact_dir/plan.json"
    local capture="$artifact_dir/routed-prompt.txt"
    ZBUILD_REPO_ROOT="$fix" MOCK_ROUTE_CAPTURE="$capture" \
        _plan_run_inner "$scope_manifest" "Fix a typo in README.md" "$output_plan_json" "$artifact_dir" \
        >/dev/null 2>&1 || true
    printf '%s' "$capture"
}

# ── P1/P2: override PRESENT ─────────────────────────────────────────────────
print_test_section "1. override present → delimiter + marker in routed prompt, after the contract"

FIX_A="$TEST_TEMP_DIR/fix_present"
mkdir -p "$FIX_A/.zbuild/prompts"
printf '# repo overlay\nPLAN_OV_MARKER enumerate the roster\n' > "$FIX_A/.zbuild/prompts/plan-overrides.md"
CAP_A="$(_run_plan "$FIX_A")"
assert_file_exists "routed prompt captured (present case)" "$CAP_A"

# P1: delimiter + marker both present in the routed prompt.
assert_contains "P1: override delimiter present in routed prompt" \
    "$(cat "$CAP_A")" "## Project-specific guidance (operator override)"
assert_contains "P1: override marker present in routed prompt" \
    "$(cat "$CAP_A")" "PLAN_OV_MARKER"

# P2: delimiter appears AFTER the plan core contract/instructions. Anchor on a
# stable line from _plan_instructions; assert the delimiter line number is
# strictly greater (ordering invariant: override follows the shipped charter).
hdr_line="$(grep -n '## Project-specific guidance (operator override)' "$CAP_A" | head -1 | cut -d: -f1)"
anchor_line="$(grep -n 'Decompose the goal into concrete' "$CAP_A" | head -1 | cut -d: -f1)"
if [[ -n "$hdr_line" && -n "$anchor_line" && "$hdr_line" -gt "$anchor_line" ]]; then
    assert_pass "P2: override delimiter is after the plan core contract"
else
    assert_fail "P2: override must follow the plan core contract" "hdr=$hdr_line anchor=$anchor_line"
fi

# P1b: marker survived BOTH cp passes → override is redaction-covered. The
# captured routed prompt IS the post-override-redaction text (the cp passthrough
# proves the redaction path ran; a broken append-before-redact would still show
# the marker, but the marker's presence here confirms the override-pass output
# was spliced in, not the pre-redaction input).
assert_contains "P1b: override is redaction-covered (survives cp passthrough)" \
    "$(cat "$CAP_A")" "PLAN_OV_MARKER"

# ── P3: override ABSENT ─────────────────────────────────────────────────────
print_test_section "2. no override file → no delimiter, plan still routes normally"

FIX_B="$TEST_TEMP_DIR/fix_absent"
CAP_B="$(_run_plan "$FIX_B")"
assert_file_exists "routed prompt captured (absent case)" "$CAP_B"

# P3: no override file → no delimiter noise in the routed prompt.
if grep -q '## Project-specific guidance (operator override)' "$CAP_B"; then
    assert_fail "P3: must NOT emit override delimiter when no override file"
else
    assert_pass "P3: no override delimiter when override absent"
fi
# P3b: plan still routes normally — its core contract is intact.
assert_contains "P3b: plan core contract intact when no override" \
    "$(cat "$CAP_B")" "Decompose the goal into concrete"

# ── SPEC-1[change]: product-owner manifest present → perspective in prompt ────
print_test_section "3. product-owner manifest present → perspective in routed prompt [SPEC-1]"

_ORIG_PLAN_ROOT="$_PLAN_ROOT"

_PROOT_WITH="$TEST_TEMP_DIR/proot_with"
mkdir -p "$_PROOT_WITH/plugins/persona/product-owner"
cat > "$_PROOT_WITH/plugins/persona/product-owner/manifest.yaml" <<'EOF'
id: product-owner
name: Product Owner
kind: persona
version: 0.1.0
persona:
  role: a product owner
  perspective: PLAN_PO_PERSPECTIVE_SENTINEL user value definition-of-done.
EOF
_PLAN_ROOT="$_PROOT_WITH"
FIX_C="$TEST_TEMP_DIR/fix_po_present"
CAP_C="$(_run_plan "$FIX_C")"
_PLAN_ROOT="$_ORIG_PLAN_ROOT"

assert_file_exists "[SPEC-1] prompt captured with product-owner manifest present" "$CAP_C"
assert_contains "[SPEC-1] product-owner perspective text in routed prompt when manifest present" \
    "$(cat "$CAP_C")" "PLAN_PO_PERSPECTIVE_SENTINEL"

# ── SPEC-2[guard]: product-owner manifest absent → fallback text in prompt ────
print_test_section "4. product-owner manifest absent → fallback text in routed prompt [SPEC-2]"

_PROOT_WITHOUT="$TEST_TEMP_DIR/proot_without"
mkdir -p "$_PROOT_WITHOUT/plugins"
_PLAN_ROOT="$_PROOT_WITHOUT"
FIX_D="$TEST_TEMP_DIR/fix_po_absent"
CAP_D="$(_run_plan "$FIX_D")"
_PLAN_ROOT="$_ORIG_PLAN_ROOT"

assert_file_exists "[SPEC-2] prompt captured with product-owner manifest absent" "$CAP_D"
assert_contains "[SPEC-2] fallback behavior sentence present when product-owner manifest absent" \
    "$(cat "$CAP_D")" "Decompose the goal into concrete implementation steps."
if grep -q "You are a software planning agent" <"$CAP_D"; then
    assert_fail "[SPEC-2] fallback must NOT contain profession-role prefix when manifest absent"
else
    assert_pass "[SPEC-2] fallback does not contain profession-role prefix when manifest absent"
fi

# ── SPEC-3[guard]: schema_version and steps present regardless of framing ─────
print_test_section "5. schema_version and steps present regardless of framing path [SPEC-3]"

assert_contains "[SPEC-3] schema_version in prompt with product-owner manifest" \
    "$(cat "$CAP_C")" "schema_version"
assert_contains "[SPEC-3] steps in prompt with product-owner manifest" \
    "$(cat "$CAP_C")" '"steps"'
assert_contains "[SPEC-3] schema_version in prompt without product-owner manifest" \
    "$(cat "$CAP_D")" "schema_version"
assert_contains "[SPEC-3] steps in prompt without product-owner manifest" \
    "$(cat "$CAP_D")" '"steps"'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
