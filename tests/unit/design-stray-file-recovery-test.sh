#!/usr/bin/env bash
# Tests: design plugin ADR-018 Pattern 2 single-file-artifact contract (#817).
#
# The design stage's LLM is told to write design.md at an absolute path. If it
# writes to repo-root instead — a real failure observed in dogfood
# run_id 20260612060213-30653 — the plugin must:
#
#   (a) recover an UNTRACKED stray by mv + emit design.stray.recovered
#   (b) REFUSE a TRACKED stray (operator-owned doc) by emitting
#       design.stray.conflict reason=tracked and returning rc=1
#   (c) be a no-op when the LLM correctly writes to the declared path
#
# Companion ADR amendment lives in #816 (PR #820): ADR-018 §"Pattern 2
# outputs — derived diff vs single-file artifact".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: stray-file recovery + ADR-018 destination-path contract (#817)"
setup_test_env "design-stray-file-recovery"

# A fresh git repo each test — git ls-files needs a real worktree.
_init_git_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init --quiet >/dev/null 2>&1
    git -C "$dir" config user.email 'test@example.com' >/dev/null 2>&1
    git -C "$dir" config user.name  'test' >/dev/null 2>&1
}

# Capture the prompt route_to_model_loop sees + mock its file-write behavior.
# Behavior is driven by env vars set per test:
#   MOCK_DESIGN_WRITE_PATH   — where the mock "LLM" writes design.md (or empty for no write)
#   MOCK_DESIGN_BODY         — the contents to write (default: minimal valid scope block)
_MOCK_ROUTE_PROMPT_CAPTURE="$TEST_TEMP_DIR/captured-prompt.txt"

# Source the design plugin FIRST so the real route.sh + scope-redaction.sh
# get loaded, THEN override their public functions with mocks. This is the
# only ordering that wins — if mocks come first, the plugin's own `source`
# directives replace them.
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

route_to_model_loop() {
    local _prompt_file="$2"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_MOCK_ROUTE_PROMPT_CAPTURE"
    # Default body: a minimal valid design.md with scope + acceptance blocks.
    # printf-built to avoid heredoc backtick/quote portability quirks between
    # bash 3.2 (macOS) and bash 5.x (Linux CI). Backticks written as %s args.
    local _body
    if [[ -n "${MOCK_DESIGN_BODY:-}" ]]; then
        _body="$MOCK_DESIGN_BODY"
    else
        local _bt='```'
        _body="$(printf '# Design\n\n## Decision\nImplement per plan.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC: foo works\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' "$_bt" "$_bt" "$_bt" "$_bt")"
    fi
    if [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]]; then
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '%s' "$_body" > "$MOCK_DESIGN_WRITE_PATH"
    fi
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

apply_scope_redaction() {
    cp "$1" "$2"
    return 0
}

atomic_write() {
    local dest="$1"; cat - > "$dest"
}

# ─── Per-test fixture helper — sets caller-visible globals directly ──────────
# Globals set: FIXTURE_DIR, SCOPE_MANIFEST, PLAN_JSON, OUTPUT_MD, ARTIFACT_DIR
# Plus exports ZBUILD_REPO_ROOT + ZBUILD_EVENTS_JSONL for the plugin.
_setup_test_fixture() {
    local test_id="$1"
    FIXTURE_DIR="$TEST_TEMP_DIR/$test_id"
    _init_git_fixture "$FIXTURE_DIR"
    local state_dir="$FIXTURE_DIR/state"
    ARTIFACT_DIR="$state_dir/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    SCOPE_MANIFEST="$state_dir/scope-manifest.md"
    PLAN_JSON="$ARTIFACT_DIR/plan.json"
    OUTPUT_MD="$ARTIFACT_DIR/design.md"
    printf 'scope: all\n' > "$SCOPE_MANIFEST"
    cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
    export ZBUILD_REPO_ROOT="$FIXTURE_DIR"
    export ZBUILD_EVENTS_JSONL="$state_dir/events.jsonl"
    export ZBUILD_EVENTS_DIR="$state_dir"
    : > "$ZBUILD_EVENTS_JSONL"
}

# ─── T1: untracked stray → mv into place + design.stray.recovered ────────────
_setup_test_fixture t1
fixture="$FIXTURE_DIR"; scope_manifest="$SCOPE_MANIFEST"; plan_json="$PLAN_JSON"; output_md="$OUTPUT_MD"; artifact_dir="$ARTIFACT_DIR"
MOCK_DESIGN_WRITE_PATH="$fixture/design.md"   # LLM writes to repo root, not declared path
set +e
_design_stage_run_inner "$scope_manifest" "$plan_json" "$output_md" "$artifact_dir"
rc=$?
set -e
assert_eq "T1: recovery branch returns rc=0" "0" "$rc"
[[ -f "$output_md" ]] \
    && assert_pass "T1: design.md present at declared path after recovery" \
    || assert_fail "T1: design.md missing at declared path"
[[ ! -f "$fixture/design.md" ]] \
    && assert_pass "T1: stray file removed from repo root" \
    || assert_fail "T1: stray still at repo root after mv"
if grep -q '"design.stray.recovered"' "$ZBUILD_EVENTS_JSONL"; then
    assert_pass "T1: design.stray.recovered event emitted"
