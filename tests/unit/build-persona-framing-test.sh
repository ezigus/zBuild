#!/usr/bin/env bash
# Unit (#1391): build stage uses persona_stage_framing to open its prompt.
# SPEC-1[change] — with developer manifest present, the prompt includes the
#   persona perspective text (new behavior; fails at merge-base baseline).
# SPEC-2[guard]  — with developer manifest absent, the prompt falls back to
#   'You are an autonomous build agent for the target project.' (existing behavior).
# SPEC-3[guard]  — the '## INSTRUCTIONS' section is present regardless of framing path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: build persona framing seam (#1391)"
setup_test_env "build-persona-framing-1391"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ── Mocks (mirrors design-persona-framing-test.sh pattern) ───────────────────
route_to_model_loop() {
    _ROUTE_LOOP_FINAL_OUTPUT="ok"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}
_route_resolve_max_iterations() { echo 3; }
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

# Build a temp _BUILD_ROOT whose plugins/ has the developer manifest.
_root_with_developer() {
    local br; br="$(mktemp -d "$TEST_TEMP_DIR/broot.XXXXXX")"
    mkdir -p "$br/plugins/persona/developer"
    cat > "$br/plugins/persona/developer/manifest.yaml" <<'EOF'
id: developer
name: Developer
kind: persona
version: 0.1.0
persona:
  role: a software engineer
  perspective: Focus on correctness and minimal implementation.
EOF
    printf '%s' "$br"
}

# Build a temp _BUILD_ROOT whose plugins/ has no developer manifest.
_root_without_developer() {
    local br; br="$(mktemp -d "$TEST_TEMP_DIR/broot_empty.XXXXXX")"
    mkdir -p "$br/plugins"
    printf '%s' "$br"
}

_ORIG_BUILD_ROOT="$_BUILD_ROOT"

# ── SPEC-1[change]: developer manifest present → perspective in prompt ─────────
AD1="$(_setup_fixture)"
BROOT1="$(_root_with_developer)"
_BUILD_ROOT="$BROOT1"
_build_stage_run_inner \
    "$(dirname "$AD1")/scope-manifest.md" \
    "$AD1/plan.json" \
    "$AD1/diff.patch" \
    "$AD1/build-summary.json" \
    "$AD1" >/dev/null 2>&1 || true
_BUILD_ROOT="$_ORIG_BUILD_ROOT"

PROMPT1="$AD1/build-prompt.txt"
assert_file_exists "SPEC-1: prompt file written when developer manifest present" "$PROMPT1"
assert_contains "[SPEC-1] developer perspective text in prompt when manifest present" \
    "$(cat "$PROMPT1")" "Focus on correctness and minimal implementation."

# ── SPEC-2[guard]: developer manifest absent → fallback text in prompt ─────────
AD2="$(_setup_fixture)"
BROOT2="$(_root_without_developer)"
_BUILD_ROOT="$BROOT2"
_build_stage_run_inner \
    "$(dirname "$AD2")/scope-manifest.md" \
    "$AD2/plan.json" \
    "$AD2/diff.patch" \
    "$AD2/build-summary.json" \
    "$AD2" >/dev/null 2>&1 || true
_BUILD_ROOT="$_ORIG_BUILD_ROOT"

PROMPT2="$AD2/build-prompt.txt"
assert_file_exists "SPEC-2: prompt file written when developer manifest absent" "$PROMPT2"
assert_contains "[SPEC-2] fallback text present when manifest absent" \
    "$(cat "$PROMPT2")" "You are an autonomous build agent for the target project."
# Byte-identical fallback (DoD): the exact pre-#1391 opening, including line wraps.
_expected_open='You are an autonomous build agent for the target project. You have Read, Edit, Write, and
Bash tools available. Your job is to edit the working tree to implement the
ORIGINAL TASK above.'
assert_contains "[SPEC-2] fallback opening is byte-identical to the pre-persona framing" \
    "$(cat "$PROMPT2")" "$_expected_open"

# ── SPEC-3[guard]: ## INSTRUCTIONS section present regardless of framing path ──
assert_contains "[SPEC-3] INSTRUCTIONS present in prompt with developer manifest" \
    "$(cat "$PROMPT1")" "## INSTRUCTIONS"
assert_contains "[SPEC-3] INSTRUCTIONS present in prompt without developer manifest" \
    "$(cat "$PROMPT2")" "## INSTRUCTIONS"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
