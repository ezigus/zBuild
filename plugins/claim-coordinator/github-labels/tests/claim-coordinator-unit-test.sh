#!/usr/bin/env bash
# Tests: plugins/claim-coordinator/github-labels/plugin.sh — local-fs backend (Wave 4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

print_test_header "plugin: claim-coordinator/github-labels — local-fs backend"
setup_test_env "claim-coordinator-unit"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Use local-fs backend so tests never call gh
export ZBUILD_CLAIM_BACKEND="local-fs"
export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store"
export ZBUILD_CLAIM_MACHINE_ID="test-machine-1"

# shellcheck source=../../../../plugins/claim-coordinator/github-labels/plugin.sh
source "$REPO_ROOT/plugins/claim-coordinator/github-labels/plugin.sh"
# Explicitly source claim.sh so DSCLA-1/-2/-3/-8 do not silently rely on
# plugin.sh's transitive import; a future refactor of plugin.sh that moves
# the source must not silently break these tests.
# Guard: on base code claim.sh does not exist yet; zbuild_claim_acquire is
# therefore undefined and the DSCLA blocks fail on rc≠0 — the intended red step.
if [[ -f "$REPO_ROOT/core/claim/claim.sh" ]]; then
    # shellcheck source=../../../../core/claim/claim.sh
    source "$REPO_ROOT/core/claim/claim.sh"
fi

# ── claim issue 42 → rc=0 ─────────────────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_claim "42"; rc=$?; set -e
assert_eq "claim_coordinator_claim → rc=0" "0" "$rc"

# ── label file created after claim ───────────────────────────────────────────
labels_file="$ZBUILD_CLAIM_STORE/42/labels.txt"
if [[ -f "$labels_file" ]]; then
    assert_pass "claim store file created after claim"
else
    assert_fail "claim store file created after claim" "file not found: $labels_file"
fi

# ── label is exactly zbuild:claimed (no machine name component) ───────────────
# On base code the label was claimed:<machine>; new code uses the shared
# zbuild:claimed label.  grep -Fxq requires an exact line match.
if grep -Fxq "zbuild:claimed" "$labels_file" 2>/dev/null; then
    assert_pass "label is exactly zbuild:claimed (no machine name)"
else
    assert_fail "label is exactly zbuild:claimed (no machine name)" \
        "$(cat "$labels_file" 2>/dev/null || echo '<empty>')"
fi

# ── release → rc=0 and zbuild:claimed removed ────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_release "42"; rc=$?; set -e
assert_eq "claim_coordinator_release → rc=0" "0" "$rc"

if ! grep -Fxq "zbuild:claimed" "$labels_file" 2>/dev/null; then
    assert_pass "zbuild:claimed label removed after release"
else
    assert_fail "zbuild:claimed label removed after release" \
        "$(cat "$labels_file" 2>/dev/null || echo '<empty>')"
fi

# ── list_claims returns empty JSON array after release ────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
list_out="$(claim_coordinator_list_claims 2>/dev/null || true)"
assert_eq "list_claims returns [] after release" "[]" "$list_out"

# ── heartbeat → rc=0 ─────────────────────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
claim_coordinator_claim "99" 2>/dev/null
set +e; claim_coordinator_heartbeat "99"; rc=$?; set -e
assert_eq "claim_coordinator_heartbeat → rc=0" "0" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-1: gh is called to add exactly zbuild:claimed when no claim is present
# ─────────────────────────────────────────────────────────────────────────────

# Given: a run is started with an issue number; zbuild:claimed is not on the issue
_dscla1_issue="1001"
_dscla1_calls="$TEST_TEMP_DIR/gh-calls-dscla1.txt"
: > "$_dscla1_calls"

# gh mock: records every invocation; returns no labels (zbuild:claimed absent)
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla1_calls"
case "\${1:-}:\${2:-}:\${3:-}" in
    issue:view:*)
        echo ""
        ;;
    issue:edit:*)
        ;;
    *)
        ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_CLAIM_BACKEND="gh"
unset GITHUB_ACTIONS 2>/dev/null || true
export ZBUILD_RUN_ID="${ZBUILD_RUN_ID:-test-run-dscla1}"
export ZBUILD_CLAIM_MACHINE_ID="test-machine-dscla1"

# Tight backoff so this test completes quickly
export ZBUILD_CLAIM_BACKOFF_MIN_MS=5
export ZBUILD_CLAIM_BACKOFF_MAX_MS=15

# When: the run starts (zbuild_claim_acquire is called with the issue number)
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire "$_dscla1_issue"; _dscla1_rc=$?; set -e

# Then: function returns 0 (claim acquired)
assert_eq "[DSCLA-1] zbuild_claim_acquire returns 0 when zbuild:claimed is absent" "0" "$_dscla1_rc"

# Then: gh is called to add the label zbuild:claimed to the issue
if grep -qF "zbuild:claimed" "$_dscla1_calls" 2>/dev/null; then
    assert_pass "[DSCLA-1] gh is called to add zbuild:claimed to the issue"
else
    assert_fail "[DSCLA-1] gh is called to add zbuild:claimed to the issue" \
        "calls recorded: $(cat "$_dscla1_calls" 2>/dev/null || echo '<empty>')"
fi

# Then: the label name is exactly zbuild:claimed — no hostname component (not claimed:<machine>)
if ! grep -qE "claimed:[a-zA-Z0-9_-]" "$_dscla1_calls" 2>/dev/null; then
    assert_pass "[DSCLA-1] label is exactly zbuild:claimed with no hostname suffix"
else
    assert_fail "[DSCLA-1] label is exactly zbuild:claimed with no hostname suffix" \
        "hostname-specific label found: $(grep -oE 'claimed:[a-zA-Z0-9_-]+' "$_dscla1_calls" 2>/dev/null || echo '<none>')"
fi

# Cleanup: restore local-fs backend and plain gh mock for subsequent tests
export ZBUILD_CLAIM_BACKEND="local-fs"
mock_gh

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-2: claim comment names holder; label has no hostname
# ─────────────────────────────────────────────────────────────────────────────

# Given: mock gh backend; set run_id and machine id
_dscla2_issue="1002"
_dscla2_calls="$TEST_TEMP_DIR/gh-calls-dscla2.txt"
: > "$_dscla2_calls"

