#!/usr/bin/env bash
# tests/unit/stage-blocks-dispatch-test.sh — the engine hands every stage its
# three blocks at dispatch (ADR-067 §8, amended), whether or not it calls a
# model, and launches it without checking what it "needs" (ADR-055, amended).
#
#   D1 [change]: a dispatched stage sees ZBUILD_STAGE_BLOCKS with the three
#                blocks written: From the repo, Previous work, Rules
#   D2 [change]: the dispatch records what the repository and the issue looked
#                like, so a later stage can be told what moved since
#   D3 [change]: a stage is launched even when an output it once declared it
#                required is absent — a missing prerequisite is its own check
#   D4 [change]: a map element gets its own blocks and its own notes file
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
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"

print_test_header "stage blocks at dispatch — every stage, no required-input refusal"
setup_test_env "stage-blocks-dispatch"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT \
      ZBUILD_RESTORED_ARTIFACTS_DIR 2>/dev/null || true
ZBUILD_ISSUE="$(zb_test_issue)"; export ZBUILD_ISSUE

PROOT="$TEST_TEMP_DIR/plugins"
STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
REPO="$(setup_git_temp_repo sb-target)"
mkdir -p "$ART" "$PROOT/tool/sb-producer" "$PROOT/tool/sb-tool"
init_state "$STATE/pipeline-state.json" run-sb 1 >/dev/null 2>&1

cat > "$PROOT/tool/sb-producer/manifest.yaml" <<'EOF'
id: sb-producer
name: SB Producer
kind: tool
version: 0.0.1
hooks:
  run: sbp_run
outputs:
  - id: sb_producer_out
    path: ${artifact_dir}/sb-producer-out.json
    type: json
    required: true
    primary: true
  - id: sb_producer_never
    path: ${artifact_dir}/sb-producer-never.json
    type: json
    required: false
EOF
printf 'sbp_run() { return 0; }\n' > "$PROOT/tool/sb-producer/plugin.sh"

cat > "$PROOT/tool/sb-tool/manifest.yaml" <<'EOF'
id: sb-tool
name: SB Tool
kind: tool
version: 0.0.1
hooks:
  run: sbt_run
inputs:
  - id: sb_producer_never
    required: true
outputs:
  - id: sb_tool_out
    path: ${artifact_dir}/sb-tool-out.json
    type: json
    required: true
    primary: true
EOF
{
    printf '_SBT_SEEN=%q\n' "$TEST_TEMP_DIR/sbt-seen.txt"
    cat <<'FIXTURE'
sbt_run() {
    printf '{"verdict":"pass"}\n' > "${ZBUILD_STATE_DIR:?}/artifacts/sb-tool-out.json"
    {
        printf 'blocks=%s\n' "${ZBUILD_STAGE_BLOCKS-<unset>}"
        for f in from-repo previous-work rules; do
            printf '%s=%s\n' "$f" "$([[ -s "${ZBUILD_STAGE_BLOCKS:-/nonexistent}/$f.md" ]] && echo present || echo absent)"
        done
    } > "$_SBT_SEEN"
    [[ -n "${ZBUILD_STAGE_BLOCKS:-}" ]] && cp "$ZBUILD_STAGE_BLOCKS"/*.md "$(dirname "$_SBT_SEEN")/" 2>/dev/null
    return 0
}
FIXTURE
} > "$PROOT/tool/sb-tool/plugin.sh"

_TPL_STAGES=(sb-producer sb-tool)
printf '{"marker":"PRODUCED"}\n' > "$ART/sb-producer-out.json"
printf '# the issue\n' > "$STATE/intake.md"
_seen() { grep "^$1=" "$TEST_TEMP_DIR/sbt-seen.txt" 2>/dev/null | head -1 | cut -d= -f2-; }

EVENTS="$TEST_TEMP_DIR/events.jsonl"
rc=0
ZBUILD_EVENTS_JSONL="$EVENTS" ZBUILD_EVENTS_DB=/dev/null ZBUILD_STATE_DIR="$STATE" \
ZBUILD_REPO_ROOT="$REPO" ZBUILD_CURRENT_STAGE=sb-tool \
    plugin_hook_call "$PROOT/tool/sb-tool" run sb-tool "$STATE/pipeline-state.json" \
    >/dev/null 2>"$TEST_TEMP_DIR/d1.err" || rc=$?

assert_eq "[D3] launched although a once-required output is absent (rc=0)" "0" "$rc"
assert_file_exists "[D3] the stage ran" "$TEST_TEMP_DIR/sbt-seen.txt"
assert_eq "[D1] the stage saw its blocks directory" "$STATE/runtime/blocks/sb-tool" "$(_seen blocks)"
assert_eq "[D1] From the repo was written" "present" "$(_seen from-repo)"
assert_eq "[D1] Previous work was written" "present" "$(_seen previous-work)"
assert_eq "[D1] Rules were written" "present" "$(_seen rules)"
assert_contains "[D1] Previous work lists the producer's output" \
    "$(cat "$TEST_TEMP_DIR/previous-work.md" 2>/dev/null)" "$ART/sb-producer-out.json"
assert_contains "[D1] Rules: a tool calls no model" \
    "$(cat "$TEST_TEMP_DIR/rules.md" 2>/dev/null)" "calls no model"
assert_file_exists "[D2] what the repository and issue looked like is recorded" \
    "$ART/stage-context/sb-tool.txt"
assert_eq "[D2] the recorded HEAD is the repository's" \
    "$(git -C "$REPO" rev-parse HEAD)" "$(head -n1 "$ART/stage-context/sb-tool.txt" 2>/dev/null)"

# D4: a map element
rm -f "$TEST_TEMP_DIR/sbt-seen.txt"
ZBUILD_EVENTS_JSONL="$EVENTS" ZBUILD_EVENTS_DB=/dev/null ZBUILD_STATE_DIR="$STATE" \
ZBUILD_REPO_ROOT="$REPO" ZBUILD_CURRENT_STAGE=sb-tool ZBUILD_MAP_ELEMENT=alpha \
    plugin_hook_call "$PROOT/tool/sb-tool" run sb-tool "$STATE/pipeline-state.json" \
    >/dev/null 2>&1 || true
assert_eq "[D4] a map element's own blocks" "$STATE/runtime/blocks/sb-tool-alpha" "$(_seen blocks)"
assert_contains "[D4] … and its own notes file" \
    "$(cat "$TEST_TEMP_DIR/rules.md" 2>/dev/null)" "notes/sb-tool-alpha.md"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
