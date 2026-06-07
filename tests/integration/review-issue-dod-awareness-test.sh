#!/usr/bin/env bash
# Integration: Wave 19-G (#739) — review agent reads intake.md and verifies
# against the issue's Definition of done, not only against the plan.
#
# Tests the prompt-construction path of _review_run_inner: when intake.md
# is provided as the 7th positional arg, the prompt MUST contain the issue
# body labeled "Issue body (authoritative — what 'done' means)". When
# intake.md is absent or empty, the prompt falls back to the legacy shape
# (no issue body section, no behavioral regression).
#
# We intercept the LLM by stubbing route_to_model so we can inspect the
# exact prompt assembled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "review agent reads intake.md + DoD verification discipline (Wave 19-G #739)"
setup_test_env "review-issue-dod-awareness"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
: > "$ZBUILD_EVENTS_JSONL"

ARTIFACTS="$TEST_TEMP_DIR/state/artifacts"
STATE_DIR="$TEST_TEMP_DIR/state"
mkdir -p "$ARTIFACTS"

# Fixtures
SCOPE_MANIFEST="$STATE_DIR/scope-manifest.md"
cat > "$SCOPE_MANIFEST" <<'EOF'
+ ./
EOF

PLAN_JSON="$ARTIFACTS/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"X","goal":"x","steps":[{"id":"step-1","description":"add feature","files":["src/foo.sh"],"estimated_lines":10}],"estimated_total_lines":10,"notes":""}
EOF

DIFF_PATCH="$ARTIFACTS/diff.patch"
printf '' > "$DIFF_PATCH"  # empty diff is fine for prompt construction

TEST_RESULTS="$ARTIFACTS/test-results.json"
cat > "$TEST_RESULTS" <<'EOF'
{"schema_version":1,"verdict":"pass","passed":10,"failed":0,"exit_code":0}
EOF

REVIEW_OUT="$ARTIFACTS/review.json"

# Stub plugin globals.
zbuild_plugin_bootstrap() { _ZBUILD_PLUGIN_DIR="$REPO_ROOT/plugins/agent/review"; _ZBUILD_PLUGIN_ROOT="$REPO_ROOT"; }
emit_event() { return 0; }
warn() { return 0; }
error() { echo "ERROR: $*" >&2; }

# shellcheck source=../../plugins/agent/review/plugin.sh
source "$REPO_ROOT/plugins/agent/review/plugin.sh"

# Re-stub route_to_model AFTER plugin source so we capture the real prompt.
CAPTURED_PROMPT_FILE="$TEST_TEMP_DIR/captured-prompt.txt"
route_to_model() {
    local _tier="$1"
    local _prompt="$2"
    printf '%s' "$_prompt" > "$CAPTURED_PROMPT_FILE"
    # Return a valid review.json so _review_run_inner doesn't abort.
    printf '{"verdict":"approve","confidence":0.9,"issues":[],"summary":"ok"}'
    return 0
}
# Stubs for the redaction pipeline + atomic write so we don't need real files.
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { cat > "$1"; }
extract_first_json_object() { cat; }
render_artifact() { cat; }
_zbuild_sanitize_for_llm() { cat; }
_zbuild_diff_stat() { printf '## Changed files (0 total)\n'; }

print_test_section "1. intake.md present → prompt contains issue body section"

INTAKE_MD="$STATE_DIR/intake.md"
cat > "$INTAKE_MD" <<'EOF'
[A] Migrate stage X
## Definition of done
- [ ] Stage X is invoked by standard.yaml flow
- [ ] Integration test verifies plugin.run.start fires for stage X

## 5-test trial
- [ ] Removing the new implementation reproduces the original symptom
EOF

set +e
_review_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$TEST_RESULTS" "$REVIEW_OUT" "$ARTIFACTS" "$INTAKE_MD"
rc=$?
set -e

assert_eq "T1: _review_run_inner returns rc=0" "0" "$rc"
assert_file_exists "T2: review.json written" "$REVIEW_OUT"
assert_file_exists "T3: prompt was captured" "$CAPTURED_PROMPT_FILE"

prompt_content="$(cat "$CAPTURED_PROMPT_FILE")"

if printf '%s' "$prompt_content" | grep -q "Issue body (authoritative"; then
    assert_pass "T4: prompt contains 'Issue body (authoritative...)' header"
else
    assert_fail "T4: prompt MUST contain Issue body header" "missing"
fi

if printf '%s' "$prompt_content" | grep -q "Definition of done"; then
    assert_pass "T5: prompt contains the issue's 'Definition of done' text"
else
    assert_fail "T5: prompt MUST contain DoD checkboxes from intake.md" "missing"
fi

if printf '%s' "$prompt_content" | grep -q "5-test trial"; then
    assert_pass "T6: prompt contains the issue's '5-test trial' header"
else
    assert_fail "T6: prompt MUST contain 5-test trial section from intake.md" "missing"
fi

if printf '%s' "$prompt_content" | grep -q "Wave 19-G verification discipline"; then
    assert_pass "T7: prompt instruction block carries Wave 19-G discipline"