# gh mock: records every invocation; returns empty labels for view; succeeds for edits/comments
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla2_calls"
case "\${1:-}:\${2:-}:\${3:-}" in
    issue:view:*)
        # Return no labels (zbuild:claimed absent)
        echo ""
        ;;
    issue:comment:*)
        # Accept comment creation
        echo "comment created"
        ;;
    issue:edit:*)
        # Accept label edit
        ;;
    *)
        ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_CLAIM_BACKEND="gh"
export ZBUILD_RUN_ID="run-dscla2-123"
export ZBUILD_CLAIM_MACHINE_ID="testmachine-dscla2"
unset GITHUB_ACTIONS 2>/dev/null || true

# When: zbuild_claim_acquire succeeds for the issue
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire "$_dscla2_issue"; _dscla2_rc=$?; set -e
assert_eq "[DSCLA-2] zbuild_claim_acquire returns 0 (claim acquired via gh)" "0" "$_dscla2_rc"

# Then: gh was called to add the label zbuild:claimed (not claimed:<machine>)
if grep -q "zbuild:claimed" "$_dscla2_calls" 2>/dev/null; then
    assert_pass "[DSCLA-2] gh called with zbuild:claimed label"
else
    assert_fail "[DSCLA-2] gh called with zbuild:claimed label" \
        "calls recorded: $(cat "$_dscla2_calls" 2>/dev/null || echo '<empty>')"
fi

# Then: the label name is exactly zbuild:claimed — no hostname component
if grep -Fq "claimed:" "$_dscla2_calls" 2>/dev/null && \
   ! grep -Eq "claimed:[a-zA-Z0-9_-]" "$_dscla2_calls" 2>/dev/null; then
    assert_pass "[DSCLA-2] label is zbuild:claimed with no extra hostname suffix"
else
    # Check explicitly: zbuild:claimed should appear; claimed:testmachine-dscla2 should NOT
    if ! grep -qF "claimed:testmachine-dscla2" "$_dscla2_calls" 2>/dev/null; then
        assert_pass "[DSCLA-2] label has no hostname component (machine-specific label not used)"
    else
        assert_fail "[DSCLA-2] label has no hostname component (machine-specific label not used)" \
            "hostname-specific label found: $(grep -oE 'claimed:[a-zA-Z0-9_-]+' "$_dscla2_calls" 2>/dev/null || echo '<none>')"
    fi
fi

# Then: gh issue comment was NOT called (holder is in run-status comment, not a separate claim comment)
if grep -q "^comment$" "$_dscla2_calls" 2>/dev/null; then
    assert_fail "[DSCLA-2] gh issue comment was NOT called (holder goes into run-status comment)" \
        "unexpected comment call found in: $(cat "$_dscla2_calls" 2>/dev/null)"
else
    assert_pass "[DSCLA-2] gh issue comment was NOT called (holder goes into run-status comment)"
fi

# Then: _ZBUILD_CLAIM_HOLDER is set to run_id and machine name (for the runner to embed in <!-- zbuild-holder: -->)
if grep -q "run-dscla2-123" <<< "${_ZBUILD_CLAIM_HOLDER:-}"; then
    assert_pass "[DSCLA-2] _ZBUILD_CLAIM_HOLDER contains run_id after successful acquire"
else
    assert_fail "[DSCLA-2] _ZBUILD_CLAIM_HOLDER contains run_id after successful acquire" \
        "_ZBUILD_CLAIM_HOLDER='${_ZBUILD_CLAIM_HOLDER:-}' (expected to contain 'run-dscla2-123')"
fi

if grep -q "testmachine-dscla2" <<< "${_ZBUILD_CLAIM_HOLDER:-}"; then
    assert_pass "[DSCLA-2] _ZBUILD_CLAIM_HOLDER contains machine name after successful acquire"
else
    assert_fail "[DSCLA-2] _ZBUILD_CLAIM_HOLDER contains machine name after successful acquire" \
        "_ZBUILD_CLAIM_HOLDER='${_ZBUILD_CLAIM_HOLDER:-}' (expected to contain 'testmachine-dscla2')"
fi

# DSCLA-2 (render sub-test): rsc_render_header embeds the holder in the run-status comment header

# Given: a local run (GITHUB_ACTIONS not true) starts with an issue number;
#        the holder string is run_id=run-dscla2-123 machine=testmachine-dscla2
# shellcheck source=../../../../scripts/lib/run-status-render.sh
source "$REPO_ROOT/scripts/lib/run-status-render.sh"
_dscla2_rsc_events="$TEST_TEMP_DIR/dscla2-rsc-events.jsonl"
printf '{"type":"pipeline.start","data":{"run_id":"run-dscla2-123","issue":1002},"ts":"2026-01-01T00:00:00Z"}\n' \
    > "$_dscla2_rsc_events"
_dscla2_rsc_model="$(rsc_rows_json "$_dscla2_rsc_events" 2>/dev/null || printf '{}')"
_ZBUILD_CLAIM_HOLDER="run_id=run-dscla2-123 machine=testmachine-dscla2"

# When: rsc_render_header is called with the run id and holder string
_dscla2_rsc_hdr="$(rsc_render_header "$_dscla2_rsc_model" "$TEST_TEMP_DIR" 2>/dev/null || printf '')"

# Then: the rendered header contains <!-- zbuild-holder: run_id=<id> machine=<hostname> -->
if grep -qF '<!-- zbuild-holder: run_id=run-dscla2-123 machine=testmachine-dscla2 -->' <<< "${_dscla2_rsc_hdr:-}"; then
    assert_pass "[DSCLA-2] run-status comment header contains <!-- zbuild-holder: run_id=<id> machine=<hostname> -->"
else
    assert_fail "[DSCLA-2] run-status comment header contains <!-- zbuild-holder: run_id=<id> machine=<hostname> -->" \
        "holder not found in header; header: ${_dscla2_rsc_hdr:0:400}"
fi

# DSCLA-2 (CI sub-case): CI run URL when GITHUB_ACTIONS=true

# Given: gh backend with GITHUB_ACTIONS=true; run URL variables set
_dscla2b_issue="1002b"
_dscla2b_calls="$TEST_TEMP_DIR/gh-calls-dscla2b.txt"
: > "$_dscla2b_calls"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla2b_calls"
case "\${1:-}:\${2:-}:\${3:-}" in
    issue:view:*) echo "" ;;
    *) ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export GITHUB_ACTIONS=true
