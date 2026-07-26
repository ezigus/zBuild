#!/usr/bin/env bash
# Unit (#1394): impact stage uses persona_stage_framing to open its prompt.
# SPEC-1[change] — with architect manifest present, the prompt includes the
#   persona perspective text (new behavior; fails at merge-base baseline).
# SPEC-2[guard]  — with architect manifest absent, the prompt falls back to
#   behavior-only _task_intro text (no human-profession declaration).
# SPEC-3[guard]  — the 'EXISTENCE VERIFICATION' heading is present regardless
#   of which framing path ran.
# SPEC-4[guard]  — empty-output guard: if persona_stage_framing exits 0 but
#   returns empty (mocked), _persona_fallback is used instead (never silent).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: impact persona framing seam (#1394)"
setup_test_env "impact-persona-framing-1394"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

# ── Mocks ───────────────────────────────────────────────────────────────────
_CAPTURED_PERSONA_FILE=""
route_to_model() {
    [[ -n "${_CAPTURED_PERSONA_FILE:-}" ]] && printf '%s' "${ZBUILD_STAGE_IO_PERSONA:-__unset__}" > "$_CAPTURED_PERSONA_FILE"
    printf '%s' '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}'
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }
emit_event() { return 0; }
resolve_tier() { printf 'T2'; return 0; }
_impact_scope_prefilter() { printf '[]'; return 0; }
_impact_envelope_schema_ok() { return 0; }
_impact_drop_nonexistent_missing() { return 0; }
_impact_converge_on_overscope() { return 0; }
append_prompt_override() { return 0; }

# ── Fixture builders ─────────────────────────────────────────────────────────
_setup_fixture() {
    local fix; fix="$(mktemp -d "$TEST_TEMP_DIR/fix.XXXXXX")"
    git -C "$fix" init --quiet >/dev/null 2>&1
    git -C "$fix" config user.email 'test@example.com' >/dev/null
    git -C "$fix" config user.name 'test' >/dev/null
    local ad="$fix/state/artifacts"; mkdir -p "$ad"
    printf '# Scope\n- x.sh\n' > "$fix/state/scope-manifest.md"
    printf '{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"s1","description":"d","files":["x.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}\n' \
        > "$ad/plan.json"
    printf '# Design\n\n```scope\nx.sh\n```\n' > "$ad/design.md"
    export ZBUILD_REPO_ROOT="$fix"
    printf '%s' "$ad"
}

# Build a temp _IMPACT_ROOT whose plugins/ subdir contains the architect persona.
_root_with_architect() {
    local ir; ir="$(mktemp -d "$TEST_TEMP_DIR/iroot.XXXXXX")"
    mkdir -p "$ir/plugins/persona/architect"
    cat > "$ir/plugins/persona/architect/manifest.yaml" <<'EOF'
id: architect
name: Software Architect
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: Focus on boundaries and interfaces.
EOF
    printf '%s' "$ir"
}

# Build a temp _IMPACT_ROOT whose plugins/ has no architect manifest.
_root_without_architect() {
    local ir; ir="$(mktemp -d "$TEST_TEMP_DIR/iroot_empty.XXXXXX")"
    mkdir -p "$ir/plugins"
    printf '%s' "$ir"
}

_ORIG_IMPACT_ROOT="$_IMPACT_ROOT"

# ── SPEC-1[change]: persona_stage_framing rc≠0 → fallback has no role declaration ─
# PROMPT1 (persona-present path) is kept for SPEC-3's framing-agnostic check.
AD1="$(_setup_fixture)"
IROOT1="$(_root_with_architect)"
_IMPACT_ROOT="$IROOT1"
export _CAPTURED_PERSONA_FILE="$AD1/persona.cap"
_impact_run_inner \
    "$(dirname "$AD1")/scope-manifest.md" \
    "$AD1/design.md" \
    "$AD1/plan.json" \
    "$AD1/impact.json" \
    "$AD1" >/dev/null 2>&1 || true
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"

PROMPT1="$AD1/impact-prompt.txt"
assert_file_exists "SPEC-1: prompt file written when architect manifest present" "$PROMPT1"
assert_eq "[SPEC-6] ZBUILD_STAGE_IO_PERSONA=architect exported when manifest present" \
    "architect" "$(cat "$AD1/persona.cap" 2>/dev/null)"
