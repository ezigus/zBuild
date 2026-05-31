#!/usr/bin/env bash
# Tests: plugins/agent/build — build stage agent (issues #341, #467)
# Updated for ADR-018 Pattern 2: route_to_model_loop + git-derived diff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: build (agent-loop + git-derived diff — issue #467)"

setup_test_env "plugin-build"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

export ZBUILD_RUN_ID="build-test-$$"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_ISSUE="341"

PLUGIN_DIR="$REPO_ROOT/plugins/agent/build"

# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

# ─── Shared fixtures ─────────────────────────────────────────────────────────
SCOPE_MANIFEST="$TEST_TEMP_DIR/scope-manifest.md"
cat > "$SCOPE_MANIFEST" <<'EOF'
+ core/
+ tests/
+ plugins/
EOF

# ─── Test git repo setup ─────────────────────────────────────────────────────
# Each inner-run gets its own temp git repo so `git diff HEAD` is meaningful.
setup_build_repo() {
    local name="$1"
    local repo="$TEST_TEMP_DIR/$name"
    mkdir -p "$repo/tests/fixtures"
    ( cd "$repo" \
      && git init -q \
      && git config user.email "test@zbuild" \
      && git config user.name  "zbuild-test" \
      && echo "seed" > tests/fixtures/seed.txt \
      && git add tests/fixtures/seed.txt \
      && git commit -q -m "seed" )
    printf '%s\n' "$repo"
}

# ─── Prompt-capture mock (file-based — survives subshell boundary) ───────────
_CAPTURED_PROMPT_FILE="$TEST_TEMP_DIR/captured-build-prompt.txt"
: > "$_CAPTURED_PROMPT_FILE"

# apply_scope_redaction passthrough
apply_scope_redaction() {
    local _input="$1"
    local _output="$2"
    cp "$_input" "$_output"
    emit_event "redaction.applied" \
        "input=$_input" "output=$_output" \
        "size_before=0" "size_after=0" "redactions=0" \
        "scope_hash=mock" "cycle=0"
    return 0
}

# Mock route_to_model_loop: writes the prompt file content to the capture file,
# performs the configured edit inside $cwd, sets loop globals, returns rc.
# Behavior controlled by globals MOCK_LOOP_EDIT_FILE / MOCK_LOOP_EDIT_CONTENT /
# MOCK_LOOP_RC / MOCK_LOOP_REASON / MOCK_LOOP_ITERATIONS.
MOCK_LOOP_EDIT_FILE=""
MOCK_LOOP_EDIT_CONTENT=""
MOCK_LOOP_RC=0
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_ITERATIONS=1
route_to_model_loop() {
    # Args: tier prompt_file cwd max_iterations [flags...]
    local _prompt_file="$2"
    local _cwd="$3"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_CAPTURED_PROMPT_FILE"
    if [[ -n "$MOCK_LOOP_EDIT_FILE" && -d "$_cwd" ]]; then
        mkdir -p "$_cwd/$(dirname "$MOCK_LOOP_EDIT_FILE")"
        printf '%s' "$MOCK_LOOP_EDIT_CONTENT" > "$_cwd/$MOCK_LOOP_EDIT_FILE"
    fi
    _ROUTE_LOOP_ITERATIONS="$MOCK_LOOP_ITERATIONS"
    _ROUTE_LOOP_TERMINATED_REASON="$MOCK_LOOP_REASON"
    _ROUTE_LOOP_INPUT_TOKENS=100
    _ROUTE_LOOP_OUTPUT_TOKENS=50
    return "$MOCK_LOOP_RC"
}

# ─── T_PROMPT fixtures ───────────────────────────────────────────────────────
ARTIFACT_DIR_PROMPT="$TEST_TEMP_DIR/artifacts_prompt"
mkdir -p "$ARTIFACT_DIR_PROMPT"

