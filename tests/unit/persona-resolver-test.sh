#!/usr/bin/env bash
# tests/unit/persona-resolver-test.sh
# Unit tests for the kind:persona resolver + stage composition seam (#1304).
# find_persona / resolve_persona_role / resolve_persona_perspective and the
# persona_stage_framing composer, including the absent-persona byte-identical
# fallback signal (return 1, print nothing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# The facade wires manifest-validation + discovery + persona together.
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "kind:persona resolver + composition seam (issue #1304)"

# ─── SPEC-1 (issue #1573): persona_lens_framing removed from persona.sh ─────
set +e
declare -F persona_lens_framing >/dev/null 2>&1; plf_defined_rc=$?
set -e
assert_eq "[SPEC-1] persona_lens_framing is not defined after sourcing the registry" "1" "$plf_defined_rc"

setup_test_env "persona-resolver"
PROOT="$TEST_TEMP_DIR/plugins"

# ─── Fixtures: architect (valid) + developer (INVALID) ──────────────────────
# developer declares a role but NO perspective. Since #1569 makes persona.perspective
# validation-required, discover_plugins now SKIPS it as invalid — so the seams cannot
# resolve it and treat it as absent (rc=1 / empty). It stands in for "a persona that
# fails the perspective requirement."
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
expected_stage=$'Judge structure and boundaries.\n\nProduce the design.'
assert_eq "[SPEC-1][SPEC-5] persona_stage_framing leads with perspective (no role prefix)" \
    "$expected_stage" "$(persona_stage_framing architect "Produce the design." "$PROOT")"

# ─── SPEC-6: stage framing returns 1 (prints nothing) for the invalid persona ─
# developer is excluded by discovery (#1569: perspective required), so the seam
# resolves it as absent → rc=1, empty (the caller keeps its own framing).
set +e
out_np="$(persona_stage_framing developer "Write the code." "$PROOT")"; rc_np=$?
set -e
assert_eq "[SPEC-2][SPEC-6] stage framing returns 1 for a persona missing the required perspective" "1" "$rc_np"
assert_eq "[SPEC-2][SPEC-6] stage framing prints nothing for a persona missing the required perspective" "" "$out_np"

# ─── SPEC-8: absent persona ⇒ framing returns 1 AND prints nothing ───────────
# This is the byte-identical fallback contract: the caller keeps its own framing.
set +e
out="$(persona_stage_framing ghost "task" "$PROOT")"; rc=$?
set -e
assert_eq "[SPEC-8] persona_stage_framing returns 1 for an unknown persona" "1" "$rc"
assert_eq "[SPEC-8] persona_stage_framing prints nothing for an unknown persona" "" "$out"

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


# SPEC-15: persona_stage_framing leads with perspective keyword (no role prefix)
rt_stage="$(persona_stage_framing red-team "Assess the change." "$REAL_PROOT")"
case "$rt_stage" in
    *hostile*)     rt_stage_ok=1 ;;
    *exploitable*) rt_stage_ok=1 ;;
    *)             rt_stage_ok=0 ;;
esac
assert_eq "[SPEC-3][SPEC-15] stage framing leads with perspective keyword (hostile/exploitable) for live persona" "1" "$rt_stage_ok"

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

# SPEC-5: persona_stage_framing leads with perspective + task (no role prefix)
ts_stage="$(persona_stage_framing test-strategist "Write the tests." "$REAL_PROOT")"
case "$ts_stage" in
    *fail*)      ts_persp_ok=1 ;;
    *invariant*) ts_persp_ok=1 ;;
    *)           ts_persp_ok=0 ;;
esac
assert_eq "[SPEC-5] stage framing leads with perspective keyword (fail/invariant) for live persona" "1" "$ts_persp_ok"
case "$ts_stage" in
    *"Write the tests."*) ts_task_ok=1 ;;
    *) ts_task_ok=0 ;;
esac
assert_eq "[SPEC-5] stage framing contains the supplied task" "1" "$ts_task_ok"

# ─── SPEC-1..SPEC-5: live-tree security persona ──────────────────────────────
# These specs exercise the real manifest shipped in the repo (not a fixture).

# SPEC-1: security manifest is discoverable from the live plugins tree
set +e
sec_mf="$(find_persona security "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for the live security persona" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/security/manifest.yaml" \
    "$sec_mf" "plugins/persona/security/manifest.yaml"

# SPEC-2: role is exactly 'a security engineer'
assert_eq "[SPEC-2] resolve_persona_role returns 'a security engineer'" \
    "a security engineer" "$(resolve_persona_role security "$REAL_PROOT")"

# SPEC-3: perspective contains the word 'hostile' (trust-boundary framing keyword)
sec_perspective="$(resolve_persona_perspective security "$REAL_PROOT")"
case "$sec_perspective" in
    *hostile*) sec_persp_ok=1 ;;
    *)         sec_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] security perspective contains 'hostile'" "1" "$sec_persp_ok"

# SPEC-4: validate_manifest passes on the live security manifest
set +e
validate_manifest "$sec_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the live security manifest" "0" "$rc"

