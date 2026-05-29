#!/usr/bin/env bash
# Tests: extensibility contract — plugins register their own renderers (#470)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "artifact-render extensibility (#470)"
setup_test_env "render-ext"

# shellcheck source=../../scripts/lib/artifact-render.sh
source "$REPO_ROOT/scripts/lib/artifact-render.sh"

# ─── E1: register a brand-new id (e.g. "test-spec") and dispatch through it ─
render_test_spec_md() {
    local in="$1"
    printf '# Test spec\n%s\n' "$in"
}
register_artifact_renderer "test-spec" "render_test_spec_md"

out="$(render_artifact "test-spec" "Body here")"
assert_contains "E1 dispatch to registered fn" "$out" "# Test spec"
assert_contains "E1 input passed through" "$out" "Body here"

# ─── E2: lookup helper finds the new id ──────────────────────────────────────
fn="$(artifact_renderer_for "test-spec")"
assert_eq "E2 lookup helper" "render_test_spec_md" "$fn"

# ─── E3: registering an id that exists in the registry of a downstream stage
# does not break built-ins. ──────────────────────────────────────────────────
out="$(render_artifact plan '{"title":"x"}')"
assert_contains "E3 built-in still works after custom register" "$out" "# Plan: x"

# ─── E4: extensibility — second fresh id stacks without conflict ─────────────
my_security_md() { printf 'SEC: %s' "$1"; }
register_artifact_renderer "security" "my_security_md"
out="$(render_artifact "security" "ok")"
assert_eq "E4 second new id dispatches" "SEC: ok" "$out"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
