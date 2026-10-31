#!/usr/bin/env bash
# tests/unit/stage-retry-test.sh — the engine runs a stage again, every stage,
# from the one place every stage is run (ADR-054 §6a, amended 2026-10-31, #2439).
#
# Why: only the stages inside a loop were ever run again. plan, intake, pr, the
# review lenses, release and persist were not, so `retry:` on them did nothing,
# and plan carried its own `router.retries` to make up for it. Every stage is
# run through plugin_hook_call — in a loop, on its own, side by side, or in a
# generated work unit — so the retry lives there.
#
# R1 [change] a stage that ends timed_out, having changed something, runs again
#             once when its template says nothing (the default is 1)
# R2 [change] the template's `retry:` is how many times it runs again
# R3 [guard]  a stage that ends pass or fail runs once
# R4 [guard]  a try that changed nothing is not run again
# R5 [change] `retry:` above 5 is 5; a word is the default 1; 0 is no retry
# R6 [change] ZBUILD_DISPOSITION_REDISPATCH is gone: it changes nothing
# R7 [change] each retry is announced: stage.retry with the outcome, the try and
#             how many tries there are
# R8 [change] a stage run from a generated work unit (how plan, intake, pr and
#             the lenses run) is run again too
# R9 [guard]  a stage dispatched from inside a stage is not retried on its own:
#             the outer stage's retry covers it
# R10 [change] for a stage that writes code, a change to a declared output
#             other than its summary is progress, as a change to the code is
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../core/pipeline/strategies/common.sh
source "$REPO_ROOT/core/pipeline/strategies/common.sh"
print_test_header "the engine runs any stage again, as its template says (#2439)"
setup_test_env "stage-retry"

export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR"
unset ZBUILD_CYCLE_ITER ZBUILD_DISPOSITION_REDISPATCH

TPL="$TEST_TEMP_DIR/t.yaml"
cat > "$TPL" <<'YAML'
id: t
name: retries
defaults:
  strategy: fanout
flow:
  - plain
  - twice
plain:
  roles: [flaky]
twice:
  roles: [flaky]
  retry: 2
huge:
  roles: [flaky]
  retry: 9
word:
  roles: [flaky]
  retry: lots
never:
  roles: [flaky]
  retry: 0
YAML
load_template "$TPL" >/dev/null 2>&1

# A stage that counts its runs and ends with the next word of $OUTCOMES (the
# last word repeats). It changes its work output on every run unless SAME=1.
P="$TEST_TEMP_DIR/plugins/agent/flaky"; mkdir -p "$P"
cat > "$P/manifest.yaml" <<'MF'
id: flaky
name: Flaky
kind: agent
version: 0.0.1
hooks:
  run: flaky_run
provides:
  role: flaky
  result_contract: 3
outputs:
  - id: flaky_result
    path: ${artifact_dir}/flaky-result.json
    type: json
    required: true
    primary: true
  - id: flaky_work
    path: ${artifact_dir}/flaky-work.txt
    type: text
    required: false
