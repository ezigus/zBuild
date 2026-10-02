#!/usr/bin/env bash
# tests/unit/attempt-progress-test.sh — "did this attempt make progress?" counts
# the stage's work, not its report of the work (#2252 D1).
#
# Why: a timed-out stage is retried only while its last attempt made progress
# (#2187). The check counted ANY changed output — and a stage's own report
# (build-summary.json, build-summary.md) changes on every attempt, because it
# describes that attempt. #1844 run 36969128968: build attempt 1 committed its
# work and timed out; attempts 2 and 3 changed nothing (diff.patch "unchanged")
# but rewrote their reports, so each counted as progress — ~60 more minutes of
# model calls before the cycle moved on.
#
# P1 [change] a repository-writing stage whose attempt changed only its report
#             made no progress
# P2 [guard]  ...one whose attempt committed a change made progress
# P3 [guard]  ...one whose attempt left an uncommitted edit made progress
# P4 [change] any other stage: a change to only its narrative summary is no
#             progress
# P5 [guard]  ...a change to its primary output is progress
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../core/plugin-registry/attempt-archive.sh
source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh"

print_test_header "attempt progress counts the work, not the report (#2252 D1)"
setup_test_env "attempt-progress"
GIT="$(command -v git)"

S="$TEST_TEMP_DIR/state"; ART="$S/artifacts"; mkdir -p "$ART"
export ZBUILD_STATE_DIR="$S" ZBUILD_ARTIFACT_DIR="$ART"
REPO="$(setup_git_temp_repo "attempt-progress")"
export ZBUILD_REPO_ROOT="$REPO"

# _plugin <dir> <writes_repository:true|false> — a stage with a report, a
# summary, and (for a non-repo stage) a work product as its primary.
_plugin() {
    mkdir -p "$1"
    {
        printf 'id: %s\nkind: agent\n' "$(basename "$1")"
        printf 'capabilities:\n  writes_repository: %s\n' "$2"
        printf 'outputs:\n'
        printf '  - id: result\n    path: "${artifact_dir}/%s-result.json"\n    primary: true\n' "$(basename "$1")"
        printf '  - id: summary\n    path: "${artifact_dir}/%s-summary.md"\n    summary: true\n' "$(basename "$1")"
    } > "$1/manifest.yaml"
}
# _attempt <plugin_dir> <stage> <cmds> — fingerprint, run <cmds>, archive.
_attempt() {
    local before; before="$(attempt_outputs_fingerprint "$1" "$S/pipeline-state.json")"
    eval "$3"
    attempt_archive_outputs "$1" "$S/pipeline-state.json" "$2" 0 "$before" >/dev/null 2>&1
}
_progress() { _runner_attempt_made_progress "$ART" "$1" 1 && echo yes || echo no; }
export ZBUILD_CYCLE_ITER=1

print_test_section "P1-P3: a repository-writing stage"
P="$TEST_TEMP_DIR/plugins/builder"; _plugin "$P" true
_attempt "$P" builder 'printf "{\"n\":1}" > "$ART/builder-result.json"; printf "a1" > "$ART/builder-summary.md"'
_attempt "$P" builder 'printf "{\"n\":2}" > "$ART/builder-result.json"; printf "a2" > "$ART/builder-summary.md"'
assert_eq "[P1] only its report changed → no progress" "no" "$(_progress builder)"
_attempt "$P" builder 'printf x > "$REPO/f.txt"; "$GIT" -C "$REPO" add f.txt; "$GIT" -C "$REPO" commit -qm c; printf "{\"n\":3}" > "$ART/builder-result.json"'
assert_eq "[P2] it committed a change → progress" "yes" "$(_progress builder)"
_attempt "$P" builder 'printf y > "$REPO/g.txt"; printf "{\"n\":4}" > "$ART/builder-result.json"'
assert_eq "[P3] it left an uncommitted edit → progress" "yes" "$(_progress builder)"

print_test_section "P4-P5: any other stage"
Q="$TEST_TEMP_DIR/plugins/designer"; _plugin "$Q" false
_attempt "$Q" designer 'printf "d1" > "$ART/designer-result.json"; printf "s1" > "$ART/designer-summary.md"'
_attempt "$Q" designer 'printf "s2" > "$ART/designer-summary.md"'
assert_eq "[P4] only its summary changed → no progress" "no" "$(_progress designer)"
_attempt "$Q" designer 'printf "d2" > "$ART/designer-result.json"'
assert_eq "[P5] its primary output changed → progress" "yes" "$(_progress designer)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
