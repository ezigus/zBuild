#!/usr/bin/env bash
# tests/unit/verdict-undeclared-word-test.sh — a verdict a plugin never declared
# is a failure of that stage, not a warning (#2242).
#
# Why: #1838's impact plugin wrote `verdict: broken` on two exits; its manifest
# declares complete|incomplete|error. The engine's reader returned `warn` (and a
# log event) for it — even for `verdict: banana` — so every gate passed it. #1708
# and every Phase 0/F migration issue say an undeclared verdict is a structural
# failure, the rule the reader already applies to an undeclared disposition.
#
# V1 [change] a v2 result whose verdict is not in valid_verdicts → `error`, with
#             contract_violation:unknown_verdict:<word> on the event
# V2 [guard]  a declared verdict still classifies as before (complete → pass)
# V3 [guard]  a manifest that declares no list (absent or []) is not checked here
#             (the lint owns a missing declaration)
# V4 [guard]  a v1 result is unchanged (the check is part of the v2 contract)
# V5 [guard]  an inline flow list `valid_verdicts: [complete, error]` is honoured
# V6 [change] a scalar `valid_verdicts: pass` is not a list — the parser says so
#             (`invalid`), the reader does not treat it as one (review #2247)
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

print_test_header "an undeclared verdict word fails the stage (#2242)"
setup_test_env "verdict-undeclared-word"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events.jsonl"

S="$TEST_TEMP_DIR/state"; mkdir -p "$S/artifacts"
# _manifest <valid_verdicts-block> — a stage whose JSON primary is x.json.
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
  result_contract: 2
config:
$1
EOF
}
# _read <verdict> [v1] → the reader's class for a result with that verdict.
_read() {
    if [[ "${2:-}" == v1 ]]; then
        printf '{"verdict":"%s"}\n' "$1" > "$S/artifacts/x.json"
    else
        printf '{"result_contract":2,"verdict":"%s","disposition":"complete","reason":"r"}\n' "$1" > "$S/artifacts/x.json"
    fi
    : > "$ZBUILD_EVENTS_JSONL"
    runner_read_stage_verdict "$S" "$TEST_TEMP_DIR/manifest.yaml" x 0 2>/dev/null
}

_manifest '  valid_verdicts:
    - complete
    - incomplete
    - error'
assert_eq "[V1] an undeclared verdict (broken) is error, not warn" "error" "$(_read broken)"
assert_contains "[V1] ...and the event names it" "$(cat "$ZBUILD_EVENTS_JSONL")" "unknown_verdict:broken"
assert_eq "[V1] even banana" "error" "$(_read banana)"
assert_eq "[V2] a declared verdict still classifies (complete → pass)" "pass" "$(_read complete)"
assert_eq "[V4] a v1 result is unchanged (undeclared → warn)" "warn" "$(_read banana v1)"

_manifest '  valid_verdicts: []'
assert_eq "[V3] an empty declaration is not checked here" "warn" "$(_read banana)"
_manifest '  tier_default: T1'
assert_eq "[V3] an absent declaration is not checked here" "warn" "$(_read banana)"

_manifest '  valid_verdicts: [complete, error]'
assert_eq "[V5] a flow list is honoured (declared)" "pass" "$(_read complete)"
assert_eq "[V5] a flow list is honoured (undeclared)" "error" "$(_read broken)"

_manifest '  valid_verdicts: complete'
# shellcheck source=../../scripts/lib/manifest-valid-verdicts.sh
source "$REPO_ROOT/scripts/lib/manifest-valid-verdicts.sh"
assert_eq "[V6] a scalar is reported invalid, not a one-item list" "invalid complete" \
    "$(manifest_valid_verdicts_state "$TEST_TEMP_DIR/manifest.yaml")"
assert_eq "[V6] ...and the reader does not check against it" "warn" "$(_read banana)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
