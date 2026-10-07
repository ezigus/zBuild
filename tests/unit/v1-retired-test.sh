#!/usr/bin/env bash
# tests/unit/v1-retired-test.sh — #1850 (ADR-054 §4/§5): the engine reads result
# contract v2 only, and a stage that leaves no readable v2 result has failed.
#
# Versioned coexistence (#1824) let plugins move to v2 one at a time. Every
# dispatched stage has now moved, so the scaffolding comes out — and with it the
# lenient defaults that sat upstream of any version check. Those fired when there
# was no result to read a version from, which is exactly the case ADR-054 calls
# `broken`: a stage that crashed before writing anything still "passed".
#
# R1 [change] a stage plugin (one that declares a primary output) declaring no
#             result_contract is refused at load, naming the plugin and the
#             accepted range
# R2 [change] a stage plugin declaring result_contract: 1 is refused at load
# R3 [guard]  a plugin with no primary output (persona, backend) writes no stage
#             result, so it declares no contract and still loads
# R4 [change] each lenient default of runner_read_stage_verdict, at rc 0, is a
#             structural failure — verdict `error`, reason contract_violation:*,
#             on the classified and raw channels both:
#               no manifest · no primary declared · a JSON result with no
#               result_contract (the old v1 shape, verdict or not) · a non-JSON
#               primary · an absent primary
# R5 [change] the `<stage>-verdict.json` sidecar is not a verdict source: a
#             non-JSON primary with a passing sidecar is still a failure, and
#             _verdict_read_stage_sidecar no longer exists
# R6 [change] the legacy rc mapping is gone: dispatch_rc_legacy_reason and
#             dispatch_rc_legacy_disposition no longer exist
# R7 [guard]  a stage that died (rc≠0) leaving no result is still classified by
#             how it died: killed → interrupted, otherwise broken — the absent
#             result is not mistaken for a contract violation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "result contract v1 is retired (#1850, ADR-054 §4/§5)"
setup_test_env "v1-retired"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../core/pipeline/dispatch-rc.sh
source "$REPO_ROOT/core/pipeline/dispatch-rc.sh"

STATE_DIR="$TEST_TEMP_DIR/state"
ART="$STATE_DIR/artifacts"
mkdir -p "$ART"

# _manifest <dir> <id> <kind> <contract|""> <primary path|""> — a primary path of
# "" declares no outputs at all.
_manifest() {
    local dir="$1" id="$2" kind="$3" contract="$4" prim="$5"
    mkdir -p "$dir"
    {
        printf 'id: %s\nname: %s\nkind: %s\nversion: 0.1.0\n' "$id" "$id" "$kind"
        if [[ "$kind" == persona ]]; then
            printf 'persona:\n  role: a reviewer\n  perspective: "Look for problems."\n'
        else
            printf 'hooks:\n  run: %s_run\n' "${id//-/_}"
        fi
        [[ -n "$contract" ]] && printf 'provides:\n  result_contract: %s\n' "$contract"
        printf 'inputs: []\n'
        if [[ -n "$prim" ]]; then
            printf 'outputs:\n  - id: result\n    path: %s\n    type: json\n    required: true\n    primary: true\n' "$prim"
        fi
        [[ "$kind" == persona ]] || printf 'config:\n  valid_verdicts: [pass, fail]\n'
    } > "$dir/manifest.yaml"
}

# ─── R1/R2/R3: refused at load ──────────────────────────────────────────────
print_test_section "R1–R3: a stage plugin must declare v2; a plugin with no stage result need not"
_manifest "$TEST_TEMP_DIR/m/undeclared" undeclared-stage tool "" '${artifact_dir}/u-result.json'
_manifest "$TEST_TEMP_DIR/m/v1"         v1-stage         tool 1  '${artifact_dir}/v1-result.json'
_manifest "$TEST_TEMP_DIR/m/v2"         v2-stage         tool 2  '${artifact_dir}/v2-result.json'
_manifest "$TEST_TEMP_DIR/m/backend"    some-backend     tool "" ""
_manifest "$TEST_TEMP_DIR/m/persona"    some-persona     persona "" ""

