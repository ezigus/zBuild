#!/usr/bin/env bash
# Unit (#1324): design stage uses persona_stage_framing to open its prompt.
# SPEC-1[change] — with architect manifest present, the prompt includes the
#   persona perspective text (new behavior; fails at merge-base baseline).
# SPEC-2[guard]  — with architect manifest absent, the prompt falls back to
#   'You are a software architect for the target project.' (existing behavior).
# SPEC-3[guard]  — the '## Plan' section is present regardless of framing path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: design persona framing seam (#1324)"
setup_test_env "design-persona-framing-1324"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# ── Mocks (mirrors design-prior-gate-feedback-test.sh pattern) ───────────────
_CAPTURED_PERSONA_FILE=""
route_to_model_loop() {
    [[ -n "${_CAPTURED_PERSONA_FILE:-}" ]] && printf '%s' "${ZBUILD_STAGE_IO_PERSONA:-__unset__}" > "$_CAPTURED_PERSONA_FILE"
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]] && {
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        local _bt='```'
        printf '# Design\n\n## Decision\nImpl per plan.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[change]: persona framing\nTESTFILES:\ntests/unit/design-persona-framing-test.sh\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" > "$MOCK_DESIGN_WRITE_PATH"
    }
    _ROUTE_LOOP_FINAL_OUTPUT="ok"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }
_route_loop_close_final_banner() { return 0; }

# Build a minimal fixture: git repo, scope-manifest.md, plan.json.
_setup_fixture() {
    local fix; fix="$(mktemp -d "$TEST_TEMP_DIR/fix.XXXXXX")"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local ad="$fix/state/artifacts"; mkdir -p "$ad"
    printf 'scope: all\n' > "$fix/state/scope-manifest.md"
    cat > "$ad/plan.json" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    export ZBUILD_REPO_ROOT="$fix"
    printf '%s' "$ad"
}

# Build a temp _DESIGN_ROOT whose plugins/ subdir contains the architect persona.
# The design plugin passes "$_DESIGN_ROOT/plugins" to persona_stage_framing.
_root_with_architect() {
    local dr; dr="$(mktemp -d "$TEST_TEMP_DIR/droot.XXXXXX")"
    mkdir -p "$dr/plugins/persona/architect"
    cat > "$dr/plugins/persona/architect/manifest.yaml" <<'EOF'
id: architect
name: Software Architect
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: Focus on boundaries and interfaces.
EOF
    printf '%s' "$dr"
}

# Build a temp _DESIGN_ROOT whose plugins/ has no architect manifest.
_root_without_architect() {
    local dr; dr="$(mktemp -d "$TEST_TEMP_DIR/droot_empty.XXXXXX")"
    mkdir -p "$dr/plugins"
    printf '%s' "$dr"
}

_ORIG_DESIGN_ROOT="$_DESIGN_ROOT"

# ── SPEC-1[change]: architect manifest present → perspective in prompt ─────────
AD1="$(_setup_fixture)"
DROOT1="$(_root_with_architect)"
_DESIGN_ROOT="$DROOT1"
export MOCK_DESIGN_WRITE_PATH="$AD1/design.md"
_design_stage_run_inner \
    "$(dirname "$AD1")/scope-manifest.md" \
    "$AD1/plan.json" \
    "$AD1/design.md" \
    "$AD1" >/dev/null 2>&1 || true
_DESIGN_ROOT="$_ORIG_DESIGN_ROOT"

PROMPT1="$AD1/design-prompt.txt"
assert_file_exists "SPEC-1: prompt file written when architect manifest present" "$PROMPT1"
assert_contains "[SPEC-1] architect perspective text in prompt when manifest present" \
    "$(cat "$PROMPT1")" "Focus on boundaries and interfaces."

