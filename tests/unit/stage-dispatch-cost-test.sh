#!/usr/bin/env bash
# tests/unit/stage-dispatch-cost-test.sh — what the per-dispatch engine helpers
# start (ADR-065 §5, round 6). Each runs once (or more) per stage dispatch, so a
# program here is paid ~60 times by a three-run pipeline test.
#
# D1 [change] write_boundary_mark on a clean worktree starts git (rev-parse,
#             status) and the one rm of its clock probe — it also ran dirname,
#             mkdir, touch and two rm of files that were not there
# D2 [change] write_boundary_check of a non-writer that changed nothing starts
#             only its find sweeps and one git status — it also ran dirname,
#             awk, comm, sed, cut, sort, grep ×2 and a second rev-parse
# D3 [guard]  …and a non-writer that DID change the worktree is still refused,
#             with the path named
# D4 [change] _inputs_build_producer_index called again with the same inputs
#             starts nothing — it ran `tr` before the memo check
# D5 [change] a manifest_graph_collect memo hit starts nothing — it ran cat and
#             awk to re-read the memo file and the manifest's id
# D6 [guard]  manifest_graph_get_stage_id gives the awk reader's answer for
#             every real manifest and an adversarial corpus
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "per-dispatch helpers: what they start (ADR-065 §5)"
setup_test_env "stage-dispatch-cost"

emit_event() { :; }
# shellcheck source=../../core/pipeline/write-boundary.sh
source "$REPO_ROOT/core/pipeline/write-boundary.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

CALLS="$TEST_TEMP_DIR/calls"
_PROGS=(dirname basename mkdir touch rm git find awk sort comm grep sed cut cat tr mv cp stat jq head tail wc)
_wrap()   { local c; for c in "${_PROGS[@]}"; do eval "$c() { printf '%s\\n' $c >> \"\$CALLS\"; command $c \"\$@\"; }"; done; }
_unwrap() { unset -f "${_PROGS[@]}"; }
# The calls, sorted, joined by spaces; `find` collapsed to one word so the count
# of watched places (config) does not pin the test.
_calls()  { command sort "$CALLS" | command awk '$0=="find"{f=1;next}{print} END{if(f)print "find…"}' | command tr '\n' ' ' | command sed 's/ $//'; }

# ─── fixture: a run's state dir, a non-writing plugin, a clean worktree ─────
SD="$TEST_TEMP_DIR/state/runs/r1"; mkdir -p "$SD/artifacts" "$SD/runtime"; echo '{}' > "$SD/pipeline-state.json"
PD="$TEST_TEMP_DIR/plugins/tool/fx"; mkdir -p "$PD"
printf 'id: fx\nkind: tool\nhooks:\n  run: r\n' > "$PD/manifest.yaml"
WT="$TEST_TEMP_DIR/wt"; git init -q "$WT"; echo a > "$WT/a.txt"
git -C "$WT" add a.txt; git -C "$WT" -c user.email=t@t -c user.name=t commit -qm init
export ZBUILD_REPO_ROOT="$WT"

print_test_section "D1/D2: the write boundary on a clean dispatch"
: > "$CALLS"; _wrap
write_boundary_mark "$SD/pipeline-state.json" build ""
_unwrap
assert_eq "[D1] write_boundary_mark starts git (rev-parse, status) and the probe's rm" "git git rm" "$(_calls)"
: > "$CALLS"; _wrap
write_boundary_check "$PD" "$SD/pipeline-state.json" build ""; _rc=$?
_unwrap
assert_eq "[D2] write_boundary_check of an unchanged non-writer passes" "0" "$_rc"
assert_eq "[D2] …starting only its sweeps and one git status" "git find…" "$(_calls)"

print_test_section "D3: a non-writer that changed the worktree is still refused"
write_boundary_mark "$SD/pipeline-state.json" build ""
echo changed >> "$WT/a.txt"
_out="$(write_boundary_check "$PD" "$SD/pipeline-state.json" build "" 2>&1)"; _rc=$?
assert_eq "[D3] the check refuses the dispatch" "1" "$_rc"
assert_contains "[D3] …and names the changed path" "$_out" "a.txt"
git -C "$WT" checkout -q -- a.txt 2>/dev/null || true
assert_eq "[D3] _wb_repo_changed lists exactly the changed path" "a.txt" \
    "$(write_boundary_mark "$SD/pipeline-state.json" build "" >/dev/null 2>&1; echo x >> "$WT/a.txt"; _wb_repo_changed "$SD/runtime/write-boundary.build.marker.repo" "$WT")"
