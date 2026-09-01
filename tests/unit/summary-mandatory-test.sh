#!/usr/bin/env bash
# tests/unit/summary-mandatory-test.sh — every stage-bound plugin publishes a
# summary, and pre-flight refuses a flow where one does not (#2000).
#
# ADR-055 §9: a summary states what a stage DID, not what went wrong. A stage
# that publishes nothing is indistinguishable from one that had nothing to say,
# and the pipeline cannot tell those apart — so the second silently absorbs the
# first. `acceptance-summary.txt` is the worked example: written by
# spec-acceptance, declared by nobody, unread for months.
#
# ENFORCEMENT IS AT RUNTIME, and that is the whole point of this issue. The
# pre-flight validator walks the RESOLVED stage list against the configured
# plugins_root, so it sees a stage authored outside this repository. A lint over
# plugins/ cannot: it would report a clean tree while a third-party stage
# published nothing. The lint stays as the fast local signal, and the parity
# test keeps the two views from drifting.
#
#   SPEC-1 [change]: every stage-bound plugin in the tree declares exactly one
#   SPEC-2 [change]: pre-flight REFUSES a resolved flow containing a stage-bound
#                    plugin with no summary — asserted against a plugin OUTSIDE
#                    the tree, the case a lint structurally cannot cover
#   SPEC-3 [guard] : backend services are exempt (ADR-047 §5) and unaffected
#   SPEC-4 [change]: the tree lint mirrors the refusal for local plugins
#   SPEC-5 [guard] : a summary is written on pass, fail AND skip — a passing
#                    stage states its conclusion rather than being absent
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "every stage publishes a summary; pre-flight enforces it (#2000)"
setup_test_env "summary-mandatory"

# ─── SPEC-1: the tree conforms ───────────────────────────────────────────────
print_test_section "1. every stage-bound plugin declares exactly one summary"

declare -A _HAS_IN=() _ANY_OUT=() _PROD_REF=() _IN_NAMES=()
for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    _id="$(manifest_graph_get_stage_id "$_m")"; [[ -n "$_id" ]] || continue
    while IFS= read -r _r; do
        [[ -n "$_r" ]] || continue
        _IN_NAMES["${_r%%|*}"]=1; _HAS_IN["$_id"]=1
    done < <(manifest_graph_get_inputs "$_m")
    while IFS= read -r _r; do
        [[ -n "$_r" ]] && _ANY_OUT["$_id:${_r%%|*}"]=1
    done < <(manifest_graph_get_outputs "$_m")
done
for _k in "${!_ANY_OUT[@]}"; do
    [[ -n "${_IN_NAMES[${_k#*:}]:-}" ]] && _PROD_REF["${_k%%:*}"]=1
done

_missing="" _doubled=""
for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    _id="$(manifest_graph_get_stage_id "$_m")"; [[ -n "$_id" ]] || continue
    # Stage-bound iff a node in the data-dependency graph — the same derivation
    # lint-contract.sh uses, so backend services fall out with no naming.
    [[ -n "${_HAS_IN[$_id]:-}${_PROD_REF[$_id]:-}" ]] || continue
    _n="$(grep -cE '^[[:space:]]+summary:[[:space:]]*true' "$_m" || true)"
    [[ "$_n" -eq 0 ]] && _missing="${_missing}${_id} "
    [[ "$_n" -gt 1 ]] && _doubled="${_doubled}${_id} "
done
assert_eq "[SPEC-1] no stage-bound plugin is without a summary" "" \
    "$(printf '%s' "$_missing" | sed 's/[[:space:]]*$//')"
assert_eq "[SPEC-1] and none declares more than one" "" \
    "$(printf '%s' "$_doubled" | sed 's/[[:space:]]*$//')"

# ─── SPEC-2: pre-flight refuses, for a plugin the lint cannot see ────────────
print_test_section "2. pre-flight refuses a summary-less stage OUTSIDE the tree"

EXT="$TEST_TEMP_DIR/external/plugins/tool/ext-stage"
mkdir -p "$EXT"
cat > "$EXT/manifest.yaml" <<'EOF'
id: ext-stage
name: External Stage
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: ext_stage_run
inputs:
  - id: gh_issue_body
    source: external
    required: true