else
    assert_fail "T1: design.stray.recovered missing" "events: $(head -c 200 "$ZBUILD_EVENTS_JSONL")"
fi
unset MOCK_DESIGN_WRITE_PATH

# ─── T2: tracked stray at repo root → refuse + design.stray.conflict ─────────
_setup_test_fixture t2
fixture="$FIXTURE_DIR"; scope_manifest="$SCOPE_MANIFEST"; plan_json="$PLAN_JSON"; output_md="$OUTPUT_MD"; artifact_dir="$ARTIFACT_DIR"
# Pre-create AND git-track a design.md at repo root before the LLM runs.
printf '# Operator-owned design doc\n' > "$fixture/design.md"
git -C "$fixture" add design.md >/dev/null
git -C "$fixture" commit -m 'pre-existing design doc' --quiet >/dev/null
MOCK_DESIGN_WRITE_PATH="$fixture/design.md"   # LLM overwrites the tracked file
_bt='```'
MOCK_DESIGN_BODY="$(printf '# Overwritten by LLM\n%sscope\nfoo.sh\n%s\n' "$_bt" "$_bt")"
unset _bt
set +e
_design_stage_run_inner "$scope_manifest" "$plan_json" "$output_md" "$artifact_dir"
rc=$?
set -e
assert_eq "T2: tracked-conflict branch returns rc=1" "1" "$rc"
if grep -q '"design.stray.conflict"' "$ZBUILD_EVENTS_JSONL" && \
   grep '"design.stray.conflict"' "$ZBUILD_EVENTS_JSONL" | grep -q '"reason":"tracked"'; then
    assert_pass "T2: design.stray.conflict reason=tracked emitted"
else
    assert_fail "T2: design.stray.conflict missing or wrong reason" "events: $(cat "$ZBUILD_EVENTS_JSONL")"
fi
# The tracked file is still on disk (NOT moved/deleted) but its content was
# overwritten by the mock LLM. The plugin's job here is just to refuse —
# preserving the file is git's job (operator can `git checkout` to recover).
[[ -f "$fixture/design.md" ]] \
    && assert_pass "T2: tracked file path still exists at repo root" \
    || assert_fail "T2: tracked file path missing — plugin should not delete"
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY

# ─── T3: no-op when LLM writes correctly to declared path ────────────────────
_setup_test_fixture t3
fixture="$FIXTURE_DIR"; scope_manifest="$SCOPE_MANIFEST"; plan_json="$PLAN_JSON"; output_md="$OUTPUT_MD"; artifact_dir="$ARTIFACT_DIR"
MOCK_DESIGN_WRITE_PATH="$output_md"   # LLM does the right thing
set +e
_design_stage_run_inner "$scope_manifest" "$plan_json" "$output_md" "$artifact_dir"
rc=$?
set -e
assert_eq "T3: happy-path rc=0" "0" "$rc"
[[ -f "$output_md" ]] \
    && assert_pass "T3: design.md at declared path" \
    || assert_fail "T3: design.md missing on happy path"
if ! grep -q '"design.stray.recovered"' "$ZBUILD_EVENTS_JSONL" 2>/dev/null && \
   ! grep -q '"design.stray.conflict"'  "$ZBUILD_EVENTS_JSONL" 2>/dev/null; then
    assert_pass "T3: no stray-event noise on happy path"
else
    assert_fail "T3: stray event spurious on happy path"
fi
unset MOCK_DESIGN_WRITE_PATH

# ─── T4: prompt contains the absolute destination path ──────────────────────
_setup_test_fixture t4
fixture="$FIXTURE_DIR"; scope_manifest="$SCOPE_MANIFEST"; plan_json="$PLAN_JSON"; output_md="$OUTPUT_MD"; artifact_dir="$ARTIFACT_DIR"
MOCK_DESIGN_WRITE_PATH="$output_md"
set +e
_design_stage_run_inner "$scope_manifest" "$plan_json" "$output_md" "$artifact_dir" >/dev/null 2>&1
set -e
if grep -qF "$output_md" "$_MOCK_ROUTE_PROMPT_CAPTURE" 2>/dev/null; then
    assert_pass "T4: prompt contains absolute destination path ($output_md)"
else
    assert_fail "T4: prompt missing absolute destination path" \
        "first 200 chars of prompt: $(head -c 200 "$_MOCK_ROUTE_PROMPT_CAPTURE")"
fi
if grep -qF 'Do NOT write to ./design.md' "$_MOCK_ROUTE_PROMPT_CAPTURE" 2>/dev/null; then
    assert_pass "T4: prompt forbids the historical default path"
else
    assert_fail "T4: prompt missing 'Do NOT write to ./design.md' forbiddance"
fi
unset MOCK_DESIGN_WRITE_PATH

# ─── T5: events.design.stray.* registered in event-schema.json ──────────────
SCHEMA="$REPO_ROOT/config/event-schema.json"
grep -q '"design.stray.recovered"' "$SCHEMA" \
    && assert_pass "T5: event-schema.json registers design.stray.recovered" \
    || assert_fail "T5: design.stray.recovered missing from event-schema.json"
grep -q '"design.stray.conflict"' "$SCHEMA" \
    && assert_pass "T5: event-schema.json registers design.stray.conflict" \
    || assert_fail "T5: design.stray.conflict missing from event-schema.json"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
