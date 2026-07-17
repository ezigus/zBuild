#!/usr/bin/env bash
# tests/unit/persona-resolver-test.sh
# Unit tests for the kind:persona resolver + stage/lens composition seam (#1304).
# find_persona / resolve_persona_role / resolve_persona_perspective and the
# persona_stage_framing / persona_lens_framing composers, including the
# absent-persona byte-identical fallback signal (return 1, print nothing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# The facade wires manifest-validation + discovery + persona together.
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "kind:persona resolver + composition seam (issue #1304)"

setup_test_env "persona-resolver"
PROOT="$TEST_TEMP_DIR/plugins"

# ─── Fixtures: two personas — one with a perspective, one without ────────────
mkdir -p "$PROOT/persona/architect" "$PROOT/persona/developer"
cat > "$PROOT/persona/architect/manifest.yaml" <<'EOF'
id: architect
name: Software Architect
kind: persona
version: 0.1.0
persona:
  role: a software architect
  perspective: Judge structure and boundaries.
EOF
cat > "$PROOT/persona/developer/manifest.yaml" <<'EOF'
id: developer
name: Software Engineer
kind: persona
version: 0.1.0
persona:
  role: a software engineer
EOF

# ─── SPEC-1: find_persona resolves a known id to its manifest path ───────────
set +e
mf="$(find_persona architect "$PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for a known id" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at the architect manifest" "$mf" "persona/architect/manifest.yaml"

# ─── SPEC-2: find_persona fails for an unknown id ────────────────────────────
set +e
find_persona ghost "$PROOT" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-2] find_persona returns 1 for an unknown id" "1" "$rc"

# ─── SPEC-3: resolve_persona_role / resolve_persona_perspective ──────────────
assert_eq "[SPEC-3] resolve_persona_role returns the role" \
    "a software architect" "$(resolve_persona_role architect "$PROOT")"
assert_eq "[SPEC-3] resolve_persona_perspective returns the perspective" \
    "Judge structure and boundaries." "$(resolve_persona_perspective architect "$PROOT")"

# ─── SPEC-4: resolvers fail on an unknown persona ────────────────────────────
set +e
resolve_persona_role ghost "$PROOT" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] resolve_persona_role returns 1 for an unknown id" "1" "$rc"

# ─── SPEC-5: persona_stage_framing composes the stage seam ───────────────────
expected_stage=$'You are a software architect for the target project. Judge structure and boundaries.\n\nProduce the design.'
assert_eq "[SPEC-5] persona_stage_framing composes 'You are {role} for the target project. {perspective}\\n\\n{task}'" \
    "$expected_stage" "$(persona_stage_framing architect "Produce the design." "$PROOT")"

# ─── SPEC-6: stage framing omits the perspective cleanly when absent ─────────
expected_stage_np=$'You are a software engineer for the target project.\n\nWrite the code.'
assert_eq "[SPEC-6] stage framing has no dangling separator when perspective is absent" \
    "$expected_stage_np" "$(persona_stage_framing developer "Write the code." "$PROOT")"

# ─── SPEC-7: persona_lens_framing composes the lens seam ─────────────────────
assert_eq "[SPEC-7] persona_lens_framing composes the lens seam with perspective" \
    "You are a software architect reviewing a change for the target project. Judge structure and boundaries. Flag scope drift." \
    "$(persona_lens_framing architect "Flag scope drift." "$PROOT")"
assert_eq "[SPEC-7] lens framing has no dangling separator when perspective is absent" \
    "You are a software engineer reviewing a change for the target project. Check correctness." \
    "$(persona_lens_framing developer "Check correctness." "$PROOT")"

# ─── SPEC-8: absent persona ⇒ framing returns 1 AND prints nothing ───────────
# This is the byte-identical fallback contract: the caller keeps its own framing.
set +e
out="$(persona_stage_framing ghost "task" "$PROOT")"; rc=$?
set -e
assert_eq "[SPEC-8] persona_stage_framing returns 1 for an unknown persona" "1" "$rc"
assert_eq "[SPEC-8] persona_stage_framing prints nothing for an unknown persona" "" "$out"

set +e
out="$(persona_lens_framing ghost "charter" "$PROOT")"; rc=$?
set -e
assert_eq "[SPEC-8] persona_lens_framing returns 1 for an unknown persona" "1" "$rc"
assert_eq "[SPEC-8] persona_lens_framing prints nothing for an unknown persona" "" "$out"

# ─── SPEC-9: resolve_persona_charter delegates to resolve_persona_perspective ──
# resolve_persona_charter is an alias for resolve_persona_perspective; it returns
# the persona.perspective field and signals absence the same way.
assert_eq "[SPEC-9] resolve_persona_charter returns the perspective field" \
    "Judge structure and boundaries." "$(resolve_persona_charter architect "$PROOT")"
