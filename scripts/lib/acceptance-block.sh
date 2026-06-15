#!/usr/bin/env bash
# Acceptance-block extractor — parses the ```acceptance fenced block from a
# design.md artifact and emits structured output for test_assessment consumption.
# See ADR-031 for block format specification.
set -euo pipefail

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
            elif [[ "$line" == SPEC:* ]]; then
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
