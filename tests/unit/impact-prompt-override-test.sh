#!/usr/bin/env bash
# Tests: impact stage appends per-repo prompt override (OV-2, #855, ADR-032).
# The override is appended AFTER the core contract and BEFORE redaction, so it
# rides the redaction chokepoint and cannot weaken the shipped charter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "impact prompt override (OV-2 #855)"
setup_test_env "impact-prompt-override"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../plugins/agent/impact/plugin.sh
source "$REPO_ROOT/plugins/agent/impact/plugin.sh"

# Override after source so we shadow the real implementations.
# Router is a no-op success returning a valid impact verdict so the inner
# reaches rc=0 through the real prompt-assembly + redaction path.
route_to_model() {
    printf '%s' '{"schema_version":1,"verdict":"complete","missing":[],"impact_feedback_md":"ok"}'
    return 0
}
# Redaction passthrough: copy in→out so the marker survives verbatim (I3).
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

# Stable anchor from _impact_instructions (core contract) for ordering (I2).
# Must be present in ALL framing paths (architect persona OR fallback), so we
# use a phrase from the static body rather than the persona-dependent opening.
IMPACT_CONTRACT_ANCHOR="EXISTENCE VERIFICATION"

# ─── Minimal valid inputs ────────────────────────────────────────────────────
make_plan() {
    local dst="$1"
    cat > "$dst" <<'EOF'
{
  "title": "Impact test",
  "goal": "Check impact prompt override",
  "steps": [{"id":1,"description":"do","files":["x.sh"]}]
}
EOF
}

run_impact() {
    # run_impact <artifact_dir> ; returns inner rc in global RC
    local artifact_dir="$1"
    mkdir -p "$artifact_dir"
    local plan_path="$artifact_dir/plan.json"
    local design_path="$artifact_dir/design.md"
    local impact_path="$artifact_dir/impact.json"
    make_plan "$plan_path"
    # #842: impact reads design.md's ```scope block as the primary scope source,
    # so _impact_run_inner takes <scope_manifest> <design_md> <plan> <impact> [dir].
    printf '# Design\n\n```scope\nx.sh\n```\n' > "$design_path"
    local scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
    printf '# Scope\n- x.sh\n' > "$scope_manifest"
    set +e
    _impact_run_inner \
        "$scope_manifest" \
        "$design_path" \
        "$plan_path" \
        "$impact_path" \
        "$artifact_dir" >/dev/null 2>&1
    RC=$?
    set -e
}

# ─── Case A: override present ────────────────────────────────────────────────
FIXTURE_REPO="$TEST_TEMP_DIR/fixture-repo"
mkdir -p "$FIXTURE_REPO/.zbuild/prompts"
printf 'IMPACT_OV_MARKER: tailor impact for this target repo.\n' \
    > "$FIXTURE_REPO/.zbuild/prompts/impact-overrides.md"
git -C "$FIXTURE_REPO" init -q
export ZBUILD_REPO_ROOT="$FIXTURE_REPO"

art_with="$TEST_TEMP_DIR/state/artifacts-with"
run_impact "$art_with"
RC_WITH="$RC"

prompt_with="$art_with/impact-prompt.txt"
prompt_with_body="$(cat "$prompt_with" 2>/dev/null || echo '')"

assert_eq "I0 impact inner rc=0 with override" "0" "$RC_WITH"

# ─── I1: delimiter + marker present in pre-redaction prompt ──────────────────
DELIMITER="## Project-specific guidance (operator override)"
assert_contains "I1 override delimiter present" "$prompt_with_body" "$DELIMITER"
assert_contains "I1 override marker present" "$prompt_with_body" "IMPACT_OV_MARKER"

# ─── I1c (PREV-2 #882): charter instructs finding ordering/position assertions ─
assert_contains "I1c charter hunts ordering assertions" "$prompt_with_body" "ORDERING/POSITION/SEQUENCE"

