#!/usr/bin/env bash
# tests/integration/call-limits-agree-test.sh — one set of limits per call
# (#2584 R7; ADR-018, ADR-017, amended 2026-11-22).
#
# Why: on #1764 run 44910536811 a lens's prompt said "600 seconds and 20 turns"
# — its manifest's — while the call ran with 900 seconds and no turn limit, the
# template's review_lenses block (`router.max_turns.flag_omitted … resolved=0`).
# The budget line was resolved when the engine wrote the dispatch's blocks, in a
# shell with no template accessors loaded; the router resolved again at call
# time, after the stage had loaded them. The limits are now resolved once per
# dispatch, and that one record feeds the call, the prompt's budget line and
# the time-up warning.
#
# For every stage of config/templates/simple.yaml whose plugin makes model
# calls — each element of a map stage included — dispatched the way the engine
# dispatches a map element (a fresh process that sources only the registry,
# then plugin_hook_call), four things agree:
#   CL1 the configured limits (the template's router block, else the plugin's
#       manifest, else 300 seconds and no turn limit) and the CLI's: --max-turns
#       (absent for no limit) and the call's time limit (model.route timeout_s)
#   CL2 ...and the prompt's budget line
#   CL3 ...and the time-up warning the call's hook gives at its deadline
# CL4 [guard] the configured values are the ones this template has always set
#     (the change moves no limit)
# CL5 [change] (review) a stage that sets its call's turn limit itself sets it
#     in the one record (zb_call_limits_turns_override) before its prompt is
#     composed: the loop's CLI, the budget line and the warning all say it; a
#     loop asked for another limit than the record's is refused
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "one set of limits per call: configured, CLI, prompt and warning agree (#2584 R7)"
setup_test_env "call-limits-agree"
_test_cleanup_hook() { cleanup_test_env; }

TPL="$REPO_ROOT/config/templates/simple.yaml"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json" ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_LOCKFILE="$TEST_TEMP_DIR/no-lockfile" ZBUILD_RUN_ID="limits-agree"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/repo" HOME="$TEST_TEMP_DIR/home"
unset ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_MAX_TURNS_OVERRIDE ZBUILD_SCOPE_MANIFEST 2>/dev/null || true
mkdir -p "$ZBUILD_REPO_ROOT" "$HOME"
( cd "$ZBUILD_REPO_ROOT" && git init -q -b main && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add -A && git commit -qm seed ) >/dev/null 2>&1

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$TPL" >/dev/null 2>&1 || assert_fail "fixture: the template loads" "load_template refused $TPL"

# The mock CLI: its argv, the hook command from its settings, and a reply.
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
out="${LIMITS_OUT:?}"; printf '%s\n' "$@" > "$out.argv"; cat > "$out.prompt"
s=""; p=""; for a in "$@"; do [[ "$p" == --settings ]] && s="$a"; p="$a"; done
jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$s" > "$out.hook" 2>/dev/null
jq -n '{type:"result", result:"{\"score\":10,\"findings\":[]}", usage:{input_tokens:1, output_tokens:1}}'
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"