export GITHUB_RUN_ID="99887766"
export GITHUB_SERVER_URL="https://github.com"
export GITHUB_REPOSITORY="testowner/testrepo"

# When: zbuild_claim_acquire is called with the issue number
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire "$_dscla2b_issue"; _dscla2b_rc=$?; set -e

# Then: function returns 0 (claim acquired)
assert_eq "[DSCLA-2] zbuild_claim_acquire returns 0 (CI mode)" "0" "$_dscla2b_rc"

# Then: _ZBUILD_CLAIM_HOLDER contains CI run URL (run-status comment will identify the CI holder)
if grep -q "99887766" <<< "${_ZBUILD_CLAIM_HOLDER:-}" || \
   grep -q "testowner/testrepo" <<< "${_ZBUILD_CLAIM_HOLDER:-}"; then
    assert_pass "[DSCLA-2] _ZBUILD_CLAIM_HOLDER contains CI run URL when GITHUB_ACTIONS=true"
else
    assert_fail "[DSCLA-2] _ZBUILD_CLAIM_HOLDER contains CI run URL when GITHUB_ACTIONS=true" \
        "_ZBUILD_CLAIM_HOLDER='${_ZBUILD_CLAIM_HOLDER:-}' (expected CI URL with 99887766 or testowner/testrepo)"
fi

# Cleanup: restore ZBUILD_RUN_ID and ZBUILD_CLAIM_MACHINE_ID set in this block
# (GITHUB_* vars from dscla2b remain set; DSCLA-12 uses them and has its own cleanup)
export ZBUILD_CLAIM_MACHINE_ID="test-machine-1"
unset ZBUILD_RUN_ID 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-12: CI run URL as holder in rendered run-status comment header
# ─────────────────────────────────────────────────────────────────────────────

# Given: a CI run (GITHUB_ACTIONS=true) starts with an issue number
# GITHUB_ACTIONS, GITHUB_RUN_ID, GITHUB_SERVER_URL, GITHUB_REPOSITORY are set above
_dscla12_events="$TEST_TEMP_DIR/dscla12-events.jsonl"
printf '{"type":"pipeline.start","data":{"run_id":"run-dscla12","issue":1012},"ts":"2026-01-01T00:00:00Z"}\n' \
    > "$_dscla12_events"
_dscla12_model="$(rsc_rows_json "$_dscla12_events" 2>/dev/null || printf '{}')"

# When: rsc_render_header is called with the run id and the CI holder string
_dscla12_ci_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
_ZBUILD_CLAIM_HOLDER="$_dscla12_ci_url"
_dscla12_hdr="$(rsc_render_header "$_dscla12_model" "$TEST_TEMP_DIR" 2>/dev/null || printf '')"

# Then: the rendered header contains <!-- zbuild-holder: <CI_URL> -->
if grep -qF "<!-- zbuild-holder: $_dscla12_ci_url -->" <<< "${_dscla12_hdr:-}"; then
    assert_pass "[DSCLA-12] rendered header contains <!-- zbuild-holder: CI_URL -->"
else
    assert_fail "[DSCLA-12] rendered header contains <!-- zbuild-holder: CI_URL -->" \
        "CI holder not found in header; expected '<!-- zbuild-holder: $_dscla12_ci_url -->'; header: ${_dscla12_hdr:0:400}"
fi

# Cleanup: restore CI environment variables
unset GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_REPOSITORY 2>/dev/null || true
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true

# Restore local-fs backend for subsequent tests
export ZBUILD_CLAIM_BACKEND="local-fs"
# Restore a plain (non-recording) gh mock
mock_gh

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-3: zbuild_claim_acquire returns 1 when zbuild:claimed is present
# ─────────────────────────────────────────────────────────────────────────────

# Given: zbuild:claimed is already on the issue
_dscla3_issue="1003"
mkdir -p "$ZBUILD_CLAIM_STORE/$_dscla3_issue"
printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/$_dscla3_issue/labels.txt"

# When: zbuild_claim_acquire is called
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire "$_dscla3_issue"; _dscla3_rc=$?; set -e

# Then: it returns 1
assert_eq "[DSCLA-3] zbuild_claim_acquire returns 1 when zbuild:claimed is present" "1" "$_dscla3_rc"

# ─────────────────────────────────────────────────────────────────────────────
# _ZBUILD_CLAIM_HOLDER is set from the holder's run-status comment
# (DSCLA-9 integration coverage; unit-level probe of the plugin's holder-read)
# ─────────────────────────────────────────────────────────────────────────────

# Given: zbuild:claimed on the issue and a run-status comment with the holder marker
# (DSCLA-9 integration coverage; unit-level probe of the plugin's holder-read)
_dscla4_issue="1004"
_dscla4_holder_string="run-holder-99 on machine-other"

# Given: set up the claim store with the zbuild:claimed label
mkdir -p "$ZBUILD_CLAIM_STORE/$_dscla4_issue"
printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/$_dscla4_issue/labels.txt"

# Given: generate the run-status comment using rsc_render_header (the same code that
# writes it in production), so a format divergence between the writer and the reader
# is caught at the unit level, not only in integration.
_dscla4_events="$TEST_TEMP_DIR/dscla4-events.jsonl"
printf '{"type":"pipeline.start","data":{"run_id":"holder-run-99","issue":1004},"ts":"2026-01-01T00:00:00Z"}\n' \
    > "$_dscla4_events"
_dscla4_model="$(rsc_rows_json "$_dscla4_events" 2>/dev/null || printf '{}')"
_ZBUILD_CLAIM_HOLDER="$_dscla4_holder_string"
_dscla4_rsc_hdr="$(rsc_render_header "$_dscla4_model" "$TEST_TEMP_DIR" 2>/dev/null || printf '')"
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true
printf '%s\n' "$_dscla4_rsc_hdr" > "$ZBUILD_CLAIM_STORE/$_dscla4_issue/run-status-comment.txt"

# When: zbuild_claim_acquire is called and finds the label present
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire "$_dscla4_issue"; _dscla4_rc=$?; set -e

# Then: it returns 1 (issue is already claimed)
assert_eq "[DSCLA-3] zbuild_claim_acquire returns 1 when issue already claimed (with rsc fixture)" "1" "$_dscla4_rc"