PLAN_JSON_PROMPT="$ARTIFACT_DIR_PROMPT/plan.json"
cat > "$PLAN_JSON_PROMPT" <<'EOF'
{
  "schema_version": 1,
  "goal": "Add dummy fixture file for build-stage prompt tests",
  "steps": [
    {"id": "step-1", "description": "create fixture", "files": ["tests/fixtures/build-test-dummy.txt"], "estimated_lines": 1}
  ]
}
EOF

OUT_DIFF_PROMPT="$ARTIFACT_DIR_PROMPT/diff.patch"
OUT_SUMMARY_PROMPT="$ARTIFACT_DIR_PROMPT/build-summary.json"

# Configure mock to edit tests/fixtures/build-test-dummy.txt inside the repo.
REPO_PROMPT="$(setup_build_repo "repo_prompt")"
export ZBUILD_REPO_ROOT="$REPO_PROMPT"
MOCK_LOOP_EDIT_FILE="tests/fixtures/build-test-dummy.txt"
MOCK_LOOP_EDIT_CONTENT="dummy"
MOCK_LOOP_ITERATIONS=2
MOCK_LOOP_REASON="done_sentinel"

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_PROMPT" \
    "$OUT_DIFF_PROMPT" \
    "$OUT_SUMMARY_PROMPT" \
    "$ARTIFACT_DIR_PROMPT" >/dev/null 2>&1
rc_prompt=$?
set -e

_captured_prompt="$(cat "$_CAPTURED_PROMPT_FILE")"

# ─── T_PROMPT_1: Prompt contents (ADR-018 Pattern 2) ─────────────────────────
print_test_section "T_PROMPT_1: prompt invites tools and declares scope + sentinel"

assert_exit_code "T_PROMPT_1 inner run returns rc=0" "0" "$rc_prompt"
assert_contains "prompt mentions Read/Edit/Write/Bash tools"  "$_captured_prompt" "Read, Edit, Write, and"
assert_contains "prompt mentions LOOP_COMPLETE sentinel"      "$_captured_prompt" "LOOP_COMPLETE"
assert_contains "prompt mentions scope (plan.files[])"        "$_captured_prompt" "plan.files[]"
assert_contains "prompt lists the in-scope file"              "$_captured_prompt" "build-test-dummy.txt"
assert_contains "prompt forbids out-of-scope edits"           "$_captured_prompt" "out-of-scope"

# ─── T_PROMPT_2: Real edit produces non-empty diff.patch ─────────────────────
print_test_section "T_PROMPT_2: agent edit → non-empty diff.patch"

diff_lines_prompt=0
[[ -f "$OUT_DIFF_PROMPT" ]] && diff_lines_prompt="$(grep -c . "$OUT_DIFF_PROMPT" 2>/dev/null || true)"
if [[ "$diff_lines_prompt" -gt 0 ]]; then
    assert_pass "diff.patch has lines > 0 ($diff_lines_prompt lines)"
else
    assert_fail "diff.patch unexpectedly empty after agent edit"
fi
assert_contains "diff.patch contains target file path" "$(cat "$OUT_DIFF_PROMPT")" "build-test-dummy.txt"

# ─── T_PROMPT_3: Prose-only (no edits) → empty diff, rc=0, build.empty_diff ──
print_test_section "T_PROMPT_3: prose-only response → empty diff.patch, rc=0"

ARTIFACT_DIR_PROSE="$TEST_TEMP_DIR/artifacts_prose"
mkdir -p "$ARTIFACT_DIR_PROSE"
PLAN_JSON_PROSE="$ARTIFACT_DIR_PROSE/plan.json"
cp "$PLAN_JSON_PROMPT" "$PLAN_JSON_PROSE"
OUT_DIFF_PROSE="$ARTIFACT_DIR_PROSE/diff.patch"
OUT_SUMMARY_PROSE="$ARTIFACT_DIR_PROSE/build-summary.json"