outputs:
  - id: ext_stage_result
    path: ${artifact_dir}/ext-stage-result.json
    type: json
    required: true
    primary: true
EOF
printf 'ext_stage_run() { return 0; }\n' > "$EXT/plugin.sh"

# shellcheck source=../../core/pipeline/contract-validator.sh
source "$REPO_ROOT/core/pipeline/contract-validator.sh" 2>/dev/null || true

_CV_STATE="$TEST_TEMP_DIR/cv-state.json"
printf '{"schema_version":1}\n' > "$_CV_STATE"
_cv_rc=0
_cv_out="$(_contract_validate_pipeline "ext-stage" \
    "$TEST_TEMP_DIR/external/plugins" "$_CV_STATE" 2>&1)" || _cv_rc=$?

assert_contains "[SPEC-2] the refusal names the offending stage" "$_cv_out" "ext-stage"
assert_contains "[SPEC-2] and says a summary is missing" "$_cv_out" "SUMMARY_MISSING"
if [[ "$_cv_rc" -ne 0 ]]; then
    assert_pass "[SPEC-2] pre-flight REFUSES rather than warning"
else
    assert_fail "[SPEC-2] pre-flight REFUSES rather than warning" \
        "returned 0 — a warning about silence is easy to not hear"
fi

# The point of runtime enforcement: this plugin is not in the tree, so the lint
# reports clean while the stage publishes nothing.
_lint_rc=0
bash "$REPO_ROOT/scripts/lib/lint-contract.sh" >/dev/null 2>&1 || _lint_rc=$?
assert_eq "[SPEC-2] the tree lint cannot see it — hence the runtime check" "0" "$_lint_rc"

# ─── SPEC-3: backend services are exempt ─────────────────────────────────────
print_test_section "3. backend services are unaffected (ADR-047 §5)"

_svc_flagged=""
for _svc in cache-local memory-sqlite orch-sequential; do
    _sm="$REPO_ROOT/plugins/tool/$_svc/manifest.yaml"
    [[ -f "$_sm" ]] || continue
    grep -qE '^[[:space:]]+summary:[[:space:]]*true' "$_sm" && _svc_flagged="${_svc_flagged}${_svc} "
done
assert_eq "[SPEC-3] no backend service was forced to declare one" "" \
    "$(printf '%s' "$_svc_flagged" | sed 's/[[:space:]]*$//')"

# ─── SPEC-4: the lint mirrors it for local plugins ───────────────────────────
print_test_section "4. the tree lint mirrors the refusal locally"

LOCAL="$TEST_TEMP_DIR/local/plugins/tool/loc-stage"
mkdir -p "$LOCAL"
sed 's/ext-stage/loc-stage/g; s/ext_stage/loc_stage/g' "$EXT/manifest.yaml" > "$LOCAL/manifest.yaml"
printf 'loc_stage_run() { return 0; }\n' > "$LOCAL/plugin.sh"
_ll_out="$(ZBUILD_PLUGINS_ROOT="$TEST_TEMP_DIR/local/plugins" \
    bash "$REPO_ROOT/scripts/lib/lint-contract.sh" 2>&1 || true)"
assert_contains "[SPEC-4] the lint names the summary-less stage" "$_ll_out" "loc-stage"

# ─── SPEC-5: written on every terminal verdict ───────────────────────────────
print_test_section "5. a summary is written on pass, fail and skip"

# shellcheck source=../../scripts/lib/stage-summary.sh
source "$REPO_ROOT/scripts/lib/stage-summary.sh" 2>/dev/null || true
if declare -F stage_summary_write >/dev/null 2>&1; then
    _S="$TEST_TEMP_DIR/s.md"
    for _v in pass fail skip; do
        stage_summary_write "$_S" "sample" "$_v" ""
        assert_file_exists "[SPEC-5] a '$_v' verdict still writes a summary" "$_S"
        assert_contains "[SPEC-5] and states the verdict '$_v'" "$(cat "$_S")" "$_v"
    done
else
    assert_fail "[SPEC-5] stage_summary_write exists" "function not defined"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