# Then: _ZBUILD_CLAIM_HOLDER is set (not empty) — the holder was read from the comment
if [[ -n "${_ZBUILD_CLAIM_HOLDER:-}" ]]; then
    assert_pass "[DSCLA-9] _ZBUILD_CLAIM_HOLDER is set (not empty) after refused claim"
else
    assert_fail "[DSCLA-9] _ZBUILD_CLAIM_HOLDER is set (not empty) after refused claim" \
        "_ZBUILD_CLAIM_HOLDER was empty or unset"
fi

# Then: _ZBUILD_CLAIM_HOLDER contains the holder string written by rsc_render_header
# (derive the expected string from the setup variable, not a hard-coded literal)
if grep -q "$_dscla4_holder_string" <<< "${_ZBUILD_CLAIM_HOLDER:-}"; then
    assert_pass "[DSCLA-9] _ZBUILD_CLAIM_HOLDER contains holder string from rsc_render_header fixture"
else
    assert_fail "[DSCLA-9] _ZBUILD_CLAIM_HOLDER contains holder string from rsc_render_header fixture" \
        "_ZBUILD_CLAIM_HOLDER='${_ZBUILD_CLAIM_HOLDER:-}' (expected to contain '$_dscla4_holder_string')"
fi

# Cleanup: unset _ZBUILD_CLAIM_HOLDER set as a side effect of zbuild_claim_acquire above
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-8: empty issue argument → coordinator's claim hook not called, returns 0
# ─────────────────────────────────────────────────────────────────────────────

# Given: core/claim/claim.sh is loaded
# Given: a stub claim-coordinator plugin is registered in the discovery tree;
#        its claim hook writes a marker file when called — if zbuild_claim_acquire
#        calls the hook at all (even if the hook returns early for an empty issue),
#        the marker is written and the Then assertion fails.
_dscla8_plugins_root="$TEST_TEMP_DIR/plugins-dscla8"
_dscla8_stub_dir="$_dscla8_plugins_root/claim-coordinator/stub-dscla8"
_dscla8_hook_called="$TEST_TEMP_DIR/dscla8-hook-called"
mkdir -p "$_dscla8_stub_dir"
rm -f "$_dscla8_hook_called"

cat > "$_dscla8_stub_dir/manifest.yaml" <<STUBMANI
id: dscla8-stub-coordinator
name: Stub Claim Coordinator (DSCLA-8)
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: _dscla8_stub_claim
  release: _dscla8_stub_release
  heartbeat: _dscla8_stub_heartbeat
  list_claims: _dscla8_stub_list_claims
provides:
  role: claim-coordinator
  alias: stub-dscla8
STUBMANI

cat > "$_dscla8_stub_dir/plugin.sh" <<STUBPLUG
_dscla8_stub_claim() {
    printf '%s\n' "\${1:-}" > "$_dscla8_hook_called"
    printf '{"acquired": true}\n'
    return 0
}
_dscla8_stub_release() { return 0; }
_dscla8_stub_heartbeat() { return 0; }
_dscla8_stub_list_claims() { printf '[]\n'; return 0; }
STUBPLUG

# shellcheck source=/dev/null
source "$_dscla8_stub_dir/plugin.sh"

_prev_plugins_root_8="${ZBUILD_PLUGINS_ROOT:-}"
export ZBUILD_PLUGINS_ROOT="$_dscla8_plugins_root"
unset _ZBUILD_CLAIM_ACQUIRED 2>/dev/null || true

# When: zbuild_claim_acquire is called with an empty string as the issue argument
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire ""; _dscla8_rc=$?; set -e

# Then: function returns 0
assert_eq "[DSCLA-8] zbuild_claim_acquire returns 0 for empty issue" "0" "$_dscla8_rc"

# Then: the coordinator's claim hook is not called
# The stub writes the received argument to the marker file on any call, so a hook
# that is invoked but returns early for an empty issue still leaves the marker.
# Absent marker proves the hook was never entered.
if [[ ! -e "$_dscla8_hook_called" ]]; then
    assert_pass "[DSCLA-8] coordinator's claim hook was not called for empty issue"
else
    assert_fail "[DSCLA-8] coordinator's claim hook was not called for empty issue" \
        "stub's claim hook was called; marker file contains: $(cat "$_dscla8_hook_called" 2>/dev/null)"
fi

# Cleanup: restore ZBUILD_PLUGINS_ROOT and local-fs backend
if [[ -n "$_prev_plugins_root_8" ]]; then
    export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_8"
else
    unset ZBUILD_PLUGINS_ROOT 2>/dev/null || true
fi
export ZBUILD_CLAIM_BACKEND="local-fs"
mock_gh

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-17: zbuild_claim_release with no prior acquire does not call
#           the coordinator's release hook
# ─────────────────────────────────────────────────────────────────────────────

# Given: core/claim/claim.sh is loaded
# This file does not exist in the base code, so the test fails there (as required).
_dscla17_claim_sh="$REPO_ROOT/core/claim/claim.sh"
if [[ ! -f "$_dscla17_claim_sh" ]]; then
    assert_fail "[DSCLA-17] core/claim/claim.sh must exist" \
        "file not found: $_dscla17_claim_sh — zbuild_claim_release is not yet implemented"
else
    # shellcheck source=../../../../core/claim/claim.sh
    source "$_dscla17_claim_sh"

    # Given: a stub claim-coordinator plugin is registered in the discovery tree;
    #        its release hook writes a marker file when called — if zbuild_claim_release
    #        invokes the hook at all (even if the hook detects _ZBUILD_CLAIM_ACQUIRED
    #        is unset and returns early), the marker is written and the Then assertion fails.
    _dscla17_plugins_root="$TEST_TEMP_DIR/plugins-dscla17"
    _dscla17_stub_dir="$_dscla17_plugins_root/claim-coordinator/stub-dscla17"
    _dscla17_hook_called="$TEST_TEMP_DIR/dscla17-hook-called"
    mkdir -p "$_dscla17_stub_dir"
    rm -f "$_dscla17_hook_called"

    cat > "$_dscla17_stub_dir/manifest.yaml" <<STUBMANI
