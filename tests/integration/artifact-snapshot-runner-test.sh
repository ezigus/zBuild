#!/usr/bin/env bash
# tests/integration/artifact-snapshot-runner-test.sh — ADR-050 snapshot, driven
# through the REAL runner (#1878).
#
# This is the test that would have caught the defect. artifact-persist.sh had
# three green test layers, and every one of them called the library DIRECTLY with
# repo_root passed explicitly. Nothing drove the runner and asserted that a
# snapshot actually happened, so a feature that never once produced a state
# branch stayed green for its entire life.
#
# The other half of why it hid: the existing runner-level tests use stub plugins
# that write NO artifacts, so `$state_dir/artifacts` never existed and the
# snapshot took its "nothing to do" early return. The stubs here write a real
# file, which is the whole point.
#
#   SPEC-1 [change]: a completed LEAF stage emits artifact.snapshot.saved and the
#                    state branch exists in the repo's shared ref store
#   SPEC-2 [change]: a completed CYCLE MEMBER does the same — the coverage fix.
#                    Before #1878 there were four stage.complete emitters and one
#                    snapshot call, on the leaf path only
#   SPEC-3 [change]: a snapshot FAILURE emits artifact.snapshot.failed carrying a
#                    reason, instead of returning 1 into a 2>/dev/null
#   SPEC-4 [guard] : a snapshot failure never aborts the run (advisory contract)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/core/pipeline/runner.sh"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-050 artifact snapshot via the real runner (#1878)"
setup_test_env "artifact-snapshot-runner"

export ZBUILD_CONTRACT_VALIDATOR=warn   # synthetic stubs have no honest contracts
# ADR-049 §Phase-1.1: the vision gate defaults to enforce. This suite tests
# snapshot mechanics, not the vision gate, and the fixture repo has no vision doc.
export ZBUILD_VISION_GATE=off

PLUGINS_ROOT="$TEST_TEMP_DIR/plugins"
EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
mkdir -p "$TEST_TEMP_DIR/events"

# A stub that WRITES A REAL ARTIFACT. Today's runner-level stubs write nothing,
# which is exactly why they never exercised the snapshot path.
_make_artifact_plugin() {
    local id="$1" kind="${2:-agent}"
    local dir="$PLUGINS_ROOT/$kind/$id"
    mkdir -p "$dir"
    local fn; fn="${id//-/_}_run"
    cat > "$dir/manifest.yaml" <<EOF
id: $id
name: Artifact-writing $id
kind: $kind
version: 0.0.1
hooks:
  run: $fn
requires:
  core:
    - redaction
EOF
    cat > "$dir/plugin.sh" <<EOF
${fn}() {
    local _ad="\${ZBUILD_ARTIFACT_DIR:-\${ZBUILD_STATE_DIR:-.}/artifacts}"
    mkdir -p "\$_ad"
    printf 'artifact written by %s\n' "$id" > "\$_ad/${id}-output.txt"
    printf '{"schema_version":1,"verdict":"pass"}\n' > "\$_ad/${id}-result.json"
    return 0
}
EOF
}

