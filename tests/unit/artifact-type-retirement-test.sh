#!/usr/bin/env bash
# #1906: provides.artifact_type is retired — it duplicated outputs[].type (made
# authoritative and versioned by #1827) and was ALSO read as a result-artifact
# FILENAME by manifest_graph_result_filename, which it is not.
#
# Three plugins declared a value that is not their primary output's filename:
#   intake                 [scope-manifest.md, intake.md]  (a bracketed LIST)
#   security-lens          findings.json                   (the TYPE, not the file)
#   output-github-comment  [report.md]                     (a file never written)
#
# For a cycle/gate member that resolves to a nonexistent path, the reader's
# `[[ -s "$result" ]] || continue` skips the member entirely — a genuinely
# terminal stage goes unnoticed. Fail-open, so no signal marks it.
#
# RED at the merge-base: SPEC-1/2 return the wrong strings, SPEC-3 finds 23
# declarations, SPEC-4 finds output-github-comment declaring no outputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "provides.artifact_type retirement (#1906)"
setup_test_env "artifact-type-retirement"

# ─── SPEC-1 [change]: the result filename resolves from the primary output ────
# intake's declared value was a bracketed list; the fallback is the real file.
print_test_section "SPEC-1. result filename resolves from the primary output"
_s1="$(manifest_graph_result_filename "$REPO_ROOT/plugins/agent/intake/manifest.yaml" 2>/dev/null || echo "<rc1>")"
assert_eq "[SPEC-1] intake result filename is scope-manifest.md (not a bracketed list)" \
    "scope-manifest.md" "$_s1"

# ─── SPEC-2 [change]: a TYPE name is not a filename ───────────────────────────
# security-lens declared `findings.json` (its outputs[].type) while the file it
# actually writes is security-findings.json. Same defect class as SPEC-1.
print_test_section "SPEC-2. a type name is not a filename"
_s2="$(manifest_graph_result_filename "$REPO_ROOT/plugins/agent/security-lens/manifest.yaml" 2>/dev/null || echo "<rc1>")"
assert_eq "[SPEC-2] security-lens result filename is security-findings.json (not the type findings.json)" \
    "security-findings.json" "$_s2"

# ─── SPEC-3 [change]: the field is gone from every manifest ───────────────────
print_test_section "SPEC-3. provides.artifact_type declared nowhere"
_s3_hits=""
while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if grep -qE "^[[:space:]]+artifact_type:" "$m" 2>/dev/null; then
        _s3_hits="${_s3_hits}${m}"$'\n'
    fi
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -not -path '*/tests/*' 2>/dev/null | sort)
assert_eq "[SPEC-3] no manifest declares provides.artifact_type" "" "${_s3_hits%$'\n'}"

# ─── SPEC-4 [change]: output-github-comment declares what it writes ───────────
# It was the only plugin with no outputs[] at all, which is why it was also the
# only occupant of the retired check's "no outputs declared" fallback. It does
# write files — output-body.md always, report-${ZBUILD_RUN_ID}.md unless the
# local-report destination is switched off.
print_test_section "SPEC-4. output-github-comment declares its outputs"
_ogc="$REPO_ROOT/plugins/tool/output-github-comment/manifest.yaml"
_s4_primary="$(manifest_graph_result_filename "$_ogc" 2>/dev/null || echo "<rc1>")"
assert_eq "[SPEC-4] output-github-comment primary output is output-body.md" \
    "output-body.md" "$_s4_primary"
if grep -qE 'path:.*report-\$\{ZBUILD_RUN_ID\}\.md' "$_ogc" 2>/dev/null; then
    assert_pass "[SPEC-4b] the toggleable local report is declared too"
else
    assert_fail "[SPEC-4b] the toggleable local report is declared too" "not declared"
fi

# ─── SPEC-5 [guard]: the 20 unchanged plugins keep their filename ─────────────
# Deleting the field must be a no-op wherever it already equalled the primary
# output's basename. A regression here would silently re-point a gate member.
print_test_section "SPEC-5. the unchanged majority keep the same filename"
declare -A _expect=(
    [plugins/agent/build/manifest.yaml]=build-summary.json
    [plugins/agent/plan/manifest.yaml]=plan.json
    [plugins/agent/design/manifest.yaml]=design.md
    [plugins/tool/shape-floor/manifest.yaml]=shape-floor-result.json
    [plugins/tool/test/manifest.yaml]=test-results.json
    [plugins/tool/gate-aggregator/manifest.yaml]=gate-aggregator-result.json
    [plugins/tool/secret-scan/manifest.yaml]=secret-scan-result.json
    [plugins/agent/spec-acceptance/manifest.yaml]=acceptance-gate-result.json
)
_s5_bad=""
for _rel in "${!_expect[@]}"; do
    _got="$(manifest_graph_result_filename "$REPO_ROOT/$_rel" 2>/dev/null || echo "<rc1>")"
    [[ "$_got" != "${_expect[$_rel]}" ]] && _s5_bad="${_s5_bad}${_rel}: got ${_got}, want ${_expect[$_rel]}"$'\n'
done
assert_eq "[SPEC-5] every cycle/gate member still resolves to its own result file" \
    "" "${_s5_bad%$'\n'}"

# ─── SPEC-6 [guard]: artifact_type is no longer an accepted manifest key ──────
print_test_section "SPEC-6. the key is out of the allowed-keys list"
if grep -q "provides.artifact_type" "$REPO_ROOT/core/plugin-registry/manifest-validation.sh" 2>/dev/null; then
    assert_fail "[SPEC-6] provides.artifact_type removed from the allowed-keys list" "still listed"
else
    assert_pass "[SPEC-6] provides.artifact_type removed from the allowed-keys list"
fi

# #2042: the grep above is a proxy — it establishes a string is absent from one
# source file, not that a manifest carrying the key behaves as retired. Assert
# the BEHAVIOUR the retirement actually promises.
#
# Note what that behaviour IS: #1906 moved artifact enforcement to
# outputs[].required alone, so a manifest carrying the key is not REFUSED — it
# is simply inert. Asserting a refusal here would assert a contract the tree
# does not have, which is the same defect this issue is closing.
_s6_mf="$TEST_TEMP_DIR/s6-legacy-key/manifest.yaml"
mkdir -p "$(dirname "$_s6_mf")"
cat > "$_s6_mf" <<'S6EOF'
id: s6-legacy
name: S6 Legacy Key
kind: tool
version: 0.0.1
hooks:
  run: s6_run
provides:
  role: s6_legacy
  artifact_type: findings.json
outputs:
  - id: s6_result
    path: ${artifact_dir}/s6-result.json
    type: s6-result.json@1
    format: json
    required: true
    primary: true
S6EOF
_s6_rc=0
validate_manifest "$_s6_mf" >/dev/null 2>&1 || _s6_rc=$?
assert_eq "[SPEC-6] a manifest still carrying provides.artifact_type validates" "0" "$_s6_rc"
_s6_read="$(yaml_get "$_s6_mf" "provides.artifact_type" 2>/dev/null || true)"
assert_eq "[SPEC-6] the key is present in the file, so the assertion is not vacuous" \
    "findings.json" "$_s6_read"

print_test_results
cleanup_test_env
exit $((FAIL > 0))
