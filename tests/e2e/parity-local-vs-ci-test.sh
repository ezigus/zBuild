#!/usr/bin/env bash
# Tests: CI/CLI parity — pipeline core produces identical output regardless of GITHUB_ACTIONS env
# ADR-010: zbuild behavior is environmentally agnostic for the pipeline core
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "CI/CLI parity — engine behavior is environmentally agnostic (ADR-010)"
setup_test_env "parity-local-vs-ci"

FIXTURE="$REPO_ROOT/tests/golden/parity/run-fixture.sh"
RUN1_DIR="$TEST_TEMP_DIR/run-local"
RUN2_DIR="$TEST_TEMP_DIR/run-ci"
BIN_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$RUN1_DIR/events" "$RUN2_DIR/events" "$BIN_DIR"

# ── Test 1: fixture exists and is executable ──────────────────────────────────
if [[ -x "$FIXTURE" ]]; then
    assert_pass "fixture script exists and is executable"
else
    assert_fail "fixture script exists and is executable" "not found or not executable: $FIXTURE"
fi

# ── Test 2: local mode run exits 0 ───────────────────────────────────────────
# Unset any CI env vars that might bleed in from the calling environment
set +e
(
    unset GITHUB_ACTIONS CI GITHUB_STEP_SUMMARY RUNNER_OS 2>/dev/null || true
    FIXTURE_STATE_DIR="$RUN1_DIR" FIXTURE_BIN_DIR="$BIN_DIR" \
        bash "$FIXTURE" >/dev/null 2>&1
)
local_rc=$?
set -e
assert_eq "fixture runs exit 0 in local mode" "0" "$local_rc"

# ── Test 3: local run produces pipeline-state.json ───────────────────────────
assert_file_exists "pipeline-state.json created (local)" "$RUN1_DIR/pipeline-state.json"

# ── Test 4: local run produces events.jsonl ──────────────────────────────────
assert_file_exists "events.jsonl created (local)" "$RUN1_DIR/events/events.jsonl"

# ── Test 5: CI mode run exits 0 ──────────────────────────────────────────────
SUMMARY_FILE="$TEST_TEMP_DIR/step-summary.md"
set +e
FIXTURE_STATE_DIR="$RUN2_DIR" FIXTURE_BIN_DIR="$BIN_DIR" \
GITHUB_ACTIONS=true CI=true RUNNER_OS=Linux \
GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
ZBUILD_OUTPUT_GH_COMMENT=0 ZBUILD_OUTPUT_GH_CHECK_RUN=0 \
    bash "$FIXTURE" >/dev/null 2>&1
ci_rc=$?
set -e
assert_eq "fixture runs exit 0 in CI mode" "0" "$ci_rc"

# ── Test 6: pipeline final status is "complete" in both modes ────────────────
local_status="$(jq -r '.status // empty' "$RUN1_DIR/pipeline-state.json" 2>/dev/null || true)"
ci_status="$(jq -r '.status // empty' "$RUN2_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_eq "local run pipeline status=complete" "complete" "$local_status"
assert_eq "CI run pipeline status=complete" "complete" "$ci_status"

# ── Test 7: event type sequence is identical in local and CI modes ────────────
local_events="$(jq -r '.type' "$RUN1_DIR/events/events.jsonl" 2>/dev/null || true)"
ci_events="$(jq -r '.type' "$RUN2_DIR/events/events.jsonl" 2>/dev/null || true)"
assert_eq "event type sequence identical in local and CI modes" "$local_events" "$ci_events"

# ── Test 8: stage_statuses map is identical in both modes ────────────────────
local_stages="$(jq -Sc '.stage_statuses' "$RUN1_DIR/pipeline-state.json" 2>/dev/null || true)"
ci_stages="$(jq -Sc '.stage_statuses' "$RUN2_DIR/pipeline-state.json" 2>/dev/null || true)"
assert_eq "stage_statuses identical in local and CI modes" "$local_stages" "$ci_stages"

# ── Test 9: event sequence matches golden snapshot ───────────────────────────
if ! assert_golden "parity/event-sequence" "$local_events"; then
    assert_fail "event sequence matches golden snapshot" "golden mismatch (run UPDATE_GOLDEN=1 to regenerate)"
else
    assert_pass "event sequence matches golden snapshot"
fi