REPO_PROSE="$(setup_build_repo "repo_prose")"
export ZBUILD_REPO_ROOT="$REPO_PROSE"
MOCK_LOOP_EDIT_FILE=""
MOCK_LOOP_EDIT_CONTENT=""
MOCK_LOOP_REASON="max_iterations"
MOCK_LOOP_ITERATIONS=10
MOCK_LOOP_RC=1

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_PROSE" \
    "$OUT_DIFF_PROSE" \
    "$OUT_SUMMARY_PROSE" \
    "$ARTIFACT_DIR_PROSE" >/dev/null 2>&1
rc_prose=$?
set -e

assert_exit_code "prose response returns rc=0" "0" "$rc_prose"
prose_size=0
[[ -f "$OUT_DIFF_PROSE" ]] && prose_size="$(wc -c < "$OUT_DIFF_PROSE" | tr -d ' ')"
if [[ "$prose_size" -eq 0 ]]; then
    assert_pass "diff.patch is empty when agent makes no edits"
else
    assert_fail "diff.patch unexpectedly non-empty for prose-only run ($prose_size bytes)"
fi
assert_event_emitted "build.empty_diff event fired" "$ZBUILD_EVENTS_JSONL" "build.empty_diff"

# Reset mock to default success
MOCK_LOOP_RC=0
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_ITERATIONS=1

# ─── Test 1: build_stage_init sets env ───────────────────────────────────────
print_test_section "T1: build_stage_init sets ZBUILD_PLUGIN=build"

build_stage_init >/dev/null 2>&1
assert_eq "build_stage_init: ZBUILD_PLUGIN=build" "build" "$ZBUILD_PLUGIN"
assert_eq "build_stage_init: ZBUILD_PLUGIN_KIND=agent" "agent" "$ZBUILD_PLUGIN_KIND"

# ─── Test 2: missing plan.json returns rc=2 ───────────────────────────────────
print_test_section "T2: missing plan.json returns rc=2"

ARTIFACT_DIR_T2="$TEST_TEMP_DIR/artifacts_t2"
mkdir -p "$ARTIFACT_DIR_T2"
NONEXISTENT_PLAN="$ARTIFACT_DIR_T2/does-not-exist.json"
OUT_DIFF_T2="$ARTIFACT_DIR_T2/diff.patch"
OUT_SUMMARY_T2="$ARTIFACT_DIR_T2/build-summary.json"

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$NONEXISTENT_PLAN" \
    "$OUT_DIFF_T2" \
    "$OUT_SUMMARY_T2" \
    "$ARTIFACT_DIR_T2" >/dev/null 2>&1
rc_t2=$?
set -e

assert_exit_code "missing plan.json yields rc=2" "2" "$rc_t2"
assert_file_not_exists "no diff.patch written when plan.json missing" "$OUT_DIFF_T2"
assert_file_not_exists "no build-summary.json written when plan.json missing" "$OUT_SUMMARY_T2"

# ─── Test 3: produces diff.patch + build-summary.json via mocked loop ────────
print_test_section "T3: produces diff.patch and build-summary.json with mocked loop"

ARTIFACT_DIR_T3="$TEST_TEMP_DIR/artifacts_t3"
mkdir -p "$ARTIFACT_DIR_T3"

PLAN_JSON_T3="$ARTIFACT_DIR_T3/plan.json"
cat > "$PLAN_JSON_T3" <<'EOF'
{
  "schema_version": 1,
  "goal": "Add dummy fixture file for build-stage test",
  "files": ["tests/fixtures/build-test-dummy.txt"],
  "steps": [
    {"id": 1, "action": "create", "path": "tests/fixtures/build-test-dummy.txt", "content": "dummy"}
  ]
}
EOF

OUT_DIFF_T3="$ARTIFACT_DIR_T3/diff.patch"
OUT_SUMMARY_T3="$ARTIFACT_DIR_T3/build-summary.json"

