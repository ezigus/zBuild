#!/usr/bin/env bash
# tests/unit/contract2-retired-test.sh — result contract 2 is gone (#2366, ADR-054 §6).
#
# Every stage writes one outcome (contract 3). The engine reads nothing else, and
# the per-stage verdict words, their translation table and their lints go with
# contract 2.
#
#   V1 [change] the engine reads contract 3 only
#   V2 [change] a contract-2 result is a broken result
#   V3 [change] no manifest lists verdict words, and the tooling for them is gone
#   V4 [change] the engine's verdict classes are pass, fail and error — no
#               stage's own word is known to it
#   V5 [change] no stage reads a result's `.verdict`
#   V6 [change] ...or its `.disposition`
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "result contract 2 is gone (#2366)"
setup_test_env "contract2-retired"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

print_test_section "V1/V2: contract 3 only"
assert_eq "[V1] the engine reads contract 3 only" "3..3" "$(contract_version_range)"
S="$TEST_TEMP_DIR/s"; P="$TEST_TEMP_DIR/p"; mkdir -p "$S/artifacts" "$P"
printf 'id: v\noutputs:\n  - id: r\n    path: ${artifact_dir}/v-result.json\n    type: v@1\n    required: true\n    primary: true\n' > "$P/manifest.yaml"
printf '{"result_contract":2,"verdict":"pass","disposition":"complete","reason":"ok"}\n' > "$S/artifacts/v-result.json"
assert_eq "[V2] a contract-2 result is broken" "broken" "$(runner_read_stage_disposition "$S" "$P/manifest.yaml" v 0 2>/dev/null)"

print_test_section "V3: no verdict words"
assert_eq "[V3] no manifest lists valid_verdicts" "" \
    "$(/usr/bin/grep -l 'valid_verdicts' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"
for _f in scripts/lib/lint-verdict-classify.sh scripts/lib/lint-verdict-words.sh scripts/lib/manifest-valid-verdicts.sh; do
    assert_file_not_exists "[V3] $_f is gone" "$REPO_ROOT/$_f"
done
if /usr/bin/grep -q 'lint-verdict-classify\|lint-verdict-words' "$REPO_ROOT/package.json" "$REPO_ROOT/.github/workflows/test.yml"; then
    assert_fail "[V3] nothing runs the retired lints" "still wired"
else
    assert_pass "[V3] nothing runs the retired lints"
fi

print_test_section "V4: the engine's classes"
assert_eq "[V4] pass is pass" "pass" "$(verdict_classify pass)"
assert_eq "[V4] fail is fail" "fail" "$(verdict_classify fail)"
assert_eq "[V4] error (a stage that did not finish) is a fail" "fail" "$(verdict_classify error)"
for _w in covered uncovered corresponds mismatch partial degraded complete skip skipped deployed healthy blocked incomplete approve; do
    assert_eq "[V4] '$_w' is no longer a word the engine knows" "unknown" "$(verdict_classify "$_w")"
done

print_test_section "V5: no stage reads .verdict"
_bad="$(cd "$REPO_ROOT" && /usr/bin/grep -rnE "\.verdict\b" plugins --include='*.sh' \
        | /usr/bin/grep -v '/tests/' | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
        | /usr/bin/grep -v 'schema_version == 1 and (.verdict|type=="string")' \
        | /usr/bin/grep -v '^plugins/agent/monitor/plugin.sh:[0-9]*:.*report_json' || true)"
assert_eq "[V5] no stage reads a result's .verdict" "" "$_bad"

print_test_section "V6: no stage reads a result's .disposition"
_bad6="$(cd "$REPO_ROOT" && /usr/bin/grep -rnE "\.disposition //|\(\.disposition\b" plugins --include='*.sh' \
        | /usr/bin/grep -v '/tests/' | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
assert_eq "[V6] no stage reads a result's .disposition" "" "$_bad6"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
