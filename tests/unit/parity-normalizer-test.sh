#!/usr/bin/env bash
# Tests: parity normalizer library (scripts/lib/parity.sh)
# Verifies each normalization function strips non-deterministic fields.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "parity normalizer — scripts/lib/parity.sh"
setup_test_env "parity-normalizer"

# Source the library under test (will fail if it does not exist)
source "$REPO_ROOT/scripts/lib/parity.sh"

# ── normalize_run_id ──────────────────────────────────────────────────────────
actual="$(normalize_run_id "run_id: 20260525123456-99999 and another 20261231235959-1")"
assert_eq "normalize_run_id replaces YYYYMMDDHHMMSS-PID pattern" \
    "run_id: __RUN_ID__ and another __RUN_ID__" \
    "$actual"

actual="$(normalize_run_id "no run id here")"
assert_eq "normalize_run_id leaves unmatched text unchanged" \
    "no run id here" \
    "$actual"

# ── normalize_timestamps ──────────────────────────────────────────────────────
actual="$(normalize_timestamps "ts: 2026-05-25T12:34:56Z updated_at: 2026-01-01T00:00:00Z")"
assert_eq "normalize_timestamps replaces ISO-8601 datetimes" \
    "ts: __TS__ updated_at: __TS__" \
    "$actual"

actual="$(normalize_timestamps "no timestamps here")"
assert_eq "normalize_timestamps leaves unmatched text unchanged" \
    "no timestamps here" \
    "$actual"

# ── normalize_paths ───────────────────────────────────────────────────────────
actual="$(normalize_paths "/tmp/foo/state/pipeline-state.json" "/tmp/foo")"
assert_eq "normalize_paths replaces base prefix with __FIXTURE_DIR__" \
    "__FIXTURE_DIR__/state/pipeline-state.json" \
    "$actual"

actual="$(normalize_paths "no path here" "/tmp/foo")"
assert_eq "normalize_paths leaves unmatched text unchanged" \
    "no path here" \
    "$actual"

# ── strip_ci_only_events ──────────────────────────────────────────────────────
input="$(printf 'pipeline.started\noutput.gh-check-run\npipeline.stage.complete\noutput.step-summary\npipeline.complete')"
actual="$(printf '%s' "$input" | strip_ci_only_events)"
assert_eq "strip_ci_only_events removes output.gh-check-run lines" \
    "$(printf 'pipeline.started\npipeline.stage.complete\npipeline.complete')" \
    "$actual"

actual="$(printf 'pipeline.started\npipeline.complete' | strip_ci_only_events)"
assert_eq "strip_ci_only_events passes through non-CI events unchanged" \
    "$(printf 'pipeline.started\npipeline.complete')" \
    "$actual"

# ── normalize_output_for_parity (composed pipeline) ──────────────────────────
input="run_id: 20260525123456-99999 ts: 2026-05-25T12:34:56Z path: /tmp/mydir/state"
actual="$(normalize_output_for_parity "$input" "/tmp/mydir")"
assert_eq "normalize_output_for_parity composes all normalizers" \
    "run_id: __RUN_ID__ ts: __TS__ path: __FIXTURE_DIR__/state" \
    "$actual"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
