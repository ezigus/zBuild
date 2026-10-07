#!/usr/bin/env bash
# tests/unit/dispatched-stage-plugins-v2-test.sh — #1850 (ADR-054 §5): every
# plugin a shipped template dispatches as a stage writes result contract v2.
#
# The rule is derived from the tree, not from a list of names:
#
#   * A plugin that declares a `primary: true` output writes a stage result, so
#     it must declare `provides.result_contract: 2` (the loader refuses it
#     otherwise — v1-retired-test.sh R1; this checks the shipped tree).
#   * A plugin with no primary output writes no stage result. Personas (data),
#     the orch-/memory-/cache- backends (resolved by role through
#     core/{orch,memory,cache}/contract.sh) and helper executors are this kind.
#     They are exempt for a reason, not by name: the engine calls them itself,
#     and no template may dispatch one as a stage — which is what G2 checks.
#
# G1 [guard] every shipped plugin with a primary output declares result_contract: 2
# G2 [guard] no shipped template names, as a stage or a stage role, a plugin that
#            has no primary output
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "every dispatched stage plugin writes result contract v2 (#1850)"

# The words a template can dispatch by: stage ids (items of a `flow:` or
# `always_run:` list) and the role names inside `roles: [...]`. A map group's
# `elements:` are the values it maps over (lens names, which select personas),
# not stages, so their items are not counted.
_dispatch_words=""
for _tpl in "$REPO_ROOT"/config/templates/*.yaml; do
    _in_list=0
    while IFS= read -r _line; do
        if [[ "$_line" =~ ^[[:space:]]*(flow|always_run):[[:space:]]*$ ]]; then
            _in_list=1; continue
        fi
        if [[ "$_line" =~ ^[[:space:]]+-[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*$ ]]; then
            [[ $_in_list -eq 1 ]] && _dispatch_words+=" ${BASH_REMATCH[1]}"
            continue
        fi
        # Any other key ends the list; blank and comment lines do not.
        [[ "$_line" =~ ^[[:space:]]*(#|$) ]] || _in_list=0
        if [[ "$_line" =~ roles:[[:space:]]*\[([^]]*)\] ]]; then
            _dispatch_words+=" ${BASH_REMATCH[1]//,/ }"
        fi
    done < "$_tpl"
done
_dispatch_words=" ${_dispatch_words} "

_bad_contract="" _dispatched_helper="" _n_stage=0 _n_exempt=0
for _m in "$REPO_ROOT"/plugins/*/*/manifest.yaml; do
    _rel="${_m#"$REPO_ROOT"/}"
    _id="" _role="" _contract="" _primary=0
    while IFS= read -r _line; do
        [[ "$_line" =~ ^id:[[:space:]]*([^[:space:]#]+) ]] && _id="${BASH_REMATCH[1]}"
        [[ "$_line" =~ ^[[:space:]]+role:[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*$ ]] && _role="${BASH_REMATCH[1]}"
        [[ "$_line" =~ ^[[:space:]]+result_contract:[[:space:]]*([0-9]+) ]] && _contract="${BASH_REMATCH[1]}"
        [[ "$_line" =~ ^[[:space:]]+primary:[[:space:]]*true ]] && _primary=1
    done < "$_m"
    if [[ "$_primary" -eq 1 ]]; then
        _n_stage=$((_n_stage + 1))
        [[ "$_contract" == 2 ]] || _bad_contract+="$_rel(result_contract=${_contract:-none}) "
    else
        _n_exempt=$((_n_exempt + 1))
        for _w in "$_id" "$_role"; do
            [[ -n "$_w" && "$_dispatch_words" == *" $_w "* ]] && _dispatched_helper+="$_rel(as '$_w') "
        done
    fi
done

# Liveness: the scan must have found both kinds, or it checked nothing.
if [[ "$_n_stage" -gt 20 && "$_n_exempt" -gt 5 ]]; then
    assert_pass "[setup] the scan saw $_n_stage stage plugins and $_n_exempt with no stage result"
else
    assert_fail "[setup] the scan saw stage plugins and plugins with no stage result" \
        "stage=$_n_stage exempt=$_n_exempt"
fi
assert_eq "[G1] every plugin with a primary output declares result_contract: 2" "" "$_bad_contract"
assert_eq "[G2] no template dispatches a plugin that writes no stage result" "" "$_dispatched_helper"

print_test_results
