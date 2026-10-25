#!/usr/bin/env bash
# tests/unit/run-constant-lookups-cost-test.sh — lookups whose answer does not
# change during a run are asked once per shell (ADR-065 §5, round 6).
#
# L1 [change] zbuild_resolve_default_branch_v fills a memo in the calling
#             shell: a later $(zbuild_resolve_default_branch) for that repo
#             starts no git (it ran up to 7 per stage)
# L2 [guard]  an unresolved trunk is not remembered — the next call asks again
# L3 [change] _artifact_persist_git_dir_v asks git once per repo per shell
# L4 [change] template_stage_time_limit_v reads each template once per shell, for
#             every stage (round 8; once per (template, stage) in round 6), once per
#             shell (one awk per stage per dispatch before)
# L5 [guard]  …and gives what template_stage_time_limit gives, for a set stage,
#             an unset one, and another template
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-constant lookups: once per shell (ADR-065 §5)"
setup_test_env "run-constant-lookups-cost"

# shellcheck source=../../scripts/lib/default-branch.sh
source "$REPO_ROOT/scripts/lib/default-branch.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"
# shellcheck source=../../scripts/lib/stage-time-limit.sh
source "$REPO_ROOT/scripts/lib/stage-time-limit.sh"

CALLS="$TEST_TEMP_DIR/calls"
git() { printf 'git\n' >> "$CALLS"; command git "$@"; }
awk() { printf 'awk\n' >> "$CALLS"; command awk "$@"; }
_n() { local c; c="$(grep -c "^$1\$" "$CALLS" 2>/dev/null)"; printf '%s' "${c:-0}"; }

R="$TEST_TEMP_DIR/repo"; command git init -q -b main "$R"
command git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

print_test_section "L1/L2: the default branch"
: > "$CALLS"
_b=""; zbuild_resolve_default_branch_v _b "$R"
_first="$(_n git)"
_b2="$(zbuild_resolve_default_branch "$R")"; _b3="$(zbuild_resolve_default_branch "$R")"
assert_eq "[L1] the trunk is found" "main|main|main" "$_b|$_b2|$_b3"
assert_eq "[L1] …and two later lookups start no git" "$_first" "$(_n git)"
E="$TEST_TEMP_DIR/empty"; command git init -q -b topic "$E"
: > "$CALLS"
_e=""; zbuild_resolve_default_branch_v _e "$E"; _e1="$(_n git)"
_e2="$(zbuild_resolve_default_branch "$E")"
assert_eq "[L2] no trunk: nothing, both times" "|" "$_e|$_e2"
if [[ "$(_n git)" -gt "$_e1" ]]; then assert_pass "[L2] an unresolved trunk is asked again"
else assert_fail "[L2] an unresolved trunk is asked again" "the second call started no git"; fi

print_test_section "L3: persist's git dir"
: > "$CALLS"
_g1=""; _artifact_persist_git_dir_v _g1 "$R"; _g2=""; _artifact_persist_git_dir_v _g2 "$R"
assert_eq "[L3] the shared git dir" "$R/.git|$R/.git" "$_g1|$_g2"
assert_eq "[L3] …asked once" "1" "$(_n git)"
assert_eq "[L3] the \$( ) form agrees" "$R/.git" "$(_artifact_persist_git_dir "$R")"

print_test_section "L4/L5: the stage time limit"
T1="$TEST_TEMP_DIR/t1.yaml"; T2="$TEST_TEMP_DIR/t2.yaml"
printf 'stages:\n  - build\nbuild:\n  timeout_s: 3600\nplan:\n  gate: auto\n' > "$T1"
printf 'stage_definitions:\n  build:\n    timeout_s: 120\n' > "$T2"
: > "$CALLS"
_TPL_SOURCE_FILE="$T1"
# The reader is the shell's (round 7), and reads every stage at once (round 8):
# a read is counted when the loader finds the template not yet read.
eval "$(declare -f template_stage_time_limits_load | sed '1s/template_stage_time_limits_load/_tl_load_real/')"
template_stage_time_limits_load() {
    [[ -n "${_ZB_STAGE_TL_MEMO["${_TPL_SOURCE_FILE:-}"$'\034']+x}" && "${1:-}" != force ]] || printf 'read\n' >> "$CALLS"
    _tl_load_real "$@"
}
_t1=""; template_stage_time_limit_v _t1 build; _t1b=""; template_stage_time_limit_v _t1b build
_t2=""; template_stage_time_limit_v _t2 plan
assert_eq "[L4] one read of the template for three lookups of two stages" "1" "$(_n read)"
assert_eq "[L5] a set limit, read twice, and the default for an unset one" "3600|3600|900" "$_t1|$_t1b|$_t2"
_TPL_SOURCE_FILE="$T2"
_t3=""; template_stage_time_limit_v _t3 build
assert_eq "[L5] another template is its own read" "120|$(template_stage_time_limit build)" "$_t3|$_t3"
_TPL_SOURCE_FILE="$T1"
assert_eq "[L5] the \$( ) form agrees" "$_t1" "$(template_stage_time_limit build)"
unset _TPL_SOURCE_FILE
unset -f git awk

cleanup_test_env
print_test_results
exit $((FAIL > 0))
