#!/usr/bin/env bash
# Acceptance-block extractor — parses the ```acceptance fenced block from a
# design.md artifact and emits structured output for test_assessment consumption.
# See ADR-031 for block format specification.
#
# This file is source-only (a pure function, never executed directly), so it
# deliberately does NOT `set -euo pipefail` at top level: doing so mutates the
# shell options of any caller that sources it (e.g. plugins/agent/design),
# altering their control flow. This matches the no-side-effect-on-source
# convention of the sibling core/ and scripts/lib/ libraries. The function
# below is self-contained (guarded parameter expansions + explicit returns).

[[ -n "${_ACCEPTANCE_BLOCK_LOADED:-}" ]] && return 0
_ACCEPTANCE_BLOCK_LOADED=1

# extract_acceptance_block <design_md>
# Parses the ```acceptance fenced block from the given file and prints:
#   - One "SPEC: <text>" line per behavioral claim (in order)
#   - A "TESTFILES:" sentinel line
#   - One test-file path per line (non-blank lines after TESTFILES: sentinel)
# Returns 0 on success (block found and parsed), 1 when no block is present.
# Produces empty stdout on return 1. A malformed block (no closing fence or
# missing TESTFILES section) returns 1 with whatever partial output was emitted.
extract_acceptance_block() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1

    local in_block=0
    local in_testfiles=0
    local found_block=0
    local found_testfiles=0
    local -a specs=()
    local -a testfiles=()

    while IFS= read -r line; do
        if [[ "$line" == '```acceptance' ]]; then
            in_block=1
            found_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            in_block=0
            break
        fi
        if [[ $in_block -eq 1 ]]; then
            if [[ "$line" == 'TESTFILES:' ]]; then
                in_testfiles=1
                found_testfiles=1
                continue
            fi
            if [[ $in_testfiles -eq 1 ]]; then
                [[ -n "$line" ]] && testfiles+=("$line")
            elif [[ "$line" == SPEC:* || "$line" =~ ^SPEC-[0-9]+: ]]; then
                specs+=("$line")
            fi
        fi
    done < "$design_md"

    if [[ $found_block -eq 0 ]]; then
        return 1
    fi

    for spec in "${specs[@]+"${specs[@]}"}"; do
        printf '%s\n' "$spec"
    done

    if [[ $found_testfiles -eq 1 ]]; then
        printf 'TESTFILES:\n'
        for tf in "${testfiles[@]+"${testfiles[@]}"}"; do
            printf '%s\n' "$tf"
        done
    fi

    [[ $found_testfiles -eq 1 ]] || return 1
    return 0
}

# acceptance_list_spec_ids <design_md>  (ADR-036 / #922)
# Prints each STABLE SPEC id (e.g. "SPEC-1", "SPEC-2") from the ```acceptance
# block, one per line, in declaration order. Only `SPEC-<n>:` lines carry an
# id; bare legacy `SPEC:` lines are intentionally ignored (they have no id to
# map to a [SPEC-n]-tagged assertion). Returns 0 when ≥1 id is found, else 1.
acceptance_list_spec_ids() {
    local design_md="${1:-}"
    local block_output line ids_found=0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    [[ -z "$block_output" ]] && return 1
    while IFS= read -r line; do
        if [[ "$line" =~ ^(SPEC-[0-9]+): ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            ids_found=1
        fi
    done <<< "$block_output"
    [[ $ids_found -eq 1 ]]
}

# acceptance_list_testfiles <design_md>  (ADR-036 / #922)
# Prints the repo-relative TESTFILES paths from the ```acceptance block, one
# per line. Mirrors the path-traversal guard used by build (never surfaces an
# absolute or ".."-containing path). Empty when the block/TESTFILES is absent.
acceptance_list_testfiles() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 0
    local block_output line in_testfiles=0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    [[ -z "$block_output" ]] && return 0
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then
            in_testfiles=1
            continue
        fi
        if [[ $in_testfiles -eq 1 && -n "$line" ]]; then
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
            printf '%s\n' "$line"
        fi
    done <<< "$block_output"
}
