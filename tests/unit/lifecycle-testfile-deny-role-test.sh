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
# SPEC-3[change]: (#2174) every OTHER plugin's declared outputs (resolved into this run's artifact
#   dir) are in the deny list; the plugin's own declared outputs are not — #1841's builder
#   rewrote design.md to retag two SPECs
# SPEC-4[change]: (#2174) a plugin that does not declare capabilities.writes_repository is denied
#   every tracked top-level entry of the target repo; one that declares it is not
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
_mk() {   # <dir> <role> [writes_repository:true|false]
    mkdir -p "$1"
    cat > "$1/manifest.yaml" <<M
id: $(basename "$1")
name: Fixture
kind: agent
version: 0.0.1
provides:
  role: $2
capabilities:
  writes_repository: ${3:-false}
outputs:
  - id: $(basename "$1")-out
    path: \${artifact_dir}/$(basename "$1").md
    type: markdown
    required: false
    primary: true
hooks:
  run: fixture_run
M
    cat > "$1/plugin.sh" <<'P'
fixture_run() { printf '%s|%s\n' "${ZBUILD_PLUGIN:-}" "$(printf '%s' "${ZBUILD_PERMISSION_DENY_EDIT:-<empty>}" | tr '\n' ' ')" >> "$DENY_LOG"; return 0; }
P
}
_mk "$TEST_TEMP_DIR/plugins/agent/author-fixture" test_author true
_mk "$TEST_TEMP_DIR/plugins/agent/builder-fixture" builder true
_mk "$TEST_TEMP_DIR/plugins/agent/reader-fixture" reviewer false
export ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
# The target repo has tracked top-level entries a non-writing stage must not touch.
mkdir -p "$ZBUILD_REPO_ROOT/core"; : > "$ZBUILD_REPO_ROOT/core/x.sh"; : > "$ZBUILD_REPO_ROOT/README.md"
git -C "$ZBUILD_REPO_ROOT" init -q; git -C "$ZBUILD_REPO_ROOT" config user.email t@t; git -C "$ZBUILD_REPO_ROOT" config user.name t
git -C "$ZBUILD_REPO_ROOT" add -A; git -C "$ZBUILD_REPO_ROOT" commit -qm init

print_test_section "SPEC-1: the author role gets no deny list"
: > "$DENY_LOG"
plugin_hook_call "$TEST_TEMP_DIR/plugins/agent/author-fixture" run author-fixture "$STATE/pipeline-state.json" >/dev/null 2>&1 || true
_a="$(grep '^author-fixture|' "$DENY_LOG" | head -1 | cut -d'|' -f2-)"
if grep -q 'tests/acc-test.sh' <<< "$_a"; then
    assert_fail "[SPEC-1] the test_author plugin is not denied the acceptance testfiles" "denied: $_a"
else
    assert_pass "[SPEC-1] the test_author plugin is not denied the acceptance testfiles"
fi

print_test_section "SPEC-2: every other role is denied the TESTFILES"
plugin_hook_call "$TEST_TEMP_DIR/plugins/agent/builder-fixture" run builder-fixture "$STATE/pipeline-state.json" >/dev/null 2>&1 || true
_b="$(grep '^builder-fixture|' "$DENY_LOG" | head -1 | cut -d'|' -f2-)"
assert_contains "[SPEC-2] a builder-role plugin is denied the design's testfile" "$_b" "tests/acc-test.sh"

print_test_section "SPEC-3: other plugins' declared outputs are read-only; your own are not"
assert_contains "[SPEC-3] the builder is denied the author's declared output" "$_b" "$STATE/artifacts/author-fixture.md"
assert_contains "[SPEC-3] …and the reader's" "$_b" "$STATE/artifacts/reader-fixture.md"
if grep -q 'artifacts/builder-fixture.md' <<< "$_b"; then
    assert_fail "[SPEC-3] the builder is NOT denied its own declared output" "denied its own: $_b"
else
    assert_pass "[SPEC-3] the builder is NOT denied its own declared output"
fi

print_test_section "SPEC-4: only a plugin declaring writes_repository may edit the repo"
plugin_hook_call "$TEST_TEMP_DIR/plugins/agent/reader-fixture" run reader-fixture "$STATE/pipeline-state.json" >/dev/null 2>&1 || true
_r="$(grep '^reader-fixture|' "$DENY_LOG" | head -1 | cut -d'|' -f2-)"
_root="$(cd "$ZBUILD_REPO_ROOT" && pwd)"
assert_contains "[SPEC-4] a non-writing plugin is denied the repo's tracked directories" "$_r" "$_root/core/**"
assert_contains "[SPEC-4] …and its tracked top-level files" "$_r" "$_root/README.md"
if grep -qF -e "$_root/core/**" -e "$_root/README.md" <<< "$_b"; then
    assert_fail "[SPEC-4] a plugin declaring writes_repository is not denied the repo" "denied: $_b"
else
    assert_pass "[SPEC-4] a plugin declaring writes_repository is not denied the repo"
fi
cleanup_test_env
print_test_results
exit $((FAIL > 0))
