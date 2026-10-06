#!/usr/bin/env bash
# tests/unit/acceptance-unclaimed-code-test.sh — a change that edits code must
# have a requirement that says what the code must now do (#2304, ADR-069 §5).
#
# Why: a requirement marked "no code" or "already done" is not run against the
# old code. Without this backstop a change could ship code under those labels
# and nothing would ever check that its tests fail without it — the way #2035
# dropped its own red step by relabelling every requirement a [guard].
#
# U1 the branch edits scripts/x.sh, the only requirement is [no-code]
#    → the check reports scripts/x.sh (and not the docs it also touched)
# U2 the same change with a [code] requirement, or an old [change] one → silent
# U3 only tests/, plugins/<kind>/<id>/tests/, docs/ and *.md changed → silent
# U4 through the gate's own entry: verdict fail, failures has
#    unclaimed_code:scripts/x.sh, the reason says what to add, the event is
#    emitted and declared, and the class is recoverable; with a [code]
#    requirement the gate does not report it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-negctl.sh
source "$REPO_ROOT/scripts/lib/acceptance-negctl.sh"
# shellcheck source=../../core/event-bus/known-types.sh
source "$REPO_ROOT/core/event-bus/known-types.sh"

print_test_header "a change that edits code needs a [code] requirement (#2304, ADR-069 §5)"
setup_test_env "acceptance-unclaimed-code"
unset ZBUILD_ISSUE 2>/dev/null || true

GIT="$(command -v git)"

# _repo <name> <path>... — a repo whose feature branch adds each path.
_repo() {
    local name="$1"; shift
    local repo; repo="$(setup_git_temp_repo "$name")" || return 1
    (
        cd "$repo" || exit 1
        "$GIT" checkout -q -b feature
        local p
        for p in "$@"; do
            mkdir -p "$(dirname "$p")"
            printf '#!/usr/bin/env bash\n# %s\nexit 0\n' "$p" > "$p"
            chmod +x "$p"
        done
        "$GIT" add -A; "$GIT" commit -q -m "feature"
    ) >/dev/null 2>&1 || return 1
    printf '%s' "$repo"
}
# _design <repo> <spec line>... — an acceptance block with those requirements.
_design() {
    local repo="$1"; shift
    {
        printf '```acceptance\n'
        printf '%s\n' "$@"
        printf 'TESTFILES:\ntests/a-test.sh\nWIRING: none\n```\n'
    } > "$repo/design.md"
}

print_test_section "U1: code changed, only a [no-code] requirement"
R1="$(_repo unclaimed-u1 scripts/x.sh docs/notes.txt tests/a-test.sh)"
_design "$R1" "SPEC-1[no-code]: the docs explain the flag"
OUT1="$(acceptance_unclaimed_code_check "$R1/design.md" "$R1" 2>&1)"; RC1=$?
assert_eq "[U1] the check names the code file nothing claims" "UNCLAIMED_CODE scripts/x.sh" "$OUT1"
assert_eq "[U1] ...and reports it with rc 1" "1" "$RC1"

print_test_section "U2: the same change with a requirement for the code"
_design "$R1" "SPEC-1[no-code]: the docs explain the flag" "SPEC-2[code]: x does the new thing"
OUT2="$(acceptance_unclaimed_code_check "$R1/design.md" "$R1" 2>&1)"; RC2=$?
assert_eq "[U2] a [code] requirement claims the code — nothing reported" "" "$OUT2"
assert_eq "[U2] ...rc 0" "0" "$RC2"
_design "$R1" "SPEC-1[done]: already there" "SPEC-2[change]: x does the new thing"
OUT2b="$(acceptance_unclaimed_code_check "$R1/design.md" "$R1" 2>&1)"
assert_eq "[U2] an old [change] requirement also claims the code" "" "$OUT2b"
_design "$R1" "SPEC-1[guard]: an old guard"
OUT2c="$(acceptance_unclaimed_code_check "$R1/design.md" "$R1" 2>&1)"
assert_eq "[U2] an old [guard] alone does not (it reads as already done)" "UNCLAIMED_CODE scripts/x.sh" "$OUT2c"

