#!/usr/bin/env bash
# Tests: review stage appends per-repo prompt override (OV-2, #855, ADR-032)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "review prompt per-repo override (OV-2, #855)"
setup_test_env "review-prompt-override"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR"

export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# Override after source so we shadow the real route_to_model.
route_to_model() {
    printf '%s' "$2" > "$_MOCK_ROUTE_CAPTURE"
    # Return an approve verdict so review_run finishes cleanly.
    printf '%s' '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}
apply_scope_redaction() {
    local in="$1" out="$2"
    cp "$in" "$out"
    return 0
}

# ─── Shared review-inner inputs (cribbed from plugin-review-prompt-render-test) ─
_make_review_inputs() {
    local _art="$1"
    mkdir -p "$_art"
    cat > "$_art/plan.json" <<'EOF'
{
  "title": "Override test",
  "goal": "Check review prompt override append",
  "steps": [{"id":1,"description":"do","files":["x.sh"]}]
}
EOF
    cat > "$_art/diff.patch" <<'EOF'
diff --git a/x.sh b/x.sh
--- a/x.sh
+++ b/x.sh
@@ -1,1 +1,1 @@
-a
+b
EOF
    cat > "$_art/test-results.json" <<'EOF'
{"status":"passed","passed":3,"failed":0}
EOF
}

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Case A: override file present → delimiter + marker appended, in order    ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# Fixture TARGET repo carrying a per-repo review override.
FIXTURE_REPO="$TEST_TEMP_DIR/fixture-repo"
mkdir -p "$FIXTURE_REPO/.zbuild/prompts"
cat > "$FIXTURE_REPO/.zbuild/prompts/review-overrides.md" <<'EOF'
Domain note: REVIEW_OV_MARKER — prefer reading helpers/*.sh first.
EOF
git -C "$FIXTURE_REPO" init -q
export ZBUILD_REPO_ROOT="$FIXTURE_REPO"

artifact_dir="$TEST_TEMP_DIR/state/artifacts"
_make_review_inputs "$artifact_dir"
plan_path="$artifact_dir/plan.json"
diff_path="$artifact_dir/diff.patch"
test_path="$artifact_dir/test-results.json"
review_path="$artifact_dir/review.json"

scope_manifest="$TEST_TEMP_DIR/state/scope-manifest.md"
touch "$scope_manifest"

set +e
_review_run_inner \
    "$scope_manifest" \
    "$plan_path" \
    "$diff_path" \
    "$test_path" \
    "$review_path" \
    "$artifact_dir" >/dev/null 2>&1
rc=$?
set -e

prompt_file="$artifact_dir/review-prompt.txt"
redacted_file="$artifact_dir/review-prompt.redacted.txt"
DELIM='## Project-specific guidance (operator override)'
ANCHOR='You are a code review agent'

# ─── R1: override present → delimiter AND marker in pre-redaction prompt ─────
prompt_body="$(cat "$prompt_file" 2>/dev/null || echo '')"
assert_contains "R1 override delimiter present" "$prompt_body" "$DELIM"
assert_contains "R1 override marker present" "$prompt_body" "REVIEW_OV_MARKER"

# ─── R2: ordering — delimiter appears AFTER a stable core-contract anchor ────
anchor_line="$(grep -n -F "$ANCHOR" "$prompt_file" | head -1 | cut -d: -f1)"
delim_line="$(grep -n -F "$DELIM" "$prompt_file" | head -1 | cut -d: -f1)"
if [[ -n "$anchor_line" && -n "$delim_line" && "$delim_line" -gt "$anchor_line" ]]; then
    assert_pass "R2 delimiter (line $delim_line) after core anchor (line $anchor_line)"
else
    assert_fail "R2 delimiter after core anchor" \
        "anchor=$anchor_line delim=$delim_line (expected delim>anchor, both non-empty)"
fi

# ─── R3: marker survives the redaction chokepoint into redacted prompt ──────
redacted_body="$(cat "$redacted_file" 2>/dev/null || echo '')"
assert_contains "R3 marker survives into redacted prompt" "$redacted_body" "REVIEW_OV_MARKER"

# Sanity: inner ran cleanly with the mocked router.
assert_eq "R1b review inner rc=0 (override present)" "0" "$rc"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Case B: no override file → no delimiter, core contract intact            ║
# ╚══════════════════════════════════════════════════════════════════════════╝

FIXTURE_REPO_NOOV="$TEST_TEMP_DIR/fixture-repo-noov"
mkdir -p "$FIXTURE_REPO_NOOV/.zbuild/prompts"
git -C "$FIXTURE_REPO_NOOV" init -q
export ZBUILD_REPO_ROOT="$FIXTURE_REPO_NOOV"

artifact_dir_b="$TEST_TEMP_DIR/state/artifacts-b"
_make_review_inputs "$artifact_dir_b"
review_path_b="$artifact_dir_b/review.json"

set +e
_review_run_inner \
    "$scope_manifest" \
    "$artifact_dir_b/plan.json" \
    "$artifact_dir_b/diff.patch" \
    "$artifact_dir_b/test-results.json" \
    "$review_path_b" \
    "$artifact_dir_b" >/dev/null 2>&1
rc_b=$?
set -e

prompt_file_b="$artifact_dir_b/review-prompt.txt"
prompt_body_b="$(cat "$prompt_file_b" 2>/dev/null || echo '')"

# ─── R4: no override → no delimiter, but core contract anchor still present ──
if printf '%s' "$prompt_body_b" | grep -qF "$DELIM"; then
    assert_fail "R4 no delimiter without override" "override delimiter leaked with no override file"
else
    assert_pass "R4 no delimiter without override"
fi
assert_contains "R4 core contract intact without override" "$prompt_body_b" "$ANCHOR"
assert_eq "R4b review inner rc=0 (no override)" "0" "$rc_b"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
