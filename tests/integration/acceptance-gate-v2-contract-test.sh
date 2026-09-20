#!/usr/bin/env bash
# tests/integration/acceptance-gate-v2-contract-test.sh
# TDD red step for issue #1839: spec-acceptance adopts the v2 result contract.
#
# [SPEC-1] result_contract:2 is present on every terminal exit path of
#          acceptance_gate_run — precondition_unmet (all three preconditions),
#          malformed_acceptance_block, pass, and fail
# [SPEC-2] acceptance-summary.txt is written on the precondition_unmet path and
#          on the malformed_acceptance_block path, so acceptance_detail exists on
#          every terminal verdict (making required:true correct)
# [SPEC-3] design_md is resolved from ZBUILD_STAGE_INPUTS JSON index
#          (jq -r .inputs.design) rather than the hardcoded $artifact_dir/design.md
#          path — plugin.sh has zero grep hits for the literal string
#          '$artifact_dir/design.md' after this change
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate v2 result contract (#1839)"
setup_test_env "acceptance-gate-v2-contract"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

_build_repo() {
    local name="$1" body="$2"
    local repo; repo="$(setup_git_temp_repo "$name")"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
        printf '%s\n' "$body" > tests/feature-test.sh
        chmod +x tests/feature-test.sh impl.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    )
    printf '%s' "$repo"
}

_run_gate() {
    local repo="$1"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    local _si_json="$state_dir/stage-inputs.json"
    printf '{"inputs":{"design":"%s"}}\n' "$state_dir/artifacts/design.md" > "$_si_json"
    export ZBUILD_STAGE_INPUTS="$_si_json"
    [[ -f "$repo/design.md" ]] && cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
          _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
          _ACCEPTANCE_COVERAGE_LOADED
    # shellcheck disable=SC1090
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" )
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}

# ── C1: precondition_unmet:design_acceptance_block → result_contract:2 ─────────
# No design.md → ZBUILD_STAGE_INPUTS points to a non-existent file → no block.
REPO_C1="$(_build_repo "v2c-c1" '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
printf '# Design\nNo acceptance block here.\n' > "$REPO_C1/design.md"
set +e; _run_gate "$REPO_C1"; set -e
assert_eq "[SPEC-1] design_acceptance_block: result_contract:2 present" "2" \
    "$(jq -r '.result_contract // empty' <<<"$RESULT")"
assert_eq "[SPEC-2] design_acceptance_block: acceptance-summary.txt written" "1" \
    "$([[ -f "$REPO_C1/.zbuild-state/artifacts/acceptance-summary.txt" ]] && echo 1 || echo 0)"

# ── C2: precondition_unmet:merge_base_resolvable → result_contract:2 ────────────
# Orphan branch with no ancestor: origin/main absent, main absent, HEAD~1 absent
# → zbuild_resolve_merge_base returns empty → merge_base_resolvable unmet.
REPO_C2="$TEST_TEMP_DIR/repo-c2"
mkdir -p "$REPO_C2"
(
    cd "$REPO_C2"
    git init -q
    git -c user.email="t@t.com" -c user.name="T" checkout -q --orphan orphan-feature 2>/dev/null \
        || git checkout -q --orphan orphan-feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\n# [SPEC-1] x\nexit 0\n' > tests/feature-test.sh
    chmod +x tests/feature-test.sh
    git add -A
    git -c user.email="t@t.com" -c user.name="T" commit -q -m "orphan" 2>/dev/null \
        || git commit -q -m "orphan"
) >/dev/null 2>&1
cat > "$REPO_C2/design.md" <<'EOF'
```acceptance
SPEC-1: something
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO_C2"; set -e
assert_eq "[SPEC-1] merge_base_resolvable: result_contract:2 present" "2" \
    "$(jq -r '.result_contract // empty' <<<"$RESULT")"
assert_eq "[SPEC-2] merge_base_resolvable: acceptance-summary.txt written" "1" \
    "$([[ -f "$REPO_C2/.zbuild-state/artifacts/acceptance-summary.txt" ]] && echo 1 || echo 0)"

# ── C3: precondition_unmet:tagged_testfiles → result_contract:2 ─────────────────
REPO_C3="$(_build_repo "v2c-c3" '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
printf '```acceptance\nTESTFILES:\n```\n' > "$REPO_C3/design.md"
set +e; _run_gate "$REPO_C3"; set -e
assert_eq "[SPEC-1] tagged_testfiles: result_contract:2 present" "2" \
    "$(jq -r '.result_contract // empty' <<<"$RESULT")"
assert_eq "[SPEC-2] tagged_testfiles: acceptance-summary.txt written" "1" \
    "$([[ -f "$REPO_C3/.zbuild-state/artifacts/acceptance-summary.txt" ]] && echo 1 || echo 0)"

# ── C4: malformed_acceptance_block → result_contract:2 ──────────────────────────
REPO_C4="$(_build_repo "v2c-c4" '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
cat > "$REPO_C4/design.md" <<'EOF'
```acceptance
SPEC-1: missing testfiles section and closing fence
EOF
set +e; _run_gate "$REPO_C4"; set -e
assert_eq "[SPEC-1] malformed_acceptance_block: result_contract:2 present" "2" \
    "$(jq -r '.result_contract // empty' <<<"$RESULT")"