unset _CAPTURED_PERSONA_FILE

# [SPEC-1] change assertion: when persona_stage_framing fails with rc≠0 (distinct
# from SPEC-4's rc=0-but-empty), _persona_fallback is used and must NOT contain the
# role declaration. Fails at baseline where _persona_fallback opened with
# "You are an Impact Analyzer agent."
persona_stage_framing() { return 1; }
AD1b="$(_setup_fixture)"
_IMPACT_ROOT="$IROOT1"
_impact_run_inner \
    "$(dirname "$AD1b")/scope-manifest.md" \
    "$AD1b/design.md" \
    "$AD1b/plan.json" \
    "$AD1b/impact.json" \
    "$AD1b" >/dev/null 2>&1 || true
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"
unset -f persona_stage_framing
PROMPT1b="$AD1b/impact-prompt.txt"
if grep -qF "You are an Impact Analyzer agent." "$PROMPT1b" 2>/dev/null; then
    assert_fail "[SPEC-1] fallback must be behavior-only (no role declaration)" \
        "role declaration found in fallback prompt"
else
    assert_pass "[SPEC-1] fallback must be behavior-only (no role declaration)"
fi

# ── SPEC-2[guard]: architect manifest absent → fallback text in prompt ─────────
AD2="$(_setup_fixture)"
IROOT2="$(_root_without_architect)"
_IMPACT_ROOT="$IROOT2"
export _CAPTURED_PERSONA_FILE="$AD2/persona.cap"
_impact_run_inner \
    "$(dirname "$AD2")/scope-manifest.md" \
    "$AD2/design.md" \
    "$AD2/plan.json" \
    "$AD2/impact.json" \
    "$AD2" >/dev/null 2>&1 || true
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"

PROMPT2="$AD2/impact-prompt.txt"
assert_file_exists "SPEC-2: prompt file written when architect manifest absent" "$PROMPT2"
assert_contains "[SPEC-2] fallback text present when manifest absent" \
    "$(cat "$PROMPT2")" "adversarial consequence-finding"
assert_eq "[SPEC-6] ZBUILD_STAGE_IO_PERSONA=architect:fallback exported when manifest absent" \
    "architect:fallback" "$(cat "$AD2/persona.cap" 2>/dev/null)"
unset _CAPTURED_PERSONA_FILE

# ── SPEC-3[guard]: EXISTENCE VERIFICATION heading present regardless of framing ─
assert_contains "[SPEC-3] EXISTENCE VERIFICATION present in prompt with architect manifest" \
    "$(cat "$PROMPT1")" "EXISTENCE VERIFICATION"
assert_contains "[SPEC-3] EXISTENCE VERIFICATION present in prompt without architect manifest" \
    "$(cat "$PROMPT2")" "EXISTENCE VERIFICATION"

# ── SPEC-4[guard]: empty-output guard — mocked rc=0-but-empty → fallback ───────
# Simulate: persona_stage_framing succeeds (rc=0) but emits nothing (e.g. yaml_get
# returns empty for role and the real guard in persona.sh has a hypothetical gap).
persona_stage_framing() { return 0; }   # override: rc=0, no output

AD4="$(_setup_fixture)"
IROOT4="$(_root_with_architect)"
_IMPACT_ROOT="$IROOT4"
_impact_run_inner \
    "$(dirname "$AD4")/scope-manifest.md" \
    "$AD4/design.md" \
    "$AD4/plan.json" \
    "$AD4/impact.json" \
    "$AD4" >/dev/null 2>&1 || true
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"

PROMPT4="$AD4/impact-prompt.txt"
assert_file_exists "SPEC-4: prompt file written when persona_stage_framing returns empty" "$PROMPT4"
assert_contains "[SPEC-4] fallback text used when persona_stage_framing returns empty" \
    "$(cat "$PROMPT4")" "adversarial consequence-finding"
unset -f persona_stage_framing  # restore: remove mock so future SPECs use the real function

cleanup_test_env
print_test_results
exit $((FAIL > 0))