_load() { validate_manifest "$1/manifest.yaml" 2>&1; }
set +e
_out_u="$(_load "$TEST_TEMP_DIR/m/undeclared")"; _rc_u=$?
_out_1="$(_load "$TEST_TEMP_DIR/m/v1")"; _rc_1=$?
_load "$TEST_TEMP_DIR/m/v2" >/dev/null; _rc_2=$?
_load "$TEST_TEMP_DIR/m/backend" >/dev/null; _rc_b=$?
_load "$TEST_TEMP_DIR/m/persona" >/dev/null; _rc_p=$?
set -e
assert_eq "[R1] a stage plugin declaring no result_contract is refused" "1" "$_rc_u"
assert_contains "[R1] ...naming the plugin" "$_out_u" "undeclared-stage"
assert_contains "[R1] ...and the accepted range" "$_out_u" "2..2"
assert_eq "[R2] a stage plugin declaring result_contract: 1 is refused" "1" "$_rc_1"
assert_contains "[R2] ...naming the plugin" "$_out_1" "v1-stage"
assert_eq "[R3] guard: a v2 stage plugin loads" "0" "$_rc_2"
assert_eq "[R3] a backend with no primary output loads without a contract" "0" "$_rc_b"
assert_eq "[R3] a persona loads without a contract" "0" "$_rc_p"

# ─── R4/R5: the lenient defaults are failures ───────────────────────────────
print_test_section "R4/R5: a stage that leaves no readable v2 result has failed (rc 0)"
# _case <label> <manifest dir> <stage> — reads both channels at rc 0.
_case() {
    local label="$1" mdir="$2" stage="$3" cls raw why
    cls="$(runner_read_stage_verdict "$STATE_DIR" "$mdir/manifest.yaml" "$stage" 0 2>/dev/null)"
    raw="$(runner_read_stage_verdict_raw "$STATE_DIR" "$mdir/manifest.yaml" "$stage" 0 2>/dev/null)"
    why="$(runner_read_stage_reason "$STATE_DIR" "$mdir/manifest.yaml" "$stage" 0 2>/dev/null)"
    assert_eq "[$label] the verdict is a structural failure (error)" "error" "$cls"
    assert_eq "[$label] ...on the raw channel too" "error" "$raw"
    assert_contains "[$label] ...and the reason says it is a contract violation" "$why" "contract_violation:"
}

_case "R4 no manifest" "$TEST_TEMP_DIR/m/nonexistent" ghost

_manifest "$TEST_TEMP_DIR/m/noprim" no-primary tool 2 ""
_case "R4 no primary declared" "$TEST_TEMP_DIR/m/noprim" no-primary

_manifest "$TEST_TEMP_DIR/m/json" json-stage tool 2 '${artifact_dir}/json-result.json'
printf '{"verdict":"pass"}' > "$ART/json-result.json"
_case "R4 a v1-shape result (no result_contract) with a verdict" "$TEST_TEMP_DIR/m/json" json-stage
printf '{"files":[]}' > "$ART/json-result.json"
_case "R4 a v1-shape result with no verdict" "$TEST_TEMP_DIR/m/json" json-stage

_manifest "$TEST_TEMP_DIR/m/md" md-stage tool 2 '${artifact_dir}/md-stage.md'
printf '# a document\n' > "$ART/md-stage.md"
_case "R4 a non-JSON primary, present" "$TEST_TEMP_DIR/m/md" md-stage
printf '{"verdict":"pass"}' > "$ART/md-stage-verdict.json"
_case "R5 a non-JSON primary with a passing sidecar" "$TEST_TEMP_DIR/m/md" md-stage

_manifest "$TEST_TEMP_DIR/m/absent" absent-stage tool 2 '${artifact_dir}/absent-result.json'
_case "R4 an absent primary" "$TEST_TEMP_DIR/m/absent" absent-stage

if declare -F _verdict_read_stage_sidecar >/dev/null 2>&1; then
    assert_fail "[R5] _verdict_read_stage_sidecar is deleted" "still defined"
else
    assert_pass "[R5] _verdict_read_stage_sidecar is deleted"
fi

# ─── R6: the legacy rc mapping is gone ──────────────────────────────────────
print_test_section "R6: the legacy rc mapping is deleted"
for _fn in dispatch_rc_legacy_reason dispatch_rc_legacy_disposition; do
    if declare -F "$_fn" >/dev/null 2>&1; then
        assert_fail "[R6] $_fn is deleted" "still defined"
    else
        assert_pass "[R6] $_fn is deleted"
    fi
done

# ─── R7: a dead stage is classified by how it died ──────────────────────────
print_test_section "R7: a stage that died leaving no result is still interrupted or broken"
assert_eq "[R7] killed (rc 143, signal) → interrupted" "interrupted" \
    "$(runner_read_stage_disposition "$STATE_DIR" "$TEST_TEMP_DIR/m/absent/manifest.yaml" absent-stage 143 signal 0 2>/dev/null)"
assert_eq "[R7] plain failure (rc 1) → broken" "broken" \
    "$(runner_read_stage_disposition "$STATE_DIR" "$TEST_TEMP_DIR/m/absent/manifest.yaml" absent-stage 1 "" 0 2>/dev/null)"

cleanup_test_env
print_test_results
