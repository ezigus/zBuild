#!/usr/bin/env bash
# Unit: design's prompt invites Read/Grep tools (#841), so design checks the
# code before it decides. Pre-#841 design reasoned blind from plan.json.
# #2508 (ADR-069 §11): design names no files — T2 now checks it is asked for no
# file list (it used to be told to search out a scope block, #2376).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "unit: design prompt exhaustive-scope charter + tools (#841)"
setup_test_env "design-prompt-scope-charter-841"

# shellcheck source=../../plugins/agent/design/plugin.sh
source "$REPO_ROOT/plugins/agent/design/plugin.sh"

# Mock the router loop to a no-op success — we only inspect the prompt the
# inner function writes to <artifact_dir>/design-prompt.txt before routing.
# The design call: it writes a design where the prompt says, when the test
# asks for one (MOCK_DESIGN_WRITE_PATH set).
route_to_model() {
    local _t; _t="$(zb_test_prompt_write_path "$2")"
    [[ -n "${MOCK_DESIGN_WRITE_PATH:-}" && -n "$_t" ]] && {
        mkdir -p "$(dirname "$_t")"
        printf '# Design\n\n```scope\nfoo.sh\n```\n' > "$_t"
    }
    return 0
}
apply_scope_redaction() { cp "$1" "$2"; return 0; }
atomic_write() { local dest="$1"; cat - > "$dest"; }
_route_loop_close_final_banner() { return 0; }

FIX="$TEST_TEMP_DIR/fix"
mkdir -p "$FIX"
git -C "$FIX" init --quiet >/dev/null 2>&1
git -C "$FIX" config user.email 'test@example.com' >/dev/null
git -C "$FIX" config user.name 'test' >/dev/null
ARTIFACT_DIR="$FIX/state/artifacts"; mkdir -p "$ARTIFACT_DIR"
SCOPE_MANIFEST="$FIX/state/scope-manifest.md"; printf 'scope: all\n' > "$SCOPE_MANIFEST"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
cat > "$PLAN_JSON" <<'EOF'
{"schema_version":1,"title":"t","goal":"g","steps":[{"id":"step-1","description":"d","files":["foo.sh"],"estimated_lines":5}],"estimated_total_lines":5,"notes":""}
EOF
OUTPUT_MD="$ARTIFACT_DIR/design.md"
export ZBUILD_REPO_ROOT="$FIX"
export MOCK_DESIGN_WRITE_PATH="$OUTPUT_MD"

_design_stage_run_inner "$SCOPE_MANIFEST" "$OUTPUT_MD" "$ARTIFACT_DIR" >/dev/null 2>&1 || true

PROMPT="$ARTIFACT_DIR/design-prompt.txt"
assert_file_exists "design prompt written" "$PROMPT"

# T1: invites Read + Grep tools.
if grep -qiE 'Read tool|Grep tool|use .*Read.*Grep|Read and Grep' "$PROMPT"; then
    assert_pass "T1: prompt invites Read/Grep tool use"
else
    assert_fail "T1: prompt must invite Read/Grep" "got (head): $(head -40 "$PROMPT" | tr '\n' ' ' | cut -c1-200)"
fi

# T2 (#2508): design names no files — no scope block to write, and it is told so.
if grep -qF '```scope' "$PROMPT"; then
    assert_fail "T2: prompt asks for no scope block" "it still does"
else
    assert_pass "T2: prompt asks for no scope block"
fi
if grep -qF 'You name no test file, and no list of the files the change' "$PROMPT"; then
    assert_pass "T2: prompt says design names no files"
else
    assert_fail "T2: prompt says design names no files"
fi

# T3: old-value-pinning instruction (grep repo for files pinning old values).
if grep -qiE 'old value|pin|hardcode|grep .*repo|references|assumes' "$PROMPT"; then
    assert_pass "T3: prompt instructs finding files that pin/reference what changes"
else
    assert_fail "T3: prompt must instruct old-value/pinned-reference discovery"
fi

# T4: 'superset' framing dropped.
if grep -qi 'superset' "$PROMPT"; then
    assert_fail "T4: prompt should NOT use 'superset' framing anymore"
else
    assert_pass "T4: 'superset' framing removed"
fi

