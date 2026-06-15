#!/usr/bin/env bash
# Tests: design stage banner OUTPUT shows on-disk design.md content, not
# claude's stdout summary (#825). ADR-018 Pattern 2 single-file-artifact
# contract amended in #820: the canonical artifact IS the file; the banner
# should reflect that. Mirrors build's --defer-final-banner-close pattern
# but overrides _ROUTE_LOOP_FINAL_OUTPUT with file content instead of the
# LLM's result text.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "design: banner OUTPUT shows design.md content (#825)"
setup_test_env "design-banner-content-825"

# Init a git fixture per test (same pattern as design-stray test).
_init_git_fixture() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init --quiet >/dev/null 2>&1
    git -C "$dir" config user.email 'test@example.com' >/dev/null
    git -C "$dir" config user.name  'test' >/dev/null
}

# Source plugin FIRST so its source statements load; then override.
# shellcheck disable=SC1091
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Tracks whether _route_loop_close_final_banner was called and captures
# the value of _ROUTE_LOOP_FINAL_OUTPUT at that moment — that's what the
# banner would show.
_CAPTURED_BANNER_OUTPUT="$TEST_TEMP_DIR/captured-banner.txt"
_CLOSE_CALL_COUNT_FILE="$TEST_TEMP_DIR/close-call-count"
: > "$_CAPTURED_BANNER_OUTPUT"
echo 0 > "$_CLOSE_CALL_COUNT_FILE"

_route_loop_close_final_banner() {
    printf '%s' "${_ROUTE_LOOP_FINAL_OUTPUT:-<empty>}" > "$_CAPTURED_BANNER_OUTPUT"
    local n; n=$(($(cat "$_CLOSE_CALL_COUNT_FILE")+1))
    echo "$n" > "$_CLOSE_CALL_COUNT_FILE"
    return 0
}

# Mock route_to_model_loop: simulate the LLM writing design.md to the
# declared path AND returning a stdout summary (this is the actual dogfood
# behavior). Caller sets MOCK_DESIGN_BODY + MOCK_DESIGN_WRITE_PATH +
# MOCK_LLM_STDOUT_SUMMARY.
route_to_model_loop() {
    local _body
    if [[ -n "${MOCK_DESIGN_BODY:-}" ]]; then
        _body="$MOCK_DESIGN_BODY"
    else
        local _bt='```'
        _body="$(printf '# Design\n\n## Decision\nImplement per plan.\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC: it works\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' "$_bt" "$_bt" "$_bt" "$_bt")"
    fi
    if [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" ]]; then
        mkdir -p "$(dirname "$MOCK_DESIGN_WRITE_PATH")"
        printf '%s' "$_body" > "$MOCK_DESIGN_WRITE_PATH"
    fi
    # Simulate claude's stdout — the LLM's narration. By default this is
    # the buggy "Design document written to ..." summary the dogfood showed.
    _ROUTE_LOOP_FINAL_OUTPUT="${MOCK_LLM_STDOUT_SUMMARY:-Design document written to $output_design_md. It covers Decision/Scope/Contracts.}"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    return 0
}

apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }

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
    : > "$_CAPTURED_BANNER_OUTPUT"
    echo 0 > "$_CLOSE_CALL_COUNT_FILE"
}

# ─── T1: happy path — banner shows design.md content, NOT stdout summary ────
_setup_test_fixture t1
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
_bt='```'
MOCK_DESIGN_BODY="$(printf '# Design Doc T1\n\n## Decision\nUse pattern X for the migration.\n\n%sscope\nfoo.sh\nbar.sh\n%s\n\n%sacceptance\nSPEC: migration works\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' "$_bt" "$_bt" "$_bt" "$_bt")"
unset _bt
MOCK_LLM_STDOUT_SUMMARY="Design document written to $OUTPUT_MD. It covers Decision/Scope."
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T1: happy path rc=0" "0" "$rc"
banner=$(cat "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null)
if grep -q '# Design Doc T1' "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null; then
    assert_pass "T1: banner OUTPUT contains design.md content (the actual file)"
else
    assert_fail "T1: banner OUTPUT missing design.md content" \
        "got first 80 chars: $(head -c 80 "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null)"
fi
if grep -q 'Design document written to' "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null; then
    assert_fail "T1: banner OUTPUT still shows claude's stdout summary (should be overridden)" \
        "got: $(head -c 120 "$_CAPTURED_BANNER_OUTPUT")"
