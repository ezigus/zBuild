#!/usr/bin/env bash
# Unit: build consumes design.md DECISION PROSE (#916 / ADR-020).
#
# Build already reads design.md's ```scope block (scope override) and
# ```acceptance TESTFILES (charter). It ignored the narrative decision prose —
# so design's "build must do X" directives were silently dropped (the design↔
# build divergence seen across #866/#867). This verifies build now injects a
# ## DESIGN DECISIONS section sourced from design.md's out-of-fence prose.
#
# D1: prose present → prompt contains the ## DESIGN DECISIONS header.
# D2: prompt contains a distinctive sentence from the decision prose.
# D3: design.md absent → no ## DESIGN DECISIONS section (omit guard).
# D4: design.md with ONLY fenced blocks (no prose) → no section.
# D5: _build_read_design_decisions excludes fenced-block content AND keeps prose
#     that FOLLOWS a fence (the fence-toggle, not sed '/^```/q', survival case).
# D6: prose cap (_BUILD_DESIGN_DECISIONS_MAX_LINES) is honored.
# H:  _build_read_design_decisions returns empty for an all-fence / absent file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build design-decisions injection (#916 / ADR-020)"
setup_test_env "build-design-decisions-916"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-design-decisions-$$"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts"

export _MOCK_ROUTE_CAPTURE="$TEST_TEMP_DIR/route-prompt.txt"

# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# shellcheck disable=SC2317
route_to_model_loop() {
    local _prompt_file="$2"
    [[ -f "$_prompt_file" ]] && cp "$_prompt_file" "$_MOCK_ROUTE_CAPTURE"
    _ROUTE_LOOP_ITERATIONS=1
    _ROUTE_LOOP_TERMINATED_REASON="done_sentinel"
    _ROUTE_LOOP_INPUT_TOKENS=0
    _ROUTE_LOOP_OUTPUT_TOKENS=0
    _ROUTE_LOOP_LAST_RESPONSE="LOOP_COMPLETE"
    return 0
}
# shellcheck disable=SC2317
_route_resolve_max_iterations() { echo 3; }
# shellcheck disable=SC2317
_route_loop_close_final_banner() { return 0; }
# shellcheck disable=SC2317
apply_scope_redaction() { local in="$1" out="$2"; [[ -f "$in" ]] && cp "$in" "$out"; return 0; }

