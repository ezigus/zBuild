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

# Stable anchor from the output contract block for ordering (I2/I4).
# Persona framing replaces the role sentence, so use the output-contract header
# which always appears first regardless of which framing path is active.
IMPACT_CONTRACT_ANCHOR="OUTPUT CONTRACT (read first, obey absolutely):"

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

# ─── Case B: no override file ────────────────────────────────────────────────
FIXTURE_REPO_NONE="$TEST_TEMP_DIR/fixture-repo-none"
mkdir -p "$FIXTURE_REPO_NONE/.zbuild/prompts"
git -C "$FIXTURE_REPO_NONE" init -q
export ZBUILD_REPO_ROOT="$FIXTURE_REPO_NONE"

art_none="$TEST_TEMP_DIR/state/artifacts-none"
run_impact "$art_none"
RC_NONE="$RC"

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

# ─── SPEC-1[change]: persona_stage_framing rc≠0 → fallback has no role declaration ──
# prompt_spec1 (persona-present path) is kept for SPEC-3's framing-agnostic check.
_ORIG_IMPACT_ROOT="$_IMPACT_ROOT"

art_spec1="$TEST_TEMP_DIR/state/artifacts-spec1"
_IMPACT_ROOT="$REPO_ROOT"
export ZBUILD_REPO_ROOT="$FIXTURE_REPO"
run_impact "$art_spec1"
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"

prompt_spec1="$art_spec1/impact-prompt.txt"
# Guard: the persona-PRESENT path still injects the architect perspective text.
# Regression guard for the happy path — do NOT drop this positive check when
# re-authoring SPEC-1 to also cover the fallback (#1575 review, correctness/sre).
assert_contains "[SPEC-1 guard] architect perspective text in prompt when manifest present" \
    "$(cat "$prompt_spec1" 2>/dev/null || echo '')" "Judge a change by its structure"

# [SPEC-1] change assertion: when persona_stage_framing fails with rc≠0, the fallback
# must be behavior-only — no "You are an Impact Analyzer agent." role declaration.
# Fails at baseline where _persona_fallback opened with the role declaration.
persona_stage_framing() { return 1; }
art_spec1b="$TEST_TEMP_DIR/state/artifacts-spec1b"
_IMPACT_ROOT="$REPO_ROOT"
export ZBUILD_REPO_ROOT="$FIXTURE_REPO"
run_impact "$art_spec1b"
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"
unset -f persona_stage_framing
prompt_spec1b="$art_spec1b/impact-prompt.txt"
# Guard against a vacuous pass: the fallback run must have WRITTEN the prompt file.
# Without this, a crashed run (no file) makes the negative grep's else-branch fire
# assert_pass — masking a broken run (#1575 review, correctness/red-team/sre).
assert_file_exists "[SPEC-1] fallback run produced a prompt file" "$prompt_spec1b"
if grep -qF "You are an Impact Analyzer agent." "$prompt_spec1b" 2>/dev/null; then
    assert_fail "[SPEC-1] fallback must be behavior-only (no role declaration)" \
        "role declaration found in fallback prompt"
else
    assert_pass "[SPEC-1] fallback must be behavior-only (no role declaration)"
fi

# ─── SPEC-2[guard]: architect manifest absent → fallback text in prompt ───────
IROOT_NONE="$(mktemp -d "$TEST_TEMP_DIR/iroot_none.XXXXXX")"
mkdir -p "$IROOT_NONE/plugins"

art_spec2="$TEST_TEMP_DIR/state/artifacts-spec2"
_IMPACT_ROOT="$IROOT_NONE"
export ZBUILD_REPO_ROOT="$FIXTURE_REPO_NONE"
run_impact "$art_spec2"
_IMPACT_ROOT="$_ORIG_IMPACT_ROOT"

prompt_spec2="$art_spec2/impact-prompt.txt"
assert_contains "[SPEC-2] fallback text present when architect manifest absent" \
    "$(cat "$prompt_spec2" 2>/dev/null || echo '')" "adversarial consequence-finding"

# ─── SPEC-3[guard]: DESIGN SCOPE BLOCK present regardless of framing path ────
assert_contains "[SPEC-3] DESIGN SCOPE BLOCK in prompt with architect manifest" \
    "$(cat "$prompt_spec1" 2>/dev/null || echo '')" "DESIGN SCOPE BLOCK:"
assert_contains "[SPEC-3] DESIGN SCOPE BLOCK in prompt without architect manifest" \
    "$(cat "$prompt_spec2" 2>/dev/null || echo '')" "DESIGN SCOPE BLOCK:"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