# ── SPEC-2[guard]: architect manifest absent → fallback text in prompt ─────────
AD2="$(_setup_fixture)"
DROOT2="$(_root_without_architect)"
_DESIGN_ROOT="$DROOT2"
export MOCK_DESIGN_WRITE_PATH="$AD2/design.md"
_design_stage_run_inner \
    "$(dirname "$AD2")/scope-manifest.md" \
    "$AD2/plan.json" \
    "$AD2/design.md" \
    "$AD2" >/dev/null 2>&1 || true
_DESIGN_ROOT="$_ORIG_DESIGN_ROOT"

PROMPT2="$AD2/design-prompt.txt"
assert_file_exists "SPEC-2: prompt file written when architect manifest absent" "$PROMPT2"
assert_contains "[SPEC-2] fallback text present when manifest absent" \
    "$(cat "$PROMPT2")" "You are a software architect for the target project."
# Byte-identical fallback (DoD): the opening two lines must reproduce the exact
# pre-#1324 framing, including the original mid-sentence wrap after "produce an".
_expected_open=$'You are a software architect for the target project. Your job is to produce an\nADR-style design.md for the task described in the plan below.'
assert_eq "[SPEC-2] fallback opening is byte-identical to the pre-persona framing" \
    "$_expected_open" "$(head -2 "$PROMPT2")"

# ── SPEC-3[guard]: ## Plan section present regardless of framing path ──────────
assert_contains "[SPEC-3] ## Plan present in prompt with architect manifest" \
    "$(cat "$PROMPT1")" "## Plan"
assert_contains "[SPEC-3] ## Plan present in prompt without architect manifest" \
    "$(cat "$PROMPT2")" "## Plan"

# ── SPEC-1[change]: design exports ZBUILD_STAGE_IO_PERSONA=architect when manifest present ──
AD_S1="$(_setup_fixture)"
DROOT_S1="$(_root_with_architect)"
_DESIGN_ROOT="$DROOT_S1"
_CAPTURED_PERSONA_FILE="$TEST_TEMP_DIR/spec1-persona.txt"
export MOCK_DESIGN_WRITE_PATH="$AD_S1/design.md"
_design_stage_run_inner \
    "$(dirname "$AD_S1")/scope-manifest.md" \
    "$AD_S1/plan.json" \
    "$AD_S1/design.md" \
    "$AD_S1" >/dev/null 2>&1 || true
_DESIGN_ROOT="$_ORIG_DESIGN_ROOT"
_CAPTURED_PERSONA_FILE=""

assert_file_exists "SPEC-1: persona capture file written (architect present)" "$TEST_TEMP_DIR/spec1-persona.txt"
_PERSONA1="$(cat "$TEST_TEMP_DIR/spec1-persona.txt" 2>/dev/null || true)"
assert_eq "[SPEC-1] design exports ZBUILD_STAGE_IO_PERSONA=architect when manifest present" \
    "architect" "$_PERSONA1"

# ── SPEC-4[change]: design exports ZBUILD_STAGE_IO_PERSONA=architect:fallback when manifest absent
AD_S4="$(_setup_fixture)"
DROOT_S4="$(_root_without_architect)"
_DESIGN_ROOT="$DROOT_S4"
_CAPTURED_PERSONA_FILE="$TEST_TEMP_DIR/spec4-persona.txt"
export MOCK_DESIGN_WRITE_PATH="$AD_S4/design.md"
_design_stage_run_inner \
    "$(dirname "$AD_S4")/scope-manifest.md" \
    "$AD_S4/plan.json" \
    "$AD_S4/design.md" \
    "$AD_S4" >/dev/null 2>&1 || true
_DESIGN_ROOT="$_ORIG_DESIGN_ROOT"
_CAPTURED_PERSONA_FILE=""

assert_file_exists "SPEC-4: persona capture file written (architect absent)" "$TEST_TEMP_DIR/spec4-persona.txt"
_PERSONA4="$(cat "$TEST_TEMP_DIR/spec4-persona.txt" 2>/dev/null || true)"
assert_eq "[SPEC-4] design exports ZBUILD_STAGE_IO_PERSONA=architect:fallback when manifest absent" \
    "architect:fallback" "$_PERSONA4"

cleanup_test_env
print_test_results