# ─── I2: ordering — delimiter appears AFTER core-contract anchor ─────────────
contract_line="$(grep -nF -- "$IMPACT_CONTRACT_ANCHOR" "$prompt_with" 2>/dev/null | head -1 | cut -d: -f1)"
delim_line="$(grep -nF -- "$DELIMITER" "$prompt_with" 2>/dev/null | head -1 | cut -d: -f1)"
if [[ -n "$contract_line" && -n "$delim_line" ]] && (( delim_line > contract_line )); then
    assert_pass "I2 delimiter ($delim_line) after contract anchor ($contract_line)"
else
    assert_fail "I2 delimiter after contract anchor" \
        "contract_line=$contract_line delim_line=$delim_line"
fi

# ─── I3: override rides the router's redaction pass (ADR-043) ────────────────
# route_to_model receives the assembled impact-prompt.txt and redacts it by
# construction — the override being in that prompt proves it is redaction-covered.
assert_contains "I3 marker in router-bound prompt" "$prompt_with_body" "IMPACT_OV_MARKER"
assert_contains "I3 delimiter in router-bound prompt" "$prompt_with_body" "$DELIMITER"

# ─── SPEC-1[change]: architect persona perspective present when manifest exists ─
# _IMPACT_ROOT points to the real repo, which contains the architect manifest.
# After #1394, persona_stage_framing produces the architect perspective text.
# This assertion FAILS at the merge-base baseline (no persona_stage_framing call).
assert_contains "[SPEC-1] architect perspective text in prompt when manifest present" \
    "$prompt_with_body" "You judge a change by its structure"

# ─── SPEC-3[guard]: EXISTENCE VERIFICATION present regardless of framing path ─
assert_contains "[SPEC-3] EXISTENCE VERIFICATION present with architect framing" \
    "$prompt_with_body" "EXISTENCE VERIFICATION"

# ─── Case B: no override file, _IMPACT_ROOT without architect persona ─────────
# Use a separate _IMPACT_ROOT fixture that has no persona directory so that the
# fallback framing ('You are an Impact Analyzer agent.') is exercised.
FIXTURE_REPO_NONE="$TEST_TEMP_DIR/fixture-repo-none"
mkdir -p "$FIXTURE_REPO_NONE/.zbuild/prompts"
git -C "$FIXTURE_REPO_NONE" init -q
export ZBUILD_REPO_ROOT="$FIXTURE_REPO_NONE"

FIXTURE_IMPACT_ROOT_NO_ARCH="$TEST_TEMP_DIR/impact-root-no-arch"
mkdir -p "$FIXTURE_IMPACT_ROOT_NO_ARCH/plugins"
_ORIG_IMPACT_ROOT="$_IMPACT_ROOT"
_IMPACT_ROOT="$FIXTURE_IMPACT_ROOT_NO_ARCH"

art_none="$TEST_TEMP_DIR/state/artifacts-none"
run_impact "$art_none"
RC_NONE="$RC"

_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"

prompt_none="$art_none/impact-prompt.txt"
prompt_none_body="$(cat "$prompt_none" 2>/dev/null || echo '')"

assert_eq "I4 impact inner rc=0 with no override" "0" "$RC_NONE"

# ─── I4: no override → no delimiter, contract intact ─────────────────────────
if grep -qF -- "$DELIMITER" "$prompt_none" 2>/dev/null; then
    assert_fail "I4 no delimiter without override" "delimiter leaked"
else
    assert_pass "I4 no delimiter without override"
fi
assert_contains "I4 core contract intact without override" \
    "$prompt_none_body" "$IMPACT_CONTRACT_ANCHOR"

# ─── SPEC-2[guard]: fallback text byte-identical to pre-#1394 opening ─────────
# When the architect manifest is absent, persona_stage_framing returns 1 and the
# fallback 'You are an Impact Analyzer agent.' is used as the prompt opening.
assert_contains "[SPEC-2] fallback text present when architect manifest absent" \
    "$prompt_none_body" "You are an Impact Analyzer agent."

# ─── SPEC-3[guard]: EXISTENCE VERIFICATION present with fallback framing ───────
assert_contains "[SPEC-3] EXISTENCE VERIFICATION present with fallback framing" \
    "$prompt_none_body" "EXISTENCE VERIFICATION"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
