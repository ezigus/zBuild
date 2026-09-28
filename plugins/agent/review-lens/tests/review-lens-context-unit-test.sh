#!/usr/bin/env bash
# plugins/agent/review-lens/tests/review-lens-context-unit-test.sh — a lens is
# given what it needs to judge, and says whether a problem is NEW.
#
# Why: #1845's PR #2213 — six lenses, 22 findings, 0 critical/high; they missed
# the two real defects (a path the plugin built itself, against the issue; 26
# assertion tags stripped from a shared test) and raised false ones: engine-set
# ZBUILD_* values read as "attacker-controlled", a test's hand-wiring read as the
# production path, old behaviour (ZBUILD_DRY_RUN trust) blamed on the change, and
# a list of every planned file the change did not touch. Each lens saw only the
# diff: no issue, no SPECs, no scope, no leave to read the code around it
# (#1654), and no way to say "this was already there".
#
# C1 [change] the prompt carries the ISSUE (what was asked)
# C2 [change] ...the SPECs (the acceptance contract)
# C3 [change] ...and the planned SCOPE (#1654: kills "not in planned scope" misses)
# C4 [change] it tells the lens to read the surrounding code, and no longer
#             confines it to the diff (#1654)
# C5 [change] each finding says whether the change INTRODUCED it
# C6 [change] a lens is not shown its own previous review (no self-echo, as for
#             every other judging stage since #2212)
# C7 [change] the aggregator counts only introduced findings; pre-existing ones
#             are listed separately; a finding that does not say is counted
# C8 [change] lenses are given the repository's rules, framed for a reviewer
# C9 [change] the scope lens does not report planned-but-untouched files
# C11 [change] ...and the design's decisions (#1654 item 3): what was DECIDED,
#              so a lens tells "odd" from "chosen"
# C10 [change] end to end: a lens that says introduced:false produces a result
#              file that still says so, and the aggregator lists it as
#              pre-existing (review on #2215: the lens's own normalization
#              dropped the field, and C7 fed the aggregator by hand)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: review-lens — context to judge with, and new vs pre-existing"
setup_test_env "plugin-review-lens-context"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
PLUGIN_DIR="$REPO_ROOT/plugins/agent/review-lens"
# shellcheck source=../../../../plugins/agent/review-lens/plugin.sh
source "$PLUGIN_DIR/plugin.sh"

PROMPT_F="$TEST_TEMP_DIR/prompt.txt"
route_to_model() { printf '%s' "$2" > "$PROMPT_F"; printf '%s' '{"score":9,"findings":[]}'; return 0; }

ART="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ART" "$TEST_TEMP_DIR/stage-inputs"
printf 'ISSUE-BODY-MARKER migrate the validate plugin to contract v2\n' > "$TEST_TEMP_DIR/intake.md"
cat > "$ART/design.md" <<'EOF'
# Design

DECISION-MARKER: validate reads its input from the engine's index, never a path.

```acceptance
SPEC-3[change]: SPEC-TEXT-MARKER validate writes a v2 result
TESTFILES:
tests/x-test.sh
```
EOF
printf '+ SCOPE-MARKER plugins/agent/validate/\n' > "$TEST_TEMP_DIR/scope-manifest.md"
printf 'diff --git a/plugins/agent/validate/plugin.sh b/plugins/agent/validate/plugin.sh\n+ changed\n' > "$ART/diff.patch"
jq -n --arg i "$TEST_TEMP_DIR/intake.md" --arg d "$ART/design.md" --arg s "$TEST_TEMP_DIR/scope-manifest.md" --arg p "$ART/diff.patch" \
    '{inputs:{intake_goal:$i, design:$d, scope_manifest:$s, diff_patch:$p}}' > "$TEST_TEMP_DIR/stage-inputs/review-lens.json"
export ZBUILD_STAGE_INPUTS="$TEST_TEMP_DIR/stage-inputs/review-lens.json"

# A restored previous review of this lens, which must NOT be shown to it (C6).
RESTORED="$TEST_TEMP_DIR/restored"; mkdir -p "$RESTORED"
printf '{"score":2,"findings":[{"message":"PRIOR-REVIEW-MARKER"}]}\n' > "$RESTORED/lens-correctness.json"
export ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED"

_review_lens_run_inner correctness "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-correctness.json" "$ART" >/dev/null 2>&1 || true
P="$(cat "$PROMPT_F" 2>/dev/null || true)"

print_test_section "C1–C4: what the lens is given"
assert_contains "[C1] the issue text" "$P" "ISSUE-BODY-MARKER"
assert_contains "[C2] the SPECs" "$P" "SPEC-TEXT-MARKER"
assert_contains "[C3] the planned scope" "$P" "SCOPE-MARKER"
assert_contains "[C11] the design's decisions" "$P" "DECISION-MARKER"
# Line breaks flattened: the prompt wraps this sentence across two lines.
if grep -qF "Report only issues you can point to in the change below" <<< "$(tr '\n' ' ' <<< "$P" | tr -s ' ')"; then
    assert_fail "[C4] no longer confined to the diff" "the confining sentence is still there"