else
    assert_fail "T7: prompt MUST include the 19-G verification discipline text" "missing"
fi

if printf '%s' "$prompt_content" | grep -q "Plan (plan agent interpretation)"; then
    assert_pass "T8: prompt labels Plan as 'plan agent interpretation' (not authoritative)"
else
    assert_fail "T8: Plan section label MUST clarify it is the plan agent's interpretation" "missing"
fi

print_test_section "2. intake.md missing → falls back to legacy prompt shape"

: > "$CAPTURED_PROMPT_FILE"
rm -f "$REVIEW_OUT"

set +e
_review_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$TEST_RESULTS" "$REVIEW_OUT" "$ARTIFACTS" "$STATE_DIR/nonexistent-intake.md"
rc=$?
set -e

assert_eq "T9: _review_run_inner returns rc=0 (graceful intake-missing fallback)" "0" "$rc"
fallback_prompt="$(cat "$CAPTURED_PROMPT_FILE")"

if printf '%s' "$fallback_prompt" | grep -q "Issue body (authoritative"; then
    assert_fail "T10: fallback prompt MUST NOT contain Issue body header (intake.md absent)" "present"
else
    assert_pass "T10: fallback prompt omits Issue body header when intake.md absent"
fi

if printf '%s' "$fallback_prompt" | grep -q "^Plan:"; then
    assert_pass "T11: fallback prompt uses legacy 'Plan:' label (no behavioral regression)"
else
    assert_fail "T11: fallback prompt MUST use legacy 'Plan:' label" "missing"
fi

print_test_section "3. diff-stat file paths survive redaction (#739 dogfood fix)"

# Reproduce the dogfood symptom: scope-manifest is empty/narrow but the
# diff-stat lists file paths. Pre-fix: every path renders as
# <out-of-scope-context>. Post-fix: diff-stat is prepended AFTER redaction
# so file paths come through verbatim.
NARROW_SCOPE="$STATE_DIR/narrow-scope-manifest.md"
cat > "$NARROW_SCOPE" <<'EOF'
+ docs/
EOF

# Build a diff that touches files OUTSIDE the narrow scope.
DIFF_OUT_OF_SCOPE="$ARTIFACTS/diff-oos.patch"
cat > "$DIFF_OUT_OF_SCOPE" <<'EOF'
diff --git a/plugins/agent/example/plugin.sh b/plugins/agent/example/plugin.sh
new file mode 100644
index 0000000..abcdef
--- /dev/null
+++ b/plugins/agent/example/plugin.sh
@@ -0,0 +1,3 @@
+#!/usr/bin/env bash
+# example plugin
+true
EOF

# Need a real diff-stat block based on this patch. Override the helper.
_zbuild_diff_stat() { printf '## Changed files (1 total, +3 -0)\n+3 -0  plugins/agent/example/plugin.sh\n'; }

: > "$CAPTURED_PROMPT_FILE"
rm -f "$REVIEW_OUT"

set +e
_review_run_inner "$NARROW_SCOPE" "$PLAN_JSON" "$DIFF_OUT_OF_SCOPE" "$TEST_RESULTS" "$REVIEW_OUT" "$ARTIFACTS" "$INTAKE_MD"
rc=$?
set -e

assert_eq "T_DS1: review runs successfully with out-of-scope diff" "0" "$rc"

diff_stat_prompt="$(cat "$CAPTURED_PROMPT_FILE")"

if printf '%s' "$diff_stat_prompt" | grep -q "plugins/agent/example/plugin.sh"; then
    assert_pass "T_DS2: diff-stat file paths survive redaction (NOT wrapped in <out-of-scope-context>)"
else
    assert_fail "T_DS2: diff-stat MUST surface file paths verbatim — dogfood gap" "out-of-scope wrapper present"
fi

if printf '%s' "$diff_stat_prompt" | grep -q "## Changed files"; then
    assert_pass "T_DS3: diff-stat header survives ('## Changed files' present)"
else
    assert_fail "T_DS3: diff-stat header MUST be present" "missing"
fi

# Restore default stub for subsequent sections.
_zbuild_diff_stat() { printf '## Changed files (0 total)\n'; }

print_test_section "4. intake.md present but empty → graceful fallback"

: > "$CAPTURED_PROMPT_FILE"
rm -f "$REVIEW_OUT"
EMPTY_INTAKE="$STATE_DIR/empty-intake.md"
: > "$EMPTY_INTAKE"

set +e
_review_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" "$TEST_RESULTS" "$REVIEW_OUT" "$ARTIFACTS" "$EMPTY_INTAKE"
rc=$?
set -e

assert_eq "T12: _review_run_inner returns rc=0 for empty intake.md" "0" "$rc"
empty_prompt="$(cat "$CAPTURED_PROMPT_FILE")"

if printf '%s' "$empty_prompt" | grep -q "Issue body (authoritative"; then
    assert_fail "T13: empty intake.md MUST trigger fallback (no Issue body header)" "present"
else
    assert_pass "T13: empty intake.md triggers legacy prompt fallback"
fi

print_test_results
cleanup_test_env
exit $((FAIL > 0))
