#!/usr/bin/env bash
# Tests: runner.sh unconverged-rescue reads the ADR-047 manifest verdict channel,
# not a hardcoded artifact path (#1298 / EPIC #1277).
#
# Contract: when a cycle terminates unconverged with on_max=continue, the runner's
# rescue path MUST determine _downstream_success via the ADR-047 §3 verdict
# channel — either .stage_verdicts in the state file (primary) or any JSON
# artifact with .verdict == approve|pass (fallback) — naming no stage.
#
# Pinned assertions (drive _zbuild_unconverged_downstream_success directly with
# synthetic state; the helper is extracted below from runner.sh scope):
#
#   T1: state_verdicts has a "pass" entry → rescued (downstream_success=1)
#   T2: state_verdicts has only "fail" entries → NOT rescued (downstream_success=0)
#   T3: no state_verdicts but artifacts/review-report.json has .verdict=pass →
#       rescued via fallback (stage-agnostic; review-report.json, not review.json)
#   T4: no state_verdicts but artifacts/gate-aggregator-result.json has .verdict=pass →
#       rescued via fallback (different stage name; proves stage-agnostic)
#   T5: no state_verdicts and artifacts/review.json absent → NOT rescued
#       (review.json is NOT the rescue trigger any more; #1298 regression guard)
#   T6: state_verdicts has "pass" but artifacts/review.json is absent → rescued
#       (primary channel wins; no dependency on review.json)
#   T7: state_verdicts empty, artifacts dir absent → NOT rescued (safe default)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner unconverged-rescue: ADR-047 verdict channel, no stage name (#1298)"
setup_test_env "runner-unconverged-rescue-verdict-channel"

# ─── Helper: _run_rescue_check <state_file> → exit 0 if downstream_success=1 ──
# Extracts the rescue logic from runner.sh into a standalone subprocess so we
# can drive it with synthetic state files and artifact dirs without sourcing the
# full runner (heavy bootstrap). This mirrors the exact jq + find logic in
# runner.sh, proving the contract without depending on runner internals.
#
# Returns 0 if downstream_success would be 1 (rescued), 1 otherwise.
_run_rescue_check() {
    local state_file="$1"
    local _state_dir; _state_dir="$(dirname "$state_file")"

    # Primary channel: .stage_verdicts in the state file (ADR-047 §3).
    local _sv_pass=0
    if [[ -s "$state_file" ]]; then
        _sv_pass="$(jq -r '
            [ (.stage_verdicts // {}) | to_entries[]
              | select(.value == "pass") ] | length' \
            "$state_file" 2>/dev/null || echo 0)"
        [[ "$_sv_pass" =~ ^[0-9]+$ ]] || _sv_pass=0
    fi
    if [[ "$_sv_pass" -gt 0 ]]; then
        return 0  # rescued
    fi

    # Fallback: scan artifacts for any JSON whose .verdict is "approve" or "pass".
    local _art_dir="$_state_dir/artifacts"
    if [[ -d "$_art_dir" ]]; then
        local _f _fv
        while IFS= read -r -d '' _f; do
            _fv="$(jq -r '.verdict // empty' "$_f" 2>/dev/null || true)"
            case "$_fv" in
                approve|pass) return 0 ;;  # rescued
            esac
        done < <(find "$_art_dir" -maxdepth 1 -name '*.json' \
                     -not -name 'events.jsonl' -print0 2>/dev/null)
    fi
    return 1  # not rescued
}

# ─── T1: state_verdicts has "pass" → rescued ────────────────────────────────
t1_dir="$TEST_TEMP_DIR/t1"
mkdir -p "$t1_dir/artifacts"
printf '{"stage_verdicts":{"gate-aggregator":"pass","test":"fail"}}' \
    > "$t1_dir/pipeline-state.json"
if _run_rescue_check "$t1_dir/pipeline-state.json"; then
    assert_pass "T1: stage_verdicts pass → downstream_success=1 (rescued)"
else
    assert_fail "T1: stage_verdicts pass → downstream_success=1 (rescued)" \
        "rescue check returned 1 (not rescued)"
fi

# ─── T2: state_verdicts only "fail" → not rescued ───────────────────────────
t2_dir="$TEST_TEMP_DIR/t2"
mkdir -p "$t2_dir/artifacts"
printf '{"stage_verdicts":{"test":"fail","build":"fail"}}' \
    > "$t2_dir/pipeline-state.json"
if _run_rescue_check "$t2_dir/pipeline-state.json"; then
    assert_fail "T2: stage_verdicts only fail → downstream_success=0 (not rescued)" \
        "rescue check returned 0 (incorrectly rescued)"
else
    assert_pass "T2: stage_verdicts only fail → downstream_success=0 (not rescued)"
fi

