#!/usr/bin/env bash
# tests/integration/write-boundary-ownership-test.sh — the write boundary halts
# only on writes it can ATTRIBUTE, and it attributes by ownership, never by time
# (ADR-058 C12).
#
# Why: `find -newer` knows when a file was written, never who wrote it. Every
# place the sweep could ever report as a violation — $HOME, ~/.zbuild, the
# engine's own tree — is shared with other processes, so a stage was blamed for
# whatever else happened to write there during its dispatch. #1845 lost four
# iterations to it: per-run-state-isolation's nested runner halted its `build`
# stage on `.zbuild-nested-state/cost-ledger.jsonl.lock`, a file another test's
# fake model call wrote at the same moment (2 of 5 nested suites, 0 of 5 plain;
# run 36322270557). Earlier: #1952 (the Claude CLI's own file), #2201
# (another process's .git/index.lock), #1839.
#
# O1 [change] a write to a watched SHARED place does not fail the dispatch
# O2 [change] it is still recorded: stderr, ZBUILD_WRITE_BOUNDARY_LOG, and
#             stage.write_boundary.unattributable with reason=shared_location
# O3 [change] a stage that does not declare capabilities.writes_repository and
#             changes a tracked file in the run's own worktree fails the dispatch,
#             resolves to broken, and the path is named
# O4 [change] ... and so does one that creates an untracked file there
# O5 [guard]  a stage that declares writes_repository: true may change it
# O6 [guard]  a file already dirty before the dispatch, and left alone, is not
#             blamed on it
# O7 [guard]  a stage that moves HEAD with a clean tree before and after (intake
#             checking out the work branch) is not blamed
# O8 [guard]  in-place mode (ZBUILD_NO_WORKTREE=1): the checkout is the user's,
#             shared with the user, so the repository check does not apply
# O9 [change] no timing heuristic remains in the boundary
# O10 [guard] a non-writer that REVERTS earlier uncommitted work has changed
#             the worktree too — that is a violation (review on #2211)
# O11 [change] several changed files are all named, not only the first
#             (review on #2211: `broken` is terminal, so one path per retry)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../core/pipeline/write-boundary.sh
source "$REPO_ROOT/core/pipeline/write-boundary.sh"

print_test_header "write boundary: attribute by ownership, never by time (ADR-058 C12)"
setup_test_env "write-boundary-ownership"

_EV=()
emit_event() { _EV+=("$*"); }
verify_plugin_for_source() { return 0; }
scan_plugin_outputs() { return 0; }

JOB="$TEST_TEMP_DIR/state/runs/wb-own"
SF="$JOB/pipeline-state.json"
mkdir -p "$JOB/artifacts" "$JOB/runtime"
echo '{}' > "$SF"

# A shared place: watched, not an engine-owned area.
SHARED="$TEST_TEMP_DIR/shared"; mkdir -p "$SHARED"
printf '%s\n' "$SHARED" > "$TEST_TEMP_DIR/watch.txt"
export ZBUILD_WRITE_BOUNDARY_WATCH="$TEST_TEMP_DIR/watch.txt"
printf '# none\n' > "$TEST_TEMP_DIR/allow.txt"
export ZBUILD_WRITE_BOUNDARY_ALLOW="$TEST_TEMP_DIR/allow.txt"
export ZBUILD_WRITE_BOUNDARY_LOG="$TEST_TEMP_DIR/wb.log"
unset ZBUILD_SCRATCH_ROOT ZBUILD_NO_WORKTREE 2>/dev/null || true

# The run's own worktree.
WT="$TEST_TEMP_DIR/worktree"
mkdir -p "$WT"
git -C "$WT" init -q
printf 'one\n' > "$WT/tracked.txt"
printf 'x\n' > "$WT/other.txt"
git -C "$WT" add -A
git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m base
git -C "$WT" branch -q side
git -C "$WT" checkout -q side
printf 'side\n' > "$WT/side-only.txt"
git -C "$WT" add -A
git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m side
git -C "$WT" checkout -q -
export ZBUILD_REPO_ROOT="$WT"

# _fixture <dir> <id> <writes_repository:true|false> <body>
_fixture() {
    local d="$1" id="$2" wr="$3" body="$4"
    mkdir -p "$d"
    {
        printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\nhooks:\n  run: %s_run\n' "$id" "$id" "${id//-/_}"
        [[ "$wr" == "true" ]] && printf 'capabilities:\n  writes_repository: true\n'
        printf 'outputs:\n  - id: result\n    path: ${artifact_dir}/%s-result.json\n    required: true\n    primary: true\n' "$id"
    } > "$d/manifest.yaml"
    cat > "$d/plugin.sh" <<PEOF
${id//-/_}_run() {
    printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}\n' > "\${ZBUILD_ARTIFACT_DIR:-$JOB/artifacts}/${id}-result.json"
${body}
}
PEOF
}

_run() {  # <fixture_dir> <stage> → sets RC, clears markers first
    rm -f "$JOB/runtime/write-boundary-violated"
    _EV=()
    RC=0
    plugin_hook_call "$1" run "$2" "$SF" 2>"$TEST_TEMP_DIR/stderr.txt" || RC=$?
}
_ev_has() { local e; for e in "${_EV[@]}"; do [[ "$e" == *"$1"* ]] && return 0; done; return 1; }

print_test_section "O1/O2: a shared place is observed, never blamed"
FX1="$TEST_TEMP_DIR/plugins/wb-shared"
_fixture "$FX1" wb-shared false "    printf 'x' > '$SHARED/someone-else.lock'"
: > "$ZBUILD_WRITE_BOUNDARY_LOG"
_run "$FX1" shared-stage
assert_eq "[O1] the dispatch succeeds" "0" "$RC"
assert_file_not_exists "[O1] no violated marker" "$JOB/runtime/write-boundary-violated"
assert_eq "[O1] the stage is not broken" "complete" \
    "$(runner_read_stage_disposition "$JOB" "$FX1/manifest.yaml" shared-stage 0 "" 0 2>/dev/null)"
