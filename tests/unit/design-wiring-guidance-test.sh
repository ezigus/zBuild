#!/usr/bin/env bash
# tests/unit/design-wiring-guidance-test.sh — design is told that a registry or
# data file is not WIRING (#2252 G).
#
# Why: WIRING names the file that routes the live path to the new code; the gate
# reverts it and expects a test to flip. Listing a name in a registry (an event
# list, a schema) changes no behaviour, so reverting it flips nothing and the
# gate rightly calls it inert — #2032 run 36969130031's design declared
# config/event-schema.json as WIRING in all three of its designs. The prompt's
# own example listed that very file.
#
# G1 [change] the prompt's WIRING example does not name config/event-schema.json
# G2 [change] the WIRING key comes with the plain question it stands for, and
#             says a list, schema or config entry is never that file (#2269)
# G3 [change] the acceptance section speaks plainly: no internal check names
#             (inert, negative control, reachability), no ADR numbers, no
#             "dispatch table entry" example (a list entry) (#2269)
# G4 [change] the three statuses are explained in before-and-after words (#2269, #2304)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: a registry or data file is not WIRING (#2252 G)"
setup_test_env "design-wiring-guidance"

# Source the design plugin so real route.sh / redaction get loaded, then override.
# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Override budget resolvers with known sentinel values so the assertions can be
# precise: any appearance of "777" for timeout or "99" for max_turns proves the
# live resolver output reached the prompt.
_route_resolve_max_turns() { printf '99'; }
_route_resolve_timeout()   { printf '777'; }

_MOCK_DESIGN_WRITE_PATH=""
route_to_model_loop() {
    local _bt='```'
    if [[ -n "${_MOCK_DESIGN_WRITE_PATH:-}" ]]; then
        mkdir -p "$(dirname "$_MOCK_DESIGN_WRITE_PATH")"
        printf '# Design\n\n## Decision\nMinimal.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC-1[no-code]: works\nWIRING: none\nTESTFILES:\n%s\n' \
            "$_bt" "$_bt" "$_bt" "$_bt" > "$_MOCK_DESIGN_WRITE_PATH"
    fi
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }

FIX="$TEST_TEMP_DIR/fixture"
mkdir -p "$FIX"
git -C "$FIX" init --quiet >/dev/null 2>&1
git -C "$FIX" config user.email 'test@example.com' >/dev/null 2>&1
git -C "$FIX" config user.name  'test' >/dev/null 2>&1
ARTIFACT_DIR="$FIX/state/artifacts"; mkdir -p "$ARTIFACT_DIR"
SCOPE_MANIFEST="$FIX/state/scope-manifest.md"; printf 'scope: all\n' > "$SCOPE_MANIFEST"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
OUTPUT_MD="$ARTIFACT_DIR/design.md"
export ZBUILD_REPO_ROOT="$FIX"
export ZBUILD_EVENTS_JSONL="$FIX/state/events.jsonl"
export ZBUILD_EVENTS_DIR="$FIX/state"
: > "$ZBUILD_EVENTS_JSONL"
_MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"

_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1 || true

PROMPT="$ARTIFACT_DIR/design-prompt.txt"
_wiring="$(awk '/^WIRING:/{f=1} f&&/^Existing checks this change makes wrong/{exit} f' "$PROMPT" 2>/dev/null)"
assert_contains "fixture: the prompt carries the WIRING guidance" "$_wiring" "WIRING:"
# The whole acceptance section: from the acceptance item to the supersedes note.
_acc="$(awk '/fenced block listing behavioral claims|block listing the behaviour|block listing what this change must deliver/{f=1} f&&/^Existing checks this change makes wrong/{exit} f' "$PROMPT" 2>/dev/null)"
if grep -q 'config/event-schema.json' <<< "$_wiring"; then
    assert_fail "[G1] the WIRING example does not name a registry file" "example lists config/event-schema.json"
else
    assert_pass "[G1] the WIRING example does not name a registry file"
fi
assert_contains "[G2] the WIRING key asks the plain question" "$_wiring" "Which existing file calls the new code?"
assert_contains "[G2] a list, schema or config entry is never that file" "$_wiring" "A list, schema or config entry is never this file"
for _w in inert "negative control" reachability "ADR-" "dispatch table entry" "load-bearing" "CHECK THE TREE" "merge-base"; do
    if grep -qiF -- "$_w" <<< "$_acc"; then
        assert_fail "[G3] the acceptance section does not say '$_w'" "found in the rendered prompt"
    else
        assert_pass "[G3] the acceptance section does not say '$_w'"
    fi
done
assert_contains "[G4] [code] is explained as fails-before, passes-after" "$_acc" "fail on the code as it is before your change"
assert_contains "[G4] [no-code] is explained as passes after, need not fail before" "$_acc" "it need not fail before"
assert_contains "[G4] [done] is explained as what the code already does" "$_acc" "the code already does it"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
