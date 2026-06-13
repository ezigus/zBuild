#!/usr/bin/env bash
# Tests: test_assessment plugin appends per-repo prompt override (OV-2, #855).
# Mirrors tests/unit/plugin-review-prompt-render-test.sh — exercises the inner
# (_test_assessment_run_inner) to the prompt-write line, mocking route_to_model
# and apply_scope_redaction so the run reaches artifact emission without a real
# LLM or redaction backend.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test_assessment prompt override (OV-2 #855)"
setup_test_env "test-assessment-prompt-override"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

# shellcheck source=../../plugins/agent/test_assessment/plugin.sh
source "$REPO_ROOT/plugins/agent/test_assessment/plugin.sh"

# Override after source so we shadow the real router + redaction.
route_to_model() {
    # Return a schema-valid assessment so the inner finishes cleanly.
    printf '%s' '{"schema_version":1,"verdict":"fail","summary":"ok","diagnosis":"d","required_changes":["x"],"agrees_with_build_complete":false,"branch_numstat":"unknown","failure_summary_md":"body","iter":0}'
    return 0
}
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

# ─── Fixture TARGET repo with an override file ──────────────────────────────
FIXTURE_REPO="$TEST_TEMP_DIR/fixture-repo"
mkdir -p "$FIXTURE_REPO/.zbuild/prompts"
printf 'TA_OV_MARKER\nUse the project test taxonomy when assessing.\n' \
    > "$FIXTURE_REPO/.zbuild/prompts/test_assessment-overrides.md"

# load_prompt_override resolves repo_root via ZBUILD_REPO_ROOT first; it also
# requires the override's real path to sit under a real .zbuild/prompts, so a
# git-initialised fixture is the cleanest match for the symlink-containment gate.
(
    cd "$FIXTURE_REPO" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    git add -A
    git commit -qm init
) >/dev/null 2>&1

# ─── Inputs the inner fails-CLOSED without ──────────────────────────────────
# state_dir holds scope-manifest.md + intake-baseline-ref.txt; artifact_dir
# holds test-results.json / plan.json / build-summary.json.
run_inner() {
    local with_override="$1"          # 1 → keep override file, 0 → remove it
    local label="$2"
    local state_dir artifact_dir
    state_dir="$TEST_TEMP_DIR/state-$label"
    artifact_dir="$state_dir/artifacts"
    mkdir -p "$artifact_dir"

    local scope_manifest="$state_dir/scope-manifest.md"
    touch "$scope_manifest"

    # intake-baseline-ref.txt: a valid commit sha in the fixture repo so
    # branch_numstat_since reaches the prompt-write line (fail-CLOSED otherwise).
    git -C "$FIXTURE_REPO" rev-parse HEAD > "$state_dir/intake-baseline-ref.txt"

    cat > "$artifact_dir/test-results.json" <<'EOF'
{"verdict":"failed","passed":2,"failed":1,"test_output":"sample output"}
EOF
    cat > "$artifact_dir/plan.json" <<'EOF'
{"title":"TA test","goal":"assess","steps":[{"id":1,"description":"do","files":["x.sh"]}]}
EOF
    cat > "$artifact_dir/build-summary.json" <<'EOF'
{"verdict":"fail","iterations":1,"terminated_reason":"complete"}
EOF

    if [[ "$with_override" == "0" ]]; then
        rm -f "$FIXTURE_REPO/.zbuild/prompts/test_assessment-overrides.md"
    fi

    # ZBUILD_REPO_ROOT points load_prompt_override at the fixture TARGET repo.
    # numstat helper must run inside the fixture git repo, so cwd is the fixture.
    (
        cd "$FIXTURE_REPO" || exit 1
        export ZBUILD_REPO_ROOT="$FIXTURE_REPO"
        _test_assessment_run_inner \
            "$scope_manifest" \
            "$artifact_dir/test-results.json" \
            "$artifact_dir/plan.json" \
            "$artifact_dir/build-summary.json" \
            "$artifact_dir/test-assessment.json" \
            "$artifact_dir/test-assessment.md" \
            "$artifact_dir" \
            "$state_dir"
    )
    return $?
}

DELIM='## Project-specific guidance (operator override)'
# Stable anchor string from _ta_instructions (the core contract body).
ANCHOR='You are a test-results assessment agent.'

# ─── With override present ──────────────────────────────────────────────────
set +e
run_inner 1 "ov" >/dev/null 2>&1
rc_ov=$?
set -e 2>/dev/null || true

prompt_ov="$TEST_TEMP_DIR/state-ov/artifacts/test-assessment-prompt.txt"
redacted_ov="$TEST_TEMP_DIR/state-ov/artifacts/test-assessment-prompt.redacted.txt"
prompt_ov_content="$(cat "$prompt_ov" 2>/dev/null || echo '')"
redacted_ov_content="$(cat "$redacted_ov" 2>/dev/null || echo '')"

assert_eq "inner rc=0 with override" "0" "$rc_ov"

# ─── T1: delimiter + marker present in pre-redaction prompt ─────────────────
assert_contains "T1 override delimiter present" "$prompt_ov_content" "$DELIM"
assert_contains "T1 override marker present" "$prompt_ov_content" "TA_OV_MARKER"

# ─── T2: delimiter appears AFTER the core-contract anchor (ordering) ────────
delim_line="$(grep -nF "$DELIM" "$prompt_ov" | head -1 | cut -d: -f1)"
anchor_line="$(grep -nF "$ANCHOR" "$prompt_ov" | head -1 | cut -d: -f1)"
if [[ -n "$delim_line" && -n "$anchor_line" ]] && (( delim_line > anchor_line )); then
    assert_pass "T2 delimiter after core contract anchor"
else
    assert_fail "T2 delimiter after core contract anchor" \
        "delim_line=$delim_line anchor_line=$anchor_line"
fi

# ─── T3: marker survives into the redacted prompt ───────────────────────────
assert_contains "T3 marker survives redaction" "$redacted_ov_content" "TA_OV_MARKER"

# ─── Without override → no delimiter, contract intact ───────────────────────
set +e
run_inner 0 "noov" >/dev/null 2>&1
rc_noov=$?
set -e 2>/dev/null || true

prompt_noov="$TEST_TEMP_DIR/state-noov/artifacts/test-assessment-prompt.txt"
prompt_noov_content="$(cat "$prompt_noov" 2>/dev/null || echo '')"

assert_eq "inner rc=0 without override" "0" "$rc_noov"

# ─── T4: no override file → no delimiter, anchor still present ───────────────
if printf '%s' "$prompt_noov_content" | grep -qF "$DELIM"; then
    assert_fail "T4 no delimiter without override" "delimiter leaked into prompt"
else
    assert_pass "T4 no delimiter without override"
fi
assert_contains "T4 contract intact without override" "$prompt_noov_content" "$ANCHOR"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
