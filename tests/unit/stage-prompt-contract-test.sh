#!/usr/bin/env bash
# tests/unit/stage-prompt-contract-test.sh — the engine/stage prompt contract
# (ADR-067 §8, amended).
#
# Every stage receives the same three blocks from the engine: what comes from
# the repository, the previous work, and the rules for the stage. A stage that
# calls a model writes only its own three parts and hands them to one library,
# which puts every prompt in the same order:
#
#   From the repo → What you own → What you judge against → Previous work →
#   What you must not do → Rules for this stage
#
#   K1 [change]: stage_prompt_compose writes the six sections in that order
#   K2 [change]: it refuses (rc≠0, nothing written) when the engine blocks are absent
#   K3 [change]: it refuses an empty stage part
#   K4 [change]: stage_prompt_check accepts the contract and rejects a missing
#                or out-of-order section
#   K5 [change]: stage_prompt_compose_parts takes the stage's text under its
#                three headings (any lead-in goes with What you own) and composes
#                the same contract; a text missing a part is refused
#   F1 [change]: From the repo reads the TARGET repository's .zbuild/: its
#                vision, its rules, and this stage's guidance
#   F2 [change]: without them: no intent stated, zBuild's default rules from the
#                install, no guidance section; a docs/VISION.md is not read
#   P1 [change]: Previous work lists the latest output of every stage that has
#                run, including the stage's own, with its summary inline
#   P2 [change]: a stage's output from an earlier run is listed like any other
#   P3 [change]: no engine framing ("its findings, to answer") and no stage is
#                dropped to fit a total size
#   P4 [retired]: (#2363) what moved since a stage last ran — replaced by one
#                line at the top (engine-blocks-shared-only-test B2)
#   P5 [guard] : (ported from the summaries block) a summary over its own cap is
#                cut with a marker that names the file holding the rest
#   P6 [guard] : (ported) a failing stage's declared error output ships with it
#   P7 [guard] : (ported) stages are listed in the order they first completed
#   P8 [change]: an aggregator's members are listed as well as the aggregator
#   R1 [change]: Rules carry the own-job rule, the notes file, the shared rules
#   R2 [change]: the read-only rule appears only for a stage that may not
#                change the repository
#   R3 [change]: the budget comes from the limits the engine enforces: seconds
#                and turns per model call — the same for every stage, with no
#                declaration from the stage about how it calls a model
#   F4 [change]: the repository block's cache is written whole or not at all —
#                a write that fails part-way leaves no cache for the next stage
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/state/resume.sh
source "$REPO_ROOT/core/state/resume.sh"
# shellcheck source=../../core/pipeline/state_helpers.sh
source "$REPO_ROOT/core/pipeline/state_helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/stage-prompt.sh
source "$REPO_ROOT/scripts/lib/stage-prompt.sh"

assert_not_contains() {
    if grep -qF -- "$3" <<< "$2" 2>/dev/null; then
        assert_fail "$1" "output unexpectedly has: $3"
    else
        assert_pass "$1"
    fi
}

print_test_header "stage prompt contract — three engine blocks, one order"
setup_test_env "stage-prompt-contract"
unset ZBUILD_STAGE_INPUTS ZBUILD_STAGE_BLOCKS ZBUILD_INPUTS_FLOW ZBUILD_MAP_ELEMENT \
      ZBUILD_ROUTER_TIMEOUT ZBUILD_ROUTER_MAX_TURNS ZBUILD_ROUTER_MAX_ITERATIONS 2>/dev/null || true

# ─── K: compose and check ────────────────────────────────────────────────────
BL="$TEST_TEMP_DIR/blocks"
mkdir -p "$BL"
printf 'REPO-BODY\n' > "$BL/from-repo.md"
printf 'PREV-BODY\n' > "$BL/previous-work.md"
printf 'RULES-BODY\n' > "$BL/rules.md"
printf 'OWN-BODY\n' > "$TEST_TEMP_DIR/own.md"
printf 'JUDGE-BODY\n' > "$TEST_TEMP_DIR/judge.md"
printf 'LIMITS-BODY\n' > "$TEST_TEMP_DIR/limits.md"

