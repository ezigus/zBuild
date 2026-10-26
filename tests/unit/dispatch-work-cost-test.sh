#!/usr/bin/env bash
# tests/unit/dispatch-work-cost-test.sh — what a stage dispatch, a manifest check
# and a snapshot start (ADR-065 §5, round 9).
#
# A three-run pipeline test started 11,714 processes, about 3,900 a run: ~775 at
# start-up, the rest ~55 a stage. Most were a helper called through `$( )` or
# `< <( )` — a copy of the whole engine shell to print one value — and the same
# file read by several jq calls.
#
# P1 [change] the Previous work block reads each stage's output roles in this
#             shell, not one `$( )` a stage
# P2 [guard]  …and _sp_manifest_roles_v gives each role's line, in order
# P3 [change] the result readers a dispatch uses have `_v` forms that start no
#             subshell (the report: its one jq)
# P4 [guard]  …and both forms give main's answers, for a pass, a declared
#             disposition, a non-JSON primary and a stage that died
# P5 [change] a snapshot asks for the temp dir and branch in this shell, and
#             starts no mktemp
# P6 [change] a goal's branch name is worked out once a shell
# P7 [change] a dispatch reads its deny list, writes flag, scratch dir, input
#             index and prompt blocks in this shell
# P8 [change] validate_manifest runs its checks in this shell
# P9 [change] atomic_write in a child of a shell that loaded helpers.sh reads
#             no umask (the engine never changes its umask)
# P10 [guard] …and a new file is still 600, and the umask is back as it was
# P11 [change] the abort check and the disposition tests start no subshell,
#             and answer as before
# P12 [change] the rules block reads the notes path and time limit in its shell
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "dispatch work: once, in this shell (ADR-065 §5, round 9)"
setup_test_env "dispatch-work-cost"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"

# P9 first: nothing here may have called atomic_write in this shell yet.
print_test_section "P9/P10: atomic_write's umask"
T="$TEST_TEMP_DIR/work.trace"
_um0="$(umask)"
_d9="$( zb_test_work "$T" atomic_write "$TEST_TEMP_DIR/new.txt" <<< "x"; zb_test_work_procs "$T" )"
assert_eq "[P9] a write in a child reads no umask" "0" "$_d9"
_d10="$( atomic_write "$TEST_TEMP_DIR/new2.txt" <<< "x"; umask )"
_m10="$(stat -c '%a' "$TEST_TEMP_DIR/new2.txt" 2>/dev/null || stat -f '%Lp' "$TEST_TEMP_DIR/new2.txt")"
assert_eq "[P10] …a new file is still 600" "600" "$_m10"
assert_eq "[P10] …and the umask is back as it was" "$_um0" "$_d10"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../core/pipeline/dispatch-rc.sh
source "$REPO_ROOT/core/pipeline/dispatch-rc.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"
# shellcheck source=../../scripts/lib/identity.sh
source "$REPO_ROOT/scripts/lib/identity.sh"
# shellcheck source=../../core/pipeline/stage-scratch.sh
source "$REPO_ROOT/core/pipeline/stage-scratch.sh"

work()  { zb_test_work "$T" "$@"; }
procs() { zb_test_work_procs "$T"; }

# watch_sub <fn>...: from here on, each call of <fn> made from a subshell of
# this shell is logged to $SUB (the function still runs).
SUB="$TEST_TEMP_DIR/sub.calls"; : > "$SUB"
watch_sub() {
    local f
    for f; do
        declare -F "$f" >/dev/null || { printf 'undefined:%s\n' "$f" >> "$SUB"; continue; }
        eval "$(declare -f "$f" | sed "1s/^$f /_ws_real_$f /")"
        eval "$f() { [[ \$BASHPID == $$ ]] || printf '%s\n' $f >> \"\$SUB\"; _ws_real_$f \"\$@\"; }"
    done
}
subs() { sort -u "$SUB" | tr '\n' ' ' | sed 's/ $//'; }

