#!/usr/bin/env bash
# Unit tests: _impact_converge_on_overscope (#936) — over-scope-safe convergence.
#
# The backstop flips verdict incomplete→complete ONLY in the provably-safe
# over-scope case, so a real reference gap or a structural omission is NEVER
# masked. Safety-critical no-fire cases are paired with a positive control so
# the whole file fails at the merge-base baseline (function absent).
#
# SPEC-1: collateral plateau at iter>=2 (same non-floor set as prior) → FIRES
# SPEC-2: a structural (core/scripts/plugins) file present → does NOT fire
# SPEC-3: a floor entry (step_id==prefilter) present → does NOT fire (#781/#881)
# SPEC-4: first iter / no prior sidecar → does NOT fire
# SPEC-5: changed non-floor set (cascade) → does NOT fire
# SPEC-6: verdict=error → never flipped
# SPEC-7: shape-change plan → does NOT fire (unrecoverable-omission regime)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "unit: impact over-scope convergence backstop (#936)"
setup_test_env "impact-scope-plateau"

EVENTS_LOG="$TEST_TEMP_DIR/events.log"
emit_event() { printf '%s\n' "$*" >> "$EVENTS_LOG"; return 0; }

# shellcheck source=../../scripts/lib/impact-prefilter.sh
source "$REPO_ROOT/scripts/lib/impact-prefilter.sh"

# ─── Fake repo: collateral + structural files ───────────────────────────────
FAKE_ROOT="$TEST_TEMP_DIR/fake-repo"
mkdir -p "$FAKE_ROOT/tests/unit" "$FAKE_ROOT/config" "$FAKE_ROOT/scripts/lib" \
         "$FAKE_ROOT/docs" "$FAKE_ROOT/plugins/agent/foo"
: > "$FAKE_ROOT/tests/unit/a-test.sh"
: > "$FAKE_ROOT/tests/unit/b-test.sh"
: > "$FAKE_ROOT/config/c.json"
: > "$FAKE_ROOT/scripts/lib/d.sh"
mkdir -p "$FAKE_ROOT/config/templates"
: > "$FAKE_ROOT/config/templates/standard.yaml"
# Shape-change glob list so _impact_detect_shape_change fires for SHAPE_PLAN.
printf 'config/templates/*.yaml\n' > "$FAKE_ROOT/config/shape-change-paths.txt"

ARTDIR="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ARTDIR"
SIDE="$ARTDIR/impact-prior-missing.txt"
NONSHAPE_PLAN='{"schema_version":1,"steps":[{"id":"s","files":["plugins/agent/foo/plugin.sh"],"estimated_lines":1}]}'
SHAPE_PLAN='{"schema_version":1,"steps":[{"id":"s","files":["config/templates/standard.yaml"],"estimated_lines":1}]}'

_set_prior() { printf '%s\n' "$1" > "$SIDE"; }   # newline list of prior non-floor paths

# ─── SPEC-1: collateral plateau at iter2 → fires ────────────────────────────
: > "$EVENTS_LOG"
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh","tests/unit/b-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh\ntests/unit/b-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-1] collateral plateau iter2 → verdict flips to complete" \
    "complete" "$(printf '%s' "$impact_json" | jq -r .verdict)"
if grep -q 'impact.scope.plateau' "$EVENTS_LOG"; then
    assert_pass "[SPEC-1] impact.scope.plateau emitted with verdict_flipped"
else
    assert_fail "[SPEC-1] impact.scope.plateau not emitted" "$(cat "$EVENTS_LOG")"
fi

# ─── SPEC-2: structural file present → no fire (+ positive control) ──────────
: > "$EVENTS_LOG"
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh","scripts/lib/d.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'scripts/lib/d.sh\ntests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-2] structural (scripts/lib) present → stays incomplete" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"
# positive control: same set minus the structural path → fires (fails at baseline)
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-2] control: collateral-only same set → flips (proves the structural veto)" \
    "complete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-3: floor entry present → no fire (+ control) ───────────────────────
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"prefilter","files_to_add":["tests/unit/b-test.sh"],"reason":"floor"},{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-3] floor entry (step_id=prefilter) present → stays incomplete" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-4: iter=1 / no prior sidecar → no fire ────────────────────────────
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=1 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-4] first iter (ZBUILD_CYCLE_ITER=1) → stays incomplete" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"
# no prior sidecar at all → no fire even at iter2
rm -f "$SIDE"
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-4] no prior sidecar → stays incomplete (need a real prior pass)" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-5: changed non-floor set (cascade) → no fire ──────────────────────
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/b-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'   # prior set differs from current → cascade, not plateau
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-5] changed set (cascade, prior!=current) → stays incomplete" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-6: verdict=error → never flipped ──────────────────────────────────
impact_json='{"schema_version":1,"verdict":"error","reason":"router_timeout","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-6] verdict=error never flipped by the backstop" \
    "error" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-7: shape-change plan → no fire (+ control via NONSHAPE_PLAN) ───────
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$SHAPE_PLAN"
assert_eq "[SPEC-7] shape-change plan → stays incomplete (run full iteration budget)" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-8 (Codex P2): shape file in the DESIGN SCOPE (not the plan) → no fire
# design can add a shape file the plan omitted; the floor keys off the plan, so
# the backstop must also inspect the design scope (4th arg).
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/unit/a-test.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior $'tests/unit/a-test.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN" "config/templates/standard.yaml"
assert_eq "[SPEC-8] shape file in design scope → stays incomplete (plan was non-shape)" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

# ─── SPEC-9 (Codex P2): a `..` traversal path → no fire ─────────────────────
# tests/../scripts/lib/d.sh passes the prefix collateral check yet resolves to a
# structural file; the traversal guard must refuse to converge.
impact_json='{"schema_version":1,"verdict":"incomplete","missing":[{"step_id":"s1","files_to_add":["tests/../scripts/lib/d.sh"],"reason":"adj"}],"impact_feedback_md":""}'
_set_prior 'tests/../scripts/lib/d.sh'
ZBUILD_CYCLE_ITER=2 _impact_converge_on_overscope "$FAKE_ROOT" "$ARTDIR" "$NONSHAPE_PLAN"
assert_eq "[SPEC-9] '..' traversal path → stays incomplete (no structural hiding)" \
    "incomplete" "$(printf '%s' "$impact_json" | jq -r .verdict)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
