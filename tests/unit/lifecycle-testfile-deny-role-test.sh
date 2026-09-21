#!/usr/bin/env bash
# lifecycle-testfile-deny-role-test.sh — the acceptance-testfile deny list is
# decided by the plugin's ROLE, and the author is exempt (#2170).
#
# #1841: test-author's own claude-settings.json carried
# Edit(//…/security-lens-test.sh) — the file it exists to write — and every
# call died against the denial (25 turns of "File is in a directory that is
# denied"). The exemption at core/plugin-registry/lifecycle.sh looked the role
# up with `$1` AFTER `shift 2`, i.e. the stage id, found no manifest, and
# denied everyone. Invisible until #2163 made the rendered rule real.
#
# SPEC-1[change]: a plugin whose manifest declares provides.role: test_author is dispatched
#   with an EMPTY deny list — it may edit the acceptance testfiles
# SPEC-2[guard]:  a plugin with any other role is dispatched with the design's TESTFILES in
#   ZBUILD_PERMISSION_DENY_EDIT (build cannot rewrite an assertion to fit its code)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "lifecycle: the testfile deny list follows the plugin's role (#2170)"
setup_test_env "lifecycle-deny-role"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE/artifacts" "$STATE/runtime"
export ZBUILD_STATE_DIR="$STATE"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo"; mkdir -p "$ZBUILD_REPO_ROOT/tests"
printf '{"schema_version":1,"status":"in_progress"}' > "$STATE/pipeline-state.json"
# The design names one acceptance testfile.
cat > "$STATE/artifacts/design.md" <<'D'
# Design
```acceptance
SPEC-1[change]: it does the thing
TESTFILES:
SPEC-1: tests/acc-test.sh
```
D
DENY_LOG="$TEST_TEMP_DIR/deny.log"; export DENY_LOG

# Two fixture plugins, identical but for provides.role.
_mk() {   # <dir> <role>
    mkdir -p "$1"
    cat > "$1/manifest.yaml" <<M
id: $(basename "$1")
name: Fixture
kind: agent
version: 0.0.1
provides:
  role: $2
hooks:
  run: fixture_run
M
    cat > "$1/plugin.sh" <<'P'
fixture_run() { printf '%s|%s\n' "${ZBUILD_PLUGIN:-}" "${ZBUILD_PERMISSION_DENY_EDIT:-<empty>}" >> "$DENY_LOG"; return 0; }
P
}
_mk "$TEST_TEMP_DIR/plugins/agent/author-fixture" test_author
_mk "$TEST_TEMP_DIR/plugins/agent/builder-fixture" builder

print_test_section "SPEC-1: the author role gets no deny list"
: > "$DENY_LOG"
plugin_hook_call "$TEST_TEMP_DIR/plugins/agent/author-fixture" run author-fixture "$STATE/pipeline-state.json" >/dev/null 2>&1 || true
_a="$(grep '^author-fixture|' "$DENY_LOG" | head -1 | cut -d'|' -f2-)"
assert_eq "[SPEC-1] the test_author plugin is dispatched with an empty deny list" "<empty>" "$_a"

print_test_section "SPEC-2: every other role is denied the TESTFILES"
plugin_hook_call "$TEST_TEMP_DIR/plugins/agent/builder-fixture" run builder-fixture "$STATE/pipeline-state.json" >/dev/null 2>&1 || true
_b="$(grep '^builder-fixture|' "$DENY_LOG" | head -1 | cut -d'|' -f2-)"
assert_contains "[SPEC-2] a builder-role plugin is denied the design's testfile" "$_b" "tests/acc-test.sh"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
