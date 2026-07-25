#!/usr/bin/env bash
# Unit (#1393/#1572): plan stage uses persona_stage_framing to open its prompt.
# SPEC-1[change] — with product-owner manifest present, the prompt includes the
#   persona perspective text (new behavior; fails at merge-base baseline).
# SPEC-2[guard]  — with product-owner manifest absent, the prompt falls back to
#   behavior-only framing with no profession-role prefix (updated by #1572).
# SPEC-3[guard]  — the schema_version/steps section is present regardless of framing path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: plan persona framing seam (#1393)"
setup_test_env "plan-persona-framing-1393"

# Stub bootstrap + event emitter the plugin requires at source time.
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/plan"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
# shellcheck source=../../plugins/agent/plan/plugin.sh
source "$REPO_ROOT/plugins/agent/plan/plugin.sh"

# ── Mocks ───────────────────────────────────────────────────────────────────
# Capture the final routed prompt: plan calls `route_to_model "$tier" "$prompt"`
# and reads its stdout, so the mock writes the prompt ($2) to a side file and
# echoes a valid plan.json envelope on stdout so the parser/validator passes.
# _CAPTURED_PERSONA_FILE captures ZBUILD_STAGE_IO_PERSONA at the time of the call.
_CAPTURED_PROMPT_FILE=""
_CAPTURED_PERSONA_FILE=""
route_to_model() {
    [[ -n "${_CAPTURED_PROMPT_FILE:-}" ]] && printf '%s' "$2" > "$_CAPTURED_PROMPT_FILE"
    [[ -n "${_CAPTURED_PERSONA_FILE:-}" ]] && printf '%s' "${ZBUILD_STAGE_IO_PERSONA:-__unset__}" > "$_CAPTURED_PERSONA_FILE"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}'
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }

# Shared fixture builder: a git-init'd repo with scope-manifest + output paths.
_setup_fixture() {
    local fix; fix="$(mktemp -d "$TEST_TEMP_DIR/fix.XXXXXX")"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local ad="$fix/state/artifacts"; mkdir -p "$ad"
    printf 'scope: all\n' > "$fix/state/scope-manifest.md"
    printf '%s' "$ad"
}

# Build a temp _PLAN_ROOT whose plugins/ subdir contains the product-owner persona.
_root_with_product_owner() {
    local pr; pr="$(mktemp -d "$TEST_TEMP_DIR/proot.XXXXXX")"
    mkdir -p "$pr/plugins/persona/product-owner"
    cat > "$pr/plugins/persona/product-owner/manifest.yaml" <<'EOF'
id: product-owner
name: Product Owner
kind: persona
version: 0.1.0
persona:
  role: a product owner
  perspective: Focus on user value and acceptance criteria.
EOF
    printf '%s' "$pr"
}

# Build a temp _PLAN_ROOT whose plugins/ has no product-owner manifest.
_root_without_product_owner() {
    local pr; pr="$(mktemp -d "$TEST_TEMP_DIR/proot_empty.XXXXXX")"
    mkdir -p "$pr/plugins"
    printf '%s' "$pr"
}

_ORIG_PLAN_ROOT="$_PLAN_ROOT"

# ── SPEC-1[change]: product-owner manifest present → perspective in prompt ────
AD1="$(_setup_fixture)"
PROOT1="$(_root_with_product_owner)"
_PLAN_ROOT="$PROOT1"
_CAPTURED_PROMPT_FILE="$AD1/routed-prompt.txt"
ZBUILD_REPO_ROOT="$AD1" \
    _plan_run_inner \
    "$(dirname "$AD1")/scope-manifest.md" \
    "Fix a typo in README.md" \
    "$AD1/plan.json" \
    "$AD1" >/dev/null 2>&1 || true
_PLAN_ROOT="$_ORIG_PLAN_ROOT"

PROMPT1="$AD1/routed-prompt.txt"
assert_file_exists "SPEC-1: prompt captured when product-owner manifest present" "$PROMPT1"
assert_contains "[SPEC-1] product-owner perspective text in prompt when manifest present" \
    "$(cat "$PROMPT1")" "Focus on user value and acceptance criteria."

# ── SPEC-2[guard]: product-owner manifest absent → fallback text in prompt ────
AD2="$(_setup_fixture)"
PROOT2="$(_root_without_product_owner)"
_PLAN_ROOT="$PROOT2"
_CAPTURED_PROMPT_FILE="$AD2/routed-prompt.txt"
ZBUILD_REPO_ROOT="$AD2" \
    _plan_run_inner \
    "$(dirname "$AD2")/scope-manifest.md" \
    "Fix a typo in README.md" \
    "$AD2/plan.json" \
    "$AD2" >/dev/null 2>&1 || true
_PLAN_ROOT="$_ORIG_PLAN_ROOT"

PROMPT2="$AD2/routed-prompt.txt"
assert_file_exists "SPEC-2: prompt captured when product-owner manifest absent" "$PROMPT2"
assert_contains "[SPEC-2] fallback behavior sentence present when manifest absent" \
    "$(cat "$PROMPT2")" "Decompose the goal into concrete implementation steps."
if grep -q "You are a software planning agent" <"$PROMPT2"; then
    assert_fail "[SPEC-2] fallback must NOT contain profession-role prefix when manifest absent"
else
    assert_pass "[SPEC-2] fallback does not contain profession-role prefix when manifest absent"
fi

# ── SPEC-3[guard]: schema_version + steps present regardless of framing path ─
assert_contains "[SPEC-3] schema_version in prompt with product-owner manifest" \
    "$(cat "$PROMPT1")" "schema_version"
assert_contains "[SPEC-3] steps in prompt with product-owner manifest" \
    "$(cat "$PROMPT1")" '"steps"'
assert_contains "[SPEC-3] schema_version in prompt without product-owner manifest" \
    "$(cat "$PROMPT2")" "schema_version"
assert_contains "[SPEC-3] steps in prompt without product-owner manifest" \
    "$(cat "$PROMPT2")" '"steps"'

# ── SPEC-3 [change]: plan exports ZBUILD_STAGE_IO_PERSONA=product-owner when manifest present
AD3="$(_setup_fixture)"
PROOT3="$(_root_with_product_owner)"
_PLAN_ROOT="$PROOT3"
_CAPTURED_PROMPT_FILE=""
_CAPTURED_PERSONA_FILE="$TEST_TEMP_DIR/spec3-persona.txt"
ZBUILD_REPO_ROOT="$AD3" \
    _plan_run_inner \
    "$(dirname "$AD3")/scope-manifest.md" \
    "Fix a typo in README.md" \
    "$AD3/plan.json" \
    "$AD3" >/dev/null 2>&1 || true
_PLAN_ROOT="$_ORIG_PLAN_ROOT"

assert_file_exists "SPEC-3: persona export file captured" "$_CAPTURED_PERSONA_FILE"
_PERSONA3="$(cat "$_CAPTURED_PERSONA_FILE" 2>/dev/null || true)"
assert_eq "[SPEC-3] plan exports ZBUILD_STAGE_IO_PERSONA=product-owner when manifest present" \
    "product-owner" "$_PERSONA3"
_CAPTURED_PERSONA_FILE=""

cleanup_test_env
print_test_results
exit $((FAIL > 0))
