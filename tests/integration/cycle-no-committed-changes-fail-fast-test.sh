#!/usr/bin/env bash
# Integration test (#1265, SPEC-4): a cycle iteration that WOULD converge with
# ZERO commits ahead of the intake baseline AND build verdict != empty_diff does
# NOT converge — it terminates no_committed_changes (rc=5) so the pipeline halts
# before review/pr instead of shipping an empty branch to a confusing `pr` abort.
#
# Reproduces the #1214 dogfood: a scope_violation discarded the entire diff +
# skipped the commit (HEAD == baseline), the suite passed on the uncommitted
# tree, the final cycle member passed → the cycle "converged" on nothing.
#
# RED at baseline: today the cycle converges rc=0. GREEN after: rc=5,
# reason=no_committed_changes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build_test_cycle: 0-commit convergence fails fast (#1265)"
setup_test_env "cycle-1265-no-commits"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_PLUGINS_ROOT="$REPO_ROOT/plugins"
export ZBUILD_RUN_ID="nocommit-1265-$$"

# ─── git fixture: HEAD stays at the intake baseline (build commits nothing) ──
GIT_FIXTURE="$TEST_TEMP_DIR/repo"
mkdir -p "$GIT_FIXTURE"
git -C "$GIT_FIXTURE" init --quiet >/dev/null 2>&1
git -C "$GIT_FIXTURE" config user.email 'test@example.com' >/dev/null
git -C "$GIT_FIXTURE" config user.name 'test' >/dev/null
printf 'seed\n' > "$GIT_FIXTURE/SEED"
git -C "$GIT_FIXTURE" add SEED >/dev/null
git -C "$GIT_FIXTURE" commit -m baseline --quiet >/dev/null
_BASELINE_SHA="$(git -C "$GIT_FIXTURE" rev-parse HEAD)"
cd "$GIT_FIXTURE"

export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_STATE_FILE="$ZBUILD_STATE_DIR/pipeline-state.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
ARTIFACTS_DIR="$ZBUILD_STATE_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR" "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_FILE"
# Raw SHA, no trailing newline (matches real intake).
printf '%s' "$_BASELINE_SHA" > "$ZBUILD_STATE_DIR/intake-baseline-ref.txt"
cat > "$ZBUILD_STATE_DIR/scope-manifest.md" <<'SCOPE'
+ core/
+ plugins/
SCOPE
cat > "$ARTIFACTS_DIR/plan.json" <<'PJ'
{"schema_version":1,"title":"x","goal":"x","steps":[{"id":"s1","description":"d","files":["core/x.sh"],"estimated_lines":1}]}
PJ

# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/template.sh"
# #979: standard.yaml retired. no_committed_changes fail-fast is an orchestrator
# mechanic keyed on the build/test verdicts; the test supplies its own dispatch
# stub and needs only the build_test_cycle shape → focused minimal fixture.
load_template "$REPO_ROOT/tests/fixtures/templates/build-test-cycle-minimal.yaml"
# shellcheck disable=SC1090
source "$REPO_ROOT/core/pipeline/cycle-orchestrator.sh"

# ─── Stub dispatch: build scope_violation (no commit), test pass ─────────────
cycle_dispatch_stage() {
    local stage="$1" state_file="$3"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artdir="$state_dir/artifacts"; mkdir -p "$artdir"
    local v="pass"
    case "$stage" in
        build)
            # A scope_violation zeroed the diff + skipped the commit: HEAD stays
            # at the baseline. verdict != empty_diff (a real work-was-discarded).
            printf '{"schema_version":1,"verdict":"scope_violation","iterations":1,"terminated_reason":"scope_violation","scope_violation":true,"files_changed":[]}' \
                > "$artdir/build-summary.json"
            v="scope_violation"
            ;;
        test)
            # The suite passes on the UNCOMMITTED tree (misleading green).
            printf '{"schema_version":1,"verdict":"pass","exit_code":0,"passed":10,"failed":0,"test_output":"total: 10/10 passed","diff_applied":true,"test_cmd":"npm test"}' \
                > "$artdir/test-results.json"
            v="pass"
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR" "$ZBUILD_STATE_FILE"
RC=$?
set -e

# ── (1) NOT a clean converge — halts blocked-class rc=5 ─────────────────────
assert_eq "0-commit scope_violation: cycle rc=5 (halt, not converged)" "5" "$RC"
assert_eq "0-commit scope_violation: reason=no_committed_changes" \
    "no_committed_changes" "${_CYCLE_LAST_TERMINATED_REASON:-}"