REPO_T3="$(setup_build_repo "repo_t3")"
export ZBUILD_REPO_ROOT="$REPO_T3"
MOCK_LOOP_EDIT_FILE="tests/fixtures/build-test-dummy.txt"
MOCK_LOOP_EDIT_CONTENT="dummy content"
MOCK_LOOP_ITERATIONS=3
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_RC=0

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_T3" \
    "$OUT_DIFF_T3" \
    "$OUT_SUMMARY_T3" \
    "$ARTIFACT_DIR_T3" >/dev/null 2>&1
rc_t3=$?
set -e

assert_exit_code "mocked inner run returns rc=0" "0" "$rc_t3"
assert_file_exists "diff.patch artifact produced" "$OUT_DIFF_T3"
assert_file_exists "build-summary.json artifact produced" "$OUT_SUMMARY_T3"

diff_content_t3="$(cat "$OUT_DIFF_T3")"
assert_contains "diff.patch contains diff --git header" "$diff_content_t3" "diff --git"
assert_contains "diff.patch contains target file" "$diff_content_t3" "build-test-dummy.txt"

summary_json_t3="$(cat "$OUT_SUMMARY_T3")"
if printf '%s' "$summary_json_t3" | jq empty >/dev/null 2>&1; then
    assert_pass "build-summary.json is valid JSON"
else
    assert_fail "build-summary.json is not valid JSON"
fi

# ─── Test 4: build-summary.json schema_version=3 + new fields ────────────────
# #507 bumped schema_version to 3 to add the .verdict field.
print_test_section "T4: build-summary.json has schema_version=3 + loop fields"

assert_json_key "schema_version == 3" "$summary_json_t3" ".schema_version" "3"
assert_json_key "verdict field present (#507)" "$summary_json_t3" ".verdict" "pass"

files_changed_type="$(printf '%s' "$summary_json_t3" | jq -r '.files_changed | type' 2>/dev/null || echo "missing")"
assert_eq "files_changed is an array" "array" "$files_changed_type"

assert_json_key "issue matches ZBUILD_ISSUE=341" "$summary_json_t3" ".issue" "341"
assert_json_key "iterations == 3"               "$summary_json_t3" ".iterations" "3"
assert_json_key "terminated_reason == done_sentinel" "$summary_json_t3" ".terminated_reason" "done_sentinel"
assert_json_key "scope_violation == false"      "$summary_json_t3" ".scope_violation" "false"
assert_json_key "loop_input_tokens == 100"      "$summary_json_t3" ".loop_input_tokens" "100"
assert_json_key "loop_output_tokens == 50"      "$summary_json_t3" ".loop_output_tokens" "50"

diff_patch_path_val="$(printf '%s' "$summary_json_t3" | jq -r '.diff_patch_path // empty' 2>/dev/null || echo "")"
[[ -n "$diff_patch_path_val" ]] && assert_pass "diff_patch_path field is present and non-empty" \
    || assert_fail "diff_patch_path field missing or empty"

notes_val="$(printf '%s' "$summary_json_t3" | jq -r '.notes // empty' 2>/dev/null || echo "")"
[[ -n "$notes_val" ]] && assert_pass "notes field is present and non-empty" \
    || assert_fail "notes field missing or empty"

scope_violations_type="$(printf '%s' "$summary_json_t3" | jq -r '.scope_violations | type' 2>/dev/null || echo "missing")"
assert_eq "scope_violations is an array" "array" "$scope_violations_type"

# ─── Test 5: build_stage_finalize runs cleanly ───────────────────────────────
print_test_section "T5: build_stage_finalize returns rc=0"

set +e
build_stage_finalize >/dev/null 2>&1
rc_finalize=$?
set -e
assert_exit_code "build_stage_finalize returns rc=0" "0" "$rc_finalize"

if [[ -f "$ZBUILD_EVENTS_JSONL" ]]; then
    finalize_count="$(grep -c '"plugin.finalize.complete"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
    if [[ "$finalize_count" -ge 1 ]]; then
        assert_pass "plugin.finalize.complete event emitted by finalize"
    else
        assert_fail "plugin.finalize.complete event not found in event log"
    fi
else
    assert_pass "build_stage_finalize returned rc=0 (event log not yet written)"
