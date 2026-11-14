#!/usr/bin/env bash
# scripts/lib/earlier-output.sh — a stage finds earlier work by what it
# contains, never by which stage made it (#2364, ADR-055 §1, ADR-067 §8).
#
# Every stage is handed every earlier stage's latest output: the engine's index
# ($ZBUILD_STAGE_INPUTS, written at dispatch). A stage that needs one of them
# asks for it by its content — an acceptance block, a plan's work items, the
# issue text — and gets the path of the first output that has it. With no index
# (a stage run by hand), the run's artifacts and state directories are searched.
#
# Sourced library: inherits the caller's shell options; do NOT add set -euo.

[[ -n "${_ZBUILD_EARLIER_OUTPUT_LOADED:-}" ]] && return 0
_ZBUILD_EARLIER_OUTPUT_LOADED=1

# _eo_candidates_v <array_var> [dir...] — every output in the index, or, with
# no index, every file in the given directories (the caller's own artifact and
# state directories) and the run's, in the caller's shell (#2472, ADR-065).
_eo_candidates_v() {
    local -n _eoc="$1"; shift
    _eoc=()
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS}" ]]; then
        mapfile -t _eoc < <(jq -r '.inputs // {} | .[] | if type == "array" then .[] else . end | select(type == "string")' \
            "$ZBUILD_STAGE_INPUTS" 2>/dev/null)
        return 0
    fi
    local _eoc_d _eoc_f
    for _eoc_d in "$@" "${ZBUILD_ARTIFACT_DIR:-}" "${ZBUILD_STATE_DIR:+$ZBUILD_STATE_DIR/artifacts}" "${ZBUILD_STATE_DIR:-}"; do
        [[ -n "$_eoc_d" && -d "$_eoc_d" ]] || continue
        for _eoc_f in "$_eoc_d"/*; do [[ -f "$_eoc_f" ]] && _eoc+=("$_eoc_f"); done
    done
    return 0
}

# earlier_output_with_text <ERE> [dir...] — the first earlier output with a line
# matching <ERE>. Prints its path; rc 1 when none has. One grep for them all:
# `grep -l` names the files in the order given (#2472, ADR-065).
earlier_output_with_text() {
    local re="$1" f out; shift
    local -a _eot_all=() _eot_txt=()
    _eo_candidates_v _eot_all "$@"
    for f in ${_eot_all[@]+"${_eot_all[@]}"}; do
        [[ -n "$f" && "$f" != *.json && -f "$f" && -s "$f" ]] && _eot_txt+=("$f")
    done
    [[ ${#_eot_txt[@]} -gt 0 ]] || return 1
    out="$(grep -lE -- "$re" "${_eot_txt[@]}" 2>/dev/null)" || true
    [[ -n "$out" ]] || return 1
    printf '%s\n' "${out%%$'\n'*}"
}

# earlier_output_with_json <jq-test> [dir...] — the first earlier JSON output
# <jq-test> is true of. Prints its path; rc 1 when none is.
earlier_output_with_json() {
    local test="$1" f; shift
    local -a _eoj_all=()
    _eo_candidates_v _eoj_all "$@"
    for f in ${_eoj_all[@]+"${_eoj_all[@]}"}; do
        [[ "$f" == *.json && -s "$f" ]] || continue
        jq -e "$test" "$f" >/dev/null 2>&1 && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# earlier_outputs_with_json <jq-test> [dir...] — every earlier JSON output
# <jq-test> is true of, one path per line. rc 0 always.
earlier_outputs_with_json() {
    local test="$1" f; shift
    local -a _eos_all=()
    _eo_candidates_v _eos_all "$@"
    for f in ${_eos_all[@]+"${_eos_all[@]}"}; do
        [[ "$f" == *.json && -s "$f" ]] || continue
        jq -e "$test" "$f" >/dev/null 2>&1 && printf '%s\n' "$f"
    done
    return 0
}

# The kinds of earlier work stages ask for, each named for what it is. Each
# takes the caller's own directories to search when there is no index.
# The acceptance contract: a document with an ```acceptance block.
earlier_acceptance_contract() { earlier_output_with_text '^```acceptance' "$@"; }
# The work plan: JSON with a list of work items.
earlier_work_plan() { earlier_output_with_json '(.steps | type) == "array"' "$@"; }
# The issue's numbered requirements: JSON with a requirements list.
earlier_requirements() { earlier_output_with_json '(.requirements | type) == "array"' "$@"; }
# The scope manifest: lines of "+ <dir>/".
earlier_scope_manifest() { earlier_output_with_text '^\+ .*/$' "$@"; }
# The issue text, as written: the result that carries it (data.issue_text). An
# empty one is no issue text.
earlier_issue_text() {
    local f; f="$(earlier_output_with_json '(.data.issue_text | type) == "string" and (.data.issue_text | length) > 0' "$@")" || return 1
    jq -r '.data.issue_text' "$f" 2>/dev/null
}
# A test run's per-file timing: lines of "file <ms> <path>".
earlier_test_timing() { earlier_output_with_text '^file [0-9]+ ' "$@"; }
# A test run's result: JSON with the run's exit code.
earlier_test_run() { earlier_output_with_json '(.data // {}) | has("exit_code") and has("passed")' "$@"; }
# A test run's report: the markdown a test run writes about itself.
earlier_test_report() { earlier_output_with_text '^# Test stage summary$' "$@"; }
# A deploy's result: JSON saying whether anything was deployed (true or false).
earlier_deploy_result() { earlier_output_with_json '(.data.deployed | type) == "boolean"' "$@"; }
# A pull request's address: a one-line GitHub pull request URL.
earlier_pr_url_file() { earlier_output_with_text '^https://[^ ]+/pull/[0-9]+$' "$@"; }
# The change as a patch: a unified diff.
earlier_change_patch() { earlier_output_with_text '^diff --git ' "$@"; }
# Every review lens's result: its findings, each graded and saying whether the
# change introduced it (#2433).
earlier_review_findings() {
    earlier_outputs_with_json '(.name | type) == "string" and (.findings | type) == "array"
        and all(.findings[]; type == "object" and has("severity") and has("introduced"))' "$@"
}