set +e
resolve_persona_charter ghost "$PROOT" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-9] resolve_persona_charter returns 1 for an unknown persona" "1" "$rc"
set +e
out="$(resolve_persona_charter ghost "$PROOT")"; rc=$?
set -e
assert_eq "[SPEC-9] resolve_persona_charter prints nothing for an unknown persona" "" "$out"

# ─── SPEC-10..SPEC-15: live-tree red-team persona (plugins/persona/red-team) ──
# These specs exercise the real manifest shipped in the repo (not a fixture).
REAL_PROOT="$REPO_ROOT/plugins"

# SPEC-10: red-team manifest is discoverable from the live plugins tree
set +e
rt_mf="$(find_persona red-team "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-10] find_persona returns 0 for the live red-team persona" "0" "$rc"
assert_contains "[SPEC-10] find_persona points at plugins/persona/red-team/manifest.yaml" \
    "$rt_mf" "plugins/persona/red-team/manifest.yaml"

# SPEC-11: role is exactly 'a red-team operator'
assert_eq "[SPEC-11] resolve_persona_role returns 'a red-team operator'" \
    "a red-team operator" "$(resolve_persona_role red-team "$REAL_PROOT")"

# SPEC-12: perspective contains the word 'attacker' or 'adversarial'
rt_perspective="$(resolve_persona_perspective red-team "$REAL_PROOT")"
case "$rt_perspective" in
    *adversar*) rt_persp_ok=1 ;;
    *attacker*)  rt_persp_ok=1 ;;
    *)           rt_persp_ok=0 ;;
esac
assert_eq "[SPEC-12] red-team perspective references adversarial mindset" "1" "$rt_persp_ok"

# SPEC-13: validate_manifest passes on the live red-team manifest
set +e
validate_manifest "$rt_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-13] validate_manifest passes on the live red-team manifest" "0" "$rc"

# SPEC-14: persona_lens_framing composes a framing containing role + supplied charter
rt_framing="$(persona_lens_framing red-team "Look for exploitable flaws." "$REAL_PROOT")"
case "$rt_framing" in
    *"red-team operator"*) rt_role_ok=1 ;;
    *) rt_role_ok=0 ;;
esac
assert_eq "[SPEC-14] lens framing contains 'red-team operator'" "1" "$rt_role_ok"
case "$rt_framing" in
    *"Look for exploitable flaws."*) rt_charter_ok=1 ;;
    *) rt_charter_ok=0 ;;
esac
assert_eq "[SPEC-14] lens framing contains the supplied charter" "1" "$rt_charter_ok"

# SPEC-15: persona_stage_framing composes a framing containing role for the live persona
rt_stage="$(persona_stage_framing red-team "Assess the change." "$REAL_PROOT")"
case "$rt_stage" in
    *"red-team operator"*) rt_stage_ok=1 ;;
    *) rt_stage_ok=0 ;;
esac
assert_eq "[SPEC-15] stage framing contains 'red-team operator' for live persona" "1" "$rt_stage_ok"

# ─── SPEC-1..SPEC-5: live-tree test-strategist persona ───────────────────────
# These specs exercise the real manifest shipped in the repo (not a fixture).

# SPEC-1: test-strategist manifest is discoverable from the live plugins tree
set +e
ts_mf="$(find_persona test-strategist "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for the live test-strategist persona" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/test-strategist/manifest.yaml" \
    "$ts_mf" "plugins/persona/test-strategist/manifest.yaml"

# SPEC-2: role is exactly 'a test strategist'
assert_eq "[SPEC-2] resolve_persona_role returns 'a test strategist'" \
    "a test strategist" "$(resolve_persona_role test-strategist "$REAL_PROOT")"

# SPEC-3: perspective contains the word 'fail'
ts_perspective="$(resolve_persona_perspective test-strategist "$REAL_PROOT")"
case "$ts_perspective" in
    *fail*) ts_persp_ok=1 ;;
    *)      ts_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] test-strategist perspective contains 'fail'" "1" "$ts_persp_ok"

# SPEC-4: validate_manifest passes on the live test-strategist manifest
set +e
validate_manifest "$ts_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the live test-strategist manifest" "0" "$rc"

# SPEC-5: persona_stage_framing composes a framing with role + perspective + task
ts_stage="$(persona_stage_framing test-strategist "Write the tests." "$REAL_PROOT")"
case "$ts_stage" in
    *"test strategist"*) ts_role_ok=1 ;;
    *) ts_role_ok=0 ;;
esac
assert_eq "[SPEC-5] stage framing contains 'test strategist' for live persona" "1" "$ts_role_ok"
case "$ts_stage" in
    *"Write the tests."*) ts_task_ok=1 ;;
    *) ts_task_ok=0 ;;
esac
assert_eq "[SPEC-5] stage framing contains the supplied task" "1" "$ts_task_ok"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
