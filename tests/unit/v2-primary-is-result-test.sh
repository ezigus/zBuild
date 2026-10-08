#!/usr/bin/env bash
# tests/unit/v2-primary-is-result-test.sh — a v2 stage's primary output is its
# v2 result file (ADR-054 §5; #1844).
#
# Why: ADR-054 §5 says the result file — result_contract, verdict, disposition,
# reason — is "the primary artifact declared in the stage's manifest". Nothing
# enforced it. Three v2 stages (design, pr-open, pr-delivery) declared a
# non-JSON primary (design.md, pr-url.txt), so the engine read them as v1:
# their disposition and reason were never seen. #1844 run 37066147994 passed
# every gate that way. Eric (2026-10-03): ADR-054 wins over ADR-047 §3's
# sidecar, which now serves v1 stages only.
#
# V1 [change] a manifest declaring result_contract: 2 with a non-JSON primary
#             fails validation, naming the primary
# V2 [guard]  result_contract: 2 with a JSON primary passes
# V3 [change] a manifest declaring no result_contract (v1) with a non-JSON
#             primary no longer loads — v1 and its sidecar are gone (#1850)
# V4 [change] every shipped v2 manifest's primary output is JSON
# V5 [change] a JSON primary written in single quotes, or with a trailing
#             comment, still passes (review on #2285: it was read as non-JSON)
# V6 [guard]  a multi-line reason is read in full (review on #2285)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/manifest-validation.sh
source "$REPO_ROOT/core/plugin-registry/manifest-validation.sh"

print_test_header "a v2 stage's primary output is its v2 result (ADR-054 §5, #1844)"
setup_test_env "v2-primary-is-result"

_mf() {   # _mf <dir> <result_contract or ""> <primary path>
    mkdir -p "$1"
    {
        printf 'id: fx\nname: fx\nversion: 1.0.0\nkind: tool\ndescription: fixture\n'
        printf 'provides:\n  role: fx\n'
        [[ -n "$2" ]] && printf '  result_contract: %s\n' "$2"
        printf 'outputs:\n'
        printf '  - id: main\n    path: %s\n    required: true\n    primary: true\n' "$3"
        printf 'hooks:\n  run: fx_run\n'
        printf 'config:\n  valid_verdicts: [pass]\n'
    } > "$1/manifest.yaml"
}
_valid() { validate_manifest "$1/manifest.yaml" >/dev/null 2>"$TEST_TEMP_DIR/err"; }

D="$TEST_TEMP_DIR/v1"; _mf "$D" 2 '${artifact_dir}/fx-url.txt'
if _valid "$D"; then
    assert_fail "[V1] a v2 manifest with a non-JSON primary fails validation" "it passed"
else
    assert_pass "[V1] a v2 manifest with a non-JSON primary fails validation"
fi
assert_contains "[V1] the error names the primary" "$(cat "$TEST_TEMP_DIR/err")" "fx-url.txt"

D="$TEST_TEMP_DIR/v2"; _mf "$D" 2 '${artifact_dir}/fx-result.json'
if _valid "$D"; then assert_pass "[V2] a v2 manifest with a JSON primary passes"
else assert_fail "[V2] a v2 manifest with a JSON primary passes" "$(cat "$TEST_TEMP_DIR/err")"; fi

D="$TEST_TEMP_DIR/v3"; _mf "$D" "" '${artifact_dir}/fx-url.txt'
if _valid "$D"; then assert_fail "[V3] a v1 manifest with a non-JSON primary no longer loads (#1850)" "it passed"
else assert_pass "[V3] a v1 manifest with a non-JSON primary no longer loads (#1850)"; fi

D="$TEST_TEMP_DIR/v5"; _mf "$D" 2 "'\${artifact_dir}/fx-result.json'   # the stage's v2 result"
if _valid "$D"; then assert_pass "[V5] a quoted, commented JSON primary passes"
else assert_fail "[V5] a quoted, commented JSON primary passes" "$(cat "$TEST_TEMP_DIR/err")"; fi

# V6: the engine's reader keeps every line of a multi-line reason.
# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh" >/dev/null 2>&1 || true
D="$TEST_TEMP_DIR/v6"; _mf "$D" 2 '${artifact_dir}/fx-result.json'; mkdir -p "$D/state/artifacts"
jq -n '{result_contract:2,verdict:"pass",disposition:"complete",reason:"line one\nline two"}' > "$D/state/artifacts/fx-result.json"
_verdict_read_result "$D/state" "$D/manifest.yaml" fx 0 _v6 >/dev/null 2>&1 || true
assert_eq "[V6] a multi-line reason is read in full" $'line one\nline two' "${_v6_reason:-}"

# V4: the shipped tree.
_bad=""
for m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    grep -qE '^[[:space:]]*result_contract:[[:space:]]*2' "$m" || continue
    # The primary entry's path: track path per `- id:` entry under outputs:.
    p="$(awk '/^outputs:/{o=1;next} o&&/^[a-zA-Z_]/{o=0} o&&/^[[:space:]]*-[[:space:]]*id:/{if(pr=="true"&&pa!=""){print pa;done=1;exit} pa="";pr=""} o&&/^[[:space:]]+path:/{sub(/^[[:space:]]+path:[[:space:]]*/,"");sub(/[[:space:]]+#.*$/,"");gsub(/["\047]/,"");pa=$0} o&&/^[[:space:]]+primary:[[:space:]]*true/{pr="true"} END{if(!done&&pr=="true"&&pa!="")print pa}' "$m")"
    p="${p//\"/}"
    [[ "$p" == *.json ]] || _bad+="${m#"$REPO_ROOT"/} → ${p:-<none>}"$'\n'
done
assert_eq "[V4] every shipped v2 manifest's primary output is JSON" "" "$_bad"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
