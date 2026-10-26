#!/usr/bin/env bash
# tests/unit/shell-work-cost-test.sh — work the shell repeats, and subshells it
# does not need (ADR-065 §5, round 8).
#
# The slowest pipeline test ran 1.56 million shell commands in 18,745 processes,
# 11,800 of them subshells: copies of the whole engine shell made for a `$( )`.
# Most of the commands were a few loops redoing the same work: every manifest
# lookup walked the index's file list (manifest_index_get), the id/role maps were
# rebuilt in each `$( )` that asked for a stage's manifest, a stage's time limit
# re-read the whole template on each dispatch, and each event checked its keys
# for repeats pair by pair.
#
# W1 [change] manifest_index_get does the same work for 6 manifests as for 80
# W2 [change] _inputs_stage_manifest_v answers in this shell, with no subshell,
#             and a second lookup does not rebuild the maps
# W3 [change] the producer index and stage-previous-work never ask for a manifest
#             through the `$( )` form
# W4 [change] one read of a template gives every stage's time limit: a lookup
#             after the first reads nothing, and a template load fills them, so a
#             `$( )` child reads nothing either
# W5 [guard]  …and each limit is what the old reader gave, for every stage of
#             every template plus an edge set
# W6 [change] an event's work grows with its key count, not with its square
# W7 [guard]  …and a repeated key keeps its first place and its last value
# W8 [change] the helpers called on every dispatch run in this shell: no subshell
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../scripts/lib/stage-previous-work.sh
source "$REPO_ROOT/scripts/lib/stage-previous-work.sh"
# shellcheck source=../../core/pipeline/write-boundary.sh
source "$REPO_ROOT/core/pipeline/write-boundary.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"

print_test_header "shell work: once, in this shell (ADR-065 §5)"
setup_test_env "shell-work-cost"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events" ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
mkdir -p "$ZBUILD_EVENTS_DIR"
T="$TEST_TEMP_DIR/work.trace"
work() { zb_test_work "$T" "$@"; }
cmds() { zb_test_work_cmds "$T"; }
procs() { zb_test_work_procs "$T"; }

# mkroot <dir> <n>: a plugins root of <n> tool manifests, p1..p<n>.
mkroot() {
    local d="$1" n="$2" i
    for (( i = 1; i <= n; i++ )); do
        mkdir -p "$d/tool/p$i"
        printf 'id: p%s\nkind: tool\nprovides:\n  role: r%s\noutputs:\n  - id: o%s\n    path: ${artifact_dir}/p%s.json\n' \
            "$i" "$i" "$i" "$i" > "$d/tool/p$i/manifest.yaml"
    done
}

print_test_section "W1: an index lookup"
mkroot "$TEST_TEMP_DIR/small" 6; mkroot "$TEST_TEMP_DIR/big" 80
# The small root alone first, then with the big one loaded beside it.
manifest_index_load "$TEST_TEMP_DIR/small"
work manifest_index_get "$TEST_TEMP_DIR/small/tool/p3/manifest.yaml" id; _w_small="$(cmds)"
manifest_index_load "$TEST_TEMP_DIR/big"
work manifest_index_get "$TEST_TEMP_DIR/big/tool/p70/manifest.yaml" id; _w_big="$(cmds)"
# Equal up to a command or two of tracing noise (the coverage run differs by
# one); a walk of the file list would add one or more per manifest.
if (( _w_big <= _w_small + 3 )); then
    assert_pass "[W1] the same work for 6 manifests as for 80 ($_w_small vs $_w_big commands)"
else
    assert_fail "[W1] the same work for 6 manifests as for 80" "$_w_small vs $_w_big commands"
fi
assert_eq "[W1] …and the value" "p70" "$(manifest_index_get "$TEST_TEMP_DIR/big/tool/p70/manifest.yaml" id)"
assert_eq "[W1] a file no root lists is still rc 2" "2" \
    "$(manifest_index_get "$TEST_TEMP_DIR/elsewhere/manifest.yaml" id >/dev/null; echo $?)"

print_test_section "W2: a stage's manifest"
R="$TEST_TEMP_DIR/big"
if declare -F _inputs_stage_manifest_v >/dev/null; then
    _m=""; work _inputs_stage_manifest_v _m p12 "$R"
    assert_eq "[W2] answered with no subshell" "0" "$(procs)"
    _m=""; _inputs_stage_manifest_v _m p12 "$R"
    assert_eq "[W2] …the manifest the \$( ) form names" "$(_inputs_stage_manifest p12 "$R")" "$_m"
    work _inputs_stage_manifest_v _m p40 "$R"; _w2="$(cmds)"
    if (( _w2 < 40 )); then assert_pass "[W2] a second lookup does not rebuild the maps ($_w2 commands)"
    else assert_fail "[W2] a second lookup does not rebuild the maps" "$_w2 commands"; fi
else
    assert_fail "[W2] _inputs_stage_manifest_v exists" "not defined"
fi