MF
cat > "$P/plugin.sh" <<'PL'
flaky_run() {
    local art; art="$(dirname "$2")/artifacts"; mkdir -p "$art"
    local n=0; [[ -f "$art/runs.$1" ]] && n="$(cat "$art/runs.$1")"
    n=$(( n + 1 )); printf '%s' "$n" > "$art/runs.$1"
    local -a w=(${OUTCOMES:-pass}); local i=$(( n - 1 ))
    (( i >= ${#w[@]} )) && i=$(( ${#w[@]} - 1 ))
    if [[ "${SAME:-0}" == "1" ]]; then printf 'same' > "$art/flaky-work.txt"
    else printf 'run %s' "$n" > "$art/flaky-work.txt"; fi
    source "@RESULT_LIB@"
    local why="run $n"; [[ "${SAME:-0}" == "1" ]] && why="same"
    stage_result_write "$art/flaky-result.json" "${w[$i]}" "$why"
    [[ "${w[$i]}" == pass || "${w[$i]}" == fail ]] && return 0
    return 1
}
PL
sed -i.bak "s|@RESULT_LIB@|$REPO_ROOT/scripts/lib/stage-result.sh|" "$P/plugin.sh"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
printf '{"schema_version":1}' > "$S/pipeline-state.json"
export ZBUILD_STATE_DIR="$S"

# _runs <stage> — how many times the stage ran, from a clean slate first.
_fresh() { rm -rf "$S/artifacts"; mkdir -p "$S/artifacts"; rm -rf "$S/runtime"; }
_runs() { cat "$S/artifacts/runs.$1" 2>/dev/null || echo 0; }
_dispatch() { plugin_hook_call "$P" run "$1" "$S/pipeline-state.json" >/dev/null 2>&1; }

# ── R1 ───────────────────────────────────────────────────────────────────────
_fresh; OUTCOMES="timed_out" _dispatch plain
assert_eq "[R1] timed_out with progress, no retry: in the template → 2 runs" "2" "$(_runs plain)"
_fresh; OUTCOMES="timed_out pass" _dispatch plain; _rc=$?
assert_eq "[R1] the retry that passes is what the dispatch reports" "0" "$_rc"

# ── R2 ───────────────────────────────────────────────────────────────────────
_fresh; OUTCOMES="timed_out" _dispatch twice
assert_eq "[R2] retry: 2 → 3 runs" "3" "$(_runs twice)"
_fresh; OUTCOMES="unusable out_of_turns pass" _dispatch twice
assert_eq "[R2] every word that means 'did not finish' is retried" "3" "$(_runs twice)"

# ── R3 ───────────────────────────────────────────────────────────────────────
_fresh; OUTCOMES="pass" _dispatch twice
assert_eq "[R3] pass → 1 run" "1" "$(_runs twice)"
_fresh; OUTCOMES="fail" _dispatch twice
assert_eq "[R3] fail → 1 run (the loop handles a failure, not the retry)" "1" "$(_runs twice)"

# ── R4 ───────────────────────────────────────────────────────────────────────
_fresh; SAME=1 OUTCOMES="timed_out" _dispatch twice
assert_eq "[R4] a try that changed nothing is not run again" "2" "$(_runs twice)"

# ── R5 ───────────────────────────────────────────────────────────────────────
_fresh; OUTCOMES="timed_out" _dispatch huge
assert_eq "[R5] retry: 9 is capped at 5 → 6 runs" "6" "$(_runs huge)"
_fresh; OUTCOMES="timed_out" _dispatch word
assert_eq "[R5] retry: lots → the default 1 → 2 runs" "2" "$(_runs word)"
_fresh; OUTCOMES="timed_out" _dispatch never
assert_eq "[R5] retry: 0 → 1 run" "1" "$(_runs never)"

# ── R6 ───────────────────────────────────────────────────────────────────────
_fresh; ZBUILD_DISPOSITION_REDISPATCH=4 OUTCOMES="timed_out" _dispatch plain
assert_eq "[R6] ZBUILD_DISPOSITION_REDISPATCH=4 changes nothing → 2 runs" "2" "$(_runs plain)"

# ── R7 ───────────────────────────────────────────────────────────────────────
_fresh; : > "$ZBUILD_EVENTS_JSONL"; OUTCOMES="timed_out pass" _dispatch twice
_ev="$(jq -c 'select(.type == "stage.retry")' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"
assert_eq "[R7] one stage.retry for the one retry" "1" "$(grep -c . <<< "$_ev")"
assert_eq "[R7] it names the stage" "twice" "$(jq -r '.data.stage' <<< "$_ev")"
assert_eq "[R7] ...the outcome the try ended on" "timed_out" "$(jq -r '.data.outcome' <<< "$_ev")"
assert_eq "[R7] ...which try comes next" "2" "$(jq -r '.data.try' <<< "$_ev")"
assert_eq "[R7] ...of how many" "3" "$(jq -r '.data.of' <<< "$_ev")"
if grep -q '"stage.retry"' "$REPO_ROOT/config/event-schema.json"; then
    assert_pass "[R7] stage.retry is a known event"
else
    assert_fail "[R7] stage.retry is a known event" "not in config/event-schema.json"
fi

# ── R8 ───────────────────────────────────────────────────────────────────────
_fresh; _wu="$(_strategy_make_work_unit "$P" plain "$S/pipeline-state.json")"
OUTCOMES="timed_out" bash "$_wu" >/dev/null 2>&1
assert_eq "[R8] a stage run from a work unit is run again too → 2 runs" "2" "$(_runs plain)"
rm -f "$_wu"

# ── R9 ───────────────────────────────────────────────────────────────────────
O="$TEST_TEMP_DIR/plugins/agent/outer"; mkdir -p "$O"
sed -e 's/^id: flaky/id: outer/' -e 's/flaky_run/outer_run/' -e 's/role: flaky/role: outer/' \
    -e 's/flaky-result/outer-result/' -e 's/flaky_result/outer_result/' "$P/manifest.yaml" > "$O/manifest.yaml"
cat > "$O/plugin.sh" <<PL
outer_run() {
    plugin_hook_call "$P" run plain "\$2" >/dev/null 2>&1
    source "$REPO_ROOT/scripts/lib/stage-result.sh"
    stage_result_write "\$(dirname "\$2")/artifacts/outer-result.json" pass "outer ran"
}
PL
_fresh; OUTCOMES="timed_out" plugin_hook_call "$O" run plain-outer "$S/pipeline-state.json" >/dev/null 2>&1
assert_eq "[R9] the inner dispatch runs once; it is not retried on its own" "1" "$(_runs plain)"

# ── R10 ──────────────────────────────────────────────────────────────────────
C="$TEST_TEMP_DIR/plugins/agent/coder"; mkdir -p "$C"
cat > "$C/manifest.yaml" <<'MF'
id: coder
kind: agent
capabilities:
  writes_repository: true
outputs:
  - id: result
    path: "${artifact_dir}/coder-result.json"
    primary: true
  - id: summary
    path: "${artifact_dir}/coder-summary.md"
    summary: true
MF
REPO="$(setup_git_temp_repo "stage-retry-coder")"
export ZBUILD_REPO_ROOT="$REPO"
_coder_try() {
    local before; before="$(attempt_outputs_fingerprint "$C" "$S/pipeline-state.json")"
    eval "$1"
    attempt_archive_outputs "$C" "$S/pipeline-state.json" coder 1 "$before" >/dev/null 2>&1
}
_fresh
_coder_try 'printf "{\"n\":1}" > "$S/artifacts/coder-result.json"'
_coder_try 'printf "{\"n\":2}" > "$S/artifacts/coder-result.json"'
assert_eq "[R10] a code-writing stage whose result changed made progress" "true" "${_ATTEMPT_LAST_PROGRESS:-unset}"
_coder_try 'printf "s2" > "$S/artifacts/coder-summary.md"'
assert_eq "[R10] ...one whose summary alone changed did not" "false" "${_ATTEMPT_LAST_PROGRESS:-unset}"
_coder_try 'printf x > "$REPO/f.txt"'
assert_eq "[R10] ...one whose code changed did" "true" "${_ATTEMPT_LAST_PROGRESS:-unset}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