id: dscla17-stub-coordinator
name: Stub Claim Coordinator (DSCLA-17)
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: _dscla17_stub_claim
  release: _dscla17_stub_release
  heartbeat: _dscla17_stub_heartbeat
  list_claims: _dscla17_stub_list_claims
provides:
  role: claim-coordinator
  alias: stub-dscla17
STUBMANI

    cat > "$_dscla17_stub_dir/plugin.sh" <<STUBPLUG
_dscla17_stub_claim() {
    printf '{"acquired": true}\n'
    return 0
}
_dscla17_stub_release() {
    : > "$_dscla17_hook_called"
    return 0
}
_dscla17_stub_heartbeat() { return 0; }
_dscla17_stub_list_claims() { printf '[]\n'; return 0; }
STUBPLUG

    # shellcheck source=/dev/null
    source "$_dscla17_stub_dir/plugin.sh"

    _prev_plugins_root_17="${ZBUILD_PLUGINS_ROOT:-}"
    export ZBUILD_PLUGINS_ROOT="$_dscla17_plugins_root"

    # Given: _ZBUILD_CLAIM_ACQUIRED is not set
    unset _ZBUILD_CLAIM_ACQUIRED 2>/dev/null || true

    # When: zbuild_claim_release is called
    set +e; zbuild_claim_release; _dscla17_rc=$?; set -e

    # Then: the coordinator's release hook is not called
    # A release hook that is invoked but detects _ZBUILD_CLAIM_ACQUIRED is unset
    # and returns early would still write the marker file; absent marker proves
    # the hook was never entered.
    if [[ ! -e "$_dscla17_hook_called" ]]; then
        assert_pass "[DSCLA-17] coordinator's release hook was not called when _ZBUILD_CLAIM_ACQUIRED is not set"
    else
        assert_fail "[DSCLA-17] coordinator's release hook was not called when _ZBUILD_CLAIM_ACQUIRED is not set" \
            "stub's release hook was called despite _ZBUILD_CLAIM_ACQUIRED being unset"
    fi

    # Cleanup: restore ZBUILD_PLUGINS_ROOT and local-fs backend
    if [[ -n "$_prev_plugins_root_17" ]]; then
        export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_17"
    else
        unset ZBUILD_PLUGINS_ROOT 2>/dev/null || true
    fi
    export ZBUILD_CLAIM_BACKEND="local-fs"
    mock_gh
fi

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-10: pipeline.refused.claimed is an accepted event name in event-schema.json
# ─────────────────────────────────────────────────────────────────────────────

# Given: config/event-schema.json includes an entry for pipeline.refused.claimed
_dscla10_schema="$REPO_ROOT/config/event-schema.json"
_dscla10_coverage="$REPO_ROOT/tests/unit/event-schema-emitted-coverage-test.sh"

# Given check: pipeline.refused.claimed must be in the composed known set.
# On base code the event is absent from event-schema.json so this fails
# immediately (the right red step).  On new code the event is registered and
# the check passes; we then invoke the actual coverage check.
_dscla10_known="$(eb_compose_known_types "$_dscla10_schema" "$REPO_ROOT/plugins" 2>/dev/null || printf '')"
if ! grep -qxF "pipeline.refused.claimed" <<< "$_dscla10_known"; then
    assert_fail "[DSCLA-10] Given: pipeline.refused.claimed must be in config/event-schema.json" \
        "not found in composed known set; the coverage check cannot accept it if it is not registered"
else
    # When: the event-schema emitted-coverage check runs against the codebase
    set +e
    _dscla10_out="$(bash "$_dscla10_coverage" 2>&1)"
    _dscla10_rc=$?
    set -e

    # Then: the check exits without reporting pipeline.refused.claimed as an unregistered event name
    if [[ "$_dscla10_rc" -eq 0 ]]; then
        assert_pass "[DSCLA-10] event-schema emitted-coverage check exits 0 (pipeline.refused.claimed is accepted)"
    elif grep -qF "pipeline.refused.claimed" <<< "$_dscla10_out"; then
        assert_fail "[DSCLA-10] event-schema emitted-coverage check reports pipeline.refused.claimed as an unregistered event name" \
            "coverage check output (first 400 chars): ${_dscla10_out:0:400}"
    else
        assert_pass "[DSCLA-10] event-schema emitted-coverage check does not report pipeline.refused.claimed as unregistered (failed for other reasons)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-18: claim_coordinator_claim adds zbuild:claimed via gh issue edit;
#           no hostname component in the label
# ─────────────────────────────────────────────────────────────────────────────

# Given: plugins/claim-coordinator/github-labels/plugin.sh is loaded (sourced at top)
#        the issue has no zbuild:claimed label
_dscla18_issue="2018"
_dscla18_calls="$TEST_TEMP_DIR/gh-calls-dscla18.txt"
: > "$_dscla18_calls"

# gh mock: records all invocations; returns empty label list (no zbuild:claimed)
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla18_calls"
case "\${1:-}:\${2:-}:\${3:-}" in
    issue:view:*)
        echo ""
        ;;
    issue:edit:*)
        ;;
    *)
        ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_CLAIM_BACKEND="gh"
export ZBUILD_CLAIM_BACKOFF_MIN_MS=5
export ZBUILD_CLAIM_BACKOFF_MAX_MS=15
export ZBUILD_CLAIM_MACHINE_ID="test-machine-dscla18"

# When: claim_coordinator_claim is called with the issue number
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_claim "$_dscla18_issue"; _dscla18_rc=$?; set -e

# Then: gh issue edit is called to add the label zbuild:claimed to the issue
# (must check --add-label specifically; --remove-label zbuild:claimed would also match zbuild:claimed alone)
if grep -qF "zbuild:claimed" "$_dscla18_calls" 2>/dev/null && grep -qF -- "--add-label" "$_dscla18_calls" 2>/dev/null; then
    assert_pass "[DSCLA-18] gh issue edit is called to add zbuild:claimed"
else
    assert_fail "[DSCLA-18] gh issue edit is called to add zbuild:claimed" \
        "zbuild:claimed with --add-label not found in gh calls; calls: $(cat "$_dscla18_calls" 2>/dev/null || echo '<empty>')"
fi

# And: the label added has no hostname component (not claimed:<hostname>)
if ! grep -qE "^claimed:[a-zA-Z0-9_-]" "$_dscla18_calls" 2>/dev/null; then
    assert_pass "[DSCLA-18] label added has no hostname component (zbuild:claimed, not claimed:<host>)"
