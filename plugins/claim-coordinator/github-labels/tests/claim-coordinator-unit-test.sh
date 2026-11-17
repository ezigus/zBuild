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

# ── label contains claimed:<machine> pattern ─────────────────────────────────
if grep -q "claimed:" "$labels_file" 2>/dev/null; then
    assert_pass "claimed label contains 'claimed:' prefix"
else
    assert_fail "claimed label contains 'claimed:' prefix" "$(cat "$labels_file" 2>/dev/null || echo '<empty>')"
fi

# ── release → rc=0 and label removed ─────────────────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e; claim_coordinator_release "42"; rc=$?; set -e
assert_eq "claim_coordinator_release → rc=0" "0" "$rc"

remaining="$({ grep "claimed:" "$labels_file" 2>/dev/null || true; } | wc -l | tr -d ' \n')"
assert_eq "claimed label removed after release" "0" "$remaining"

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
_dscla4_issue="1004"
mkdir -p "$ZBUILD_CLAIM_STORE/$_dscla4_issue"
printf 'zbuild:claimed\n' > "$ZBUILD_CLAIM_STORE/$_dscla4_issue/labels.txt"
# Run-status comment with <!-- zbuild-holder: --> field (the holder's run wrote this via run-status-comment.sh)
cat > "$ZBUILD_CLAIM_STORE/$_dscla4_issue/run-status-comment.txt" <<'RSCEOF'
<!-- zbuild-run-status run_id=holder-run-99 -->
<!-- zbuild-holder: run-holder-99 on machine-other -->
run is in progress...
RSCEOF

# When: zbuild_claim_acquire is called and finds the label present
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire "$_dscla4_issue"; _dscla4_rc=$?; set -e

# Then: it returns 1
assert_eq "zbuild_claim_acquire returns 1 when issue already claimed (pre-stage check)" "1" "$_dscla4_rc"

# Then: _ZBUILD_CLAIM_HOLDER is set to the holder string from the run-status comment
if [[ -n "${_ZBUILD_CLAIM_HOLDER:-}" ]]; then
    assert_pass "_ZBUILD_CLAIM_HOLDER is set (not empty) after refused claim"
else
    assert_fail "_ZBUILD_CLAIM_HOLDER is set (not empty) after refused claim" \
        "_ZBUILD_CLAIM_HOLDER was empty or unset"
fi

if grep -q "run-holder-99" <<< "${_ZBUILD_CLAIM_HOLDER:-}"; then
    assert_pass "_ZBUILD_CLAIM_HOLDER contains holder string from run-status comment"
else
    assert_fail "_ZBUILD_CLAIM_HOLDER contains holder string from run-status comment" \
        "_ZBUILD_CLAIM_HOLDER='${_ZBUILD_CLAIM_HOLDER:-}' (expected to contain 'run-holder-99')"
fi

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-8: empty issue argument → no gh call, returns 0
# ─────────────────────────────────────────────────────────────────────────────

# Given: mock gh that records calls
_dscla8_calls="$TEST_TEMP_DIR/gh-calls-dscla8.txt"
: > "$_dscla8_calls"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla8_calls"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Switch to gh backend to verify no calls are made
_prev_backend="$ZBUILD_CLAIM_BACKEND"
export ZBUILD_CLAIM_BACKEND="gh"

# When: zbuild_claim_acquire is called with an empty issue argument
unset _ZBUILD_CLAIM_HOLDER 2>/dev/null || true
: > "$ZBUILD_EVENTS_JSONL"
set +e; zbuild_claim_acquire ""; _dscla8_rc=$?; set -e

# Then: no gh label call is made
_dscla8_call_count="$(wc -l < "$_dscla8_calls" | tr -d ' ')"
assert_eq "[DSCLA-8] no gh calls made for empty issue" "0" "$_dscla8_call_count"

# Then: function returns 0
assert_eq "[DSCLA-8] zbuild_claim_acquire returns 0 for empty issue" "0" "$_dscla8_rc"

# Cleanup: restore previous backend and plain gh mock
export ZBUILD_CLAIM_BACKEND="$_prev_backend"
mock_gh

# ─────────────────────────────────────────────────────────────────────────────
# DSCLA-10: pipeline.refused.claimed is an accepted event name in event-schema.json
# ─────────────────────────────────────────────────────────────────────────────

# Given: config/event-schema.json is the event schema for the engine
# When: we check for pipeline.refused.claimed in the known_types
# Then: pipeline.refused.claimed is registered (passes the schema coverage check)
if grep -qF '"pipeline.refused.claimed"' "$REPO_ROOT/config/event-schema.json" 2>/dev/null; then
    assert_pass "[DSCLA-10] pipeline.refused.claimed is in config/event-schema.json known_types"
else
    assert_fail "[DSCLA-10] pipeline.refused.claimed is in config/event-schema.json known_types" \
        "not found in $REPO_ROOT/config/event-schema.json"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
