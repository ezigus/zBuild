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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