OUT="$TEST_TEMP_DIR/prompt.md"
rc=0
ZBUILD_STAGE_BLOCKS="$BL" stage_prompt_compose "$OUT" "$TEST_TEMP_DIR/own.md" \
    "$TEST_TEMP_DIR/judge.md" "$TEST_TEMP_DIR/limits.md" || rc=$?
assert_eq "[K1] compose rc=0" "0" "$rc"
order="$(/usr/bin/grep -E '^## ' "$OUT" 2>/dev/null | tr '\n' '|')"
assert_eq "[K1] the six sections, in the contract order" \
    "## From the repo|## What you own|## What you judge against|## Previous work|## What you must not do|## Rules for this stage|" \
    "$order"
bodies="$(/usr/bin/grep -E 'BODY$' "$OUT" 2>/dev/null | tr '\n' '|')"
assert_eq "[K1] each body sits under its own section" \
    "REPO-BODY|OWN-BODY|JUDGE-BODY|PREV-BODY|LIMITS-BODY|RULES-BODY|" "$bodies"

OUT2="$TEST_TEMP_DIR/prompt2.md"
rc=0
ZBUILD_STAGE_BLOCKS="$TEST_TEMP_DIR/no-such-dir" stage_prompt_compose "$OUT2" \
    "$TEST_TEMP_DIR/own.md" "$TEST_TEMP_DIR/judge.md" "$TEST_TEMP_DIR/limits.md" 2>/dev/null || rc=$?
assert_eq "[K2] no engine blocks → refused" "1" "$rc"
assert_eq "[K2] … and nothing written" "no" "$([[ -e "$OUT2" ]] && echo yes || echo no)"

: > "$TEST_TEMP_DIR/empty.md"
rc=0
ZBUILD_STAGE_BLOCKS="$BL" stage_prompt_compose "$OUT2" "$TEST_TEMP_DIR/own.md" \
    "$TEST_TEMP_DIR/empty.md" "$TEST_TEMP_DIR/limits.md" 2>/dev/null || rc=$?
assert_eq "[K3] an empty stage part → refused" "1" "$rc"

rc=0; stage_prompt_check "$OUT" || rc=$?
assert_eq "[K4] a composed prompt passes the check" "0" "$rc"
/usr/bin/grep -v '^## Previous work$' "$OUT" > "$TEST_TEMP_DIR/missing.md"
rc=0; stage_prompt_check "$TEST_TEMP_DIR/missing.md" || rc=$?
assert_eq "[K4] a missing section fails the check" "1" "$rc"
printf '## What you own\nx\n## From the repo\nx\n## What you judge against\nx\n## Previous work\nx\n## What you must not do\nx\n## Rules for this stage\nx\n' \
    > "$TEST_TEMP_DIR/swapped.md"
rc=0; stage_prompt_check "$TEST_TEMP_DIR/swapped.md" || rc=$?
assert_eq "[K4] sections out of order fail the check" "1" "$rc"

# K5: the stage's text under its own three headings
STAGE_TEXT="$(printf 'LEAD-IN\n\n## What you own\nOWN-BODY\n\n## What you judge against\nJUDGE-BODY\n\n## What you must not do\nLIMITS-BODY\n')"
rc=0
k5="$(ZBUILD_STAGE_BLOCKS="$BL" stage_prompt_compose_parts "$STAGE_TEXT")" || rc=$?
assert_eq "[K5] composed from the stage's text (rc=0)" "0" "$rc"
assert_eq "[K5] the six sections, in order" \
    "## From the repo|## What you own|## What you judge against|## Previous work|## What you must not do|## Rules for this stage|" \
    "$(/usr/bin/grep -E '^## ' <<< "$k5" | tr '\n' '|')"
