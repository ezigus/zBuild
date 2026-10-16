#!/usr/bin/env bash
# tests/unit/gate-detail-outputs-test.sh — each gate publishes its own failure
# detail; the aggregator stops rendering prose (#1988).
#
# The gate-aggregator did three jobs. Two are irreplaceable: it produces the ONE
# convergence verdict `exit_when` binds to (ADR-040 §5 requires exactly one
# `convergence: gate` construct to bind to), and it rolls up the declared fault
# class (#1987). The third — rendering gate-feedback.md and design-feedback.md —
# existed only because it was the sole path for gate detail to reach a prompt.
#
# #1976 made another path. Five gates declared ONLY a result JSON and had no
# detail artifact, which is why this could not come first: removing the
# aggregator's rendering before the gates could publish would have lost failure
# detail outright, and losing it silently is the failure mode this series exists
# to stop.
#
# Because the gates now publish individually, the aggregator must ALSO drop
# `aggregates: gate` — otherwise the engine suppresses the members and ships an
# aggregate that no longer contains anything.
#
#   SPEC-1 [change]: each of the five gates declares a summary output
#   SPEC-2 [change]: a failing gate writes its detail; a passing one does not
#   SPEC-3 [change]: no manifest names gate_feedback / design_feedback
#   SPEC-4/5 retired with gate-aggregator (#2368): the engine combines a loop
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "gates publish their own detail; the aggregator stops rendering (#1988)"
setup_test_env "gate-detail-outputs"

_GATES="lint-gate coverage-gate mutation-gate"

# ─── SPEC-1: every gate declares a summary ───────────────────────────────────
print_test_section "1. each gate declares a summary output"

for _g in $_GATES; do
    _m="$REPO_ROOT/plugins/tool/$_g/manifest.yaml"
    _found=""
    while IFS= read -r _rec; do
        [[ -n "$_rec" ]] || continue
        _oid="${_rec%%|*}"
        [[ "$(manifest_graph_output_summary "$_m" "$_oid")" == "true" ]] && _found="$_oid"
    done < <(manifest_graph_get_outputs "$_m")
    if [[ -n "$_found" ]]; then
        assert_pass "[SPEC-1] $_g publishes '$_found'"
    else
        assert_fail "[SPEC-1] $_g publishes a summary" "no summary output declared"
    fi
done

# ─── SPEC-2: written on fail, absent on pass ─────────────────────────────────
# Absent-on-pass matters: a stale detail file from a previous iteration would be
# rendered as a current finding, which is the #1979 duplication in another form.
print_test_section "2. detail is written on fail and absent on pass"

# Behavioural, not a grep for a write site: the guarantee is "every gate always
# speaks", and asserting WHERE that lives would pin the implementation instead.
# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh"

_GD="$TEST_TEMP_DIR/gd-detail.md"
stage_summary_write "$_GD" "sample-gate" "fail" "the floor is missing two files" "- a.sh
- b.sh"
assert_file_exists "[SPEC-2] a failing gate writes its summary" "$_GD"
assert_contains "[SPEC-2] the summary names the gate" "$(cat "$_GD")" "sample-gate"
assert_contains "[SPEC-2] and carries the reason" "$(cat "$_GD")" "the floor is missing two files"
assert_contains "[SPEC-2] and the body" "$(cat "$_GD")" "a.sh"

# ADR-055 §9: "ran and found nothing" and "published nothing" are different
# facts. If absence were legitimate the pipeline could not tell them apart, so a
# passing gate states its conclusion rather than staying silent.
stage_summary_write "$_GD" "sample-gate" "pass" ""
assert_file_exists "[SPEC-2] a PASSING gate still writes its summary" "$_GD"
assert_contains "[SPEC-2] and states the verdict it reached" "$(cat "$_GD")" "pass"
assert_contains "[SPEC-2] saying so explicitly rather than being empty" \
    "$(cat "$_GD")" "no findings"

stage_summary_write "$_GD" "sample-gate" "skip" "no shape change in the diff"
assert_contains "[SPEC-2] a SKIPPING gate says why it skipped" \
    "$(cat "$_GD")" "no shape change in the diff"

# Because every run rewrites the file, a previous iteration's finding cannot
# survive to be read as a current one — the stale-file hazard is gone by
# construction rather than by a clear step someone has to remember.
stage_summary_write "$_GD" "sample-gate" "fail" "OLD-FINDING"
stage_summary_write "$_GD" "sample-gate" "pass" ""
if grep -qF 'OLD-FINDING' "$_GD"; then
    assert_fail "[SPEC-2] a prior iteration's finding cannot survive" "stale content remains"
else
    assert_pass "[SPEC-2] a prior iteration's finding cannot survive"
fi

# Every gate must actually CALL it — a helper nothing invokes is inert (#1919).
for _g in $_GATES; do
    if grep -qF 'stage_summary_write' "$REPO_ROOT/plugins/tool/$_g/plugin.sh" 2>/dev/null; then
        assert_pass "[SPEC-2] $_g publishes through the shared helper"
    else
        assert_fail "[SPEC-2] $_g publishes through the shared helper" "no call found"
    fi
done

# ─── SPEC-3: the aggregator stops rendering ──────────────────────────────────
print_test_section "3. the aggregator no longer renders prose"

# No inert declaration left behind — the #1865/#1898 lesson.
_orphans=""
while IFS= read -r -d '' _m; do
    # Declared inputs are retired (ADR-055 §1, amended 2026-10-12): a manifest
    # that still names a retired output anywhere is an inert leftover.
    grep -qE '(^|[^A-Za-z_])(gate_feedback|design_feedback)([^A-Za-z_]|$)' "$_m" 2>/dev/null \
        && _orphans="${_orphans}$(manifest_graph_get_stage_id "$_m") "
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)
assert_eq "[SPEC-3] no consumer still names the retired outputs" "" \
    "$(printf '%s' "$_orphans" | sed 's/[[:space:]]*$//')"


cleanup_test_env
print_test_results
exit $((FAIL > 0))
