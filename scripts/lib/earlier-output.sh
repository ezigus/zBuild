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

# _eo_candidates [dir...] — one path per line: every output in the index, or,
# with no index, every file in the given directories (the caller's own artifact
# and state directories) and the run's.
_eo_candidates() {
    if [[ -n "${ZBUILD_STAGE_INPUTS:-}" && -s "${ZBUILD_STAGE_INPUTS}" ]]; then
        jq -r '.inputs // {} | .[] | if type == "array" then .[] else . end | select(type == "string")' \
            "$ZBUILD_STAGE_INPUTS" 2>/dev/null
        return 0
    fi
    local d f
    for d in "$@" "${ZBUILD_ARTIFACT_DIR:-}" "${ZBUILD_STATE_DIR:+$ZBUILD_STATE_DIR/artifacts}" "${ZBUILD_STATE_DIR:-}"; do
        [[ -n "$d" && -d "$d" ]] || continue
        for f in "$d"/*; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
    done
}

# earlier_output_with_text <ERE> [dir...] — the first earlier output with a line
# matching <ERE>. Prints its path; rc 1 when none has.
earlier_output_with_text() {
    local re="$1" f; shift
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" && -s "$f" ]] || continue
        [[ "$f" == *.json ]] && continue
        grep -qE -- "$re" "$f" 2>/dev/null && { printf '%s\n' "$f"; return 0; }
    done < <(_eo_candidates "$@")
    return 1
}

# earlier_output_with_json <jq-test> [dir...] — the first earlier JSON output
# <jq-test> is true of. Prints its path; rc 1 when none is.
earlier_output_with_json() {
    local test="$1" f; shift
    while IFS= read -r f; do
        [[ "$f" == *.json && -s "$f" ]] || continue
        jq -e "$test" "$f" >/dev/null 2>&1 && { printf '%s\n' "$f"; return 0; }
    done < <(_eo_candidates "$@")
    return 1
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