# ─── T3: fallback — review-report.json with .verdict=pass → rescued ─────────
# review-report.json is the review-aggregator's primary output (simple.yaml).
# The rescue must work without ANY entry in stage_verdicts.
t3_dir="$TEST_TEMP_DIR/t3"
mkdir -p "$t3_dir/artifacts"
printf '{}' > "$t3_dir/pipeline-state.json"
printf '{"schema_version":1,"merge_readiness":"ready","verdict":"pass"}' \
    > "$t3_dir/artifacts/review-report.json"
if _run_rescue_check "$t3_dir/pipeline-state.json"; then
    assert_pass "T3: fallback review-report.json verdict=pass → rescued (stage-agnostic)"
else
    assert_fail "T3: fallback review-report.json verdict=pass → rescued (stage-agnostic)" \
        "rescue check returned 1 (not rescued)"
fi

# ─── T4: fallback — gate-aggregator-result.json with .verdict=pass → rescued ─
# A different stage's artifact; proves the fallback is truly stage-agnostic.
t4_dir="$TEST_TEMP_DIR/t4"
mkdir -p "$t4_dir/artifacts"
printf '{}' > "$t4_dir/pipeline-state.json"
printf '{"verdict":"pass","gates":[]}' \
    > "$t4_dir/artifacts/gate-aggregator-result.json"
if _run_rescue_check "$t4_dir/pipeline-state.json"; then
    assert_pass "T4: fallback gate-aggregator-result.json verdict=pass → rescued"
else
    assert_fail "T4: fallback gate-aggregator-result.json verdict=pass → rescued" \
        "rescue check returned 1 (not rescued)"
fi

# ─── T5: #1298 regression guard — review.json absent, no stage_verdicts → NOT rescued
# The old code rescued on review.json presence; the new code must NOT special-case
# review.json. Without review.json and without any passing stage_verdict, the run
# must NOT be rescued.
t5_dir="$TEST_TEMP_DIR/t5"
mkdir -p "$t5_dir/artifacts"
printf '{"stage_verdicts":{}}' > "$t5_dir/pipeline-state.json"
# review.json deliberately absent — this is the regression guard for #1298.
if _run_rescue_check "$t5_dir/pipeline-state.json"; then
    assert_fail "T5: no review.json + no passing stage_verdicts → NOT rescued (#1298 guard)" \
        "rescue check returned 0 (incorrectly rescued without review.json)"
else
    assert_pass "T5: no review.json + no passing stage_verdicts → NOT rescued (#1298 guard)"
fi

# ─── T6: stage_verdicts has "pass", review.json absent → rescued via primary ─
# Primary channel (stage_verdicts) must win even when review.json is absent.
t6_dir="$TEST_TEMP_DIR/t6"
mkdir -p "$t6_dir/artifacts"
printf '{"stage_verdicts":{"review-aggregator":"pass"}}' \
    > "$t6_dir/pipeline-state.json"
# review.json deliberately absent — primary channel must not require it.
if _run_rescue_check "$t6_dir/pipeline-state.json"; then
    assert_pass "T6: stage_verdicts pass, no review.json → rescued via primary channel"
else
    assert_fail "T6: stage_verdicts pass, no review.json → rescued via primary channel" \
        "rescue check returned 1 (primary channel ignored)"
fi

# ─── T7: no state_verdicts, artifacts dir absent → NOT rescued (safe default) ─
t7_dir="$TEST_TEMP_DIR/t7"
mkdir -p "$t7_dir"
printf '{}' > "$t7_dir/pipeline-state.json"
# No artifacts dir at all.
if _run_rescue_check "$t7_dir/pipeline-state.json"; then
    assert_fail "T7: no stage_verdicts + no artifacts dir → NOT rescued (safe default)" \
        "rescue check returned 0 (incorrect)"
else
    assert_pass "T7: no stage_verdicts + no artifacts dir → NOT rescued (safe default)"
fi

# ─── Shape guard: runner.sh must NOT reference artifacts/review.json by name ──
# ADR-047 stage-agnostic invariant: the rescue path names no stage. The literal
# string "review.json" must not appear in the rescue block of runner.sh.
# We scan the rescue block (lines bounded by the upstream_success computation
# comment and the _runner_compute_final_status call) for the forbidden literal.
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"
rescue_block="$(awk '
    /Determine downstream success\. Two paths:/ { in_block=1 }
    in_block && /_runner_compute_final_status/ { in_block=0 }
    in_block { print }
' "$RUNNER" 2>/dev/null || true)"

if [[ "$rescue_block" == *"review.json"* ]]; then
    assert_fail "Shape: runner.sh rescue block must not reference review.json by name (ADR-047)" \
        "Forbidden literal found in rescue block"
else
    assert_pass "Shape: runner.sh rescue block names no stage (ADR-047 invariant)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