assert_contains "[O2] stderr names the path" "$(cat "$TEST_TEMP_DIR/stderr.txt")" "$SHARED/someone-else.lock"
assert_contains "[O2] the log names it" "$(cat "$ZBUILD_WRITE_BOUNDARY_LOG")" "$SHARED/someone-else.lock"
if _ev_has "stage.write_boundary.unattributable" && _ev_has "reason=shared_location"; then
    assert_pass "[O2] the event says it was a shared location"
else
    assert_fail "[O2] the event says it was a shared location" "events: ${_EV[*]:-<none>}"
fi

print_test_section "O3/O4: the run's own worktree is attributable"
FX3="$TEST_TEMP_DIR/plugins/wb-edits"
_fixture "$FX3" wb-edits false "    printf 'changed\n' > '$WT/tracked.txt'"
_run "$FX3" judge-stage
assert_eq "[O3] a non-writer changing a tracked file fails the dispatch" "1" "$RC"
# First offence: put back and retried (write-boundary-revert-test.sh covers the
# second, which halts). Later O-specs reuse judge-stage, so they are second+.
assert_contains "[O3] the undo marker names the path" \
    "$(cat "$JOB/runtime/write-boundary-reverted.judge-stage" 2>/dev/null || true)" "tracked.txt"
assert_eq "[O3] the stage resolves to unusable (retried)" "unusable" \
    "$(runner_read_stage_disposition "$JOB" "$FX3/manifest.yaml" judge-stage 0 "" 0 2>/dev/null)"
assert_eq "[O3] the file is put back" "one" "$(cat "$WT/tracked.txt")"
assert_contains "[O3] the path is named" "$(cat "$TEST_TEMP_DIR/stderr.txt")" "tracked.txt"
git -C "$WT" checkout -q -- tracked.txt

FX4="$TEST_TEMP_DIR/plugins/wb-creates"
_fixture "$FX4" wb-creates false "    printf 'new\n' > '$WT/new-file.txt'"
_run "$FX4" judge-stage
assert_eq "[O4] a non-writer creating an untracked file fails the dispatch" "1" "$RC"
assert_contains "[O4] the path is named" "$(cat "$TEST_TEMP_DIR/stderr.txt")" "new-file.txt"
rm -f "$WT/new-file.txt"

print_test_section "O5–O8: what is not blamed"
FX5="$TEST_TEMP_DIR/plugins/wb-writer"
_fixture "$FX5" wb-writer true "    printf 'built\n' > '$WT/tracked.txt'; printf 'n\n' > '$WT/built.txt'"
_run "$FX5" build
assert_eq "[O5] a declared repository writer may change the worktree" "0" "$RC"
assert_file_not_exists "[O5] no violated marker" "$JOB/runtime/write-boundary-violated"

# O6: the writer's changes above are still uncommitted; a later non-writer that
# leaves them alone must not be blamed for them.
FX6="$TEST_TEMP_DIR/plugins/wb-idle"
_fixture "$FX6" wb-idle false "    :"
_run "$FX6" judge-stage
assert_eq "[O6] earlier, untouched dirt is not blamed on a later stage" "0" "$RC"
git -C "$WT" checkout -q -- tracked.txt; rm -f "$WT/built.txt"

FX7="$TEST_TEMP_DIR/plugins/wb-checkout"
_fixture "$FX7" wb-checkout false "    git -C '$WT' checkout -q side"
_run "$FX7" intake
assert_eq "[O7] moving HEAD on a clean tree is not a stray write" "0" "$RC"
git -C "$WT" checkout -q -

export ZBUILD_NO_WORKTREE=1
_run "$FX3" judge-stage
assert_eq "[O8] in-place mode does not apply the repository check" "0" "$RC"
git -C "$WT" checkout -q -- tracked.txt
unset ZBUILD_NO_WORKTREE

print_test_section "O10/O11: review on #2211"
printf 'earlier writer\n' > "$WT/tracked.txt"           # a writer's uncommitted work
FX10="$TEST_TEMP_DIR/plugins/wb-reverts"
_fixture "$FX10" wb-reverts false "    git -C '$WT' checkout -q -- tracked.txt"
_run "$FX10" judge-stage
assert_eq "[O10] a non-writer that reverts earlier work fails the dispatch" "1" "$RC"
git -C "$WT" checkout -q -- tracked.txt

FX11="$TEST_TEMP_DIR/plugins/wb-many"
_fixture "$FX11" wb-many false "    printf 'a\\n' > '$WT/tracked.txt'; printf 'b\\n' > '$WT/other.txt'; printf 'c\\n' > '$WT/third.txt'"
_run "$FX11" judge-stage
_o11="$(cat "$TEST_TEMP_DIR/stderr.txt")"
assert_contains "[O11] the first changed file is named" "$_o11" "other.txt"
assert_contains "[O11] ...and the second" "$_o11" "third.txt"
assert_contains "[O11] ...and the third" "$_o11" "tracked.txt"
git -C "$WT" checkout -q -- tracked.txt other.txt; rm -f "$WT/third.txt"

print_test_section "O9: no timing heuristic"
if grep -qE 'SETTLE_MS|_wb_external_writer_witness' "$REPO_ROOT/core/pipeline/write-boundary.sh"; then
    assert_fail "[O9] the settle-window witness is gone" "still referenced in write-boundary.sh"
else
    assert_pass "[O9] the settle-window witness is gone"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