assert_eq "[K5] the lead-in goes with What you own" \
    "REPO-BODY|LEAD-IN|OWN-BODY|JUDGE-BODY|PREV-BODY|LIMITS-BODY|RULES-BODY|" \
    "$(/usr/bin/grep -E 'BODY$|^LEAD-IN$' <<< "$k5" | tr '\n' '|')"
rc=0
ZBUILD_STAGE_BLOCKS="$BL" stage_prompt_compose_parts "$(printf '## What you own\nx\n## What you must not do\ny\n')" >/dev/null 2>&1 || rc=$?
assert_eq "[K5] a text missing a part is refused" "1" "$rc"

# ─── F: From the repo ────────────────────────────────────────────────────────
TGT="$TEST_TEMP_DIR/target"
mkdir -p "$TGT/.zbuild/prompts" "$TGT/docs"
printf '## Intent\nTARGET-INTENT\n## Principles\n- p\n' > "$TGT/.zbuild/vision.md"
printf 'TARGET-RULE: write tabs\n' > "$TGT/.zbuild/prompts/rules.md"
printf 'TARGET-GUIDANCE for pc-agent\n' > "$TGT/.zbuild/prompts/pc-agent-overrides.md"
fr="$(_stage_block_from_repo pc-agent "$TGT")"
assert_contains "[F1] the repository's intent" "$fr" "TARGET-INTENT"
assert_contains "[F1] the repository's rules" "$fr" "TARGET-RULE: write tabs"
assert_contains "[F1] this stage's guidance from the repository" "$fr" "TARGET-GUIDANCE for pc-agent"
fr_other="$(_stage_block_from_repo other-stage "$TGT")"
assert_not_contains "[F1] another stage's guidance is not given" "$fr_other" "TARGET-GUIDANCE"

BARE="$TEST_TEMP_DIR/bare"
mkdir -p "$BARE/docs"
printf '## Intent\nDOCS-VISION-NOT-READ\n' > "$BARE/docs/VISION.md"
fb="$(_stage_block_from_repo pc-agent "$BARE")"
assert_not_contains "[F2] a docs/VISION.md is not read" "$fb" "DOCS-VISION-NOT-READ"
assert_contains "[F2] says the repository states no intent" "$fb" "states no intent"
default_rule="$(/usr/bin/grep -m1 '^- ' "$REPO_ROOT/config/prompts/default-rules.md")"
assert_contains "[F2] zBuild's default rules, from the install" "$fb" "$default_rule"
assert_not_contains "[F2] no guidance section without a file" "$fb" "### Guidance for this stage"

# ─── P: Previous work ────────────────────────────────────────────────────────
PROOT="$TEST_TEMP_DIR/plugins"
STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
mkdir -p "$ART" "$PROOT/tool/pc-gate" "$PROOT/agent/pc-agent" "$PROOT/tool/pc-old"
for s in pc-gate pc-old; do
    cat > "$PROOT/tool/$s/manifest.yaml" <<EOF
id: $s
name: $s
kind: tool
version: 0.0.1
hooks:
  run: x_run
