#!/usr/bin/env bash
# Tests (#2186): the engine records, per dispatch, which of a stage's declared
# outputs THIS run changed. It never learns what an output means — it compares
# the file before and after the run hook.
#
# #1849 run 35949629759: the engine acted on a build-summary.json that no stage
# of the running cycle had written. An output the run did not touch is not fresh
# from that run, and the record has to say so.
#
# SPEC-1 [change]: a declared output the run rewrote is recorded `changed`; one
#   it left as it was is recorded `unchanged`, in that attempt's attempt.json.
# SPEC-2 [change]: a dispatch that left any declared output unchanged emits
#   stage.outputs.unchanged naming them.
# SPEC-3 [guard] : a dispatch that rewrote every declared output emits no
#   stage.outputs.unchanged.
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

print_test_header "output freshness: which declared outputs a dispatch changed (#2186)"
setup_test_env "output-freshness"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/ev"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="/dev/null"

PDIR="$TEST_TEMP_DIR/plugins/tool/fr-stage"; mkdir -p "$PDIR"
cat > "$PDIR/manifest.yaml" <<'EOF'
id: fr-stage
name: fr-stage
kind: tool
version: 0.0.1
hooks:
  run: fr_stage_run
inputs: []
outputs:
  - id: fr_result
    path: ${artifact_dir}/fr-result.json
    type: json
    required: true
    primary: true
  - id: fr_summary
    path: ${artifact_dir}/fr-summary.md
    type: markdown
    required: false
EOF
# FR_WRITE_SUMMARY=1 makes the run rewrite the summary as well as the result.
cat > "$PDIR/plugin.sh" <<'EOF'
fr_stage_run() {
    local art; art="$(dirname "$2")/artifacts"
    printf '{"verdict":"pass","n":%s}\n' "$RANDOM" > "$art/fr-result.json"
    [[ "${FR_WRITE_SUMMARY:-0}" == "1" ]] && printf 'new %s\n' "$RANDOM" > "$art/fr-summary.md"
    return 0
}
EOF

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; mkdir -p "$ART"
printf '{"schema_version":1}\n' > "$STATE/pipeline-state.json"

_latest_attempt() {
    find "$ART/attempts/fr-stage" -name attempt.json 2>/dev/null | sort | tail -1
}

# ─── SPEC-1/2: the summary is left over from an earlier dispatch ─────────────
print_test_section "SPEC-1/2: an output the run did not touch is recorded unchanged"
printf '{"verdict":"pass","n":0}\n' > "$ART/fr-result.json"
printf 'old summary from an earlier pass\n' > "$ART/fr-summary.md"
: > "$ZBUILD_EVENTS_JSONL"
FR_WRITE_SUMMARY=0 plugin_hook_call "$PDIR" run "fr-stage" "$STATE/pipeline-state.json" >/dev/null 2>&1
_a="$(_latest_attempt)"
assert_eq "[SPEC-1] the rewritten output is recorded changed" "changed" \
    "$(jq -r '.outputs["fr-result.json"] // "MISSING"' "$_a" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-1] the untouched output is recorded unchanged" "unchanged" \
    "$(jq -r '.outputs["fr-summary.md"] // "MISSING"' "$_a" 2>/dev/null || echo MISSING)"
_ev="$(grep '"stage.outputs.unchanged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
if [[ -n "$_ev" ]] && grep -q 'fr-summary.md' <<< "$_ev"; then
    assert_pass "[SPEC-2] stage.outputs.unchanged names the untouched output"
else
    assert_fail "[SPEC-2] stage.outputs.unchanged missing or does not name fr-summary.md" \
        "events: $(cat "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"
fi

# ─── SPEC-3: every output rewritten → no unchanged event ─────────────────────
print_test_section "SPEC-3: a run that rewrote everything reports nothing unchanged"
: > "$ZBUILD_EVENTS_JSONL"
FR_WRITE_SUMMARY=1 plugin_hook_call "$PDIR" run "fr-stage" "$STATE/pipeline-state.json" >/dev/null 2>&1
_a="$(_latest_attempt)"
assert_eq "[SPEC-3] the summary is recorded changed this time" "changed" \
    "$(jq -r '.outputs["fr-summary.md"] // "MISSING"' "$_a" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-3] no stage.outputs.unchanged when every output changed" "0" \
    "$(grep -c '"stage.outputs.unchanged"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"

print_test_results
exit $((FAIL > 0))
