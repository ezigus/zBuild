#!/usr/bin/env bash
# tests/unit/output-paths-resolve-test.sh — a declared output path resolved into
# a variable, without a subshell (ADR-065 §3).
#
# _registry_resolve_output_path was called inside `$( )` for every output of
# every other plugin on each dispatch (write-ownership, lifecycle, the attempt
# archive, the write boundary): about 10,800 copies of the engine shell in the
# 60 slowest test files.
#
# SPEC-1: _registry_resolve_output_path_v <var> <raw> <state_dir> <artifact_dir>
#         sets <var> to exactly what `$(_registry_resolve_output_path …)` prints,
#         for every expansion it supports
# SPEC-2: whatever the caller's variable is called
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/plugin-registry/output-paths.sh
source "$REPO_ROOT/core/plugin-registry/output-paths.sh"

print_test_header "output paths resolve into a variable (ADR-065 §3)"
setup_test_env "output-paths-resolve"

export ZB_OPR_STAGE="build" ZB_OPR_NEST='${ZB_OPR_STAGE}-x'
_cases=(
    'plain/path.json'
    '${state_dir}/a.json'
    '${artifact_dir}/b.json'
    '${artifacts_dir}/c.json'
    '${artifact_dir}/${ZB_OPR_STAGE}-result.json'
    '${artifact_dir}/${ZB_OPR_NEST}.md'
    '${artifact_dir}/${ZB_OPR_UNSET_VAR}.md'
    ''
)
if declare -F _registry_resolve_output_path_v >/dev/null 2>&1; then
    _bad=0 _d=""
    for _c in "${_cases[@]}"; do
        _want="$(_registry_resolve_output_path "$_c" /st /st/artifacts)"
        _got="__unset__"
        _registry_resolve_output_path_v _got "$_c" /st /st/artifacts
        [[ "$_got" == "$_want" ]] || { _bad=$((_bad + 1)); _d+="[$_c] want=[$_want] got=[$_got]; "; }
    done
    assert_eq "[SPEC-1] _v gives what \$( ) gives for all ${#_cases[@]} cases" "0" "$_bad${_d:+ — $_d}"
    for _name in resolved _var _expansions state_dir artifact_dir; do
        eval "$_name=__unset__"
        _registry_resolve_output_path_v "$_name" '${state_dir}/z.json' /st /st/artifacts
        assert_eq "[SPEC-2] a caller variable named $_name gets the value" "/st/z.json" "${!_name}"
    done
else
    assert_fail "[SPEC-1] _registry_resolve_output_path_v is defined" "missing"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