else
    assert_fail "[DSCLA-18] label added has no hostname component (zbuild:claimed, not claimed:<host>)" \
        "hostname-specific label found in calls: $(grep -oE 'claimed:[a-zA-Z0-9_-]+' "$_dscla18_calls" 2>/dev/null || echo '<none>')"
fi

# Cleanup: restore local-fs backend and plain gh mock
export ZBUILD_CLAIM_BACKEND="local-fs"
mock_gh

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-20: claim_coordinator_release removes zbuild:claimed via gh issue edit
# ─────────────────────────────────────────────────────────────────────────────

# Given: plugins/claim-coordinator/github-labels/plugin.sh is loaded (sourced at top)
#        the issue has the zbuild:claimed label
_dscla20_issue="2020"
_dscla20_calls="$TEST_TEMP_DIR/gh-calls-dscla20.txt"
: > "$_dscla20_calls"

# gh mock: records all invocations; returns zbuild:claimed for issue view
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla20_calls"
case "\${1:-}:\${2:-}:\${3:-}" in
    issue:view:*)
        echo "zbuild:claimed"
        ;;
    issue:edit:*)
        ;;
    *)
        ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

export ZBUILD_CLAIM_BACKEND="gh"
export ZBUILD_CLAIM_MACHINE_ID="test-machine-dscla20"

# When: claim_coordinator_release is called with the issue number
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_release "$_dscla20_issue"; _dscla20_rc=$?; set -e

# Then: gh issue edit is called to remove the label zbuild:claimed from the issue
# (must check --remove-label specifically; --add-label zbuild:claimed would also match zbuild:claimed alone)
if grep -qF "zbuild:claimed" "$_dscla20_calls" 2>/dev/null && grep -qF -- "--remove-label" "$_dscla20_calls" 2>/dev/null; then
    assert_pass "[DSCLA-20] gh issue edit is called to remove zbuild:claimed"
else
    assert_fail "[DSCLA-20] gh issue edit is called to remove zbuild:claimed" \
        "zbuild:claimed with --remove-label not found in gh calls; calls: $(cat "$_dscla20_calls" 2>/dev/null || echo '<empty>')"
fi

# And: the label removed is zbuild:claimed with no hostname component
if ! grep -qE "^claimed:[a-zA-Z0-9_-]" "$_dscla20_calls" 2>/dev/null; then
    assert_pass "[DSCLA-20] label removed has no hostname component (zbuild:claimed, not claimed:<host>)"
else
    assert_fail "[DSCLA-20] label removed has no hostname component (zbuild:claimed, not claimed:<host>)" \
        "hostname-specific label found in calls: $(grep -oE 'claimed:[a-zA-Z0-9_-]+' "$_dscla20_calls" 2>/dev/null || echo '<none>')"
fi

# Cleanup: restore local-fs backend and plain gh mock
export ZBUILD_CLAIM_BACKEND="local-fs"
mock_gh

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-19: zbuild_claim_acquire delegates to coordinator's claim hook;
#           no direct gh calls within zbuild_claim_acquire
# ─────────────────────────────────────────────────────────────────────────────

# Given: core/claim/claim.sh is loaded (defines zbuild_claim_acquire)
_dscla19_claim_sh="$REPO_ROOT/core/claim/claim.sh"
if [[ ! -f "$_dscla19_claim_sh" ]]; then
    assert_fail "[DSCLA-19] core/claim/claim.sh must exist" \
        "file not found: $_dscla19_claim_sh — zbuild_claim_acquire is not yet implemented"
else
    _dscla19_issue="2019"
    _dscla19_gh_calls="$TEST_TEMP_DIR/gh-calls-dscla19.txt"
    _dscla19_hook_called="$TEST_TEMP_DIR/dscla19-hook-called"
    : > "$_dscla19_gh_calls"
    rm -f "$_dscla19_hook_called"

    # Mock gh: records every invocation (must NOT be called by zbuild_claim_acquire directly)
    cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla19_gh_calls"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Given: a claim-coordinator plugin is registered in the discovery tree;
    # that plugin's claim hook explicitly returns {"acquired": true} on stdout.
    # Create a stub plugin so the Given condition is established, not assumed
    # from the actual local-fs implementation's behaviour.
    # Unique function names (not claim_coordinator_*) prevent collision with
    # the already-loaded plugin; the manifest registers the unique names so
    # zbuild_claim_acquire discovers them via the plugin registry.
    _dscla19_plugins_root="$TEST_TEMP_DIR/plugins-dscla19"
    _dscla19_stub_dir="$_dscla19_plugins_root/claim-coordinator/stub"
    mkdir -p "$_dscla19_stub_dir"
    cat > "$_dscla19_stub_dir/manifest.yaml" <<STUBMANI
id: dscla19-stub-coordinator
name: Stub Claim Coordinator (DSCLA-19)
kind: claim-coordinator
version: 0.1.0
hooks:
  claim: _dscla19_stub_claim
  release: _dscla19_stub_release
  heartbeat: _dscla19_stub_heartbeat
  list_claims: _dscla19_stub_list_claims
provides:
  role: claim-coordinator
  alias: stub
STUBMANI
    # The stub's claim hook writes the issue number to the marker file AND
    # returns {"acquired": true} on stdout — this is the Given condition being
    # established explicitly.  Writing the actual argument (not just touching
    # the file) means the Then assertion can verify the right issue was passed:
    # if zbuild_claim_acquire calls _dscla19_stub_claim "" or the wrong value,
    # the grep below will fail.
    cat > "$_dscla19_stub_dir/plugin.sh" <<STUBPLUG
