#!/usr/bin/env bash
# tests/unit/attempt-progress-test.sh — "did this attempt make progress?" counts
# the stage's work, not its summary of the work (#2252 D1; #2439).
#
# Why: a timed-out stage is retried only while its last attempt made progress
# (#2187). The check counted ANY changed output — and a stage's own report
# (build-summary.json, build-summary.md) changes on every attempt, because it
# describes that attempt. #1844 run 36969128968: build attempt 1 committed its
# work and timed out; attempts 2 and 3 changed nothing (diff.patch "unchanged")
# but rewrote their reports, so each counted as progress — ~60 more minutes of
# model calls before the cycle moved on. #2439 (ADR-054 §6a, amended
# 2026-10-31): one rule for every stage — the code AND the declared outputs
# count; only the narrative summary does not. A try is now one model call and
# the template's retry: bounds the tries.
#
# P1 [change] a repository-writing stage whose attempt changed its result made
#             progress; one that changed only its summary did not
# P2 [guard]  ...one whose attempt committed a change made progress
# P3 [guard]  ...one whose attempt only left an uncommitted edit — no output
#             changed — made progress (isolated per review on #2253)
# P4 [change] any other stage: a change to only its narrative summary is no
#             progress
# P5 [change] ...a change to only its result file (primary) is no progress
# P6 [change] a change to the stage's notes is progress
# P7 [guard]  a change to any other declared output is progress
# P8 [change] a try whose call was cut off and whose steps were saved made
#             progress (#2454: on #1805 run 41452299475 the steps were saved
#             for a next try the progress rule then refused)
# P9 [guard]  ...the same steps again, or none (the call finished and the list
#             was removed), are no progress
# P10 [change] a try whose result holds findings about its own work that differ
#             from its last try's made progress (#2460: build said done, changed
#             nothing, and its test still failed — the next try is told so)
# P11 [guard] ...the same findings again, or none, are no progress
# P12 [guard] each result file is compared with its own last copy (review on #2461)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/attempt-archive.sh
source "$REPO_ROOT/core/plugin-registry/attempt-archive.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"

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
        printf '  - id: work\n    path: "${artifact_dir}/%s-work.md"\n' "$(basename "$1")"
    } > "$1/manifest.yaml"
}
# _attempt <plugin_dir> <stage> <cmds> — fingerprint, run <cmds>, archive.
_attempt() {
    local -x ZBUILD_CURRENT_STAGE="$2"
    local before; before="$(attempt_outputs_fingerprint "$1" "$S/pipeline-state.json")"
    eval "$3"
    attempt_archive_outputs "$1" "$S/pipeline-state.json" "$2" 0 "$before" >/dev/null 2>&1
}
_progress() { [[ "${_ATTEMPT_LAST_PROGRESS:-}" == "true" ]] && echo yes || echo no; }
export ZBUILD_CYCLE_ITER=1

print_test_section "P1-P3: a repository-writing stage"
P="$TEST_TEMP_DIR/plugins/builder"; _plugin "$P" true
_attempt "$P" builder 'printf "{\"n\":1}" > "$ART/builder-result.json"; printf "a1" > "$ART/builder-summary.md"'
_attempt "$P" builder 'printf "{\"n\":2}" > "$ART/builder-result.json"; printf "a2" > "$ART/builder-summary.md"'
assert_eq "[P1] only its result and its summary changed → no progress" "no" "$(_progress builder)"
_attempt "$P" builder 'printf "a3" > "$ART/builder-summary.md"'
assert_eq "[P1] only its summary changed → no progress" "no" "$(_progress builder)"
_attempt "$P" builder 'printf x > "$REPO/f.txt"; "$GIT" -C "$REPO" add f.txt; "$GIT" -C "$REPO" commit -qm c'
assert_eq "[P2] it committed a change → progress" "yes" "$(_progress builder)"
_attempt "$P" builder 'printf y > "$REPO/g.txt"'
assert_eq "[P3] an uncommitted edit alone (no output changed) → progress" "yes" "$(_progress builder)"

