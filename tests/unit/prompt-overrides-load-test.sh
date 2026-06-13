#!/usr/bin/env bash
# Unit: load_prompt_override (ADR-032, #854). Reads a per-repo override file
# under <repo>/.zbuild/prompts/<stage>-overrides.md, fail-open, path-contained.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "unit: load_prompt_override per-repo overlay (#854)"
setup_test_env "prompt-overrides-load-854"

# shellcheck source=../../scripts/lib/prompt-overrides.sh
source "$REPO_ROOT/scripts/lib/prompt-overrides.sh"

REPO="$TEST_TEMP_DIR/repo"
PROMPTS="$REPO/.zbuild/prompts"
mkdir -p "$PROMPTS"
export ZBUILD_REPO_ROOT="$REPO"

# L1: present file → content returned, rc 0.
printf '# overlay\nOVERRIDE_MARKER_L1 line one\nline two\n' > "$PROMPTS/design-overrides.md"
out="$(load_prompt_override design)"; rc=$?
assert_eq "L1: rc 0 when file present" "0" "$rc"
assert_contains "L1: returns override content" "$out" "OVERRIDE_MARKER_L1"
assert_contains "L1: preserves full content" "$out" "line two"

# L2: absent file → empty, rc 0 (fail-open, no error).
out="$(load_prompt_override review)"; rc=$?
assert_eq "L2: rc 0 when absent" "0" "$rc"
assert_eq "L2: empty when absent" "" "$out"

# L3: empty file → empty, rc 0.
: > "$PROMPTS/plan-overrides.md"
out="$(load_prompt_override plan)"; rc=$?
assert_eq "L3: rc 0 when empty file" "0" "$rc"
assert_eq "L3: empty content when empty file" "" "$out"

# L4: path traversal via stage arg → rejected (no /etc/passwd read).
out="$(load_prompt_override '../../../../etc/passwd')"; rc=$?
assert_eq "L4: rc 0 on traversal stage" "0" "$rc"
assert_eq "L4: empty on traversal stage" "" "$out"
if printf '%s' "$out" | grep -q 'root:'; then
    assert_fail "L4: must NOT leak /etc/passwd content"
else
    assert_pass "L4: no /etc/passwd leak via traversal stage"
fi

# L5: absolute-path stage arg → rejected.
out="$(load_prompt_override '/etc/passwd')"; rc=$?
assert_eq "L5: empty on absolute stage" "" "$out"
if printf '%s' "$out" | grep -q 'root:'; then
    assert_fail "L5: must NOT leak via absolute stage"
else
    assert_pass "L5: no leak via absolute stage"
fi

# L6: symlink-out → rejected (file exists & non-empty but resolves out of repo).
ln -s /etc/passwd "$PROMPTS/intake-overrides.md"
out="$(load_prompt_override intake)"; rc=$?
assert_eq "L6: rc 0 on symlink-out" "0" "$rc"
if printf '%s' "$out" | grep -q 'root:'; then
    assert_fail "L6: symlink-out must NOT leak target content" "got: $(printf '%s' "$out" | head -1)"
else
    assert_pass "L6: symlink-out rejected, no leak"
fi

# L7: resolves under ZBUILD_REPO_ROOT, not cwd. Two repos with distinct markers.
REPO_B="$TEST_TEMP_DIR/repoB"; mkdir -p "$REPO_B/.zbuild/prompts"
printf 'FROM_B overlay\n' > "$REPO_B/.zbuild/prompts/design-overrides.md"
out="$(ZBUILD_REPO_ROOT="$REPO_B" load_prompt_override design)"
assert_contains "L7: reads override under ZBUILD_REPO_ROOT" "$out" "FROM_B"
if printf '%s' "$out" | grep -q 'OVERRIDE_MARKER_L1'; then
    assert_fail "L7: must not read repo A's override when root is B"
else
    assert_pass "L7: does not bleed repo A override into repo B"
fi