# ─── SPEC-1..SPEC-5: live-tree performance persona ───────────────────────────
# These specs exercise the real manifest shipped in the repo (not a fixture).

# SPEC-1: performance manifest is discoverable from the live plugins tree
set +e
perf_mf="$(find_persona performance "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for the live performance persona" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/performance/manifest.yaml" \
    "$perf_mf" "plugins/persona/performance/manifest.yaml"

# SPEC-2: role is exactly 'a performance engineer'
assert_eq "[SPEC-2] resolve_persona_role returns 'a performance engineer'" \
    "a performance engineer" "$(resolve_persona_role performance "$REAL_PROOT")"

# SPEC-3: perspective contains the word 'complexity' (hot-path/complexity framing keyword)
perf_perspective="$(resolve_persona_perspective performance "$REAL_PROOT")"
case "$perf_perspective" in
    *complexity*) perf_persp_ok=1 ;;
    *)            perf_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] performance perspective contains 'complexity'" "1" "$perf_persp_ok"

# SPEC-4: validate_manifest passes on the live performance manifest
set +e
validate_manifest "$perf_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the live performance manifest" "0" "$rc"

# ─── SPEC-1..SPEC-5: live-tree correctness persona ───────────────────────────
# These specs exercise the real manifest shipped in the repo (not a fixture).

# SPEC-1: correctness manifest is discoverable from the live plugins tree
set +e
corr_mf="$(find_persona correctness "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for the live correctness persona" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/correctness/manifest.yaml" \
    "$corr_mf" "plugins/persona/correctness/manifest.yaml"

# SPEC-2: role is exactly 'a test strategist'
assert_eq "[SPEC-2] resolve_persona_role returns 'a test strategist'" \
    "a test strategist" "$(resolve_persona_role correctness "$REAL_PROOT")"

# SPEC-3: perspective contains the word 'logic errors' (correctness-charter keyword)
corr_perspective="$(resolve_persona_perspective correctness "$REAL_PROOT")"
case "$corr_perspective" in
    *"logic errors"*) corr_persp_ok=1 ;;
    *)                corr_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] correctness perspective contains 'logic errors'" "1" "$corr_persp_ok"

# SPEC-4: validate_manifest passes on the live correctness manifest
set +e
validate_manifest "$corr_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the live correctness manifest" "0" "$rc"

# ─── SPEC-1..SPEC-5: live-tree SRE persona ───────────────────────────────────
# These specs exercise the real manifest shipped in the repo (not a fixture).

# SPEC-1: sre manifest is discoverable from the live plugins tree
set +e
sre_mf="$(find_persona sre "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for the live sre persona" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/sre/manifest.yaml" \
    "$sre_mf" "plugins/persona/sre/manifest.yaml"

# SPEC-2: role is exactly 'a site-reliability engineer'
assert_eq "[SPEC-2] resolve_persona_role returns 'a site-reliability engineer'" \
    "a site-reliability engineer" "$(resolve_persona_role sre "$REAL_PROOT")"

# SPEC-3: perspective contains a production-framing keyword ('production' or 'failure')
sre_perspective="$(resolve_persona_perspective sre "$REAL_PROOT")"
case "$sre_perspective" in
    *production*) sre_persp_ok=1 ;;
    *failure*)    sre_persp_ok=1 ;;
    *)            sre_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] sre perspective contains 'production' or 'failure'" "1" "$sre_persp_ok"

# SPEC-4: validate_manifest passes on the live sre manifest
set +e
validate_manifest "$sre_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the live sre manifest" "0" "$rc"

# ─── SPEC-1..SPEC-5: live-tree scope persona ─────────────────────────────────
# These specs exercise the real manifest shipped in the repo (not a fixture).

# SPEC-1: scope manifest is discoverable from the live plugins tree
set +e
scope_mf="$(find_persona scope "$REAL_PROOT")"; rc=$?
set -e
assert_eq "[SPEC-1] find_persona returns 0 for the live scope persona" "0" "$rc"
assert_contains "[SPEC-1] find_persona points at plugins/persona/scope/manifest.yaml" \
    "$scope_mf" "plugins/persona/scope/manifest.yaml"

# SPEC-2: role is exactly 'a software architect'
assert_eq "[SPEC-2] resolve_persona_role returns 'a software architect'" \
    "a software architect" "$(resolve_persona_role scope "$REAL_PROOT")"

# SPEC-3: perspective contains 'WARN ONLY' (scope-charter keyword)
scope_perspective="$(resolve_persona_perspective scope "$REAL_PROOT")"
case "$scope_perspective" in
    *"WARN ONLY"*) scope_persp_ok=1 ;;
    *)             scope_persp_ok=0 ;;
esac
assert_eq "[SPEC-3] scope perspective contains 'WARN ONLY'" "1" "$scope_persp_ok"

# SPEC-4: validate_manifest passes on the live scope manifest
set +e
validate_manifest "$scope_mf" >/dev/null 2>&1; rc=$?
set -e
assert_eq "[SPEC-4] validate_manifest passes on the live scope manifest" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