# mkplug <root> <id> <out> — a v2 tool plugin whose one output is its primary
# result and its summary.
mkplug() {
    local d="$1/tool/$2"
    mkdir -p "$d"
    printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\nhooks:\n  run: %s_run\nrequires:\n  core: [event-bus]\noutputs:\n  - id: %s\n    path: ${artifact_dir}/%s.json\n    primary: true\n    summary: true\n    required: true\nprovides:\n  result_contract: 3\n' \
        "$2" "$2" "${2//-/_}" "$3" "$2" > "$d/manifest.yaml"
    printf '%s_run() { return 0; }\n' "${2//-/_}" > "$d/plugin.sh"
}

R="$TEST_TEMP_DIR/plugins"; SD="$TEST_TEMP_DIR/state"
mkdir -p "$SD/artifacts" "$SD/runtime"
for _p in s1 s2 s3 s4 s5 s6; do mkplug "$R" "$_p" "${_p}_out"; done
printf '{"stage_statuses":{"s1":"complete","s2":"complete","s3":"complete","s4":"complete","s5":"complete"}}\n' > "$SD/pipeline-state.json"
for _p in s1 s2 s3 s4 s5; do stage_result_write "$SD/artifacts/$_p.json" pass "done"; done
_TPL_STAGES=(s1 s2 s3 s4 s5 s6)
manifest_index_load "$R" >/dev/null 2>&1 || true

print_test_section "P1/P2: the Previous work block"
_IR_INDEX_KEY=""
_ix="$(_inputs_resolve_stage s6 "$R" "$SD")"
watch_sub _sp_manifest_roles
_stage_block_previous_work s6 "$SD" "$R" "$_ix" "$TEST_TEMP_DIR" > "$TEST_TEMP_DIR/pw.md" 2>/dev/null
assert_eq "[P1] no stage's roles are read through a subshell" "" "$(subs)"
assert_contains "[P1] …and the block still lists s5's output" "$(cat "$TEST_TEMP_DIR/pw.md")" "s5_out"
: > "$SUB"
if declare -F _sp_manifest_roles_v >/dev/null; then
    _r=""; work _sp_manifest_roles_v _r "$R/tool/s2/manifest.yaml" "$SD"
    assert_eq "[P2] _sp_manifest_roles_v starts no subshell" "0" "$(procs)"
    _r=""; _sp_manifest_roles_v _r "$R/tool/s2/manifest.yaml" "$SD"
    # Summary, then errors, primary, required: the order the reader prints them.
    assert_eq "[P2] …and gives the roles' lines" \
        "S"$'\t''${artifact_dir}/s2.json'$'\n'"P"$'\t''${artifact_dir}/s2.json'$'\n'"R"$'\t''${artifact_dir}/s2.json' "$_r"
    assert_eq "[P2] …as _sp_manifest_roles prints them" "$_r" "$(_ws_real__sp_manifest_roles "$R/tool/s2/manifest.yaml" "$SD")"
else
    assert_fail "[P2] _sp_manifest_roles_v exists" "not defined"
fi

print_test_section "P3/P4: the result readers"
M2="$R/tool/s2/manifest.yaml"
mkplug "$R" doc doc_out; sed -i.bak 's#doc.json#doc.md#' "$R/tool/doc/manifest.yaml"; printf '# x\n' > "$SD/artifacts/doc.md"
mkplug "$R" thr thr_out
stage_result_write "$SD/artifacts/thr.json" throttled "slow down"
# <label> <stage> <manifest> <rc> <observation, - for none>
_cases=("pass s2 $M2 0 -" "died s6 $R/tool/s6/manifest.yaml 1 signal" "nonjson doc $R/tool/doc/manifest.yaml 0 -"
        "declared thr $R/tool/thr/manifest.yaml 1 signal" "timedout s6 $R/tool/s6/manifest.yaml 124 timeout"
        "plain s6 $R/tool/s6/manifest.yaml 1 -")
