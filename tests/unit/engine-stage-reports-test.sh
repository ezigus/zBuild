#!/usr/bin/env bash
# Tests (#2189 part C): engine setup reads what stages REPORTED, never plan.json
# or design.md by path, and never a role name (ADR-055 §1, ADR-050 §1).
#
# SPEC-1 [change]: the member report carries owned_files and wiring_files when
#   the result declares them. #2508: never scope_files — no stage widens a file
#   list for build (ADR-030 §8).
# SPEC-2 [change]: each dispatch's report is merged into the run's record
#   (artifacts/stage-reports.json): wiring files unioned, owned files kept per
#   reporting stage; a scope_files field is not recorded (#2508).
# SPEC-3: retired (#2508) — there is no per-run scope allowlist to export.
# SPEC-4 [change]: "this run changes its own grader" is decided from the reported
#   wiring files — design.md is not read.
# SPEC-5 [change]: a stage is denied edits to files ANOTHER stage reported owning,
#   and never its own — no role name is consulted.
# SPEC-6 [change]: the stages report them — design its WIRING files, test-author
#   the testfiles it owns, found by their tags (#2508). (Plan reported scope
#   files until #2363.)
# SPEC-7 [change]: reports recorded concurrently (parallel members) all land —
#   none is lost to a sibling's read-modify-write.
# SPEC-9 [change] (#2565): the report lock records its holder; a holder that is
#             alive is never broken, however long it holds; a dead one's is
# SPEC-8 [change]: both group dispatch boundaries record their report — cycle
#   and parallel — so a stage's report is not dropped by the kind of group it
#   ran in. (The linear leaf path runs only for a template with no groups; no
#   shipped template is one, and reading a report there costs ~30 forks per run
#   against the ADR-065 budget.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "engine setup reads stage reports, not plan.json / design.md (#2189)"
setup_test_env "engine-stage-reports"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
# shellcheck source=../../core/pipeline/runner.sh
source "$REPO_ROOT/core/pipeline/runner.sh"
# shellcheck source=../../core/plugin-registry/lifecycle.sh
source "$REPO_ROOT/core/plugin-registry/lifecycle.sh" 2>/dev/null
set +e

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"

print_test_section "SPEC-1: the report carries the setup fields"
# #2366: results are made with the engine's writer.
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
stage_result_write "$ART/r.json" pass r '{"scope_files":["a.sh"],"owned_files":["tests/t.sh"],"wiring_files":["scripts/lib/x.sh"]}'
_r="$(_verdict_report_from_file "$ART/r.json")"
assert_eq "[SPEC-1] scope_files is not carried (#2508)" 'null' "$(jq -c '.scope_files' <<< "$_r")"
assert_eq "[SPEC-1] owned_files" '["tests/t.sh"]' "$(jq -c '.owned_files' <<< "$_r")"
assert_eq "[SPEC-1] wiring_files" '["scripts/lib/x.sh"]' "$(jq -c '.wiring_files' <<< "$_r")"

print_test_section "SPEC-2: reports merge into the run's record"
_runner_record_report "$STATE" plan '{"scope_files":["a.sh","b.sh"]}'
_runner_record_report "$STATE" design '{"scope_files":["b.sh","c.sh"],"wiring_files":["scripts/lib/x.sh"]}'
_runner_record_report "$STATE" author '{"owned_files":["tests/t.sh"]}'
_rec="$ART/stage-reports.json"
assert_eq "[SPEC-2] scope files are not recorded (#2508)" 'null' "$(jq -c '.scope_files' "$_rec" 2>/dev/null)"
assert_eq "[SPEC-2] owned files kept per stage" '["tests/t.sh"]' "$(jq -c '.owned_files.author' "$_rec" 2>/dev/null)"
assert_eq "[SPEC-2] wiring files unioned" '["scripts/lib/x.sh"]' "$(jq -c '.wiring_files' "$_rec" 2>/dev/null)"

print_test_section "SPEC-4: self-grade detection from reported wiring"
LIB="$TEST_TEMP_DIR/lib"; mkdir -p "$LIB"; : > "$LIB/x.sh"
_runner_contract_lib_closure() { printf 'x.sh\n'; }
printf '%s\n' '```acceptance' 'WIRING: scripts/lib/unrelated.sh' '```' > "$ART/design.md"
assert_eq "[SPEC-4] a reported wiring file in the grader set is a hit" "scripts/lib/x.sh" \
    "$(_runner_design_targets_contract_lib "$STATE" "$LIB" 2>/dev/null)"

print_test_section "SPEC-5: ownership denies others, never the owner"
export ZBUILD_REPO_ROOT="/repo"
assert_eq "[SPEC-5] another stage is denied the owned file" "/repo/tests/t.sh" \
    "$(_lc_owned_by_others_deny "$STATE" build 2>/dev/null)"
assert_eq "[SPEC-5] the owner is not denied its own file" "" \
    "$(_lc_owned_by_others_deny "$STATE" author 2>/dev/null)"


print_test_section "SPEC-6: the stages report the fields"
S6="$TEST_TEMP_DIR/s6"; mkdir -p "$S6"
printf '%s\n' '# D' '```acceptance' 'SPEC-1[change]: x' 'WIRING: scripts/lib/wired.sh' '```' > "$S6/design.md"
R6="$TEST_TEMP_DIR/r6"; mkdir -p "$R6/tests"
printf 'assert "[SPEC-1] x" 1 1\n' > "$R6/tests/acc-test.sh"
git -C "$R6" init -q >/dev/null 2>&1
_d6="$( source "$REPO_ROOT/plugins/agent/design/plugin.sh" >/dev/null 2>&1
        declare -F _design_write_outcome >/dev/null || { echo "design plugin.sh did not load"; exit; }
        _design_write_outcome "$S6" pass "ok" >/dev/null 2>&1
        jq -c '.data.wiring_files' "$S6/design-verdict.json" 2>/dev/null )"