fi

# ─── Test 6: Out-of-scope edit → build.scope.violation + empty diff.patch ────
print_test_section "T6: out-of-scope edit → scope_violation=true, empty diff.patch, rc=0"

ARTIFACT_DIR_T6="$TEST_TEMP_DIR/artifacts_t6"
mkdir -p "$ARTIFACT_DIR_T6"
PLAN_JSON_T6="$ARTIFACT_DIR_T6/plan.json"
cat > "$PLAN_JSON_T6" <<'EOF'
{
  "schema_version": 1,
  "files": ["core/safe.sh"],
  "steps": []
}
EOF
OUT_DIFF_T6="$ARTIFACT_DIR_T6/diff.patch"
OUT_SUMMARY_T6="$ARTIFACT_DIR_T6/build-summary.json"

REPO_T6="$(setup_build_repo "repo_t6")"
export ZBUILD_REPO_ROOT="$REPO_T6"
MOCK_LOOP_EDIT_FILE="dangerous/secrets.txt"
MOCK_LOOP_EDIT_CONTENT="leaked"
MOCK_LOOP_ITERATIONS=1
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_RC=0

set +e
_build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_T6" \
    "$OUT_DIFF_T6" \
    "$OUT_SUMMARY_T6" \
    "$ARTIFACT_DIR_T6" >/dev/null 2>&1
rc_t6=$?
set -e

assert_exit_code "scope violation returns rc=0 (review verdicts)" "0" "$rc_t6"
t6_size=0
[[ -f "$OUT_DIFF_T6" ]] && t6_size="$(wc -c < "$OUT_DIFF_T6" | tr -d ' ')"
assert_eq "diff.patch is empty on scope violation (0 bytes)" "0" "$t6_size"

summary_t6="$(cat "$OUT_SUMMARY_T6")"
assert_json_key "scope_violation == true" "$summary_t6" ".scope_violation" "true"

t6_violation_count="$(printf '%s' "$summary_t6" | jq '.scope_violations | length' 2>/dev/null || echo 0)"
if [[ "$t6_violation_count" -ge 1 ]]; then
    assert_pass "scope_violations array lists offending path"
else
    assert_fail "scope_violations array is empty"
fi
assert_event_emitted "build.scope.violation event fired" "$ZBUILD_EVENTS_JSONL" "build.scope.violation"

# ─── #498: _build_format_numstat unit tests ─────────────────────────────────
print_test_section "T7: _build_format_numstat — single-file rendering"

_allowed_empty=()
# Run NOT in subshell so _BUILD_NUMSTAT_FILES_COUNT propagates. Capture stdout
# via redirection-to-file instead of $().
_t7_out="$TEST_TEMP_DIR/t7-numstat.txt"
_build_format_numstat $'12\t0\tcore/foo.sh' _allowed_empty > "$_t7_out"
out_single="$(cat "$_t7_out")"
assert_contains "single-file shows +12 -0 line" "$out_single" "+12 -0  core/foo.sh"
assert_contains "single-file footer: 1 file, +12 -0" "$out_single" "total: 1 files, +12 -0"
assert_eq "single-file _BUILD_NUMSTAT_FILES_COUNT == 1" "1" "$_BUILD_NUMSTAT_FILES_COUNT"

print_test_section "T8: _build_format_numstat — multi-file totals"
_allowed_empty=()
multi_input=$'5\t2\ta.sh\n10\t3\tb.sh\n1\t0\tc.sh'
out_multi="$(_build_format_numstat "$multi_input" _allowed_empty)"
assert_contains "multi-file footer: 3 files, +16 -5" "$out_multi" "total: 3 files, +16 -5"
assert_contains "multi-file includes a.sh" "$out_multi" "a.sh"
assert_contains "multi-file includes b.sh" "$out_multi" "b.sh"
assert_contains "multi-file includes c.sh" "$out_multi" "c.sh"