_d3=""; _d4=""
_check() {   # <fn> <want> <got> <label>
    [[ "$2" == "$3" ]] || _d4+="$1/$4: want [$2] got [$3]; "
}
# What main's readers gave for these cases before round 9:
# verdict|verdict_raw|reason|report|disposition|data_kind, and observation|narrow.
declare -A _MAIN=(
    [pass]='pass|pass|done|{"reason":"done"}|complete|'
    [died]='fail|fail||{}|interrupted|'
    [nonjson]='error|error|contract_violation:nonjson_primary|{}|broken|'
    [declared]='fail|fail|slow down|{"reason":"slow down"}|throttled|'
    [timedout]='fail|fail||{}|interrupted|'
    [plain]='fail|fail||{}|broken|'
    [rc0]='|0' [rc1]='|1' [rc124]='timeout|1' [rc137]='signal|1' [rc192]='signal|1' [rc193]='|1' [rc300]='|1' [rcx]='|1'
)
_FIELDS=(verdict verdict_raw reason report disposition data_kind)
# The first reader of a result reads it with one jq and the rest reuse that
# read, and an event's cost is the event writer's: so each case is read once
# before its _v forms are counted, with events switched off.
eval "$(declare -f eb_emit_event | sed '1s/^eb_emit_event /_d3_real_emit /')"
for _c in "${_cases[@]}"; do
    read -r _l _s _m _rc _obs <<< "$_c"
    [[ "$_obs" == - ]] && _obs=""
    IFS='|' read -r -a _want <<< "${_MAIN[$_l]}|"
    _i=0
    for _f in "${_FIELDS[@]}"; do
        case "$_f" in
            disposition) _args=("$SD" "$_m" "$_s" "$_rc" "$_obs" 0) ;;
            data_kind)   _args=("$SD" "$_m" "$_s") ;;
            *)           _args=("$SD" "$_m" "$_s" "$_rc") ;;
        esac
        _check "$_f" "${_want[$_i]}" "$("runner_read_stage_${_f}" "${_args[@]}" 2>/dev/null)" "$_l"
        if ! declare -F "runner_read_stage_${_f}_v" >/dev/null; then _d3+="${_f}=undefined "; _i=$((_i + 1)); continue; fi
        _verdict_read_result "$SD" "$_m" "$_s" "$_rc" _warm 2>/dev/null
        eb_emit_event() { :; }
        work "runner_read_stage_${_f}_v" _o "${_args[@]}"
        eval "$(declare -f _d3_real_emit | sed '1s/^_d3_real_emit /eb_emit_event /')"
        _n="$(procs)"; _max=0; [[ "$_f" == report ]] && _max=1
        (( _n <= _max )) || _d3+="${_f}/${_l}=$_n "
        _o=""; "runner_read_stage_${_f}_v" _o "${_args[@]}" 2>/dev/null
        _check "${_f}_v" "${_want[$_i]}" "$_o" "$_l"
        _i=$((_i + 1))
    done
done
for _rc in 0 1 124 137 192 193 300 x; do
    IFS='|' read -r _wo _wn <<< "${_MAIN[rc$_rc]}"
    _check rc_observation "$_wo" "$(dispatch_rc_observation "$_rc")" "$_rc"
    _check rc_narrow "$_wn" "$(dispatch_rc_narrow "$_rc")" "$_rc"
    for _f in observation narrow; do
        if ! declare -F "dispatch_rc_${_f}_v" >/dev/null; then _d3+="rc_${_f}=undefined "; continue; fi
        work "dispatch_rc_${_f}_v" _o "$_rc"; _n="$(procs)"; (( _n == 0 )) || _d3+="rc_${_f}/$_rc=$_n "
        _o=""; "dispatch_rc_${_f}_v" _o "$_rc"
        if [[ "$_f" == observation ]]; then _check rc_observation_v "$_wo" "$_o" "$_rc"; else _check rc_narrow_v "$_wn" "$_o" "$_rc"; fi
    done
done
assert_eq "[P3] the readers' _v forms start no subshell" "" "${_d3% }"
assert_eq "[P4] …and both forms give main's answers" "" "$_d4"