print_test_section "W3: the callers"
SD="$TEST_TEMP_DIR/state"; mkdir -p "$SD/artifacts" "$SD/runtime"
printf '{"stage_statuses":{"p1":"complete","p2":"complete"}}\n' > "$SD/pipeline-state.json"
printf '{"x":1}\n' > "$SD/artifacts/p1.json"; printf '{"x":2}\n' > "$SD/artifacts/p2.json"
_TPL_STAGES=(p1 p2 p3)
_W3="$TEST_TEMP_DIR/w3.calls"; : > "$_W3"
eval "$(declare -f _inputs_stage_manifest | sed '1s/_inputs_stage_manifest/_ism_real/')"
_inputs_stage_manifest() { printf 'x\n' >> "$_W3"; _ism_real "$@"; }
_IR_INDEX_KEY=""; _inputs_build_producer_index "$R" "$SD"
( _stage_block_previous_work p3 "$SD" "$R" "" "$TEST_TEMP_DIR" >/dev/null 2>&1 ) || true
assert_eq "[W3] no \$( ) manifest lookups from the producer index or previous work" "0" "$(grep -c . "$_W3")"
assert_eq "[W3] …and the producer index still knows p1's output" "$SD/artifacts/p1.json" "${_IR_PATHS[o1]:-}"
eval "$(declare -f _ism_real | sed '1s/_ism_real/_inputs_stage_manifest/')"
unset _TPL_STAGES

print_test_section "W4/W5: stage time limits"
TP="$TEST_TEMP_DIR/tpl.yaml"
printf 'stages:\n  - build\n  - plan\nbuild:\n  timeout_s: 3600 # an hour\nplan:\n  gate: auto\nstage_definitions:\n  review:\n    timeout_s: 120\n' > "$TP"
unset _TPL_SOURCE_FILE; _TPL_SOURCE_FILE="$TP"
_ZB_STAGE_TL_MEMO=()
_a=""; template_stage_time_limit_v _a build
work template_stage_time_limit_v _b review; _w4="$(cmds)"
if (( _w4 < 15 )); then assert_pass "[W4] after the first lookup, another stage's reads nothing ($_w4 commands)"
else assert_fail "[W4] after the first lookup, another stage's reads nothing" "$_w4 commands"; fi
_b=""; template_stage_time_limit_v _b review; _c=""; template_stage_time_limit_v _c plan
assert_eq "[W4] the three limits" "3600 120 900" "$_a $_b $_c"
# A template load fills them in this shell; a `$( )` child then reads nothing.
_ZB_STAGE_TL_MEMO=()
load_template "$REPO_ROOT/config/templates/simple.yaml" >/dev/null 2>&1
_child="$( zb_test_work "$T" template_stage_time_limit_v _x build; zb_test_work_cmds "$T" )"
if (( _child < 15 )); then assert_pass "[W4] after load_template, a \$( ) child reads nothing ($_child commands)"
else assert_fail "[W4] after load_template, a \$( ) child reads nothing" "$_child commands"; fi
# The reader this replaces (scripts/lib/stage-time-limit.sh before round 7),
# verbatim: the answer every stage must still get.
_old_tl() {
    local stage_id="$1" v=""
    if [[ -n "${_TPL_SOURCE_FILE:-}" && -f "${_TPL_SOURCE_FILE}" ]]; then
        v="$(awk -v stage="$stage_id" '
            function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
            $0 ~ "^"stage":[[:space:]]*$" { in_block = 1; block_ind = 0; in_defs = 0; next }
            /^stage_definitions:[[:space:]]*$/ { in_defs = 1; next }
            in_defs && /^[a-zA-Z_]/ { in_defs = 0 }
            in_defs && !in_block && $0 ~ "^  "stage":[[:space:]]*$" { in_block = 1; block_ind = 2; next }
            in_block {
                ind = indent($0)
                if ($0 ~ /[^[:space:]]/ && ind <= block_ind) { in_block = 0 }
            }
            in_block && indent($0) == block_ind + 2 && $0 ~ "^[[:space:]]+timeout_s:" {
                sub(/^[[:space:]]+timeout_s:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/[[:space:]]/, "")
                print; exit
            }
        ' "${_TPL_SOURCE_FILE}" 2>/dev/null)"
    fi
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || v=900
    printf '%s' "$v"
}
E="$TEST_TEMP_DIR/tpl-edge"; mkdir -p "$E"
printf 'stages:\n  - build\nbuild:\n  timeout_s: 3600 # an hour\n  other:\n    timeout_s: 5\nplan:\n  gate: auto\n    timeout_s: 77\nstage_definitions:\n  review:\n    timeout_s:  1 2\n  design:\n    nested:\n      timeout_s: 9\n    timeout_s: 0042\n  build:\n    timeout_s: 11\n' > "$E/a.yaml"
printf 'stage_definitions:\r\n  build:\r\n    timeout_s: 300\r\n' > "$E/crlf.yaml"
printf 'build:\nstage_definitions:\n  plan:\n    timeout_s: 60\nbuild:\n  timeout_s: 70\nreview:\n  x: 1\nstage_definitions:\n  review:\n    timeout_s: 80\n  plan:\n    timeout_s: 61\n' > "$E/reopen.yaml"
printf 'stage_definitions:\n  build:\n  timeout_s: 5\n    timeout_s: 6\n  plan:\n\n    timeout_s: 7\n' > "$E/blank.yaml"
_diffs=0; _show=""; _n=0
for _t in "$REPO_ROOT"/config/templates/*.yaml "$REPO_ROOT"/tests/fixtures/templates/*.yaml "$E"/*.yaml; do
    # Every name a line opens, but the reserved key itself: stage_definitions
    # is the template's block of stages, never a stage.
    _stages="$(grep -oE '^ {0,2}[a-zA-Z_][a-zA-Z0-9_-]*:' "$_t" | tr -d ' :' | grep -vx stage_definitions | sort -u)"
    for _s in $_stages build plan review design nope; do
        _TPL_SOURCE_FILE="$_t"; _ZB_STAGE_TL_MEMO=()
        _o="$(_old_tl "$_s")"; _nw=""; template_stage_time_limit_v _nw "$_s"
        _n=$((_n + 1))
        [[ "$_o" == "$_nw" ]] || { _diffs=$((_diffs + 1)); _show+="[${_t##*/} $_s old=$_o new=$_nw] "; }
    done
