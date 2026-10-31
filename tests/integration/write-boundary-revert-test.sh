#!/usr/bin/env bash
# tests/integration/write-boundary-revert-test.sh — a stage that may not change
# the repository and does is UNDONE and retried; only a second offence by the
# same stage in the same run stops the run (ADR-058 C12 amendment).
#
# Why: #1845 run 36332698182 halted with 4½ hours of budget left because one
# judge edited one test once. Halting is right for a stage that keeps doing it;
# for the first time, putting the files back and re-running the stage costs a
# retry, not the run.
#
# D1 [change] first offence: every change is put back exactly — an edited
#             tracked file, a new file, a deleted file, and a file another stage
#             had already changed (uncommitted) before this dispatch
# D2 [change] first offence: the dispatch fails, the stage resolves to
#             `unusable` (the engine's retry), not `broken`, and the paths are named
# D3 [change] second offence by the same stage: `broken`, files still put back
# D4 [guard]  the count is per stage: another stage's first offence is `unusable`
# D5 [guard]  a clean re-dispatch of the stage is not held to its earlier offence
# D6 [change] the halt's reason names the stage and the files it changed, not
#             the stage's own result (ADR-058 C12, amended 2026-10-26; #1801 run
#             40390919951 halted saying "21 of 818 tests failed")
# D7 [change] through the engine's retry (#2439, ADR-054 §6a): a stage that
#             offends is undone and run again once; when the retry offends too,
#             that second offence halts
#
# D1–D6 look at one try each (_plugin_hook_call_once); D7 at the whole dispatch.
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

print_test_header "write boundary: undo and retry, halt on a second offence"
setup_test_env "write-boundary-revert"

_EV=()
emit_event() { _EV+=("$*"); }
verify_plugin_for_source() { return 0; }
scan_plugin_outputs() { return 0; }

JOB="$TEST_TEMP_DIR/state/runs/wb-rev"; SF="$JOB/pipeline-state.json"
mkdir -p "$JOB/artifacts" "$JOB/runtime"; echo '{}' > "$SF"
printf '# none\n' > "$TEST_TEMP_DIR/empty.txt"
export ZBUILD_WRITE_BOUNDARY_WATCH="$TEST_TEMP_DIR/empty.txt" ZBUILD_WRITE_BOUNDARY_ALLOW="$TEST_TEMP_DIR/empty.txt"
unset ZBUILD_SCRATCH_ROOT ZBUILD_NO_WORKTREE 2>/dev/null || true

WT="$TEST_TEMP_DIR/worktree"; mkdir -p "$WT/tests"
git -C "$WT" init -q
printf 'original\n' > "$WT/edited.txt"
printf 'keep me\n' > "$WT/deleted.txt"
printf 'base\n' > "$WT/tests/wip.txt"
git -C "$WT" add -A
git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m base
export ZBUILD_REPO_ROOT="$WT"

_fixture() {  # <dir> <id> <body>
    local d="$1" id="$2"
    mkdir -p "$d"
    printf 'id: %s\nname: %s\nkind: agent\nversion: 0.0.1\nhooks:\n  run: %s_run\nprovides:\n  result_contract: 3\noutputs:\n  - id: result\n    path: ${artifact_dir}/%s-result.json\n    required: true\n    primary: true\n' \
        "$id" "$id" "${id//-/_}" "$id" > "$d/manifest.yaml"
    cat > "$d/plugin.sh" <<PEOF
${id//-/_}_run() {
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\${ZBUILD_ARTIFACT_DIR:-$JOB/artifacts}/${id}-result.json" pass ok
$3
}
PEOF
}
_run() {  # <fixture_dir> <stage> — one try
    RC=0; _EV=()
    _plugin_hook_call_once "$1" run "$2" "$SF" 2>"$TEST_TEMP_DIR/stderr.txt" || RC=$?
}
_disp() { runner_read_stage_disposition "$JOB" "$1/manifest.yaml" "$2" "$RC" "" 0 2>/dev/null; }

# An earlier writer's uncommitted work, present before the judge runs.
printf 'work in progress\n' > "$WT/tests/wip.txt"