_dscla19_stub_claim() {
    local _issue="\${1:-}"
    printf '%s\n' "\$_issue" > "$_dscla19_hook_called"
    printf '{"acquired": true, "lease_id": "stub:%s"}\n' "\$_issue"
    return 0
}
_dscla19_stub_release() { return 0; }
_dscla19_stub_heartbeat() { return 0; }
_dscla19_stub_list_claims() { printf '[]\n'; return 0; }
STUBPLUG

    # Source the stub to put its functions in scope; set ZBUILD_PLUGINS_ROOT
    # so zbuild_claim_acquire can discover it via the plugin registry.
    # Unique function names mean no collision with claim_coordinator_* from
    # the already-loaded plugin.sh, so no restore is needed after the test.
    _prev_plugins_root_19="${ZBUILD_PLUGINS_ROOT:-}"
    export ZBUILD_PLUGINS_ROOT="$_dscla19_plugins_root"
    # shellcheck source=/dev/null
    source "$_dscla19_stub_dir/plugin.sh"
    unset _ZBUILD_CLAIM_ACQUIRED 2>/dev/null || true

    # When: zbuild_claim_acquire is called with an issue number
    : > "$ZBUILD_EVENTS_JSONL"
    set +e; zbuild_claim_acquire "$_dscla19_issue"; _dscla19_rc=$?; set -e

    # Then: the coordinator's claim hook function is called with the issue number
    # The stub writes the received argument to the marker file; grep for the
    # exact issue number so the test fails if the wrong value (or empty string)
    # was forwarded to the hook.
    if grep -Fxq "$_dscla19_issue" "$_dscla19_hook_called" 2>/dev/null; then
        assert_pass "[DSCLA-19] coordinator's claim hook was called with the issue number"
    else
        assert_fail "[DSCLA-19] coordinator's claim hook was called with the issue number" \
            "marker file content: $(cat "$_dscla19_hook_called" 2>/dev/null || echo '<absent>'); rc=$_dscla19_rc"
    fi

    # And: gh is not invoked directly within zbuild_claim_acquire
    _dscla19_gh_count="$(wc -l < "$_dscla19_gh_calls" | tr -d ' ')"
    assert_eq "[DSCLA-19] gh is not invoked directly within zbuild_claim_acquire" "0" "$_dscla19_gh_count"

    # Cleanup: restore ZBUILD_PLUGINS_ROOT; original claim_coordinator_* functions
    # are still the loaded ones from the top-level source of plugin.sh (the stub
    # used unique names, so there is nothing to un-define).
    if [[ -n "$_prev_plugins_root_19" ]]; then
        export ZBUILD_PLUGINS_ROOT="$_prev_plugins_root_19"
    else
        unset ZBUILD_PLUGINS_ROOT 2>/dev/null || true
    fi
    mock_gh
fi

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-21: zbuild_claim_release delegates to coordinator's release hook;
#           no direct gh calls within zbuild_claim_release
# ─────────────────────────────────────────────────────────────────────────────

# Given: core/claim/claim.sh is loaded; _ZBUILD_CLAIM_ACQUIRED is set
_dscla21_claim_sh="$REPO_ROOT/core/claim/claim.sh"
if [[ ! -f "$_dscla21_claim_sh" ]]; then
    assert_fail "[DSCLA-21] core/claim/claim.sh must exist" \
        "file not found: $_dscla21_claim_sh — zbuild_claim_release is not yet implemented"
else
    _dscla21_issue="2021"
    _dscla21_gh_calls="$TEST_TEMP_DIR/gh-calls-dscla21.txt"
    : > "$_dscla21_gh_calls"

    # Mock gh: records every invocation (must NOT be called by zbuild_claim_release directly)
    cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla21_gh_calls"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Pre-populate claim store with zbuild:claimed (simulates prior successful acquire)
    _prev_backend_21="$ZBUILD_CLAIM_BACKEND"
    export ZBUILD_CLAIM_BACKEND="local-fs"
    mkdir -p "$ZBUILD_CLAIM_STORE/$_dscla21_issue"
    printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/$_dscla21_issue/labels.txt"

    # Given: _ZBUILD_CLAIM_ACQUIRED is set (simulate successful acquire)
    export _ZBUILD_CLAIM_ACQUIRED=1
    export _ZBUILD_CLAIM_ISSUE="$_dscla21_issue"

    # When: zbuild_claim_release is called with the issue number
    : > "$ZBUILD_EVENTS_JSONL"
    set +e; zbuild_claim_release "$_dscla21_issue"; _dscla21_rc=$?; set -e

    # Then: the coordinator's release hook function is called with the issue number
    # (evidenced by zbuild:claimed being removed from the claim store)
    _dscla21_labels="$ZBUILD_CLAIM_STORE/$_dscla21_issue/labels.txt"
    if ! grep -Fxq "zbuild:claimed" "$_dscla21_labels" 2>/dev/null; then
        assert_pass "[DSCLA-21] coordinator's release hook was called (zbuild:claimed removed from claim store)"
    else
        assert_fail "[DSCLA-21] coordinator's release hook was called (zbuild:claimed removed from claim store)" \
            "zbuild:claimed still present in $_dscla21_labels after zbuild_claim_release"
    fi

    # And: gh is not invoked directly within zbuild_claim_release
    _dscla21_gh_count="$(wc -l < "$_dscla21_gh_calls" | tr -d ' ')"
    assert_eq "[DSCLA-21] gh is not invoked directly within zbuild_claim_release" "0" "$_dscla21_gh_count"

    # Cleanup
    unset _ZBUILD_CLAIM_ACQUIRED _ZBUILD_CLAIM_ISSUE 2>/dev/null || true
    export ZBUILD_CLAIM_BACKEND="$_prev_backend_21"
    mock_gh
fi

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-23: _ccgl_read_holder only reads from comments authored by the
#           authenticated GitHub actor
# ─────────────────────────────────────────────────────────────────────────────

# Given: the issue has two comments that each contain <!-- zbuild-run-status -->
#        and <!-- zbuild-holder: -->; one was posted by the authenticated actor
#        and one by a different user

_dscla23_issue="2023"
_dscla23_actor="dscla23-actor"
_dscla23_other="dscla23-other-user"
_dscla23_actor_holder="actor-holder-dscla23"
_dscla23_other_holder="other-holder-dscla23"
_dscla23_calls="$TEST_TEMP_DIR/gh-calls-dscla23.txt"
: > "$_dscla23_calls"

# _ccgl_read_holder does not exist in the base code; the test fails there
# (function not defined) and passes after the implementation ships.
if ! declare -f _ccgl_read_holder >/dev/null 2>&1; then
    assert_fail "[DSCLA-23] _ccgl_read_holder must be defined" \
        "_ccgl_read_holder is not defined — the function has not been implemented yet"
