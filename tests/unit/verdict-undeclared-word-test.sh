#!/usr/bin/env bash
# tests/unit/verdict-undeclared-word-test.sh — a word the engine does not know
# is a failure of that stage, not a warning (#2242; contract 3 since #2366).
#
# Why: #1838's impact plugin wrote `verdict: broken` on two exits; its manifest
# declared complete|incomplete|error. The engine's reader returned `warn` (and a
# log event) for it — even for `verdict: banana` — so every gate passed it.
# Since #2366 a result carries one `outcome` from the engine's closed list, and
# a word off that list is a structural failure.
#
# V1 [change] a contract-3 outcome off the list → `error`, with
#             contract_violation:unknown_outcome:<word> on the event
# V2 [guard]  an outcome on the list still classifies as before (pass → pass)
# V4 [change] a v1 result is refused outright since #1850
# V6 [change] a scalar `valid_verdicts: pass` is not a list — the parser says so
#             (`invalid`) (review #2247)
# (V3 and V5 tested contract 2's per-stage `valid_verdicts` reading, which
#  contract 3 does not have; they were removed with it.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"
# shellcheck source=../../scripts/lib/stage-result.sh
source "$REPO_ROOT/scripts/lib/stage-result.sh"

print_test_header "a word the engine does not know fails the stage (#2242, #2366)"
setup_test_env "verdict-undeclared-word"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
# _manifest <config-block> — a stage whose JSON primary is x.json.
_manifest() {
    cat > "$TEST_TEMP_DIR/manifest.yaml" <<EOF
id: x
kind: agent
outputs:
  - id: x
    path: "\${artifact_dir}/x.json"
    format: json
    primary: true
provides:
  result_contract: 3
config:
$1
EOF
}
# _read <outcome> [v1|raw] → the reader's class for a result with that word.
# A word on the list is written with the engine's writer; one off the list
# cannot be (the writer refuses it), so it is written raw.
_read() {
    case "${2:-}" in
        v1)  printf '{"verdict":"%s"}\n' "$1" > "$S/artifacts/x.json" ;;
        raw) printf '{"result_contract":3,"outcome":"%s","reason":"r"}\n' "$1" > "$S/artifacts/x.json" ;;
        *)   stage_result_write "$S/artifacts/x.json" "$1" "r" ;;
    esac
    : > "$ZBUILD_EVENTS_JSONL"
    runner_read_stage_verdict "$S" "$TEST_TEMP_DIR/manifest.yaml" x 0 2>/dev/null
}

_manifest '  tier_default: T1'
assert_eq "[V1] an outcome off the list (degraded) is error, not warn" "error" "$(_read degraded raw)"
assert_contains "[V1] ...and the event names it" "$(cat "$ZBUILD_EVENTS_JSONL")" "unknown_outcome:degraded"
assert_eq "[V1] even banana" "error" "$(_read banana raw)"
assert_eq "[V2] an outcome on the list still classifies (pass → pass)" "pass" "$(_read pass)"
assert_eq "[V4] a v1 result is refused, whatever its word (#1850)" "error" "$(_read banana v1)"

_manifest '  valid_verdicts: complete'
# shellcheck source=../../scripts/lib/manifest-valid-verdicts.sh
source "$REPO_ROOT/scripts/lib/manifest-valid-verdicts.sh"
assert_eq "[V6] a scalar is reported invalid, not a one-item list" "invalid complete" \
    "$(manifest_valid_verdicts_state "$TEST_TEMP_DIR/manifest.yaml")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