# L8: non-canonical stage (embedded slash) → rejected.
out="$(load_prompt_override 'design/../plan')"; rc=$?
assert_eq "L8: empty on slashed stage" "" "$out"
assert_eq "L8: rc 0 on slashed stage" "0" "$rc"

# L9: filename construction is exact <stage>-overrides.md (no cross-stage read).
# Only design-overrides.md exists; asking for 'security' returns nothing.
out="$(load_prompt_override security)"
assert_eq "L9: unrelated stage → empty (exact filename match)" "" "$out"

# L10: explicit repo_root arg overrides env.
out="$(load_prompt_override design "$REPO_B")"
assert_contains "L10: explicit repo_root arg honored" "$out" "FROM_B"

# L11: size cap truncates oversized override with a visible marker.
big="$PROMPTS/build-overrides.md"
head -c 5000 /dev/zero | tr '\0' 'x' > "$big"
out="$(ZBUILD_PROMPT_OVERRIDE_MAX_BYTES=64 load_prompt_override build)"
assert_contains "L11: oversized override truncated with marker" "$out" "override truncated"
if [[ "${#out}" -lt 400 ]]; then
    assert_pass "L11: truncated output bounded (<400 chars for 64-byte cap)"
else
    assert_fail "L11: truncation did not bound size" "len=${#out}"
fi

# L12: hardlink to an out-of-tree file → rejected (realpath can't see through a
# hardlink; the nlink>1 gate catches it).
echo "HARDLINK_SECRET root:x:0:0" > "$TEST_TEMP_DIR/outside-secret.txt"
if ln "$TEST_TEMP_DIR/outside-secret.txt" "$PROMPTS/monitor-overrides.md" 2>/dev/null; then
    out="$(load_prompt_override monitor)"
    if printf '%s' "$out" | grep -q 'HARDLINK_SECRET'; then
        assert_fail "L12: hardlink-out must NOT leak file content"
    else
        assert_pass "L12: hardlink-out rejected, no leak"
    fi
    rm -f "$PROMPTS/monitor-overrides.md"
else
    assert_pass "L12: hardlink unsupported on this fs (skipped)"
fi

# L13: a .zbuild/prompts dir that is itself a symlink out → rejected.
EXT_DIR="$TEST_TEMP_DIR/external-prompts"; mkdir -p "$EXT_DIR"
printf 'FROM_EXTERNAL_DIR root:x\n' > "$EXT_DIR/deploy-overrides.md"
REPO_SL="$TEST_TEMP_DIR/repo-symlinkdir"; mkdir -p "$REPO_SL/.zbuild"
ln -s "$EXT_DIR" "$REPO_SL/.zbuild/prompts"
out="$(ZBUILD_REPO_ROOT="$REPO_SL" load_prompt_override deploy)"
if printf '%s' "$out" | grep -q 'FROM_EXTERNAL_DIR'; then
    assert_fail "L13: symlinked prompts dir must NOT read out-of-tree content"
else
    assert_pass "L13: symlinked-out prompts dir rejected"
fi

# L14: FIFO override → rejected by -f (guards against a future -e refactor that
# would hang cat on a blocking FIFO).
if mkfifo "$PROMPTS/cleanup-overrides.md" 2>/dev/null; then
    out="$(load_prompt_override cleanup)"
    assert_eq "L14: FIFO override → empty (not a regular file)" "" "$out"
    rm -f "$PROMPTS/cleanup-overrides.md"
else
    assert_pass "L14: mkfifo unavailable (skipped)"
fi

# L15: non-numeric operator cap → full override returned (cap falls back to
# default, not silently truncated to empty).
printf 'CAP_MARKER_L15 content stays intact\n' > "$PROMPTS/audit-overrides.md"
out="$(ZBUILD_PROMPT_OVERRIDE_MAX_BYTES=not-a-number load_prompt_override audit)"
assert_contains "L15: non-numeric cap → override intact (default fallback)" "$out" "CAP_MARKER_L15"
if printf '%s' "$out" | grep -q 'truncated'; then
    assert_fail "L15: non-numeric cap must NOT truncate"
else
    assert_pass "L15: non-numeric cap did not truncate"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