_run_pipeline() {
    local repo="$1" issue="$2" template="$3" state_dir="$4"; shift 4
    rm -f "$EVENTS_JSONL"
    mkdir -p "$state_dir"
    ( cd "$repo" && env -u ZBUILD_STATE_ROOT \
        ZBUILD_PLUGINS_ROOT="$PLUGINS_ROOT" \
        ZBUILD_STATE_DIR="$state_dir" \
        ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" \
        ZBUILD_EVENTS_JSONL="$EVENTS_JSONL" \
        ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db" \
        ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" \
        ZBUILD_CONTRACT_VALIDATOR=warn \
        ZBUILD_VISION_GATE=off \
        ZBUILD_RUN_ID="run-1878-$$-$issue" \
        HOME="$TEST_TEMP_DIR/home" \
        PATH="$PATH" \
        "$@" \
        bash "$RUNNER" --issue "$issue" --template "$template" ) >/dev/null 2>&1
    return $?
}

_events_have() { grep -qF "\"$1\"" "$EVENTS_JSONL" 2>/dev/null; }

mkdir -p "$TEST_TEMP_DIR/home/.zbuild"

# ─── Fixture: a git repo carrying the template overlay ──────────────────────
REPO="$(setup_git_temp_repo snapshot-cov-repo)"
install_template_overlay "$REPO" artifact-snapshot-coverage
_make_artifact_plugin "intake"  "agent"
_make_artifact_plugin "cycled"  "agent"

SD="$TEST_TEMP_DIR/state-ok"
_run_pipeline "$REPO" 1878 artifact-snapshot-coverage "$SD"
run_rc=$?

# ─── SPEC-1: a leaf stage snapshots ─────────────────────────────────────────
print_test_section "1. a completed leaf stage snapshots"
if _events_have "artifact.snapshot.saved"; then
    assert_pass "[SPEC-1] artifact.snapshot.saved emitted"
else
    assert_fail "[SPEC-1] artifact.snapshot.saved emitted" \
        "events: $(jq -r '.type' "$EVENTS_JSONL" 2>/dev/null | sort -u | tr '\n' ' ')"
fi
if git -C "$REPO" rev-parse -q --verify refs/heads/zbuild/state/issue-1878 >/dev/null 2>&1; then
    assert_pass "[SPEC-1] the state branch exists in the shared ref store"
else
    assert_fail "[SPEC-1] the state branch exists in the shared ref store" "branch absent"
fi

# ─── SPEC-2: a cycle member snapshots (THE coverage fix) ────────────────────
print_test_section "2. a completed cycle member snapshots"
_cyc_stages="$(jq -r 'select(.type=="artifact.snapshot.saved") | .data.stage' "$EVENTS_JSONL" 2>/dev/null | sort -u | tr '\n' ' ')"
if grep -qw "cycled" <<<"$_cyc_stages"; then
    assert_pass "[SPEC-2] the cycle member 'cycled' snapshotted (stages: $_cyc_stages)"
else
    assert_fail "[SPEC-2] the cycle member 'cycled' snapshotted" \
        "only these stages snapshotted: [$_cyc_stages] — cycle members are still uncovered"
fi

# ─── SPEC-3 / SPEC-4: a failing snapshot is loud, and never fatal ───────────
# Force the failure INSIDE a real run rather than by breaking the environment: a
# non-repo CWD aborts the runner at worktree acquisition, before any stage, so it
# proves nothing about the snapshot path.
#
# A git ref directory/file conflict does it cleanly: creating
# refs/heads/zbuild/state/issue-<N>/blocker makes the parent path a DIRECTORY, so
# `git update-ref refs/heads/zbuild/state/issue-<N>` cannot create a ref of the
# same name. The run is otherwise completely healthy — which is the point.
print_test_section "3. a snapshot failure is reported, and is not fatal"
REPO2="$(setup_git_temp_repo snapshot-fail-repo)"
install_template_overlay "$REPO2" artifact-snapshot-coverage
_blocker_sha="$(git -C "$REPO2" rev-parse HEAD 2>/dev/null)"
git -C "$REPO2" update-ref "refs/heads/zbuild/state/issue-1879/blocker" "$_blocker_sha" 2>/dev/null
SD2="$TEST_TEMP_DIR/state-fail"
_run_pipeline "$REPO2" 1879 artifact-snapshot-coverage "$SD2"
fail_rc=$?

if _events_have "artifact.snapshot.failed"; then
    assert_pass "[SPEC-3] artifact.snapshot.failed emitted when the snapshot cannot run"
    _reason="$(jq -r 'select(.type=="artifact.snapshot.failed") | .data.reason' "$EVENTS_JSONL" 2>/dev/null | head -1)"
    if [[ -n "$_reason" && "$_reason" != "null" && "$_reason" != "unknown" ]]; then
        assert_pass "[SPEC-3] the failure carries a reason: ${_reason:0:60}…"
    else
        assert_fail "[SPEC-3] the failure carries a reason" "reason was [$_reason]"
    fi
else
    # Not every environment can force this; report honestly rather than pass vacuously.
    assert_fail "[SPEC-3] artifact.snapshot.failed emitted when the snapshot cannot run" \
        "no such event; types seen: $(jq -r '.type' "$EVENTS_JSONL" 2>/dev/null | sort -u | tr '\n' ' ')"
fi

# [guard] persistence is advisory: it must never turn a good run into a bad one.
assert_eq "[SPEC-4] a snapshot failure does not abort the run" "0" "$fail_rc"
assert_eq "[SPEC-4] the healthy run also exited 0" "0" "$run_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