# T5 (#2376): design writes only its design (the working copy, ADR-068 §8) and
# its notes file, and changes no code.
if grep -qF 'Do not write any file other than the working copy above and your notes file' "$PROMPT" \
        && grep -qF 'Do not change the code' "$PROMPT"; then
    assert_pass "T5: design writes only its working copy and its notes, and changes no code"
else
    assert_fail "T5: design writes only its working copy and its notes, and changes no code"
fi

# T7 (#1801 run): design writes design.md as it goes, so nothing in its prompt
# may call it read-only — the old Tools heading did, and design wrote nothing.
if grep -qiE 'read-only|may NOT modify' "$PROMPT"; then
    assert_fail "T7: prompt does not call design read-only" "$(grep -iE 'read-only|may NOT modify' "$PROMPT")"
else
    assert_pass "T7: prompt does not call design read-only"
fi

# T6: simple.yaml design call limit raised to 1200 (#1944: three 600s calls
# in a row ran out of time on a resumed run).
# router.timeout_s (4-space indent), not the whole-stage limit (ADR-063, amended).
tmo="$(awk '/^design:/{f=1;next} /^[a-z]/{f=0} f && /^    timeout_s:/{print $2; exit}' "$REPO_ROOT/config/templates/simple.yaml")"
assert_eq "T6: design timeout_s raised to 1200" "1200" "${tmo:-unset}"

# T9 (#2482, ADR-001): design is told its id prefix, from its manifest, and
# every example id in its prompt has it — an example without it is one the
# check refuses.
_px9="$(awk '/^id_prefix:/{print $2}' "$REPO_ROOT/plugins/agent/design/manifest.yaml")"
assert_contains "[T9] the prompt says every SPEC id starts with design's prefix" "$(tr -s '[:space:]' ' ' < "$PROMPT")" "The id describes the SPEC: ${_px9:-<none>}, then"
assert_contains "[T9] ...and its examples have it" "$(cat "$PROMPT")" "${_px9:-<none>}LOOP-1[code]:"
_t9_bare="$(grep -oE '(^|[^A-Z0-9])(LOOP|GARD)-[0-9]+' "$PROMPT" | head -3 || true)"
assert_eq "[T9] ...no example id without it" "" "$_t9_bare"

# T8 (#2482, ADR-069 §2): design is shown the code from before the change —
# the copy of the commit the branch started from, the one its check reads a
# [done] claim in. On #1805 run 42293991602 design had only the working copy,
# took code this branch added for old code ("Since I can't pull the git history
# here"), and lost all three tries to [done] claims the check refused.
FX8="$TEST_TEMP_DIR/fix8"; mkdir -p "$FX8/scripts"
git -C "$FX8" init -q -b main && git -C "$FX8" config user.email t@t && git -C "$FX8" config user.name t
printf 'old_guard\n' > "$FX8/scripts/run.sh"; git -C "$FX8" add -A; git -C "$FX8" commit -qm base
git -C "$FX8" checkout -qb work; printf 'old_guard\nnew_guard\n' > "$FX8/scripts/run.sh"; git -C "$FX8" commit -qam work
A8="$FX8-state/artifacts"; mkdir -p "$A8"; printf 'scope: all\n' > "$FX8-state/scope-manifest.md"
cp "$PLAN_JSON" "$A8/plan.json"
ZBUILD_REPO_ROOT="$FX8" ZBUILD_STATE_DIR="$FX8-state" MOCK_DESIGN_WRITE_PATH="$A8/design.md" \
    _design_stage_run_inner "$FX8-state/scope-manifest.md" "$A8/design.md" "$A8" >/dev/null 2>&1 || true
P8="$(cat "$A8/design-prompt.txt" 2>/dev/null)"
assert_contains "[T8] the prompt names the copy of the code from before the change" "$P8" "$FX8-state/base-code"
assert_contains "[T8] ...and says a [done] claim is read there, not in the working copy" "$P8" \
    "open the file there, not in the working copy"
if [[ "$(cat "$FX8-state/base-code/scripts/run.sh" 2>/dev/null)" == old_guard ]]; then
    assert_pass "[T8] the copy holds the code from where the branch started"
else
    assert_fail "[T8] the copy holds the code from where the branch started" "$(cat "$FX8-state/base-code/scripts/run.sh" 2>&1)"
fi
judge_base_release "$FX8-state" "$FX8" >/dev/null 2>&1

cleanup_test_env
print_test_results
exit $((FAIL > 0))