outputs:
  - id: ${s//-/_}_result
    path: \${artifact_dir}/$s-result.json
    type: json
    required: true
    primary: true
  - id: ${s//-/_}_detail
    path: \${artifact_dir}/$s-detail.md
    type: text
    format: markdown
    required: false
    summary: true
EOF
    printf 'x_run() { return 0; }\n' > "$PROOT/tool/$s/plugin.sh"
done
cat > "$PROOT/agent/pc-agent/manifest.yaml" <<'EOF'
id: pc-agent
name: pc-agent
kind: agent
version: 0.0.1
hooks:
  run: x_run
outputs:
  - id: pc_agent_result
    path: ${artifact_dir}/pc-agent-result.json
    type: json
    required: true
    primary: true
  - id: pc_agent_summary
    path: ${artifact_dir}/pc-agent-summary.md
    type: text
    format: markdown
    required: false
    summary: true
EOF
printf 'x_run() { return 0; }\n' > "$PROOT/agent/pc-agent/plugin.sh"
_TPL_STAGES=(pc-old pc-gate pc-agent)

init_state "$STATE/pipeline-state.json" run-1 7 >/dev/null 2>&1
_update_stage_status "$STATE/pipeline-state.json" pc-gate complete
_zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" pc-gate fail
_update_stage_status "$STATE/pipeline-state.json" pc-agent complete
_zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" pc-agent pass
printf '{"result_contract":2,"verdict":"fail","disposition":"complete"}\n' > "$ART/pc-gate-result.json"
printf 'GATE-SUMMARY: two checks red\n' > "$ART/pc-gate-detail.md"
printf '{"result_contract":2,"verdict":"pass","disposition":"complete"}\n' > "$ART/pc-agent-result.json"
printf 'AGENT-OWN-SUMMARY\n' > "$ART/pc-agent-summary.md"
# pc-old ran in an EARLIER run: its output is here (hydrate put it back), it has
# no status in this run's state.
printf '{"result_contract":2,"verdict":"pass","disposition":"complete"}\n' > "$ART/pc-old-result.json"
printf 'OLD-RUN-SUMMARY\n' > "$ART/pc-old-detail.md"

idx="$(_inputs_resolve_stage pc-agent "$PROOT" "$STATE")"
pw="$(_stage_block_previous_work pc-agent "$STATE" "$PROOT" "$idx" "$TGT")"
assert_contains "[P1] another stage's summary inline" "$pw" "GATE-SUMMARY: two checks red"
assert_contains "[P1] another stage's output path" "$pw" "$ART/pc-gate-result.json"
assert_contains "[P1] the stage's OWN latest summary" "$pw" "AGENT-OWN-SUMMARY"
assert_contains "[P1] the stage's own output path" "$pw" "$ART/pc-agent-result.json"
assert_contains "[P2] an earlier run's output, listed like any other" "$pw" "OLD-RUN-SUMMARY"
assert_not_contains "[P2] no earlier-run label" "$pw" "earlier run"
assert_not_contains "[P3] no engine framing" "$pw" "its findings, to answer"
assert_contains "[P3] the verdict, as the stage wrote it" "$pw" "pc-gate (verdict: fail)"
index_ids="$(jq -r '.inputs | keys | join(",")' "$idx" 2>/dev/null)"
assert_contains "[P1] the index carries every stage's outputs" "$index_ids" "pc_gate_result"
assert_contains "[P1] … including the stage's own" "$index_ids" "pc_agent_result"

# P3: many stages, none dropped to fit a total
for i in 1 2 3 4 5 6 7 8; do
    mkdir -p "$PROOT/tool/pc-many$i"
    sed "s/pc-gate/pc-many$i/g; s/pc_gate/pc_many$i/g" "$PROOT/tool/pc-gate/manifest.yaml" \
        > "$PROOT/tool/pc-many$i/manifest.yaml"
    printf 'x_run() { return 0; }\n' > "$PROOT/tool/pc-many$i/plugin.sh"
    head -c 7000 /dev/zero | tr '\0' 'x' > "$ART/pc-many$i-detail.md"
    printf '\nMANY-%s-END\n' "$i" >> "$ART/pc-many$i-detail.md"
    _update_stage_status "$STATE/pipeline-state.json" "pc-many$i" complete
done
_TPL_STAGES=(pc-old pc-gate pc-many1 pc-many2 pc-many3 pc-many4 pc-many5 pc-many6 pc-many7 pc-many8 pc-agent)
_IR_INDEX_KEY=""; _IR_SCAN_KEY=""
idx="$(_inputs_resolve_stage pc-agent "$PROOT" "$STATE")"
pw="$(_stage_block_previous_work pc-agent "$STATE" "$PROOT" "$idx" "$TGT")"
assert_contains "[P3] the first of many stages is kept" "$pw" "MANY-1-END"
assert_contains "[P3] the last of many stages is kept" "$pw" "MANY-8-END"
assert_not_contains "[P3] no total-size elision marker" "$pw" "earlier stage summaries truncated"

# P5: a summary over its own cap is cut, and says where the rest is
head -c 9000 /dev/zero | tr '\0' 'y' > "$ART/pc-many1-detail.md"
pw="$(_stage_block_previous_work pc-agent "$STATE" "$PROOT" "$idx" "$TGT")"
assert_contains "[P5] an over-long summary is cut with a marker naming the file" "$pw" \
    "read $ART/pc-many1-detail.md for the rest"

# P7: completion order (the key order of .stage_statuses), not template order
first_two="$(/usr/bin/grep -E '^### ' <<< "$pw" | awk 'NR<=2' | tr '\n' '|')"
assert_eq "[P7] listed in the order the stages first completed" \
    "### pc-gate (verdict: fail)|### pc-agent (verdict: pass) — your own|" "$first_two"

# P6: a failing stage's declared error output ships with it
mkdir -p "$PROOT/tool/pc-err"
cat > "$PROOT/tool/pc-err/manifest.yaml" <<'EOF'
id: pc-err
name: pc-err
kind: tool
version: 0.0.1
hooks:
  run: x_run
outputs:
  - id: pc_err_result
    path: ${artifact_dir}/pc-err-result.json
    type: json
    required: true
    primary: true
  - id: pc_err_summary
    path: ${artifact_dir}/pc-err-summary.md
    type: text
    format: markdown
    required: false
    summary: true
  - id: pc_err_stderr
    path: ${artifact_dir}/pc-err-stderr.txt
    type: text
    format: text
    required: false
    errors: true
EOF
printf 'x_run() { return 0; }\n' > "$PROOT/tool/pc-err/plugin.sh"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete"}\n' > "$ART/pc-err-result.json"
printf 'ERR-SUMMARY\n' > "$ART/pc-err-summary.md"
printf 'THE-NESTED-STDERR\n' > "$ART/pc-err-stderr.txt"
_update_stage_status "$STATE/pipeline-state.json" pc-err complete
_zbuild_state_set_stage_verdict "$STATE/pipeline-state.json" pc-err fail
_TPL_STAGES+=(pc-err)
_IR_INDEX_KEY=""; _IR_SCAN_KEY=""
idx="$(_inputs_resolve_stage pc-agent "$PROOT" "$STATE")"
pw="$(_stage_block_previous_work pc-agent "$STATE" "$PROOT" "$idx" "$TGT")"
assert_contains "[P6] a failing stage's errors ship with it" "$pw" "THE-NESTED-STDERR"

# P8: an aggregator and its members are all listed
mkdir -p "$PROOT/tool/pc-agg"
sed 's/pc-err/pc-agg/g; s/pc_err/pc_agg/g' "$PROOT/tool/pc-err/manifest.yaml" \
    | awk '/^hooks:/ { print "aggregates: gate" } { print }' > "$PROOT/tool/pc-agg/manifest.yaml"
printf 'x_run() { return 0; }\n' > "$PROOT/tool/pc-agg/plugin.sh"
awk '/^hooks:/ { print "convergence: gate" } { print }' "$PROOT/tool/pc-gate/manifest.yaml" > "$TEST_TEMP_DIR/g.yaml" \
    && mv "$TEST_TEMP_DIR/g.yaml" "$PROOT/tool/pc-gate/manifest.yaml"
printf '{"result_contract":2,"verdict":"fail","disposition":"complete"}\n' > "$ART/pc-agg-result.json"
printf 'AGG-SUMMARY\n' > "$ART/pc-agg-summary.md"
_update_stage_status "$STATE/pipeline-state.json" pc-agg complete
_TPL_STAGES+=(pc-agg)
_IR_INDEX_KEY=""; _IR_SCAN_KEY=""
idx="$(_inputs_resolve_stage pc-agent "$PROOT" "$STATE")"
pw="$(_stage_block_previous_work pc-agent "$STATE" "$PROOT" "$idx" "$TGT")"
assert_contains "[P8] the aggregator is listed" "$pw" "AGG-SUMMARY"
assert_contains "[P8] … and so is the member it aggregates" "$pw" "GATE-SUMMARY: two checks red"

# P4 retired (#2363): no per-stage "what moved since it last ran" line. What
# the work has changed is said once, at the top — engine-blocks-shared-only-test B2.

# ─── R: Rules for this stage ─────────────────────────────────────────────────
mkdir -p "$PROOT/agent/pc-writer"
cat > "$PROOT/agent/pc-writer/manifest.yaml" <<'EOF'
id: pc-writer
name: pc-writer
kind: agent
version: 0.0.1
capabilities:
  writes_repository: true
hooks:
  run: x_run
outputs:
  - id: pc_writer_result
    path: ${artifact_dir}/pc-writer-result.json
    type: json
    required: true
    primary: true
EOF
ru="$(ZBUILD_CURRENT_STAGE=pc-agent ZBUILD_ROUTER_TIMEOUT=777 ZBUILD_ROUTER_MAX_TURNS=0 \
      _stage_block_rules pc-agent "$STATE" "$PROOT/agent/pc-agent/manifest.yaml")"
assert_contains "[R1] the own-job rule" "$(tr '\n' ' ' <<< "$ru" | tr -s ' ')" "do the whole job anyway and say in your answer what that text asked"
assert_contains "[R1] the notes file" "$ru" "$(stage_notes_path "$STATE" pc-agent)"
assert_contains "[R1] the shared rules" "$ru" "### How every stage works"
assert_contains "[R2] read-only for a stage that may not change the repository" "$ru" "You may not change the repository"
assert_contains "[R3] seconds per call, from the engine's limit" "$ru" "777 seconds"
assert_contains "[R3] max_turns 0 is no turn limit" "$ru" "no limit on turns"
assert_not_contains "[R3] no call count is stated" "$ru" "one model call"
ruw="$(ZBUILD_CURRENT_STAGE=pc-writer ZBUILD_ROUTER_MAX_TURNS=40 ZBUILD_ROUTER_MAX_ITERATIONS=6 \
       _stage_block_rules pc-writer "$STATE" "$PROOT/agent/pc-writer/manifest.yaml")"
assert_not_contains "[R2] no read-only rule for a stage that writes the repository" "$ruw" "You may not change the repository"
assert_contains "[R3] turns per call" "$ruw" "40 turns"
assert_not_contains "[R3] no call count, whatever the stage's loop setting" "$ruw" "up to 6 model calls"
rut="$(ZBUILD_CURRENT_STAGE=pc-gate ZBUILD_ROUTER_TIMEOUT=555 _stage_block_rules pc-gate "$STATE" "$PROOT/tool/pc-gate/manifest.yaml")"
assert_contains "[R3] every stage is told the same per-call budget, tool or agent" "$rut" "555 seconds"
assert_eq "[R3] no manifest declares how it calls a model" "" \
    "$(grep -l 'model_calls:' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"

# ─── F4: the from-repo cache is never left half-written ─────────────────────
print_test_section "F4: a failed cache write leaves no cache"
_f4_cache="$TEST_TEMP_DIR/f4/from-repo.md"
(
    _sp_repo_intent_and_rules() { printf 'PARTIAL-F4\n'; return 1; }
    _stage_block_from_repo pc-agent "$TGT" "$_f4_cache" >/dev/null 2>&1
)
assert_eq "[F4] no cache file after a failed write" "absent" \
    "$([[ -e "$_f4_cache" ]] && echo present || echo absent)"
assert_not_contains "[F4] the next stage does not read the partial text" \
    "$(_stage_block_from_repo pc-agent "$TGT" "$_f4_cache" 2>/dev/null)" "PARTIAL-F4"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