# The driver: what a map element's work unit runs — the registry and nothing
# else — then the plugin's run hook through plugin_hook_call.
DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<'DRV'
#!/usr/bin/env bash
set -uo pipefail
_zb="$1" _dir="$2" _stage="$3" _state="$4"
source "$_zb/scripts/lib/helpers.sh"
source "$_zb/core/event-bus/event-bus.sh"
source "$_zb/core/plugin-registry/registry.sh"
export ZBUILD_CURRENT_STAGE="$_stage"
plugin_hook_call "$_dir" run "$_stage" "$_state" >/dev/null 2>&1
DRV
# The probe plugin: the real plugin's manifest (its router block and calls),
# and a run hook that does what every model-calling stage does — its tier,
# its prompt composed with the engine's blocks, one call.
_probe() {  # <real plugin dir> → the probe's dir
    local real="$1" id="${1##*/}" d
    d="$TEST_TEMP_DIR/plugins/agent/$id"; mkdir -p "$d"
    sed 's/^  run: .*/  run: limits_probe_run/' "$real/manifest.yaml" > "$d/manifest.yaml"
    cat > "$d/plugin.sh" <<PLUGIN
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/router/route.sh"
limits_probe_run() {
    local tier p; tier="\$(resolve_tier $id "$d")" || tier=T2
    p="\$(stage_prompt_compose_parts --fresh \$'## What you own\nprobe\n\n## What you judge against\nnothing\n\n## What you must not do\n- nothing')" || return 1
    route_to_model "\$tier" "\$p" >/dev/null 2>&1
    return 0
}
PLUGIN
    printf '%s' "$d"
}
_role_dir() {  # <role> → the shipped plugin that provides it, or nothing
    local m; for m in "$REPO_ROOT"/plugins/agent/*/manifest.yaml; do
        [[ "$(yq -r '.provides.role // ""' "$m" 2>/dev/null)" == "$1" ]] && { printf '%s' "${m%/manifest.yaml}"; return 0; }
    done
}

# What this template has always set (CL4), stage: seconds turns.
declare -A WAS=([test-author]="900 0" [issue-acceptance]="600 0" [intake]="120 1" [design]="1200 0" [build]="900 0" [review_lenses]="900 0" [issue-check]="600 0")

_n=0
# #2640: NUL-separated: a stage with no timeout_s but a max_turns must not
# read its max_turns as its timeout.
while IFS= read -r -d '' stage && IFS= read -r -d '' role && IFS= read -r -d '' rt \
      && IFS= read -r -d '' rmt && IFS= read -r -d '' elems; do
    dir="$(_role_dir "$role")"
    [[ -n "$dir" ]] && grep -q '^calls:' "$dir/manifest.yaml" || continue
    msecs="$(yq -r '.config.router.timeout_s // ""' "$dir/manifest.yaml")"; mturns="$(yq -r '.config.router.max_turns // ""' "$dir/manifest.yaml")"
    want_s="${rt:-${msecs:-300}}" want_t="${rmt:-${mturns:-0}}"
    assert_eq "[CL4] $stage: the configured limits are unchanged" "${WAS[$stage]:-<new stage>}" "$want_s $want_t"
    probe="$(_probe "$dir")"
    for el in ${elems:-""}; do
        _n=$(( _n + 1 )); name="$stage${el:+/$el}"
        st="$TEST_TEMP_DIR/run-$_n"; mkdir -p "$st/artifacts" "$st/events"; printf '{}' > "$st/pipeline-state.json"
        export LIMITS_OUT="$TEST_TEMP_DIR/out-$_n"
        ( export ZBUILD_STATE_DIR="$st" ZBUILD_EVENTS_DIR="$st/events" ZBUILD_EVENTS_JSONL="$st/events/events.jsonl" \
              ZBUILD_INPUTS_FLOW="$stage" ZBUILD_STAGE_SCRATCH="$st/scratch"
          [[ -n "$el" ]] && export ZBUILD_REVIEW_LENS_ID="$el" ZBUILD_MAP_ELEMENT="$el"
          bash "$DRIVER" "$REPO_ROOT" "$probe" "$stage" "$st/pipeline-state.json" )
        argv="$(cat "$LIMITS_OUT.argv" 2>/dev/null)"
        [[ -n "$argv" ]] || { assert_fail "[CL1] $name: the call was made" "no argv recorded"; continue; }
        cli_t="$(awk 'p { print; exit } $0 == "--max-turns" { p = 1 }' <<< "$argv")"
        cli_s="$(jq -r 'select(.type == "model.route" or .event == "model.route") | (.timeout_s // .data.timeout_s // empty)' "$st/events/events.jsonl" 2>/dev/null | tail -n 1)"
        assert_eq "[CL1] $name: the CLI's limits are the configured ones" "$want_s ${want_t}" "$cli_s ${cli_t:-0}"
        budget="$(tr -s '[:space:]' ' ' < "$LIMITS_OUT.prompt" | grep -o 'each model call has [^.]*\.' | sed -n 1p)"
        if [[ "$want_t" -gt 0 ]]; then said="each model call has $want_s seconds and $want_t turns."
        else said="each model call has $want_s seconds, with no limit on turns."; fi
        assert_eq "[CL2] $name: the prompt's budget line says them" "$said" "$budget"
        # The hook's command, run past its deadline: the warning it gives.
        hook="$(cat "$LIMITS_OUT.hook" 2>/dev/null)"
        eval "set -- $hook"; args=("$@"); n=${#args[@]}
        if (( n >= 4 )); then
            args[n-2]=1
            warn="$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "${args[@]}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
        else warn=""; fi
        if [[ "$want_t" -gt 0 ]]; then wsaid="It was given $want_s seconds and $want_t turns."
        else wsaid="It was given $want_s seconds, with no limit on turns."; fi
        assert_contains "[CL3] $name: the time-up warning says them" "$warn" "$wsaid"
    done
done < <(yq -o=json "$TPL" | jq -j 'to_entries[] | select(.value | type == "object" and has("roles"))
    | "\(.key)\u0000\(.value.roles[0])\u0000\(.value.router.timeout_s // "")\u0000\(.value.router.max_turns // "")\u0000\([.value.elements[]?.id] | join(" "))\u0000"')
assert_eq "[CL1] fixture: every model-calling stage and lens was dispatched (6 stages, 7 lenses; #2614 adds issue-check, #2630 the tests lens)" "13" "$_n"

print_test_section "CL5: a stage's own turn limit is the record's"
# shellcheck disable=SC2016  # the probe's code, expanded when it runs
_loop_probe() {  # <real plugin dir> <loop flags> → the probe's dir
    local real="$1" id="${1##*/}" d
    d="$TEST_TEMP_DIR/loop-plugins/agent/$id"; mkdir -p "$d"
    sed 's/^  run: .*/  run: limits_loop_run/' "$real/manifest.yaml" > "$d/manifest.yaml"
    cat > "$d/plugin.sh" <<PLUGIN
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/router/route.sh"
limits_loop_run() {
    local tier p f="\$ZBUILD_STAGE_SCRATCH/prompt.txt"; tier="\$(resolve_tier $id "$d")" || tier=T2
    zb_call_limits_turns_override 7 || return 1
    p="\$(stage_prompt_compose_parts --fresh \$'## What you own\nprobe\n\n## What you judge against\nnothing\n\n## What you must not do\n- nothing')" || return 1
    mkdir -p "\$ZBUILD_STAGE_SCRATCH"; printf '%s' "\$p" > "\$f"
    route_to_model_loop "\$tier" "\$f" "\$ZBUILD_REPO_ROOT" $2 >/dev/null 2>&1
    printf '%s' "\$?" > "\$LIMITS_OUT.rc"
    return 0
}
PLUGIN
    printf '%s' "$d"
}
_loop_run() {  # <flags> → LIMITS_OUT and the run's dir in ST
    local probe; probe="$(_loop_probe "$(_role_dir builder)" "$1")"
    ST="$TEST_TEMP_DIR/loop-run-$2"; mkdir -p "$ST/artifacts" "$ST/events"; printf '{}' > "$ST/pipeline-state.json"
    export LIMITS_OUT="$TEST_TEMP_DIR/loop-out-$2"; rm -f "$LIMITS_OUT".*
    ( export ZBUILD_STATE_DIR="$ST" ZBUILD_EVENTS_DIR="$ST/events" ZBUILD_EVENTS_JSONL="$ST/events/events.jsonl" \
          ZBUILD_INPUTS_FLOW=build ZBUILD_STAGE_SCRATCH="$ST/scratch"
      bash "$DRIVER" "$REPO_ROOT" "$probe" build "$ST/pipeline-state.json" )
}
_loop_run "--max-turns-per-call 7" a
argv="$(cat "$LIMITS_OUT.argv" 2>/dev/null)"
assert_eq "[CL5] the loop's CLI gets the stage's 7 turns" "7" "$(awk 'p { print; exit } $0 == "--max-turns" { p = 1 }' <<< "$argv")"
assert_eq "[CL5] ...the prompt's budget line says them" "each model call has 900 seconds and 7 turns." \
    "$(tr -s '[:space:]' ' ' < "$LIMITS_OUT.prompt" 2>/dev/null | grep -o 'each model call has [^.]*\.' | sed -n 1p)"
hook="$(cat "$LIMITS_OUT.hook" 2>/dev/null)"; eval "set -- $hook"; args=("$@"); n=${#args[@]}
warn=""; if (( n >= 4 )); then args[n-2]=1; warn="$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "${args[@]}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"; fi
assert_contains "[CL5] ...and so does the time-up warning" "$warn" "It was given 900 seconds and 7 turns."
_loop_run "--max-turns-per-call 9" b
assert_eq "[CL5] a loop asked for 9 turns when the record says 7 is refused" "2|<no call>" \
    "$(cat "$LIMITS_OUT.rc" 2>/dev/null)|$([[ -s "$LIMITS_OUT.argv" ]] && echo called || echo '<no call>')"

print_test_results
exit $((FAIL > 0))