_DD_REPO="$TEST_TEMP_DIR/dd-repo"
mkdir -p "$_DD_REPO"
( cd "$_DD_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed ) >/dev/null
export ZBUILD_REPO_ROOT="$_DD_REPO"

ARTIFACT_DIR="$ZBUILD_STATE_DIR/artifacts"
PLAN_JSON="$ARTIFACT_DIR/plan.json"
SCOPE_MANIFEST="$ZBUILD_STATE_DIR/scope-manifest.md"
DIFF_PATCH="$ARTIFACT_DIR/diff.patch"
SUMMARY_JSON="$ARTIFACT_DIR/build-summary.json"
DESIGN_MD="$ARTIFACT_DIR/design.md"
cat > "$PLAN_JSON" <<'JSON'
{ "title": "design decisions", "files": ["plugins/agent/build/plugin.sh"] }
JSON
touch "$SCOPE_MANIFEST"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

_run_build() {
    : > "$_MOCK_ROUTE_CAPTURE"
    set +e
    _build_stage_run_inner "$SCOPE_MANIFEST" "$PLAN_JSON" "$DIFF_PATCH" \
        "$SUMMARY_JSON" "$ARTIFACT_DIR" >/dev/null 2>&1
    set -e
    cat "$_MOCK_ROUTE_CAPTURE" 2>/dev/null || true
}

# ─── D1 / D2: decision prose present → section + prose injected ───────────────
cat > "$DESIGN_MD" <<'DESIGN'
# Design

## Decision
Build must register the new event in config/event-schema.json before LOOP_COMPLETE.

```scope
plugins/agent/build/plugin.sh
```

```acceptance
SPEC: x
TESTFILES:
tests/unit/build-design-decisions-test.sh
```
DESIGN
prompt="$(_run_build)"
if grep -qF "## DESIGN DECISIONS" <<< "$prompt"; then
    assert_pass "D1: prompt contains '## DESIGN DECISIONS' header"
else
    assert_fail "D1: prompt must contain '## DESIGN DECISIONS' header" "not found"
fi
if grep -qF "register the new event in config/event-schema.json" <<< "$prompt"; then
    assert_pass "D2: prompt contains the decision prose sentence"
else
    assert_fail "D2: prompt must contain the decision prose" "sentence not found"
fi

# ─── D3: design.md absent → no DESIGN DECISIONS section ───────────────────────
rm -f "$DESIGN_MD"
prompt="$(_run_build)"
if grep -qF "## DESIGN DECISIONS" <<< "$prompt"; then
    assert_fail "D3: no DESIGN DECISIONS section when design.md absent" "section present"
else
    assert_pass "D3: DESIGN DECISIONS section omitted when design.md absent"
fi

# ─── D4: design.md with only fenced blocks (no prose) → no section ────────────
cat > "$DESIGN_MD" <<'DESIGN'
```scope
plugins/agent/build/plugin.sh
```
```acceptance
SPEC: x
TESTFILES:
tests/unit/build-design-decisions-test.sh
```
DESIGN
prompt="$(_run_build)"
if grep -qF "## DESIGN DECISIONS" <<< "$prompt"; then
    assert_fail "D4: no section when design.md has only fenced blocks" "section present"
else
    assert_pass "D4: DESIGN DECISIONS omitted when design.md is all fenced blocks"
fi
rm -f "$DESIGN_MD"

# ─── D5: helper excludes fence content + keeps prose AFTER a fence ────────────
# The load-bearing case: a naive `sed '/^```/q'` would drop everything after the
# first fence. The fence-toggle must keep the trailing prose and exclude the
# in-fence marker.
D5_MD="$TEST_TEMP_DIR/d5.md"
cat > "$D5_MD" <<'DESIGN'
Decision prose before the block.

```scope
core/INFENCE_SCOPE_MARKER.sh
```

Decision prose AFTER the block.
DESIGN
d5_out="$(_build_read_design_decisions "$D5_MD" 2>/dev/null || true)"
if grep -qF "Decision prose before the block." <<< "$d5_out" \
   && grep -qF "Decision prose AFTER the block." <<< "$d5_out"; then
    assert_pass "D5: prose before AND after a fence both survive (fence-toggle)"
else
    assert_fail "D5: prose after the first fence must survive" "got: $d5_out"
fi
if grep -qF "INFENCE_SCOPE_MARKER" <<< "$d5_out"; then
    assert_fail "D5: in-fence content must be excluded" "fence content leaked: $d5_out"
else
    assert_pass "D5: in-fence (scope block) content excluded from decisions"
fi

# ─── D6: prose cap honored ────────────────────────────────────────────────────
D6_MD="$TEST_TEMP_DIR/d6.md"
: > "$D6_MD"
for i in $(seq 1 40); do printf 'prose line %d\n' "$i" >> "$D6_MD"; done
d6_out="$(_BUILD_DESIGN_DECISIONS_MAX_LINES=5 _build_read_design_decisions "$D6_MD" 2>/dev/null || true)"
d6_lines="$(printf '%s\n' "$d6_out" | grep -c 'prose line' || true)"
if [[ "$d6_lines" -le 5 ]]; then
    assert_pass "D6: prose cap honored (${d6_lines} <= 5 lines)"
else
    assert_fail "D6: prose cap must bound output" "got $d6_lines lines"
fi

# ─── H: helper returns empty for all-fence / absent file ─────────────────────
H_MD="$TEST_TEMP_DIR/h.md"
printf '```scope\nfoo.sh\n```\n' > "$H_MD"
h_out="$(_build_read_design_decisions "$H_MD" 2>/dev/null || true)"
if [[ -z "${h_out//[[:space:]]/}" ]]; then
    assert_pass "H: helper returns empty for an all-fence design.md"
else
    assert_fail "H: all-fence design.md must yield empty prose" "got: $h_out"
fi
h_absent="$(_build_read_design_decisions "$TEST_TEMP_DIR/does-not-exist.md" 2>/dev/null || true)"
if [[ -z "${h_absent//[[:space:]]/}" ]]; then
    assert_pass "H: helper returns empty for an absent design.md"
else
    assert_fail "H: absent design.md must yield empty prose" "got: $h_absent"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