EDITS="    printf 'judge was here\\n' > '$WT/edited.txt'
    printf 'new\\n' > '$WT/new-file.txt'
    rm -f '$WT/deleted.txt'
    printf 'judge rewrote it\\n' > '$WT/tests/wip.txt'"
FXJ="$TEST_TEMP_DIR/plugins/wb-judge"
_fixture "$FXJ" wb-judge "$EDITS"

print_test_section "D1/D2: the first offence is undone and retried"
_run "$FXJ" judge
assert_eq "[D1] the edited file is back" "original" "$(cat "$WT/edited.txt")"
assert_file_not_exists "[D1] the new file is gone" "$WT/new-file.txt"
assert_eq "[D1] the deleted file is back" "keep me" "$(cat "$WT/deleted.txt" 2>/dev/null)"
assert_eq "[D1] the earlier stage's uncommitted work is back, not reset to HEAD" \
    "work in progress" "$(cat "$WT/tests/wip.txt")"
assert_eq "[D2] the dispatch fails" "1" "$RC"
assert_eq "[D2] the stage is retried (unusable), not halted" "unusable" "$(_disp "$FXJ" judge)"
assert_file_not_exists "[D2] no halting marker" "$JOB/runtime/write-boundary-violated"
assert_contains "[D2] the paths are named" "$(cat "$TEST_TEMP_DIR/stderr.txt")" "edited.txt"

print_test_section "D5: a clean retry is not held to it"
FXC="$TEST_TEMP_DIR/plugins/wb-judge-clean"
_fixture "$FXC" wb-judge-clean "    :"
_run "$FXC" judge
assert_eq "[D5] a clean re-dispatch of the stage resolves complete" "complete" "$(_disp "$FXC" judge)"

print_test_section "D3: a second offence by the same stage halts"
_run "$FXJ" judge
assert_eq "[D3] the second offence resolves broken" "broken" "$(_disp "$FXJ" judge)"
assert_eq "[D3] the files are still put back" "original" "$(cat "$WT/edited.txt")"
assert_eq "[D3] ...including the earlier stage's work" "work in progress" "$(cat "$WT/tests/wip.txt")"
_reason="$(runner_read_stage_reason "$JOB" "$FXJ/manifest.yaml" judge "$RC" 2>/dev/null)"
assert_contains "[D6] the halt says which stage changed the repository" "$_reason" \
    "judge changed files in the repository that it may not change"
assert_contains "[D6] ...and which files" "$_reason" "edited.txt"
_other="$(runner_read_stage_reason "$JOB" "$FXC/manifest.yaml" other 0 2>/dev/null)"
assert_eq "[D6] ...and only for the stage that did it" "0" \
    "$(grep -c 'changed files in the repository' <<< "$_other" || true)"

print_test_section "D4: the count is per stage"
rm -f "$JOB/runtime/write-boundary-violated"
FXO="$TEST_TEMP_DIR/plugins/wb-other"
_fixture "$FXO" wb-other "    printf 'x\\n' > '$WT/edited.txt'"
_run "$FXO" other-judge
assert_eq "[D4] another stage's first offence is retried" "unusable" "$(_disp "$FXO" other-judge)"
assert_eq "[D4] and put back" "original" "$(cat "$WT/edited.txt")"

print_test_section "D7: the engine retries the first offence; the retry's offence halts"
rm -f "$JOB/runtime/write-boundary-violated" "$JOB"/runtime/write-boundary-reverted.* "$JOB"/runtime/write-boundary-offences* 2>/dev/null
FXR="$TEST_TEMP_DIR/plugins/wb-again"
_fixture "$FXR" wb-again "    printf 'x\\n' > '$WT/edited.txt'"
RC=0; _EV=()
plugin_hook_call "$FXR" run again-judge "$SF" 2>"$TEST_TEMP_DIR/stderr.txt" || RC=$?
assert_contains "[D7] the first offence was retried" "${_EV[*]}" "stage.retry stage=again-judge outcome=unusable"
assert_eq "[D7] the retry's offence halts" "broken" "$(_disp "$FXR" again-judge)"
assert_eq "[D7] the files are put back" "original" "$(cat "$WT/edited.txt")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
