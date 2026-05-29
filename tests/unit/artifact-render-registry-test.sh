#!/usr/bin/env bash
# Tests: scripts/lib/artifact-render.sh — registry mechanics (#470, ADR-018)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "artifact-render registry mechanics (#470)"
setup_test_env "artifact-render-registry"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── R1: built-ins are registered after source ───────────────────────────────
fn="$(artifact_renderer_for plan)"
assert_eq "R1 plan renderer registered" "render_plan_md" "$fn"
fn="$(artifact_renderer_for diff)"
assert_eq "R1 diff renderer registered" "render_diff_md" "$fn"
fn="$(artifact_renderer_for review)"
assert_eq "R1 review renderer registered" "render_review_md" "$fn"

# ─── R2: artifact_renderer_for unknown id → rc=1 ─────────────────────────────
set +e
out="$(artifact_renderer_for nope-no-such 2>&1)"
rc=$?
set -e
assert_eq "R2 unknown id rc=1" "1" "$rc"
assert_eq "R2 unknown id prints nothing" "" "$out"

# ─── R3: register_artifact_renderer with bad args → rc=2 ─────────────────────
set +e
register_artifact_renderer >/dev/null 2>&1
rc=$?
set -e
assert_eq "R3 no args rc=2" "2" "$rc"
set +e
register_artifact_renderer "id-only" >/dev/null 2>&1
rc=$?
set -e
assert_eq "R3 id only rc=2" "2" "$rc"

# ─── R4: idempotent same (id, fn) → rc=0 ─────────────────────────────────────
my_render_x() { printf 'X: %s' "$1"; }
register_artifact_renderer "test-x" "my_render_x"
set +e
register_artifact_renderer "test-x" "my_render_x"
rc=$?
set -e
assert_eq "R4 same id+fn rc=0" "0" "$rc"

# ─── R5: conflicting fn → rc=2 by default ────────────────────────────────────
my_render_x_v2() { printf 'X2: %s' "$1"; }
set +e
err="$(register_artifact_renderer "test-x" "my_render_x_v2" 2>&1)"
rc=$?
set -e
assert_eq "R5 conflict rc=2" "2" "$rc"
assert_contains "R5 conflict stderr names id" "$err" "test-x"
# Original binding preserved
assert_eq "R5 conflict preserves original" "my_render_x" "$(artifact_renderer_for test-x)"

# ─── R6: ZBUILD_ARTIFACT_RENDERER_FORCE=1 overrides ──────────────────────────
ZBUILD_ARTIFACT_RENDERER_FORCE=1 register_artifact_renderer "test-x" "my_render_x_v2"
assert_eq "R6 force overrides binding" "my_render_x_v2" "$(artifact_renderer_for test-x)"

# ─── R7: render_artifact unknown id → raw passthrough rc=0 ───────────────────
set +e
out="$(render_artifact "no-such-id" "hello raw")"
rc=$?
set -e
assert_eq "R7 unknown id rc=0" "0" "$rc"
assert_eq "R7 unknown id raw passthrough" "hello raw" "$out"

# ─── R8: render_artifact dispatches to registered fn ─────────────────────────
my_double() { printf 'D[%s]' "$1"; }
register_artifact_renderer "test-d" "my_double"
out="$(render_artifact "test-d" "abc")"
assert_eq "R8 dispatches" "D[abc]" "$out"

# ─── R9: render_artifact renderer rc!=0 → raw passthrough rc=0 ───────────────
my_bad() { printf 'X' >&2; return 7; }
ZBUILD_ARTIFACT_RENDERER_FORCE=1 register_artifact_renderer "test-bad" "my_bad"
set +e
out="$(render_artifact "test-bad" "fallback-me")"
rc=$?
set -e
assert_eq "R9 renderer error rc=0" "0" "$rc"
assert_eq "R9 renderer error → passthrough" "fallback-me" "$out"

# ─── R10: render_artifact with empty id → passthrough ────────────────────────
out="$(render_artifact "" "blob")"
assert_eq "R10 empty id passthrough" "blob" "$out"

# ─── R11: source-once guard prevents double-init ─────────────────────────────
# Re-sourcing should be a no-op (guard returns 0 without redefining).
source "$REPO_ROOT/scripts/lib/artifact-render.sh"
# my_render_x_v2 binding from R6 must survive (no re-registration of built-ins
# would have clobbered it because they don't share the id).
assert_eq "R11 second source preserves runtime bindings" "my_render_x_v2" "$(artifact_renderer_for test-x)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