print_test_section "T9: _build_format_numstat — empty diff"
_allowed_empty=()
_t9_out="$TEST_TEMP_DIR/t9-numstat.txt"
_build_format_numstat "" _allowed_empty > "$_t9_out"
out_empty="$(cat "$_t9_out")"
assert_contains "empty footer: 0 files, +0 -0" "$out_empty" "total: 0 files, +0 -0"
assert_eq "empty _BUILD_NUMSTAT_FILES_COUNT == 0" "0" "$_BUILD_NUMSTAT_FILES_COUNT"

print_test_section "T10: _build_format_numstat — binary file (-\\t-\\tpath)"
_allowed_empty=()
out_bin="$(_build_format_numstat $'-\t-\tassets/logo.png' _allowed_empty)"
assert_contains "binary file shown with '-' counts" "$out_bin" "+- --  assets/logo.png"
assert_contains "binary file counted as 1 file" "$out_bin" "total: 1 files, +0 -0"

print_test_section "T11: _build_format_numstat — out-of-scope path redaction"
_allowed_in=(core/ tests/)
out_redact="$(_build_format_numstat $'3\t1\tdangerous/secrets.txt\n5\t0\tcore/safe.sh' _allowed_in)"
assert_contains "out-of-scope path replaced with marker" "$out_redact" "<out-of-scope-context>"
assert_contains "in-scope path rendered verbatim" "$out_redact" "core/safe.sh"
if printf '%s' "$out_redact" | grep -q "dangerous/secrets.txt"; then
    assert_fail "out-of-scope path leaked to banner" "found dangerous/secrets.txt in $out_redact"
else
    assert_pass "out-of-scope literal path NOT in banner"
fi

print_test_section "T12: _build_format_numstat — truncation cap (50)"
_allowed_empty=()
big_input=""
for i in $(seq 1 60); do
    big_input+=$'1\t0\tf'"${i}.sh"$'\n'
done
big_input="${big_input%$'\n'}"
# Reset events file so we can assert the truncation event.
: > "$ZBUILD_EVENTS_JSONL"
out_big="$(_build_format_numstat "$big_input" _allowed_empty)"
assert_contains "truncation hint emitted (#506 unified format)" "$out_big" "↪ [10 more files · full at build-summary.json]"
assert_contains "truncated footer: 60 files, +60 -0" "$out_big" "total: 60 files, +60 -0"
shown_count="$(printf '%s\n' "$out_big" | grep -c '^+1 -0  f' || true)"
assert_eq "exactly 50 numstat lines shown when total=60" "50" "$shown_count"
assert_event_emitted "build.numstat.truncated event fired" \
    "$ZBUILD_EVENTS_JSONL" "build.numstat.truncated"

# ─── T13: end-to-end — _build_emit_changed_files_summary on a real repo ────
print_test_section "T13: emit summary on real repo with edits → banner + computed event"

ARTIFACT_DIR_T13="$TEST_TEMP_DIR/artifacts_t13"
mkdir -p "$ARTIFACT_DIR_T13"
PLAN_JSON_T13="$ARTIFACT_DIR_T13/plan.json"
cat > "$PLAN_JSON_T13" <<'EOF'
{
  "schema_version": 1,
  "files": ["tests/fixtures/build-test-dummy.txt"],
  "steps": []
}
EOF
OUT_DIFF_T13="$ARTIFACT_DIR_T13/diff.patch"
OUT_SUMMARY_T13="$ARTIFACT_DIR_T13/build-summary.json"

REPO_T13="$(setup_build_repo "repo_t13")"
export ZBUILD_REPO_ROOT="$REPO_T13"
MOCK_LOOP_EDIT_FILE="tests/fixtures/build-test-dummy.txt"
MOCK_LOOP_EDIT_CONTENT="hello-498"
MOCK_LOOP_ITERATIONS=2
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_RC=0

# Configure a template that has stdout destination so the banner emits.
TEMPLATE_T13="$TEST_TEMP_DIR/template-t13.yaml"
cat > "$TEMPLATE_T13" <<'YAML'
id: standard
name: Standard Pipeline
extends: null
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file, stdout]
      tail_lines: 80