print_test_section "P5/P6: a snapshot"
G="$TEST_TEMP_DIR/repo"; mkdir -p "$G"
git -C "$G" init -q 2>/dev/null; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
MK="$TEST_TEMP_DIR/mktemp.calls"; : > "$MK"
mktemp() { printf 'mktemp\n' >> "$MK"; command mktemp "$@"; }
watch_sub zbuild_engine_tmpdir _artifact_persist_branch
ZBUILD_GOAL="tidy the docs" _artifact_persist_snapshot "$SD" 0 "$G" >/dev/null 2>&1
assert_eq "[P5] the snapshot saved" "saved" "${_ARTIFACT_PERSIST_LAST_STATUS:-}"
assert_eq "[P5] no temp dir or branch asked for through a subshell" "" "$(subs)"
assert_eq "[P5] …and no mktemp" "" "$(tr '\n' ' ' < "$MK")"
unset -f mktemp; : > "$SUB"
if declare -F _artifact_persist_branch_v >/dev/null; then
    _b=""; _artifact_persist_branch_v _b 0 "tidy the docs"
    work _artifact_persist_branch_v _b2 0 "tidy the docs"
    assert_eq "[P6] the second time, the branch name starts nothing" "0" "$(procs)"
    _b2=""; _artifact_persist_branch_v _b2 0 "tidy the docs"
    assert_eq "[P6] …and it is the goal's branch" "zbuild/state/$(zbuild_goal_key "tidy the docs")" "$_b2"
    assert_eq "[P6] …as the printing form names it" "$_b2" "$(_ws_real__artifact_persist_branch 0 "tidy the docs")"
    _b3=""; _artifact_persist_branch_v _b3 0 "another goal"
    assert_eq "[P6] …and another goal gets its own" "zbuild/state/$(zbuild_goal_key "another goal")" "$_b3"
    _b4=""; _artifact_persist_branch_v _b4 42 "tidy the docs"
    assert_eq "[P6] …and an issue its number" "zbuild/state/issue-42" "$_b4"
else
    assert_fail "[P6] _artifact_persist_branch_v exists" "not defined"
fi

print_test_section "P7: a stage dispatch"
export ZBUILD_STATE_DIR="$SD" ZBUILD_PLUGINS_ROOT="$R"
printf '{"owned_files":{"s1":["a.txt"]}}\n' > "$SD/artifacts/stage-reports.json"
watch_sub _lc_owned_by_others_deny manifest_index_get stage_scratch_ensure _inputs_resolve_stage stage_blocks_write atomic_write
ZBUILD_CURRENT_STAGE=s2 plugin_hook_call "$R/tool/s2" run s2 "$SD/pipeline-state.json" >/dev/null 2>&1 || true
assert_eq "[P7] none is called from a subshell" "" "$(subs)"
_bd=""; stage_blocks_dir_v _bd "$SD" s2
assert_contains "[P7] …the dispatch wrote s2's input index" "$(cat "$SD/stage-inputs/s2.json" 2>/dev/null)" "s1_out"
assert_contains "[P7] …and its Previous work block" "$(cat "$_bd/previous-work.md" 2>/dev/null)" "### s1"
_sc=""; stage_scratch_dir_v _sc "$SD" s2
assert_eq "[P7] …and its scratch dir is the one stage_scratch_dir names" "$SD/scratch/s2" "$_sc"
[[ -d "$SD/scratch/s2" ]] && assert_pass "[P7] …which the dispatch made" || assert_fail "[P7] …which the dispatch made" "no $SD/scratch/s2"
unset ZBUILD_STATE_DIR ZBUILD_PLUGINS_ROOT; : > "$SUB"