# ── (2) suppression + terminal events emitted ───────────────────────────────
if grep -q '"cycle.no_committed_changes.suppressed_convergence"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "cycle.no_committed_changes.suppressed_convergence emitted"
else
    assert_fail "cycle.no_committed_changes.suppressed_convergence emitted" "missing"
fi
if grep -q '"cycle.no_committed_changes"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "cycle.no_committed_changes terminal emitted"
else
    assert_fail "cycle.no_committed_changes terminal emitted" "missing"
fi

# ── SPEC-10 (#1832): empty_diff exemption reads _build_kind, not _build_verdict ─
# When build writes verdict=pass + data.build_kind=empty_diff (the new ADR-054 §6
# format), the no_committed_changes guard must be EXEMPT — "nothing to do" is a
# valid resting point, not a failure to commit.
# CHANGE-behavior: at baseline (old code: _build_verdict != "empty_diff"), a
# verdict=pass stub was not exempted → no_committed_changes fired → rc=5.
# After #1832 (new code: _build_kind != "empty_diff"), kind=empty_diff is exempt.
#
# This REDEFINES cycle_dispatch_stage, shadowing the definition above for the
# rest of the file. That is intentional and safe only because SPEC-10 is the
# last section — a new section appended below would silently inherit THIS mock
# (which returns verdict=pass + kind=empty_diff) instead of the original.
# Add new sections ABOVE this line, or give them their own redefinition.
cycle_dispatch_stage() {
    local stage="$1" state_file="$3"
    local state_dir; state_dir="$(dirname "$state_file")"
    local artdir="$state_dir/artifacts"; mkdir -p "$artdir"
    local v="pass"
    case "$stage" in
        build)
            # ADR-054: verdict=pass + disposition=complete + data.build_kind=empty_diff
            printf '{"schema_version":1,"result_contract":2,"verdict":"pass","disposition":"complete","data":{"build_kind":"empty_diff"},"iterations":1,"terminated_reason":"done_sentinel","files_changed":[]}' \
                > "$artdir/build-summary.json"
            v="pass"
            _CYCLE_DISPATCH_DISPOSITION="complete"
            _CYCLE_DISPATCH_DATA_KIND="empty_diff"
            ;;
        test)
            printf '{"schema_version":1,"verdict":"pass","exit_code":0,"passed":10,"failed":0,"test_output":"total: 10/10 passed","diff_applied":true,"test_cmd":"npm test"}' \
                > "$artdir/test-results.json"
            v="pass"
            ;;
    esac
    _CYCLE_DISPATCH_VERDICT="$v"
    _CYCLE_DISPATCH_STATUS="complete"
    return 0
}

ZBUILD_STATE_DIR2="$TEST_TEMP_DIR/state2"
mkdir -p "$ZBUILD_STATE_DIR2/artifacts" "$ZBUILD_EVENTS_DIR"
: > "$ZBUILD_EVENTS_JSONL"
printf '{"schema_version":1,"status":"in_progress"}' > "$ZBUILD_STATE_DIR2/pipeline-state.json"
# HEAD is still at baseline (build stub commits nothing) — _cycle_no_commits_ahead returns 0.
cp "$ZBUILD_STATE_DIR/intake-baseline-ref.txt" "$ZBUILD_STATE_DIR2/intake-baseline-ref.txt"
cp "$ZBUILD_STATE_DIR/scope-manifest.md" "$ZBUILD_STATE_DIR2/scope-manifest.md"
cp "$ARTIFACTS_DIR/plan.json" "$ZBUILD_STATE_DIR2/artifacts/plan.json"

set +e
cycle_orchestrator_run "build_test_cycle" "$ZBUILD_STATE_DIR2" "$ZBUILD_STATE_DIR2/pipeline-state.json"
RC10=$?
set -e

assert_eq "[SPEC-10] kind=empty_diff (verdict=pass) exempts no_committed_changes — converges rc=0" \
    "0" "$RC10"
if grep -q '"cycle.no_committed_changes"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_fail "[SPEC-10] no_committed_changes must NOT fire for kind=empty_diff resting point" \
        "event emitted"
else
    assert_pass "[SPEC-10] no_committed_changes not emitted for kind=empty_diff resting point"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