else
    assert_pass "T1: banner OUTPUT does NOT contain stdout summary"
fi
calls=$(cat "$_CLOSE_CALL_COUNT_FILE")
assert_eq "T1: _route_loop_close_final_banner called exactly once" "1" "$calls"
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY MOCK_LLM_STDOUT_SUMMARY

# ─── T2: post-recovery path — stray mv'd into place; banner shows it ─────────
_setup_test_fixture t2
MOCK_DESIGN_WRITE_PATH="$FIXTURE_DIR/design.md"   # LLM writes to repo root
_bt='```'
MOCK_DESIGN_BODY="$(printf '# Design Doc T2 (recovered)\n\n## Decision\nrecovered\n\n%sscope\nfoo.sh\n%s\n\n%sacceptance\nSPEC: recovery works\nTESTFILES:\ntests/unit/foo-test.sh\n%s\n' "$_bt" "$_bt" "$_bt" "$_bt")"
unset _bt
MOCK_LLM_STDOUT_SUMMARY="Design document written. LOOP_COMPLETE"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2: recovery path rc=0" "0" "$rc"
if grep -q '# Design Doc T2 (recovered)' "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null; then
    assert_pass "T2: banner shows recovered design.md content"
else
    assert_fail "T2: banner missing recovered content"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY MOCK_LLM_STDOUT_SUMMARY

# ─── T3: failure path — missing scope block; banner falls back to stdout ───
_setup_test_fixture t3
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(printf '# No scope block here\n\nJust prose, no fence.\n')"
MOCK_LLM_STDOUT_SUMMARY="I failed to include the scope block — sorry."
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T3: missing scope block returns rc=1" "1" "$rc"
# On failure, the banner SHOULD show the LLM's stdout summary (the
# diagnostic) — NOT the file content. The override skip in the failure
# branch is what produces this.
if grep -q 'I failed to include the scope block' "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null; then
    assert_pass "T3: failure path banner shows LLM stdout summary (diagnostic)"
else
    assert_fail "T3: failure path should expose LLM's stdout (not overridden)" \
        "got: $(head -c 120 "$_CAPTURED_BANNER_OUTPUT")"
fi
if grep -q '# No scope block here' "$_CAPTURED_BANNER_OUTPUT" 2>/dev/null; then
    assert_fail "T3: failure path leaked file content into banner (override should be skipped)" \
        "got: $(head -c 120 "$_CAPTURED_BANNER_OUTPUT")"
else
    assert_pass "T3: failure path did NOT splice file content"
fi
unset MOCK_DESIGN_WRITE_PATH MOCK_DESIGN_BODY MOCK_LLM_STDOUT_SUMMARY

# ─── T4: large file → banner receives full content (truncation is stage-io's job) ─
_setup_test_fixture t4
# Build a large file via a real heredoc + appended lines (no `\n` escapes).
_T4_TMP="$TEST_TEMP_DIR/t4-body.md"
{
    printf '# Large Design Doc T4\n\n## Decision\nUse the iterative loop pattern.\n\n'
    for n in $(seq 1 220); do
        printf 'line-%d: ' "$n"
        printf 'L%.0s' $(seq 1 60)
        printf '\n'
    done
    printf '\n```scope\nfoo.sh\n```\n\n```acceptance\nSPEC: large file works\nTESTFILES:\ntests/unit/foo-test.sh\n```\n'
} > "$_T4_TMP"
MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"
MOCK_DESIGN_BODY="$(cat "$_T4_TMP")"
MOCK_LLM_STDOUT_SUMMARY="ignore me"
set +e
_design_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1
rc=$?
set -e
assert_eq "T4: large file rc=0" "0" "$rc"
banner_size=$(wc -c < "$_CAPTURED_BANNER_OUTPUT" | tr -d ' ')
file_size=$(wc -c < "$_T4_TMP" | tr -d ' ')
# We pass the FULL content to the override; truncation is stage-io's
# responsibility (40-line tail). Assert the banner got the entire file
# (modulo the trailing newline that command substitution strips).
if [[ "$banner_size" -ge $((file_size - 5)) ]]; then
    assert_pass "T4: banner received full file content (size=$banner_size, file=$file_size; stage-io truncates downstream)"
else
    assert_fail "T4: banner content truncated by plugin" "size=$banner_size, file=$file_size"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
