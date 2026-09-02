#!/usr/bin/env bash
# tests/unit/summaries-all-stages-test.sh — every stage publishes a summary and
# following stages ingest them, advisory included (#1986, closes #1898).
#
# #1976 built the mechanism; #1977 declared the first producers. The collector
# filtered on `convergence: gate` — deliberately, to keep #1898's open question
# ("may an advisory stage's output reach the build loop?") from being answered
# by accident. #1898 is now decided: it may.
#
# ADR-040 §5 is NOT weakened. It governs whether a stage may BLOCK — whether it
# can sit in a must-pass set or an exit_when predicate. Injecting a stage's text
# into a prompt places it on no convergence path, and the B5 no-LLM-on-the-
# convergence-path invariant is untouched.
#
# The problem this creates is duplication: if every stage publishes AND an
# aggregator publishes its merged rendering of those same stages, the prompt
# carries both — the contradiction #1979 removed, from the other side. So an
# aggregator declares the roster it COVERS, and the engine ships only the
# aggregate.
#
#   SPEC-1 [change]: an advisory stage's summary reaches the block
#   SPEC-2 [change]: a stage declaring `aggregates:` suppresses the summaries of
#                    the stages it covers — only the aggregate ships
#   SPEC-3 [guard] : with no aggregator present, members flow individually
#   SPEC-4 [guard] : an aggregator never suppresses ITSELF
#   SPEC-5 [guard] : latest-wins per stage still holds — the block stays flat in
#                    stage count, never iteration count (ADR-029)
#   SPEC-6 [change]: two aggregators covering different rosters each suppress
#                    only their own
#   SPEC-7 [guard] : an aggregator that suppresses a roster MUST publish a
#                    summary itself. Otherwise it deletes its members' findings
#                    and contributes nothing in their place — a silent loss,
#                    which is the failure mode this whole series exists to stop
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "summaries from every stage; aggregators suppress their roster (#1986)"
setup_test_env "summaries-all-stages"

STATE="$TEST_TEMP_DIR/state"; ART="$STATE/artifacts"; PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART"

# _mkplugin <dir> <id> <convergence> <aggregates|-> — one summary output each.
_mkplugin() {
    local d="$PROOT/$1" id="$2" conv="$3" agg="$4"
    mkdir -p "$d"
    {
        printf 'id: %s\nname: %s\nkind: tool\nversion: 0.0.1\n' "$id" "$id"
        printf 'convergence: %s\n' "$conv"
        [[ "$agg" != "-" ]] && printf 'aggregates: %s\n' "$agg"
        printf 'hooks:\n  run: %s_run\ninputs: []\noutputs:\n' "${id//-/_}"
        printf '  - id: %s_result\n    path: ${artifact_dir}/%s-result.json\n' "${id//-/_}" "$id"
        printf '    type: json\n    required: true\n    primary: true\n'
        printf '  - id: %s_detail\n    path: ${artifact_dir}/%s-detail.txt\n' "${id//-/_}" "$id"
        printf '    type: text\n    required: false\n    summary: true\n'
    } > "$d/manifest.yaml"
    printf '%s_run() { return 0; }\n' "${id//-/_}" > "$d/plugin.sh"
    printf '%s-BODY\n' "$(printf '%s' "$id" | tr 'a-z-' 'A-Z_')" > "$ART/$id-detail.txt"
}

_mkplugin tool/sa-gate     sa-gate     gate     -
_mkplugin tool/sa-gate2    sa-gate2    gate     -
_mkplugin agent/sa-lens    sa-lens     advisory -
_mkplugin tool/sa-gateagg  sa-gateagg  gate     gate
_mkplugin agent/sa-revagg  sa-revagg   advisory advisory

_state() {
    local stages="" s
    for s in "$@"; do stages="${stages}\"$s\":\"complete\","; done
    printf '{"schema_version":1,"stage_statuses":{%s},"stage_verdicts":{}}\n' \
        "${stages%,}" > "$STATE/pipeline-state.json"
}
_block() { stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true; }

# ─── SPEC-1: advisory stages contribute ──────────────────────────────────────
print_test_section "1. an advisory stage's summary reaches the block (#1898)"

_TPL_STAGES=(sa-gate sa-lens)
_state sa-gate sa-lens
B1="$(_block)"
assert_contains "[SPEC-1] the gate's summary is present" "$B1" "SA_GATE-BODY"
assert_contains "[SPEC-1] and the ADVISORY stage's is too" "$B1" "SA_LENS-BODY"