assert_eq "[SPEC-2] malformed_acceptance_block: acceptance-summary.txt written" "1" \
    "$([[ -f "$REPO_C4/.zbuild-state/artifacts/acceptance-summary.txt" ]] && echo 1 || echo 0)"

# ── C5: pass path → result_contract:2 ──────────────────────────────────────────
REPO_C5="$(_build_repo "v2c-c5" '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_feature')"
cat > "$REPO_C5/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO_C5"; set -e
assert_eq "[SPEC-1][SPEC-5] pass path: result_contract:2 present" "2" \
    "$(jq -r '.result_contract // empty' <<<"$RESULT")"
assert_eq "pass path: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"

# ── C6: fail path → result_contract:2 ──────────────────────────────────────────
REPO_C6="$(_build_repo "v2c-c6" '#!/usr/bin/env bash
# [SPEC-1] always true
exit 0')"
cat > "$REPO_C6/design.md" <<'EOF'
```acceptance
SPEC-1: always true
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO_C6"; set -e
assert_eq "[SPEC-1] fail path: result_contract:2 present" "2" \
    "$(jq -r '.result_contract // empty' <<<"$RESULT")"
assert_eq "[SPEC-5] fail path: verdict=fail (dedicated fail test case)" \
    "fail" "$(jq -r .verdict <<<"$RESULT")"

# ── C7: SPEC-3 — zero grep hits for the literal '$artifact_dir/design.md' ───────
_hits="$(grep -cF '$artifact_dir/design.md' \
    "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" 2>/dev/null || true)"
assert_eq "[SPEC-3] plugin.sh: zero grep hits for literal '\$artifact_dir/design.md'" "0" "$_hits"

# ── C8: SPEC-3 behavioral — gate resolves design from ZBUILD_STAGE_INPUTS ────────
# design.md is at a custom path NOT under $artifact_dir; ZBUILD_STAGE_INPUTS points
# there. Gate must process the acceptance block (verdict=pass, no precondition_unmet),
# proving resolution is from ZBUILD_STAGE_INPUTS, not a hardcoded artifacts path.
REPO_C8="$(_build_repo "v2c-c8" '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
# shellcheck disable=SC1090
source "$impl"; my_feature')"
_state_c8="$REPO_C8/.zbuild-state"
mkdir -p "$_state_c8/artifacts"
export ZBUILD_EVENTS_DIR="$_state_c8/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$_state_c8/events/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
_custom_design="$TEST_TEMP_DIR/custom-inputs/design-custom.md"
mkdir -p "$(dirname "$_custom_design")"
cat > "$_custom_design" <<'DESIGNEOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
DESIGNEOF
_si_c8="$_state_c8/stage-inputs.json"
printf '{"inputs":{"design":"%s"}}\n' "$_custom_design" > "$_si_c8"
export ZBUILD_STAGE_INPUTS="$_si_c8"
unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
      _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
      _ACCEPTANCE_COVERAGE_LOADED
set +e
(cd "$REPO_C8" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
    && acceptance_gate_run "acceptance-gate" "$_state_c8/pipeline-state.json")
_rc_c8=$?
set -e
_result_c8="$(cat "$_state_c8/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
assert_eq "[SPEC-3] ZBUILD_STAGE_INPUTS non-standard path: gate processes acceptance block (verdict=pass)" \
    "pass" "$(jq -r .verdict <<<"$_result_c8")"
# #2161: a pass carries a reason too (ADR-054 mandatory) — assert it is not the no-op's.
_reason_c8="$(jq -r '.reason // ""' <<<"$_result_c8")"
if [[ -n "$_reason_c8" && "$_reason_c8" != "precondition_unmet" ]]; then
    assert_pass "[SPEC-3] ZBUILD_STAGE_INPUTS non-standard path: no precondition_unmet (block was found; reason: $_reason_c8)"
else
    assert_fail "[SPEC-3] ZBUILD_STAGE_INPUTS non-standard path: no precondition_unmet (block was found)" "reason=$_reason_c8"
fi

# ── C9: SPEC-5 — manifest declares valid_verdicts: [pass, fail] ─────────────────
MANIFEST_PATH="$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml"
_vv_block="$(awk '/^  valid_verdicts:/{found=1; next} found && /^    - /{print; next} found{exit}' \
    "$MANIFEST_PATH")"
_vv_count="$(grep -c '^\s*-' <<< "$_vv_block" || true)"
assert_eq "[SPEC-5] manifest declares exactly 2 valid_verdicts" "2" "$_vv_count"
assert_contains "[SPEC-5] manifest valid_verdicts includes 'pass'" "$_vv_block" "- pass"
assert_contains "[SPEC-5] manifest valid_verdicts includes 'fail'" "$_vv_block" "- fail"

# ── C10: SPEC-6 — manifest declares tier_default: T1; plugin.sh has no model.route call ──
_manifest_text="$(cat "$MANIFEST_PATH")"
assert_contains "[SPEC-6] manifest declares tier_default: T1" "$_manifest_text" "tier_default: T1"
_route_hits="$(grep -c 'model\.route' \
    "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" 2>/dev/null || true)"
assert_eq "[SPEC-6] plugin.sh: zero model.route calls (non-routing mechanical gate)" "0" "$_route_hits"
assert_contains "[SPEC-6] manifest provides section declares result_contract: 2 (v2 migration)" \
    "$_manifest_text" "result_contract: 2"

# ── C11: SPEC-7 — manifest declares exactly one primary: true output (gate_result) ──
_primary_count="$(grep -c '^\s*primary: true' "$MANIFEST_PATH" 2>/dev/null || true)"
assert_eq "[SPEC-7] manifest has exactly one primary: true output" "1" "$_primary_count"
_primary_id="$(awk '/^  - id: /{current_id=$NF} /^    primary: true/{print current_id}' \
    "$MANIFEST_PATH")"
assert_eq "[SPEC-7] primary output id is gate_result" "gate_result" "$_primary_id"
_detail_req="$(awk '/^  - id: acceptance_detail/{f=1} f && /^    required:/{print $2; exit}' \
    "$MANIFEST_PATH")"
assert_eq "[SPEC-7] acceptance_detail output required: true (summary on every terminal path)" \
    "true" "$_detail_req"

# ── C12: SPEC-8 — manifest declares provides.role: acceptance_gate ────────────
# Templates resolve this gate by role, not by id (ADR-042/047); the field must
# be present or the resolver cannot bind the plugin to the acceptance_gate slot.
assert_contains "[SPEC-8] manifest declares provides.role: acceptance_gate" \
    "$_manifest_text" "role: acceptance_gate"

# ── C13: SPEC-9 — manifest provides.events lists every acceptance.gate.* event ─
# For each acceptance.gate.* event emitted via eb_emit_event in plugin.sh, assert
# it appears in the manifest's provides.events list (ADR-001 §Declared events,
# #1717 — no event is emitted without a corresponding declaration).
_declared_events_list="$(awk \
    '/^  events:/{f=1; next} f && /^    - /{print $2; next} f{exit}' \
    "$MANIFEST_PATH")"
_declared_evt_count="$(grep -c 'acceptance\.gate\.' <<< "$_declared_events_list" || true)"
assert_gt "[SPEC-9] manifest provides.events is non-empty (at least one event declared)" \
    "$_declared_evt_count" "0"
while IFS= read -r _evt; do
    [[ -z "$_evt" ]] && continue
    assert_contains "[SPEC-9] emitted event '$_evt' is declared in manifest provides.events" \
        "$_declared_events_list" "$_evt"
done < <(grep -oE '"acceptance\.gate\.[^"]*"' \
    "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" 2>/dev/null \
    | tr -d '"' | sort -u)

# ── C14: SPEC-10 — manifest has no hooks.cleanup entry ───────────────────────
# spec-acceptance holds no live resources; when teardown dispatches the cleanup
# hook, plugin_hook_call emits plugin.cleanup.absent and returns 0 (ADR-056,
# #1829). The absence of hooks.cleanup is intentional — asserting it prevents
# an accidental addition from silently breaking the teardown contract.
_hooks_section="$(awk '/^hooks:/{f=1; next} f && /^[^ ]/{f=0} f{print}' "$MANIFEST_PATH")"
_cleanup_in_hooks="$(grep 'cleanup' <<< "$_hooks_section" 2>/dev/null || true)"
assert_eq "[SPEC-10] manifest has no hooks.cleanup entry" "" "$_cleanup_in_hooks"

cleanup_test_env
print_test_results