# ─── Issue #305 (Δ-5): depth — diff full state.json + artifact tree ───────────
# Until now, parity only diffed status + stage_statuses + event types. That
# misses divergence in routing decisions, scope hashes, plugin state, or
# artifact contents. ADR-010 implies stronger equivalence than event presence.

# Normalize state.json: sort keys, redact run-instance fields that legitimately
# vary across runs (updated_at timestamp; run_id is already fixed by fixture).
_normalize_state() {
    jq -S 'del(.updated_at)' "$1" 2>/dev/null
}

# ── Test 10: full normalized pipeline-state.json identical across modes ──────
local_state_norm="$(_normalize_state "$RUN1_DIR/pipeline-state.json")"
ci_state_norm="$(_normalize_state "$RUN2_DIR/pipeline-state.json")"
assert_eq "full pipeline-state.json identical after normalization" \
    "$local_state_norm" "$ci_state_norm"

# ── Test 11: artifact tree (relative paths) identical across modes ──────────
# Excludes runtime state files (events/, *.lock, *.bak, *.db) — keepers are
# stage outputs under artifacts/ and the top-level produced files.
_artifact_paths() {
    local dir="$1"
    ( cd "$dir" && \
      find . -type f \
        -not -path './events/*' \
        -not -name '*.lock' \
        -not -name '*.bak' \
        -not -name '*.db' \
        -not -name '*.db-journal' \
        -not -name '*.db-shm' \
        -not -name '*.db-wal' \
        | sort )
}

local_paths="$(_artifact_paths "$RUN1_DIR")"
ci_paths="$(_artifact_paths "$RUN2_DIR")"
assert_eq "artifact filename list identical across modes" "$local_paths" "$ci_paths"

# ── Test 12: each artifact's sha256 identical across modes ──────────────────
# Confirms the contents match, not just the filenames. Normalizes ephemeral
# timestamp fields (updated_at, generated_at, ts) in JSON artifacts so
# legitimate per-run timestamps don't mask real divergence.
_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        sha256sum | awk '{print $1}'
    fi
}

# Normalize a file for sha comparison:
# - JSON: jq -S to sort keys + del() any ephemeral timestamps
# - all files: substitute the run-specific state-dir absolute path with a
#   placeholder so embedded paths (e.g. in contract-violated findings) match.
# - everything else: pass through with that substitution.
_normalize_for_sha() {
    local f="$1" run_dir="$2"
    local body
    if [[ "$f" == *.json ]]; then
        body="$(jq -S 'del(.updated_at, .generated_at, .ts)' "$f" 2>/dev/null)" \
            || body="$(cat "$f")"
    else
        body="$(cat "$f")"
    fi
    # Strip run-specific dir prefix so embedded absolute paths normalize.
    printf '%s' "$body" | sed "s|${run_dir}|__RUN_DIR__|g"
}

mismatched_artifacts=()
while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    local_h="$(_normalize_for_sha "$RUN1_DIR/$rel" "$RUN1_DIR" | _sha256)"
    ci_h="$(_normalize_for_sha "$RUN2_DIR/$rel" "$RUN2_DIR" | _sha256)"
    if [[ "$local_h" != "$ci_h" ]]; then
        mismatched_artifacts+=("$rel local=$local_h ci=$ci_h")
    fi
done <<< "$local_paths"

if [[ ${#mismatched_artifacts[@]} -eq 0 ]]; then
    assert_pass "all artifact contents identical across modes (sha256, timestamps normalized)"
else
    assert_fail "all artifact contents identical across modes (sha256, timestamps normalized)" \
        "mismatches: $(printf '\n  %s' "${mismatched_artifacts[@]}")"
fi

# ── Test 13: normalized state shape matches golden snapshot ─────────────────
if ! assert_golden "parity/state-shape" "$local_state_norm"; then
    assert_fail "normalized state.json matches golden snapshot" "golden mismatch (run UPDATE_GOLDEN=1 to regenerate)"
else
    assert_pass "normalized state.json matches golden snapshot"
fi

# ── Test 14: artifact filename list matches golden snapshot ─────────────────
if ! assert_golden "parity/artifact-paths" "$local_paths"; then
    assert_fail "artifact filename list matches golden snapshot" "golden mismatch (run UPDATE_GOLDEN=1 to regenerate)"
else
    assert_pass "artifact filename list matches golden snapshot"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