else
    assert_pass "[C4] no longer confined to the diff"
fi
assert_contains "[C4] told to read the code around the change" "$P" "read the surrounding code"

print_test_section "C5/C6"
assert_contains "[C5] each finding says whether the change introduced it" "$P" '"introduced"'
if grep -qF "PRIOR-REVIEW-MARKER" <<< "$P"; then
    assert_fail "[C6] the lens is not shown its own previous review" "prior review injected"
else
    assert_pass "[C6] the lens is not shown its own previous review"
fi

print_test_section "C7: the aggregator counts only what the change introduced"
# shellcheck source=../../../../plugins/agent/review-aggregator/plugin.sh
source "$REPO_ROOT/plugins/agent/review-aggregator/plugin.sh" 2>/dev/null || true
LENSES="$TEST_TEMP_DIR/lenses.json"
jq -n '[{name:"red-team", score:8, findings:[
    {file:"a.sh", category:"x", severity:"medium", line:1, message:"NEW-ONE", introduced:true},
    {file:"b.sh", category:"y", severity:"medium", line:9, message:"OLD-ONE", introduced:false},
    {file:"c.sh", category:"z", severity:"low", line:3, message:"UNSAID"}]}]' > "$LENSES"
AGG="$(_ra_aggregate "$LENSES" 2>/dev/null || true)"
assert_eq "[C7] introduced + unsaid are counted (2)" "2" "$(jq '.findings | length' <<< "$AGG" 2>/dev/null || echo x)"
assert_eq "[C7] the pre-existing one is listed separately" "OLD-ONE" \
    "$(jq -r '.pre_existing[0].messages[0] // empty' <<< "$AGG" 2>/dev/null || true)"
assert_contains "[C7] the summary counts 2 findings" "$(jq -r .summary <<< "$AGG" 2>/dev/null || true)" "2 merge-readiness finding(s)"

print_test_section "C8/C9: rules and the scope lens"
assert_eq "[C8] review-lens declares prompt.repo_rules" "true" \
    "$(yaml_get "$PLUGIN_DIR/manifest.yaml" "prompt.repo_rules" 2>/dev/null || true)"
# shellcheck source=../../../../scripts/lib/repo-rules.sh
source "$REPO_ROOT/scripts/lib/repo-rules.sh"
_blk="$(repo_rules_prompt_block "$PLUGIN_DIR/manifest.yaml" "$REPO_ROOT" 2>/dev/null || true)"
assert_contains "[C8] framed for a reviewer" "$_blk" "a change that breaks one is a finding"
if grep -qF "Every file you write must follow" <<< "$_blk"; then
    assert_fail "[C8] not framed as rules for writing" "writer framing given to a reviewer"
else
    assert_pass "[C8] not framed as rules for writing"
fi
_scope="$(resolve_persona_charter scope 2>/dev/null || true)"
if grep -qiE "untouched|did not touch" <<< "$_scope"; then
    assert_fail "[C9] the scope lens does not report planned-but-untouched files" "$_scope"
else
    assert_contains "[C9] it still reports unplanned edits" "$_scope" "did not list"
fi

print_test_section "C10: introduced survives the lens's own result file"
route_to_model() { printf '%s' '{"score":7,"findings":[{"file":"a.sh","category":"x","severity":"medium","line":3,"message":"OLD-BEHAVIOUR","introduced":false},{"file":"b.sh","category":"y","severity":"low","line":5,"message":"NEW-THING","introduced":true}]}'; return 0; }
_review_lens_run_inner red-team "$TEST_TEMP_DIR/scope-manifest.md" "$ART/diff.patch" "$ART/lens-red-team.json" "$ART" >/dev/null 2>&1 || true
assert_eq "[C10] the lens's result keeps introduced:false" "false" \
    "$(jq -r '[.findings[] | select(.message == "OLD-BEHAVIOUR") | .introduced][0] | tostring' "$ART/lens-red-team.json" 2>/dev/null || true)"
jq -n --slurpfile l "$ART/lens-red-team.json" '[{name:"red-team", score:7, findings:$l[0].findings}]' > "$TEST_TEMP_DIR/l10.json"
AGG10="$(_ra_aggregate "$TEST_TEMP_DIR/l10.json" 2>/dev/null || true)"
assert_eq "[C10] ...and the aggregator lists it as pre-existing" "OLD-BEHAVIOUR" \
    "$(jq -r '.pre_existing[0].messages[0] // empty' <<< "$AGG10" 2>/dev/null || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