print_test_section "P4-P5: any other stage"
Q="$TEST_TEMP_DIR/plugins/designer"; _plugin "$Q" false
_attempt "$Q" designer 'printf "d1" > "$ART/designer-result.json"; printf "s1" > "$ART/designer-summary.md"'
_attempt "$Q" designer 'printf "s2" > "$ART/designer-summary.md"'
assert_eq "[P4] only its summary changed → no progress" "no" "$(_progress designer)"
_attempt "$Q" designer 'printf "d2" > "$ART/designer-result.json"'
assert_eq "[P5] only its result file changed → no progress" "no" "$(_progress designer)"

print_test_section "P6-P7: notes and other outputs"
mkdir -p "$ART/notes"
_attempt "$Q" designer 'printf "found X" > "$ART/notes/designer.md"'
assert_eq "[P6] its notes changed → progress" "yes" "$(_progress designer)"
_attempt "$Q" designer 'printf "d4" > "$ART/designer-result.json"'
assert_eq "[P6] ...its notes unchanged, only its result → no progress" "no" "$(_progress designer)"
_attempt "$Q" designer 'printf "w1" > "$ART/designer-work.md"'
assert_eq "[P7] another declared output changed → progress" "yes" "$(_progress designer)"

print_test_section "P8-P9: a cut-off call's saved steps"
_cut="$ART/notes/designer.cut-off.md"
_attempt "$Q" designer 'printf -- "- Read: a.sh\n" > "$_cut"'
assert_eq "[P8] its call was cut off and its steps saved → progress" "yes" "$(_progress designer)"
_attempt "$Q" designer 'printf -- "- Read: a.sh\n" > "$_cut"'
assert_eq "[P9] the same steps again → no progress" "no" "$(_progress designer)"
_attempt "$Q" designer 'rm -f "$_cut"'
assert_eq "[P9] the call finished and the list was removed → no progress" "no" "$(_progress designer)"

print_test_section "P10-P11: findings about its own work"
_fr() { printf '{"outcome":"unusable","data":{"findings":[{"n":1,"text":"%s"}]}}' "$1" > "$ART/designer-result.json"; }
_attempt "$Q" designer '_fr "tests/a-test.sh still fails"'
assert_eq "[P10] its result names a problem with its own work it did not name before → progress" "yes" "$(_progress designer)"
_attempt "$Q" designer '_fr "tests/b-test.sh still fails"'
assert_eq "[P10] ...a different problem than its last try → progress" "yes" "$(_progress designer)"
_attempt "$Q" designer '_fr "tests/b-test.sh still fails"'
assert_eq "[P11] the same findings as its last try → no progress" "no" "$(_progress designer)"
_attempt "$Q" designer 'printf "{\"outcome\":\"unusable\"}" > "$ART/designer-result.json"'
assert_eq "[P11] no findings → no progress" "no" "$(_progress designer)"

print_test_section "P12: a stage with two result files (review on #2461)"
R2P="$TEST_TEMP_DIR/plugins/twin"; mkdir -p "$R2P"
{
    printf 'id: twin\nkind: agent\noutputs:\n'
    printf '  - id: a\n    path: "${artifact_dir}/twin-a-result.json"\n    primary: true\n'
    printf '  - id: b\n    path: "${artifact_dir}/twin-b-result.json"\n    primary: true\n'
} > "$R2P/manifest.yaml"
export ZBUILD_CYCLE_ITER=7
printf '{"data":{"findings":[{"n":1,"text":"X"}]}}' > "$ART/twin-a-result.json"
printf '{"data":{"findings":[{"n":1,"text":"X"}]}}' > "$ART/twin-b-result.json"
_attempt "$R2P" twin ':'
_attempt "$R2P" twin ':'
assert_eq "[P12] the same findings in both files again → no progress (each compared with its own last)" "no" "$(_progress twin)"
export ZBUILD_CYCLE_ITER=1

cleanup_test_env
print_test_results
exit $((FAIL > 0))