print_test_section "U3: no production code changed"
R3="$(_repo unclaimed-u3 tests/a-test.sh plugins/agent/x/tests/b-test.sh docs/guide.txt README.md sub/notes.md)"
_design "$R3" "SPEC-1[no-code]: the docs and tests are updated"
OUT3="$(acceptance_unclaimed_code_check "$R3/design.md" "$R3" 2>&1)"; RC3=$?
assert_eq "[U3] tests, plugin tests, docs and *.md are not production code" "" "$OUT3"
assert_eq "[U3] ...rc 0" "0" "$RC3"

print_test_section "U4: through the gate"
# _gate <repo> — run the gate's real entry in <repo>; echoes the state dir.
_gate() {
    local repo="$1" st="$1/.zbuild-state"
    mkdir -p "$st/artifacts" "$st/events"
    cp "$repo/design.md" "$st/artifacts/design.md"
    printf '{"inputs":{"design":"%s"}}\n' "$st/artifacts/design.md" > "$st/stage-inputs.json"
    : > "$st/events/events.jsonl"
    ( cd "$repo" || exit 1
      export ZBUILD_EVENTS_DIR="$st/events" ZBUILD_EVENTS_JSONL="$st/events/events.jsonl"
      export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
      export ZBUILD_STAGE_INPUTS="$st/stage-inputs.json" ZBUILD_NEGCTL_TIMEOUT=60
      unset _ZBUILD_ACCEPTANCE_GATE_LOADED
      source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
          && acceptance_gate_run "acceptance-gate" "$st/pipeline-state.json" ) >/dev/null 2>&1 || true
    printf '%s' "$st"
}
R4="$(_repo unclaimed-u4 scripts/x.sh tests/a-test.sh)"
_design "$R4" "SPEC-1[no-code]: the docs explain the flag"
ST4="$(_gate "$R4")"; RES4="$ST4/artifacts/acceptance-gate-result.json"
assert_eq "[U4] the gate fails" "fail" "$(jq -r '.verdict // empty' "$RES4" 2>/dev/null)"
assert_contains "[U4] failures has unclaimed_code:scripts/x.sh" \
    "$(jq -r '.failures[]?' "$RES4" 2>/dev/null)" "unclaimed_code:scripts/x.sh"
assert_contains "[U4] the reason names the file and says what is missing" \
    "$(jq -r '.reason // empty' "$RES4" 2>/dev/null)" \
    "this change edits code (scripts/x.sh) but no requirement says what that code must now do — add a [code] requirement with a test"
assert_contains "[U4] the finding carries the same sentence" \
    "$(jq -r '.data.findings[]?.text' "$RES4" 2>/dev/null)" "no requirement says what that code must now do"
assert_eq "[U4] the severity is recoverable (design can add the requirement)" "recoverable" \
    "$(jq -r '.severity // empty' "$RES4" 2>/dev/null)"
assert_contains "[U4] the event acceptance.gate.unclaimed_code is emitted" \
    "$(cat "$ST4/events/events.jsonl" 2>/dev/null)" '"acceptance.gate.unclaimed_code"'
assert_contains "[U4] ...and declared in the manifest's provides.events" \
    "$(eb_manifest_events "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml" 2>/dev/null)" \
    "acceptance.gate.unclaimed_code"
# shellcheck source=../../scripts/lib/acceptance-disposition.sh
source "$REPO_ROOT/scripts/lib/acceptance-disposition.sh"
assert_eq "[U4] the class unclaimed_code is recoverable in the disposition table" "recoverable" \
    "$(_ag_failure_class_disposition unclaimed_code)"
assert_contains "[U4] ...and listed in the manifest's valid_failure_classes" \
    "$(sed -n '/valid_failure_classes:/,/tier_default/p' "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")" \
    "- unclaimed_code"

R5="$(_repo unclaimed-u4b scripts/x.sh tests/a-test.sh)"
_design "$R5" "SPEC-1[code]: x does the new thing"
ST5="$(_gate "$R5")"; RES5="$ST5/artifacts/acceptance-gate-result.json"
assert_eq "[U4] with a [code] requirement the gate does not report unclaimed code" "" \
    "$(jq -r '.failures[]? | select(startswith("unclaimed_code"))' "$RES5" 2>/dev/null)"
assert_eq "[U4] ...and emits no such event" "" \
    "$(grep -F 'acceptance.gate.unclaimed_code' "$ST5/events/events.jsonl" 2>/dev/null || true)"
assert_eq "[U4] ...the gate did run (a result was written)" "fail" \
    "$(jq -r '.verdict // empty' "$RES5" 2>/dev/null)"

cleanup_test_env
print_test_results