else
    # Given: build comment bodies using rsc_render_header (the same code that
    # writes run-status comments in production), so a change to the
    # <!-- zbuild-holder: --> format is reflected in both the writer and the reader.
    _dscla23_actor_events="$TEST_TEMP_DIR/dscla23-actor-events.jsonl"
    _dscla23_other_events="$TEST_TEMP_DIR/dscla23-other-events.jsonl"
    printf '{"type":"pipeline.start","data":{"run_id":"actor-run-%s","issue":%s},"ts":"2026-01-01T00:00:00Z"}\n' \
        "$_dscla23_issue" "$_dscla23_issue" > "$_dscla23_actor_events"
    printf '{"type":"pipeline.start","data":{"run_id":"other-run-%s","issue":%s},"ts":"2026-01-01T00:00:00Z"}\n' \
        "$_dscla23_issue" "$_dscla23_issue" > "$_dscla23_other_events"
    _dscla23_actor_model="$(rsc_rows_json "$_dscla23_actor_events" 2>/dev/null || printf '{}')"
    _dscla23_other_model="$(rsc_rows_json "$_dscla23_other_events" 2>/dev/null || printf '{}')"

    _ZBUILD_CLAIM_HOLDER="$_dscla23_actor_holder"
    _dscla23_actor_body="$(rsc_render_header "$_dscla23_actor_model" "$TEST_TEMP_DIR" 2>/dev/null || printf '')"
    _ZBUILD_CLAIM_HOLDER="$_dscla23_other_holder"
    _dscla23_other_body="$(rsc_render_header "$_dscla23_other_model" "$TEST_TEMP_DIR" 2>/dev/null || printf '')"
    unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true

    # Given: build JSON fixture files for the mock gh — one array for the raw
    # GitHub API format (gh api repos/.../issues/.../comments) and one object
    # for the issue-view format (gh issue view ... --json comments).
    # Both include the two comments; .user.login (api) and .author.login (view)
    # carry the author so the implementation can filter to the authenticated actor.
    jq -n \
        --arg actor "$_dscla23_actor" \
        --arg other "$_dscla23_other" \
        --arg actor_body "$_dscla23_actor_body" \
        --arg other_body "$_dscla23_other_body" \
        '[
          {"id":1,"user":{"login":$actor},"body":$actor_body},
          {"id":2,"user":{"login":$other},"body":$other_body}
        ]' > "$TEST_TEMP_DIR/dscla23-api-comments.json"

    jq -n \
        --arg actor "$_dscla23_actor" \
        --arg other "$_dscla23_other" \
        --arg actor_body "$_dscla23_actor_body" \
        --arg other_body "$_dscla23_other_body" \
        '{
          "comments":[
            {"author":{"login":$actor},"body":$actor_body},
            {"author":{"login":$other},"body":$other_body}
          ]
        }' > "$TEST_TEMP_DIR/dscla23-view-comments.json"

    # Given: provide the repo slug via GITHUB_REPOSITORY and a stub
    # zbuild_repo_slug — the implementation will need a slug for
    # "gh api repos/{slug}/issues/{issue}/comments".
    export GITHUB_REPOSITORY="testowner/testrepo-dscla23"
    zbuild_repo_slug() { printf '%s\n' "testowner/testrepo-dscla23"; return 0; }

    # Given: set up mock gh that returns the authenticated actor for user queries
    # and the two-comment fixture for comment-listing queries.
    # The mock handles both common gh-call patterns:
    #   "gh api user [--jq .login]"  → actor login (pre-processed for --jq usage)
    #   "gh api user"                 → JSON {"login":"..."} for separate jq processing
    #   "gh issue view ..."           → view-format JSON with .comments
    #   "gh api ..."                  → raw API array format
    # GITHUB_ACTOR is also set so implementations that read it directly work too.
    export GITHUB_ACTOR="$_dscla23_actor"
    _prev_backend_23="$ZBUILD_CLAIM_BACKEND"
    export ZBUILD_CLAIM_BACKEND="gh"

    cat > "$TEST_TEMP_DIR/bin/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla23_calls"
_dscla23_has_jq=false
for _dscla23_a in "\$@"; do
    [[ "\$_dscla23_a" == "--jq" || "\$_dscla23_a" == "-q" ]] && _dscla23_has_jq=true
done
case "\${1:-}:\${2:-}" in
    api:user)
        # Return login string (simulates --jq '.login') or full JSON for pipe-to-jq
        if [[ "\$_dscla23_has_jq" == "true" ]]; then
            printf '%s\n' "$_dscla23_actor"
        else
            printf '{"login":"%s","id":1}\n' "$_dscla23_actor"
        fi
        exit 0
        ;;
    auth:status)
        printf 'Logged in to github.com as %s\n' "$_dscla23_actor"
        exit 0
        ;;
    issue:view:*)
        cat "$TEST_TEMP_DIR/dscla23-view-comments.json"
        exit 0
        ;;
    api:*)
        cat "$TEST_TEMP_DIR/dscla23-api-comments.json"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # When: _ccgl_read_holder is called with the issue number
    _dscla23_holder="$(_ccgl_read_holder "$_dscla23_issue" 2>/dev/null || printf '')"

    # Then: the holder string returned is taken from the authenticated actor's comment
    if grep -qF "$_dscla23_actor_holder" <<< "${_dscla23_holder:-}"; then
        assert_pass "[DSCLA-23] _ccgl_read_holder returns holder from authenticated actor's comment"
    else
        assert_fail "[DSCLA-23] _ccgl_read_holder returns holder from authenticated actor's comment" \
            "expected holder containing '$_dscla23_actor_holder', got '${_dscla23_holder:-<empty>}'"
    fi

    # Then: the other user's holder string is NOT returned
    if ! grep -qF "$_dscla23_other_holder" <<< "${_dscla23_holder:-}"; then
        assert_pass "[DSCLA-23] _ccgl_read_holder does not return holder from other user's comment"
    else
        assert_fail "[DSCLA-23] _ccgl_read_holder does not return holder from other user's comment" \
            "got '${_dscla23_holder:-}' (must not contain '$_dscla23_other_holder')"
    fi

    # Cleanup: restore backend, plain gh mock, CI env vars, and repo slug stub
    unset GITHUB_ACTOR GITHUB_REPOSITORY 2>/dev/null || true
    unset -f zbuild_repo_slug 2>/dev/null || true
    export ZBUILD_CLAIM_BACKEND="$_prev_backend_23"
    mock_gh
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