YAML
# Load template module + template (stage-io reads destinations via this).
# shellcheck source=../../../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
load_template "$TEMPLATE_T13"
export ZBUILD_CURRENT_STAGE=build

BANNER_T13="$TEST_TEMP_DIR/banner-t13.txt"
: > "$ZBUILD_EVENTS_JSONL"
set +e
ZBUILD_STAGE_IO_FD=3 _build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_T13" \
    "$OUT_DIFF_T13" \
    "$OUT_SUMMARY_T13" \
    "$ARTIFACT_DIR_T13" >/dev/null 2>/dev/null 3>"$BANNER_T13"
rc_t13=$?
set -e

assert_exit_code "T13 inner run rc=0" "0" "$rc_t13"
banner_t13="$(cat "$BANNER_T13" 2>/dev/null || true)"
assert_contains "computed banner emitted for build stage (#523)" "$banner_t13" "build [computed]"
assert_contains "computed banner shows numstat input literal" "$banner_t13" "git diff HEAD --numstat"
assert_contains "computed banner shows the changed file" "$banner_t13" "build-test-dummy.txt"
assert_contains "computed banner shows total footer" "$banner_t13" "total: 1 files"
captured_computed="$(jq -c --arg t "stage.io.captured" \
    'select(.type==$t and .data.stage=="build" and .data.kind=="computed")' \
    "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "exactly 1 stage.io.captured event with kind=computed" "1" "$captured_computed"

# ─── T14: discrepancy detection — LOOP_COMPLETE + 0 changed files ──────────
print_test_section "T14: LOOP_COMPLETE + 0 files → build.discrepancy.detected + WARN"

ARTIFACT_DIR_T14="$TEST_TEMP_DIR/artifacts_t14"
mkdir -p "$ARTIFACT_DIR_T14"
PLAN_JSON_T14="$ARTIFACT_DIR_T14/plan.json"
cp "$PLAN_JSON_T13" "$PLAN_JSON_T14"
OUT_DIFF_T14="$ARTIFACT_DIR_T14/diff.patch"
OUT_SUMMARY_T14="$ARTIFACT_DIR_T14/build-summary.json"

REPO_T14="$(setup_build_repo "repo_t14")"
export ZBUILD_REPO_ROOT="$REPO_T14"
MOCK_LOOP_EDIT_FILE=""
MOCK_LOOP_EDIT_CONTENT=""
MOCK_LOOP_ITERATIONS=1
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_RC=0

BANNER_T14="$TEST_TEMP_DIR/banner-t14.txt"
: > "$ZBUILD_EVENTS_JSONL"
set +e
ZBUILD_STAGE_IO_FD=3 _build_stage_run_inner \
    "$SCOPE_MANIFEST" \
    "$PLAN_JSON_T14" \
    "$OUT_DIFF_T14" \
    "$OUT_SUMMARY_T14" \
    "$ARTIFACT_DIR_T14" >/dev/null 2>/dev/null 3>"$BANNER_T14"
rc_t14=$?
set -e
assert_exit_code "T14 inner run rc=0" "0" "$rc_t14"
banner_t14="$(cat "$BANNER_T14" 2>/dev/null || true)"
assert_contains "T14 WARN banner line emitted" "$banner_t14" "WARN: LLM signaled success but numstat shows 0 files changed"
assert_event_emitted "build.discrepancy.detected event fired" \
    "$ZBUILD_EVENTS_JSONL" "build.discrepancy.detected"

# Reset to defaults for any subsequent tests.
MOCK_LOOP_RC=0
MOCK_LOOP_REASON="done_sentinel"
MOCK_LOOP_ITERATIONS=1

# ─── Teardown ────────────────────────────────────────────────────────────────
_test_cleanup_hook() { cleanup_test_env; }
cleanup_test_env
print_test_results
exit $((FAIL > 0))
