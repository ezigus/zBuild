#!/usr/bin/env bash
# tests/unit/summary-producers-test.sh — the first stages to declare a summary
# output (#1977, follows #1976).
#
# #1976 added the `summary: true` marker and the engine-injected
# `## STAGE SUMMARIES` block. The mechanism is inert until a producer declares,
# so a green #1976 proves nothing about a real run. These are the declarations
# that make it live, and the wiring assertions that keep it from going inert
# again — the #1919 lesson: a capability nothing invokes is not a capability.
#
#   SPEC-1 [change]: spec-acceptance DECLARES acceptance-summary.txt, which it
#                    has always written (plugin.sh:533) and never declared —
#                    the only undeclared output in the tree
#   SPEC-2 [change]: gate-aggregator's gate_feedback is marked summary: true
#   SPEC-3 [change]: test's test_failures_summary is marked summary: true
#   SPEC-4 [guard] : every declared summary output resolves to a real path.
#                    This used to assert every producer was `convergence: gate`,
#                    holding #1898's question open. #1986 decided it — advisory
#                    stages DO publish — so the guard that remains is the one
#                    that still means something: a declaration must point at a
#                    file the plugin writes
#   SPEC-5 [change]: the declared path is the one the plugin actually writes —
#                    a declaration pointing at a file nobody writes is inert
#   SPEC-6 [guard] : each producer still declares exactly one primary, and at
#                    most one summary (the #1976 lint rule)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "summary producers — the declarations that make #1976 live (#1977)"
setup_test_env "summary-producers"

ACC_M="$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml"
AGG_M="$REPO_ROOT/plugins/tool/gate-aggregator/manifest.yaml"
TEST_M="$REPO_ROOT/plugins/tool/test/manifest.yaml"

# ─── SPEC-1: the undeclared output is declared ───────────────────────────────
print_test_section "1. spec-acceptance declares the summary it always wrote"

_acc_ids="$(manifest_graph_get_outputs "$ACC_M" | cut -d'|' -f1)"
assert_contains "[SPEC-1] an output id now covers acceptance-summary.txt" \
    "$_acc_ids" "acceptance_detail"
assert_eq "[SPEC-1] and it is the stage's summary" "true" \
    "$(manifest_graph_output_summary "$ACC_M" acceptance_detail)"
assert_eq "[SPEC-1] declared optional — a no-op run writes no summary" "false" \
    "$(manifest_graph_get_outputs "$ACC_M" | grep '^acceptance_detail|' | cut -d'|' -f4)"

# ─── SPEC-2 / SPEC-3: the two already-declared summaries are marked ──────────
print_test_section "2. gate-aggregator's feedback is marked a summary"
assert_eq "[SPEC-2] gate_feedback is the aggregator's summary" "true" \
    "$(manifest_graph_output_summary "$AGG_M" gate_feedback)"

print_test_section "3. the test stage's failure summary is marked"
assert_eq "[SPEC-3] test_failures_summary is the test stage's summary" "true" \
    "$(manifest_graph_output_summary "$TEST_M" test_failures_summary)"

# ─── SPEC-4: no advisory producer sneaks in ──────────────────────────────────
# The engine's collector already filters on convergence, but a declaration on an
# advisory plugin would be a standing invitation to relax that filter later.
print_test_section "4. every declared summary resolves to a real path"

_bad_paths=""
while IFS= read -r -d '' _m; do
    _sid="$(manifest_graph_get_stage_id "$_m")"
    [[ -n "$_sid" ]] || continue
    while IFS= read -r _rec; do
        [[ -n "$_rec" ]] || continue
        _oid="${_rec%%|*}"
        [[ "$(manifest_graph_output_summary "$_m" "$_oid")" == "true" ]] || continue
        _p="${_rec##*|}"
        [[ "$_p" == *'${artifact_dir}'* || "$_p" == *'${state_dir}'* ]] \
            || _bad_paths="${_bad_paths}${_sid}:${_oid} "
    done < <(manifest_graph_get_outputs "$_m")
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -not -path '*/tests/*' -print0 2>/dev/null)

assert_eq "[SPEC-4] every summary output is rooted in a run directory" "" \
    "$(printf '%s' "$_bad_paths" | sed 's/[[:space:]]*$//')"

# ─── SPEC-5: the declaration points at the file the plugin writes ────────────
# A declared path nothing writes is the mirror of an undeclared file nothing
# reads — inert either way.
print_test_section "5. the declared path is the one the plugin writes"

_acc_path="$(manifest_graph_get_outputs "$ACC_M" | grep '^acceptance_detail|' | sed 's/.*|//')"
assert_contains "[SPEC-5] the declared path names acceptance-summary.txt" \
    "$_acc_path" "acceptance-summary.txt"
assert_contains "[SPEC-5] and spec-acceptance actually writes that basename" \
    "$(cat "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh")" "acceptance-summary.txt"

# The write must land where the declaration says: ${artifact_dir} resolves to
# ${state_dir}/artifacts, which is what plugin.sh:533 builds by hand.
assert_contains "[SPEC-5] the declared path is under artifact_dir" \
    "$_acc_path" 'artifact_dir'

# ─── SPEC-6: the manifests stay well-formed ──────────────────────────────────
print_test_section "6. one primary, at most one summary, per producer"

# Scoped to the outputs: block — `provides.primary` is a different field at the
# same indent, and counting it would make this assert something it does not mean.
_count_in_outputs() {
    awk -v field="$2" '
        BEGIN { in_out=0; n=0 }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { in_out=0 }
        in_out && $0 ~ ("^[[:space:]]+" field ":[[:space:]]*true([[:space:]]|$|#)") { n++ }
        END { print n }
    ' "$1" 2>/dev/null
}

for _m in "$ACC_M" "$AGG_M" "$TEST_M"; do
    _name="$(basename "$(dirname "$_m")")"
    assert_eq "[SPEC-6] $_name declares exactly one primary output" "1" \
        "$(_count_in_outputs "$_m" primary)"
    assert_eq "[SPEC-6] $_name declares exactly one summary output" "1" \
        "$(_count_in_outputs "$_m" summary)"
done

# The repo-wide contract lint is the real enforcer; run it so a malformed
# declaration fails here rather than in CI.
_lint_rc=0
bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || _lint_rc=$?
assert_eq "[SPEC-6] the contract lint accepts the tree" "0" "$_lint_rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
