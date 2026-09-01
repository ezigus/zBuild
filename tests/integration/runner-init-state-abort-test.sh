#!/usr/bin/env bash
# Tests: core/pipeline/runner.sh — #1773
# A refused state-file write at init_state must abort the run before any stage
# executes, and must say why.
#
# Note on the merge-base behavior this pins: runner.sh runs under `set -euo
# pipefail`, so an unchecked `init_state` already died on the refused write —
# but silently, with only atomic_write's own line and nothing tying it to the
# resume contract. The stateless-run exposure the issue describes is real for
# every init_state caller that is NOT under `set -e`; at the runner the
# observable defect is a diagnostic-free death. Both are fixed by checking the
# write, so this test asserts the part the runner can observe.
#
# SPEC-5[change]: a refused state write aborts the pipeline with a diagnostic
#                 naming init_state and the resume consequence; no stage starts.
# SPEC-6[guard]:  the same invocation against a writable state dir still runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner — init_state write failure aborts the run (#1773)"
setup_test_env "runner-init-state-abort"

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
export ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# $3 is the fixture's declared role: resolve_stage_plugin fails closed on a
# stage that declares roles: but resolves none, so a stub needs provides.role.
_make_plugin() {
    local id="$1" kind="${2:-agent}" role="$3"
    local dir="$PLUGINS_ROOT/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Test $id
kind: $kind
version: 0.0.1
provides:
  role: $role
hooks:
  run: $fn
requires:
  core:
    - redaction
outputs:
  # ADR-055 §9 (#2000): every stage-bound plugin declares exactly one summary.
  - id: ${id//-/_}_summary
    type: $id-summary.md@1
    format: markdown
    path: \${artifact_dir}/$id-summary.md
    required: true
    summary: true
EOF
    cat > "$dir/plugin.sh" <<EOF
${fn}() {
    # ADR-055 §9 (#2000): the summary is a required output, so the stub writes
    # one — a declared-but-unwritten artifact is a contract violation.
    local _d="\${ZBUILD_ARTIFACT_DIR:-\$(dirname "\${2:-/tmp/x}")/artifacts}"
    mkdir -p "\$_d" 2>/dev/null || true
    printf '## %s — pass\n\n- stub stage\n' "$id" > "\$_d/$id-summary.md" 2>/dev/null || true
    return 0
}
EOF
}
# Roles mirror runner-state-dir-minimal.yaml's roles: declarations.
_make_plugin "intake" "agent" "intake"
_make_plugin "build"  "agent" "builder"

OVERLAY_REPO="$(setup_git_temp_repo tpl-overlay-repo)"
install_template_overlay "$OVERLAY_REPO" runner-state-dir-minimal
cd "$OVERLAY_REPO"

_stage_started() {
    grep -q '"type":"stage.start"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null
}

# ─── SPEC-5[change]: a refused state write aborts before any stage ─────────
# Reproduce the real defect shape, not a generic I/O error: atomic_write's
# disk-space precheck refuses while the jq producer exits 0. `df` is shadowed
# by an exported function so the refusal reaches the runner's own bash process.
# A read-only directory would NOT reproduce it — that fails loudly on its own,
# both before and after the fix.
BAD_STATE_DIR="$TEST_TEMP_DIR/refused-state"
mkdir -p "$BAD_STATE_DIR"
: > "$ZBUILD_EVENTS_JSONL"

df() { printf 'Filesystem 1M-blocks Used Avail Capacity Mounted\n/dev/fake 100 99 1 99%% /\n'; }
export -f df

set +e
ZBUILD_STATE_DIR="$BAD_STATE_DIR" \
    bash "$RUNNER" --template runner-state-dir-minimal --issue 1773 --no-resume \
    >"$TEST_TEMP_DIR/out-bad" 2>"$TEST_TEMP_DIR/err-bad"
bad_rc=$?
set -e
export -n df
unset -f df

assert_gt "SPEC-5: a refused state write aborts the run" "$bad_rc" "0"
bad_msgs="$(cat "$TEST_TEMP_DIR/out-bad" "$TEST_TEMP_DIR/err-bad")"
# Discriminating: atomic_write's own "refusing" line is present at the
# merge-base too. What was missing is anything attributing the death to
# init_state and the resume contract.
if grep -q "init_state" <<< "$bad_msgs"; then
    assert_pass "SPEC-5: the abort names init_state as the failing writer"
else
    assert_fail "SPEC-5: the abort names init_state as the failing writer" \
        "output: $bad_msgs"
fi
if grep -qi "nothing to resume from" <<< "$bad_msgs"; then
    assert_pass "SPEC-5: the abort states the stateless-run consequence"
else
    assert_fail "SPEC-5: the abort states the stateless-run consequence" \
        "output: $bad_msgs"
fi
if grep -qi "aborting before any stage runs" <<< "$bad_msgs"; then
    assert_pass "SPEC-5: the runner reports a controlled abort, not a bare death"
else
    assert_fail "SPEC-5: the runner reports a controlled abort, not a bare death" \
        "output: $bad_msgs"
fi
assert_file_not_exists "SPEC-5: no state file was persisted" \
    "$BAD_STATE_DIR/pipeline-state.json"
if _stage_started; then
    assert_fail "SPEC-5: no stage runs after a refused state write" \
        "stage.start present in $ZBUILD_EVENTS_JSONL"
else
    assert_pass "SPEC-5: no stage runs after a refused state write"
fi

# ─── SPEC-6[guard]: the same run against a writable state dir proceeds ──────
GOOD_STATE_DIR="$TEST_TEMP_DIR/writable-state"
mkdir -p "$GOOD_STATE_DIR"
: > "$ZBUILD_EVENTS_JSONL"

set +e
ZBUILD_STATE_DIR="$GOOD_STATE_DIR" \
    bash "$RUNNER" --template runner-state-dir-minimal --issue 1773 --no-resume \
    >"$TEST_TEMP_DIR/out-good" 2>"$TEST_TEMP_DIR/err-good"
good_rc=$?
set -e

assert_eq "SPEC-6: writable state dir → run completes" "0" "$good_rc"
assert_file_exists "SPEC-6: state file is persisted" \
    "$GOOD_STATE_DIR/pipeline-state.json"
if _stage_started; then
    assert_pass "SPEC-6: stages run when state was persisted"
else
    assert_fail "SPEC-6: stages run when state was persisted" \
        "no stage.start in $ZBUILD_EVENTS_JSONL"
fi

cd "$REPO_ROOT"
cleanup_test_env
print_test_results
exit $((FAIL > 0))