done
assert_eq "[W5] $_n (template, stage) pairs: each limit as the old reader gave it" "0" "$_diffs" "$_show"
unset _TPL_SOURCE_FILE

print_test_section "W6/W7: an event's keys"
# emit_work <n>: the commands one emit of <n> distinct keys runs.
emit_work() {
    local -a kv=(); local i
    for (( i = 0; i < $1; i++ )); do kv+=("k$i=v$i"); done
    eb_emit_event stage.complete "${kv[@]}"   # warm
    work eb_emit_event stage.complete "${kv[@]}"; cmds
}
_e4="$(emit_work 4)"; _e8="$(emit_work 8)"; _e16="$(emit_work 16)"
if (( (_e16 - _e8) * 10 <= (_e8 - _e4) * 25 )); then
    assert_pass "[W6] the work grows linearly: 4→8 keys +$((_e8 - _e4)), 8→16 keys +$((_e16 - _e8))"
else
    assert_fail "[W6] the work grows linearly" "4→8 keys +$((_e8 - _e4)), 8→16 keys +$((_e16 - _e8)) commands"
fi
eb_emit_event stage.complete a=1 b=2 a=3 c=4 b=5
# The line as written: jq would fold a key written twice into one.
_w7="$(tail -1 "$ZBUILD_EVENTS_JSONL")"; _w7="${_w7#*\"data\":}"; _w7="${_w7%%\}*}}"
assert_eq "[W7] a repeated key keeps its first place and its last value" '{"a":"3","b":"5","c":"4"}' "$_w7"

print_test_section "W8: the per-dispatch helpers"
# w8 <label> <cmd...>: <cmd> starts no subshell.
_w8_bad=""
w8() {
    local l="$1" p; shift
    declare -F "$1" >/dev/null || { _w8_bad+="$l=undefined "; return; }
    work "$@"; p="$(procs)"; [[ "$p" == 0 ]] || _w8_bad+="$l=$p "
}
export ZBUILD_PLUGINS_ROOT="$R"
w8 other_outputs_deny _lc_other_outputs_deny "$R/tool/p1" "$SD"
_LC_DENY_OUT=""; _lc_other_outputs_deny "$R/tool/p1" "$SD"
assert_contains "[W8] the deny list still names another plugin's output" "$_LC_DENY_OUT" "$SD/artifacts/p2.json"
unset ZBUILD_PLUGINS_ROOT
w8 scan_manifests _inputs_scan_manifests "$R/"
w8 outcome_is_valid outcome_is_valid pass
w8 result_is_current stage_result_is_current "$SD" p1 "$SD/artifacts/p1.json"
w8 watch_list write_boundary_watch_list
w8 notes_path_v stage_notes_path_v _np "$SD" p1
w8 blocks_dir_v stage_blocks_dir_v _bd "$SD" p1
printf '{"x":1}\n' > "$SD/artifacts/fmt.json"
_inputs_damaged "$SD/artifacts/fmt.json" "" "$SD/runtime/form-ok"
w8 damaged_seen _inputs_damaged "$SD/artifacts/fmt.json" "" "$SD/runtime/form-ok"
assert_eq "[W8] none starts a subshell" "" "$_w8_bad"
_np=""; stage_notes_path_v _np "$SD" p1 2>/dev/null; _bd=""; stage_blocks_dir_v _bd "$SD" p1 2>/dev/null
assert_eq "[W8] …and the paths are the \$( ) forms' paths" \
    "$(stage_notes_path "$SD" p1)|$(stage_blocks_dir "$SD" p1)" "$_np|$_bd"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
