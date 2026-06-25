#!/usr/bin/env bash
# Tests: scripts/lib/call-graph.sh — call-graph evidence producer (P3, ADR-038 §2).
# SPEC-1: function in diff → non-empty artifact containing the function name.
# SPEC-2: _rr_run_inner wires call-graph into architecture lens prompt.
# SPEC-3: diff with no bash functions → empty changed_surface, rc=0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "call-graph evidence producer — P3 arch/correctness lens"
setup_test_env "call-graph-evidence"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Source the call-graph library under test.
# shellcheck source=../../scripts/lib/call-graph.sh
source "$REPO_ROOT/scripts/lib/call-graph.sh"

# ─── Shared fixture: diff that adds one bash function ────────────────────────
fixture_diff="$TEST_TEMP_DIR/fixture.patch"
cat > "$fixture_diff" <<'FIXTURE'
diff --git a/scripts/lib/my_module.sh b/scripts/lib/my_module.sh
index 0000000..1111111 100644
--- /dev/null
+++ b/scripts/lib/my_module.sh
@@ -0,0 +1,5 @@
+cg_fixture_func_alpha() {
+    local arg="$1"
+    cg_helper_call "$arg"
+}
FIXTURE

# ─── SPEC-1: call_graph_produce on a function-bearing diff ───────────────────
cg_artifact="$TEST_TEMP_DIR/call-graph.json"

set +e
call_graph_produce "$fixture_diff" "$REPO_ROOT" "$cg_artifact"
_spec1_rc=$?
set -e

assert_eq "[SPEC-1] call_graph_produce returns 0" "0" "$_spec1_rc"
assert_file_exists "[SPEC-1] call-graph.json is written" "$cg_artifact"

_spec1_surface="$(jq -r '.changed_surface | length' "$cg_artifact" 2>/dev/null || echo 0)"
assert_gt "[SPEC-1] changed_surface is non-empty" "$_spec1_surface" "0"

_spec1_fn="$(jq -r '.changed_surface[].function' "$cg_artifact" 2>/dev/null || echo "")"
assert_contains "[SPEC-1] artifact contains the fixture function name" \
    "$_spec1_fn" "cg_fixture_func_alpha"

# ─── SPEC-2: _rr_run_inner wires call-graph into architecture lens prompt ────
# Source the full plugin (brings _rr_run_inner, _rr_fanout_lenses, registry).
export ZBUILD_EVENTS_DIR ZBUILD_EVENTS_JSONL
# shellcheck source=../../plugins/agent/review-report/plugin.sh
source "$REPO_ROOT/plugins/agent/review-report/plugin.sh"

# Stub LLM calls and redaction (both are called in subshells by fanout, so
# we export them as functions; subshell inherits exported functions via env).
route_to_model() { printf '{"score":10,"findings":[]}\n'; return 0; }
export -f route_to_model
# shellcheck disable=SC2329
apply_scope_redaction() { cp "$1" "$2"; return 0; }
export -f apply_scope_redaction

spec2_dir="$TEST_TEMP_DIR/spec2"
mkdir -p "$spec2_dir"
spec2_scope="$spec2_dir/scope-manifest.md"; touch "$spec2_scope"
spec2_diff="$spec2_dir/diff.patch"
cp "$fixture_diff" "$spec2_diff"
spec2_json="$spec2_dir/review-report.json"
spec2_md="$spec2_dir/review-report.md"

# Reset registry so any prior test state doesn't bleed through.
declare -A _RR_LENS_ARTIFACT_REGISTRY=()

set +e
_rr_run_inner "$spec2_scope" "$spec2_diff" "$spec2_json" "$spec2_md"
_spec2_rc=$?
set -e

assert_eq "[SPEC-2] _rr_run_inner returns 0" "0" "$_spec2_rc"

_arch_prompt_file="$spec2_dir/lens-architecture-prompt.txt"
assert_file_exists "[SPEC-2] lens-architecture-prompt.txt is written" "$_arch_prompt_file"

_arch_prompt="$(cat "$_arch_prompt_file" 2>/dev/null || echo "")"
assert_contains "[SPEC-2] architecture lens prompt contains call-graph function name" \
    "$_arch_prompt" "cg_fixture_func_alpha"

# ─── SPEC-3: diff with no bash functions → empty changed_surface, rc=0 ───────
no_func_diff="$TEST_TEMP_DIR/no-func.patch"
cat > "$no_func_diff" <<'NOFUNC'
diff --git a/README.md b/README.md
index 0000000..1111111 100644
--- a/README.md
+++ b/README.md
@@ -1 +1,2 @@
 # zBuild
+Some documentation change.
NOFUNC

cg_empty="$TEST_TEMP_DIR/call-graph-empty.json"

set +e
call_graph_produce "$no_func_diff" "$REPO_ROOT" "$cg_empty"
_spec3_rc=$?
set -e

assert_eq "[SPEC-3] call_graph_produce returns 0 on functionless diff" "0" "$_spec3_rc"
assert_file_exists "[SPEC-3] call-graph.json written for functionless diff" "$cg_empty"

_spec3_surface="$(jq -r '.changed_surface | length' "$cg_empty" 2>/dev/null || echo -1)"
assert_eq "[SPEC-3] changed_surface is empty array" "0" "$_spec3_surface"

_spec3_sv="$(jq -r '.schema_version' "$cg_empty" 2>/dev/null || echo "")"
assert_eq "[SPEC-3] JSON is valid with schema_version 1" "1" "$_spec3_sv"

print_test_results
