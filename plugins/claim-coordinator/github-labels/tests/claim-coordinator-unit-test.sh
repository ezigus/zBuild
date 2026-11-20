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
# DSCLA-17: zbuild_claim_release with no prior acquire invokes no gh label command
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

    # Given: _ZBUILD_CLAIM_ACQUIRED is not set
    _dscla17_calls="$TEST_TEMP_DIR/gh-calls-dscla17.txt"
    : > "$_dscla17_calls"
    cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla17_calls"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    _prev_backend_17="$ZBUILD_CLAIM_BACKEND"
    export ZBUILD_CLAIM_BACKEND="gh"
    unset _ZBUILD_CLAIM_ACQUIRED 2>/dev/null || true

    # When: zbuild_claim_release is called
    set +e; zbuild_claim_release; _dscla17_rc=$?; set -e

    # Then: no gh label command is invoked
    _dscla17_call_count="$(wc -l < "$_dscla17_calls" | tr -d ' ')"
    assert_eq "[DSCLA-17] no gh calls made when _ZBUILD_CLAIM_ACQUIRED is not set" "0" "$_dscla17_call_count"

    # Cleanup: restore previous backend and plain gh mock
    export ZBUILD_CLAIM_BACKEND="$_prev_backend_17"
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
    : > "$_dscla19_gh_calls"

    # Mock gh: records every invocation (must NOT be called by zbuild_claim_acquire directly)
    cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$_dscla19_gh_calls"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Given: a claim-coordinator plugin is registered; use local-fs backend so the
    # coordinator itself does not call gh — any gh call in the calls file comes
    # directly from zbuild_claim_acquire, not through the coordinator hook
    _prev_backend_19="$ZBUILD_CLAIM_BACKEND"
    export ZBUILD_CLAIM_BACKEND="local-fs"
    rm -rf "${ZBUILD_CLAIM_STORE:?}/$_dscla19_issue"
    unset _ZBUILD_CLAIM_ACQUIRED 2>/dev/null || true

    # When: zbuild_claim_acquire is called with an issue number
    : > "$ZBUILD_EVENTS_JSONL"
    set +e; zbuild_claim_acquire "$_dscla19_issue"; _dscla19_rc=$?; set -e

    # Then: the coordinator's claim hook function is called with the issue number
    # (evidenced by zbuild:claimed being added to the claim store for this issue)
    _dscla19_labels="$ZBUILD_CLAIM_STORE/$_dscla19_issue/labels.txt"
    if grep -Fxq "zbuild:claimed" "$_dscla19_labels" 2>/dev/null; then
        assert_pass "[DSCLA-19] coordinator's claim hook was called (zbuild:claimed in claim store)"
    else
        assert_fail "[DSCLA-19] coordinator's claim hook was called (zbuild:claimed in claim store)" \
            "zbuild:claimed not found in $_dscla19_labels; contents: $(cat "$_dscla19_labels" 2>/dev/null || echo '<absent>')"
    fi

    # And: gh is not invoked directly within zbuild_claim_acquire
    _dscla19_gh_count="$(wc -l < "$_dscla19_gh_calls" | tr -d ' ')"
    assert_eq "[DSCLA-19] gh is not invoked directly within zbuild_claim_acquire" "0" "$_dscla19_gh_count"

    # Cleanup
    export ZBUILD_CLAIM_BACKEND="$_prev_backend_19"
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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