assert_eq "[SPEC-6] design reports its WIRING files" '["scripts/lib/wired.sh"]' "$_d6"
_t6="$( export ZBUILD_REPO_ROOT="$R6"; unset ZBUILD_ISSUE
        source "$REPO_ROOT/plugins/agent/test-author/plugin.sh" >/dev/null 2>&1
        declare -F _ta_write_result >/dev/null || { echo "test-author plugin.sh did not load"; exit; }
        _ta_write_result "$S6" pass "ok" 1 >/dev/null 2>&1
        jq -c '.data.owned_files' "$S6/test-author-result.json" 2>/dev/null )"
assert_eq "[SPEC-6] test-author reports the testfiles it owns" '["tests/acc-test.sh"]' "$_t6"
# Plan no longer reports scope files (#2363): its work items name areas, and the
# scope is design's — plan-work-items-test W7.

print_test_section "SPEC-7: concurrent records all land"
S7="$TEST_TEMP_DIR/s7"; mkdir -p "$S7/artifacts"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    _runner_record_report "$S7" "m$_i" "{\"owned_files\":[\"t$_i.sh\"],\"wiring_files\":[\"s$_i.sh\"]}" &
done
wait
assert_eq "[SPEC-7] every member's owned files are kept" "12" \
    "$(jq '.owned_files | length' "$S7/artifacts/stage-reports.json" 2>/dev/null)"
assert_eq "[SPEC-7] every member's wiring files are unioned" "12" \
    "$(jq '.wiring_files | length' "$S7/artifacts/stage-reports.json" 2>/dev/null)"

print_test_section "SPEC-8: both group dispatch boundaries record their report"
_rn="$REPO_ROOT/core/pipeline/runner.sh"
for _b in '_runner_record_report "$state_dir" "$_cd_stage"' \
          '_runner_record_report "$state_dir" "$_pd_stage"'; do
    _n="$(/usr/bin/grep -cF "$_b" "$_rn" 2>/dev/null)" || _n=0
    assert_eq "[SPEC-8] $_b" "1" "$_n"
done

print_test_section "SPEC-9: a live holder's lock is never broken"
S9="$TEST_TEMP_DIR/s9"; mkdir -p "$S9/artifacts"
# A held lock as _runner_record_report writes it: the folder and its holder.
_holder() { mkdir -p "$S9/.stage-reports.lock"; printf '%s' "$1" > "$S9/.stage-reports.lock/pid"; }
bash -c 'exec sleep 600' & _live=$!
_holder "$_live"
if _runner_report_lock_stale_v _hp "$S9/.stage-reports.lock"; then
    assert_fail "[SPEC-9] a lock whose holder is alive is not stale" "it was called stale"
else
    assert_pass "[SPEC-9] a lock whose holder is alive is not stale"
fi
# A pid can be reused: a live pid on a lock older than any merge is stale.
touch -t 202001010000 "$S9/.stage-reports.lock"
if _runner_report_lock_stale_v _hp "$S9/.stage-reports.lock"; then
    assert_pass "[SPEC-9] a live pid on a lock held over 2 minutes is stale (a reused pid)"
else
    assert_fail "[SPEC-9] a live pid on a lock held over 2 minutes is stale (a reused pid)" "it was called live"
fi
# Two waiters judged the same dead holder; the second finds a new holder's lock
# and must not break it.
_holder "$_live"
_runner_report_lock_break "$S9/.stage-reports.lock" 99999999
assert_eq "[SPEC-9] a lock another holder took since is not broken" "$_live" \
    "$(cat "$S9/.stage-reports.lock/pid" 2>/dev/null)"
kill -KILL "$_live" 2>/dev/null; wait "$_live" 2>/dev/null
touch "$S9/.stage-reports.lock"
if _runner_report_lock_stale_v _hp "$S9/.stage-reports.lock"; then
    assert_pass "[SPEC-9] a lock whose holder is dead is stale"
else
    assert_fail "[SPEC-9] a lock whose holder is dead is stale" "it was called live"
fi
# A fresh lock with no pid yet is its holder's first instant: not stale.
mkdir -p "$S9/fresh.lock"
if _runner_report_lock_stale_v _hp "$S9/fresh.lock"; then
    assert_fail "[SPEC-9] a fresh lock with no pid yet is not stale" "it was called stale"
else
    assert_pass "[SPEC-9] a fresh lock with no pid yet is not stale"
fi
# The record goes through once the dead holder's lock is broken.
# Without flock, the mkdir lock is the one in use.
( zbuild_has_flock() { return 1; }; _ZB_REPORT_LOCK_TRIES=1 _runner_record_report "$S9" m1 '{"owned_files":["a.sh"]}' )
assert_eq "[SPEC-9] a dead holder's lock is broken and the record lands" "a.sh" \
    "$(jq -r '.owned_files.m1[0] // empty' "$S9/artifacts/stage-reports.json" 2>/dev/null)"
assert_eq "[SPEC-9] ...and no lock is left" "no" "$([[ -e "$S9/.stage-reports.lock" ]] && echo yes || echo no)"

print_test_results
exit $((FAIL > 0))