git -C "$WT" checkout -q -- a.txt 2>/dev/null || true

print_test_section "D4: the producer index memo"
PR="$TEST_TEMP_DIR/proot"; mkdir -p "$PR/agent/s1"
printf 'id: s1\nkind: agent\nhooks:\n  run: r\n' > "$PR/agent/s1/manifest.yaml"
_TPL_STAGES=(s1)
_inputs_build_producer_index "$PR" "$SD"
: > "$CALLS"; _wrap
_inputs_build_producer_index "$PR" "$SD"
_unwrap
assert_eq "[D4] a repeat call with the same inputs starts nothing" "" "$(_calls)"
_TPL_STAGES=(s1 s2)
_k1="$_IR_INDEX_KEY"; _inputs_build_producer_index "$PR" "$SD"
assert_eq "[D4] a changed flow is a new key (each stage, then a space)" \
    "${PR}|${SD}|s1 s2 " "$_IR_INDEX_KEY"
[[ "$_k1" != "$_IR_INDEX_KEY" ]] && assert_pass "[D4] …and differs from the old one" || assert_fail "[D4] key changed" "$_k1"
unset _TPL_STAGES

print_test_section "D5: a manifest_graph_collect memo hit"
export ZBUILD_STATE_DIR="$SD"
_m1="$(manifest_graph_collect "$PR" s1)"
_MGRAPH_COLLECT_MEMO=()   # a fresh shell: only the memo FILE is left
: > "$CALLS"; _wrap
_m2="$(manifest_graph_collect "$PR" s1)"
_unwrap
assert_eq "[D5] the memo answers" "$PR/agent/s1/manifest.yaml|$PR/agent/s1/manifest.yaml" "$_m1|$_m2"
assert_eq "[D5] …and a memo hit starts nothing" "" "$(_calls)"
printf 'id: renamed\nkind: agent\n' > "$PR/agent/s1/manifest.yaml"
_MGRAPH_COLLECT_MEMO=()
assert_eq "[D5] a hit whose manifest no longer carries the id is not used" "" "$(manifest_graph_collect "$PR" s1 2>/dev/null)"
unset ZBUILD_STATE_DIR

print_test_section "D6: manifest_graph_get_stage_id == the awk reader"
_awk_id() {
    awk '/^id:[[:space:]]*/ { sub(/^id:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; exit }' "$1" 2>/dev/null
}
C="$TEST_TEMP_DIR/idcorpus"; mkdir -p "$C"
_c() { printf '%b' "$2" > "$C/$1.yaml"; }
_c plain 'id: plain\n'; _c spaced 'id:    spaced   \n'; _c comment 'id: c1   # why\n'
_c dq 'id: "dq"\n'; _c sq "id: 'sq'\n"; _c onequote 'id: "\n'; _c inner 'id: a"b\n'
_c tight 'id:tight\n'; _c crlf 'id: crlf\r\nkind: x\r\n'; _c none 'name: x\n'; _c empty ''
_c later 'name: n\nid: later\nid: second\n'; _c indented '  id: nested\nid: top\n'
_c hash 'id: a#b\n'; _c tabs 'id:\tt1\t# c\n'; _c onlyc 'id: # nothing\n'
: > "$C/noeol.yaml"; printf 'id: noeol' > "$C/noeol.yaml"
_mism=0; _det=""
while IFS= read -r f; do
    a="$(_awk_id "$f")"; b="$(manifest_graph_get_stage_id "$f")"
    [[ "$a" == "$b" ]] || { _mism=$((_mism + 1)); _det+="$f: awk=[$a] got=[$b]; "; }
done < <(command find "$REPO_ROOT/plugins" "$C" -name '*.yaml' -type f)
assert_eq "[D6] every real manifest and every corpus case agrees" "0" "$_mism" "$_det"
assert_eq "[D6] a missing file gives nothing" "" "$(manifest_graph_get_stage_id "$C/absent.yaml")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