print_test_section "P8: validate_manifest"
watch_sub requires_core_check requires_core_unresolved eb_manifest_events_invalid _manifest_router_block _required_hooks_for_kind contract_version_check
validate_manifest "$M2" >/dev/null 2>&1; _v8=$?
assert_eq "[P8] the manifest is valid" "0" "$_v8"
assert_eq "[P8] none of its checks runs in a subshell" "" "$(subs)"
# Every config.router key is checked, not only the last one read.
mkplug "$R" rb rb_out
printf 'config:\n  router:\n    bogus_knob: 3\n    max_turns: 5\n' >> "$R/tool/rb/manifest.yaml"
_v8m="$(validate_manifest "$R/tool/rb/manifest.yaml" 2>&1)"; _v8r=$?
assert_eq "[P8] …a manifest with an unknown router key is refused" "1" "$_v8r"
assert_contains "[P8] …naming that key, though another follows it" "$_v8m" "unknown key 'bogus_knob'"
# …and the other checks still refuse what they refused.
mkplug "$R" nh nh_out; sed -i.bak '/^hooks:/d; /^  run: /d' "$R/tool/nh/manifest.yaml"
_v8h="$(validate_manifest "$R/tool/nh/manifest.yaml" 2>&1)"
assert_contains "[P8] …a tool with no run hook is refused" "$_v8h" "requires hook 'run'"
mkplug "$R" ev ev_out
printf '  events:\n    - Bad.Name\n    - also bad\n    - good.name\n' >> "$R/tool/ev/manifest.yaml"
_v8e="$(validate_manifest "$R/tool/ev/manifest.yaml" 2>&1)"
assert_contains "[P8] …each bad event name is named (the first)" "$_v8e" "'Bad.Name' is not a valid event name"
assert_contains "[P8] …each bad event name is named (the second)" "$_v8e" "'also bad' is not a valid event name"

print_test_section "P11/P12: the checks after a dispatch, and the rules block"
# shellcheck source=../../scripts/lib/abort-propagation.sh
source "$REPO_ROOT/scripts/lib/abort-propagation.sh"
# shellcheck source=../../core/pipeline/disposition.sh
source "$REPO_ROOT/core/pipeline/disposition.sh"
_d11=""
export ZBUILD_STATE_DIR="$SD"
work _zbuild_check_abort; _n="$(procs)"; [[ "$_n" == 0 ]] || _d11+="check_abort=$_n "
for _w in complete broken throttled nonsense; do
    work disposition_halts "$_w"; _n="$(procs)"; [[ "$_n" == 0 ]] || _d11+="halts/$_w=$_n "
    work disposition_retryable "$_w"; _n="$(procs)"; [[ "$_n" == 0 ]] || _d11+="retryable/$_w=$_n "
done
assert_eq "[P11] the abort check and the disposition tests start no subshell" "" "$_d11"
# The answers, from the response table: halts on broken and on a word off it,
# retries on throttled, and neither on complete.
_d11a=""
for _w in complete broken throttled nonsense; do
    disposition_halts "$_w" && _d11a+="$_w:halts "; disposition_retryable "$_w" && _d11a+="$_w:retries "
done
assert_eq "[P11] …and they answer as the table says" "broken:halts throttled:retries nonsense:halts " "$_d11a"
_zbuild_check_abort; _a0=$?
printf 'sigterm\n' > "$SD/.abort.signal"; unset _ZB_ABORT_REASON
_zbuild_check_abort; _a1=$?; _ar="$(_zbuild_abort_reason)"
: > "$SD/.abort.signal"; _ae="$(_zbuild_abort_reason)"
rm -f "$SD/.abort.signal"
assert_eq "[P11] …no abort, then the one the sentinel records" "0 1 sigterm" "$_a0 $_a1 $_ar"
assert_eq "[P11] …and an empty sentinel reads as sigint" "sigint" "$_ae"
unset ZBUILD_STATE_DIR
: > "$SUB"
watch_sub stage_notes_path template_stage_time_limit
_stage_block_rules s2 "$SD" "$M2" > "$TEST_TEMP_DIR/rules.md" 2>/dev/null
assert_eq "[P12] the rules block asks for no path or limit through a subshell" "" "$(subs)"
_np=""; stage_notes_path_v _np "$SD" s2
assert_contains "[P12] …and still names the notes file" "$(cat "$TEST_TEMP_DIR/rules.md")" "Your notes file is $_np"

unset _TPL_STAGES
cleanup_test_env
print_test_results
exit $((FAIL > 0))