# ─── SPEC-2: an aggregator suppresses its roster ─────────────────────────────
print_test_section "2. an aggregator ships the aggregate, not its members"

_TPL_STAGES=(sa-gate sa-gate2 sa-gateagg)
_state sa-gate sa-gate2 sa-gateagg
B2="$(_block)"
assert_contains "[SPEC-2] the aggregate is present" "$B2" "SA_GATEAGG-BODY"
if grep -qF 'SA_GATE-BODY' <<< "$B2" || grep -qF 'SA_GATE2-BODY' <<< "$B2"; then
    assert_fail "[SPEC-2] covered members are suppressed" \
        "a member's summary shipped alongside the aggregate — the #1979 duplication"
else
    assert_pass "[SPEC-2] covered members are suppressed"
fi

# ─── SPEC-3: no aggregator → members flow ────────────────────────────────────
print_test_section "3. with no aggregator, members flow individually"

_TPL_STAGES=(sa-gate sa-gate2)
_state sa-gate sa-gate2
B3="$(_block)"
assert_contains "[SPEC-3] the first member is present" "$B3" "SA_GATE-BODY"
assert_contains "[SPEC-3] the second member is present" "$B3" "SA_GATE2-BODY"

# ─── SPEC-4: an aggregator does not suppress itself ──────────────────────────
# sa-gateagg is `convergence: gate` AND covers `gate`. Naive matching would
# delete its own summary and ship nothing at all.
print_test_section "4. an aggregator never suppresses itself"

_TPL_STAGES=(sa-gateagg)
_state sa-gateagg
B4="$(_block)"
assert_contains "[SPEC-4] the aggregate survives when it is the only stage" \
    "$B4" "SA_GATEAGG-BODY"

# ─── SPEC-5: latest-wins per stage (ADR-029) ─────────────────────────────────
print_test_section "5. one entry per stage, whatever the iteration count"

_TPL_STAGES=(sa-gate sa-lens)
_state sa-gate sa-lens
printf 'SA_GATE-BODY\nITER-2\n' > "$ART/sa-gate-detail.txt"
B5="$(_block)"
assert_eq "[SPEC-5] the stage appears exactly once" "1" \
    "$(grep -cF 'SA_GATE-BODY' <<< "$B5" || true)"
assert_contains "[SPEC-5] carrying the LATEST body" "$B5" "ITER-2"
printf 'SA_GATE-BODY\n' > "$ART/sa-gate-detail.txt"

# ─── SPEC-6: rosters are independent ─────────────────────────────────────────
print_test_section "6. two aggregators each suppress only their own roster"

_TPL_STAGES=(sa-gate sa-lens sa-gateagg sa-revagg)
_state sa-gate sa-lens sa-gateagg sa-revagg
B6="$(_block)"
assert_contains "[SPEC-6] the gate aggregate ships" "$B6" "SA_GATEAGG-BODY"
assert_contains "[SPEC-6] the review aggregate ships" "$B6" "SA_REVAGG-BODY"
if grep -qF 'SA_GATE-BODY' <<< "$B6"; then
    assert_fail "[SPEC-6] the gate member is suppressed" "member shipped"
else
    assert_pass "[SPEC-6] the gate member is suppressed"
fi
if grep -qF 'SA_LENS-BODY' <<< "$B6"; then
    assert_fail "[SPEC-6] the advisory member is suppressed" "member shipped"
else
    assert_pass "[SPEC-6] the advisory member is suppressed"
fi

# ─── SPEC-7: an aggregator must not delete findings and replace them with none ─
print_test_section "7. a suppressing aggregator must publish a summary"

_no_summary=""
while IFS= read -r -d '' _m; do
    grep -qE '^aggregates:[[:space:]]*[a-z]' "$_m" 2>/dev/null || continue
    _sid="$(manifest_graph_get_stage_id "$_m")"
    grep -qE '^[[:space:]]+summary:[[:space:]]*true' "$_m" 2>/dev/null \
        || _no_summary="${_no_summary}${_sid} "
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

assert_eq "[SPEC-7] every aggregator publishes what it suppresses" "" \
    "$(printf '%s' "$_no_summary" | sed 's/[[:space:]]*$//')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
