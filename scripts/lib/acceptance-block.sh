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
                # Stop testfile collection at WIRING: sentinel (may appear after TESTFILES:)
                if [[ "$line" == 'WIRING:'* ]]; then
                    in_testfiles=0
                elif [[ -n "$line" ]]; then
                    testfiles+=("$line")
                fi
            elif [[ "$line" == SPEC:* || "$line" =~ ^SPEC-[0-9]+(\[[a-z]+\])?: ]]; then
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
        if [[ "$line" =~ ^(SPEC-[0-9]+)(\[[a-z]+\])?: ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            ids_found=1
        fi
    done <<< "$block_output"
    [[ $ids_found -eq 1 ]]
}

# acceptance_spec_is_guard <design_md> <spec_id>
# Returns 0 when the SPEC line for spec_id carries a [guard] classifier,
# 1 otherwise (unclassified or [change] = not a guard).
acceptance_spec_is_guard() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 1
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    grep -qF "${spec_id}[guard]:" <<< "$block_output"
}

# acceptance_spec_classifier <design_md> <spec_id>  (ADR-046 / #1218)
# Echoes the SPEC's classifier — "change", "guard", or "" (unclassified) — by
# reading the [classifier] token on its SPEC line. Reuses the [guard] parse
# pattern; the empty string means the SPEC carries no classifier at all.
# Returns 0 always (the caller inspects the echoed value).
acceptance_spec_classifier() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && { printf '\n'; return 0; }
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || { printf '\n'; return 0; }
    if grep -qF "${spec_id}[change]:" <<< "$block_output"; then
        printf 'change\n'
    elif grep -qF "${spec_id}[guard]:" <<< "$block_output"; then
        printf 'guard\n'
    else
        printf '\n'
    fi
}

# acceptance_spec_is_change <design_md> <spec_id>  (ADR-046 / #1218)
# Returns 0 when the SPEC line for spec_id carries a [change] classifier,
# 1 otherwise (unclassified or [guard] = not a change).
acceptance_spec_is_change() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ "$(acceptance_spec_classifier "$design_md" "$spec_id")" == "change" ]]
}

# acceptance_list_wiring <design_md>  (ADR-036 Level-3 / #956)
# Prints the WIRING targets declared in the ```acceptance block, one per line.
# The special token "none" is printed as-is when WIRING: none is declared
# (pure-utility exemption). Path-traversal guard applied (same as testfiles).
# Returns 0 when a WIRING: section is present (even if "none"), 1 when absent.
acceptance_list_wiring() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1

    local in_block=0 in_wiring=0 found_wiring=0

    while IFS= read -r line; do
        line="${line%$'\r'}"  # tolerate CRLF on ALL lines (sentinels + paths)
        if [[ "$line" == '```acceptance' ]]; then
            in_block=1
            continue
        fi
        if [[ $in_block -eq 1 && "$line" == '```' ]]; then
            break
        fi
        if [[ $in_block -eq 1 ]]; then
            # Stop wiring collection when a new recognized sentinel is hit
            if [[ $in_wiring -eq 1 ]]; then
                case "$line" in
                    TESTFILES:|SPEC:*|SPEC-[0-9]*) in_wiring=0 ;;
                    '') continue ;;
                    *)
                        [[ -z "$line" ]] && continue
                        [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
                        printf '%s\n' "$line"
                        continue
                        ;;
                esac
            fi
            if [[ "$line" == 'WIRING: none' ]]; then
                printf 'none\n'
                found_wiring=1
                in_wiring=0
            elif [[ "$line" == 'WIRING:' ]]; then
                found_wiring=1
                in_wiring=1
            elif [[ "$line" == 'WIRING: '* ]]; then
                # inline single path (not "none")
                local wpath="${line#WIRING: }"
                wpath="${wpath%$'\r'}"
                [[ -z "$wpath" || "$wpath" == /* || "/$wpath/" == *"/../"* ]] || printf '%s\n' "$wpath"
                found_wiring=1
                in_wiring=0
            fi
        fi
    done < "$design_md"

    [[ $found_wiring -eq 1 ]] && return 0
    return 1
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
            # Stop at WIRING: sentinel (defensive: may appear after TESTFILES: in output)
            [[ "$line" == 'WIRING:'* ]] && break
            [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
            printf '%s\n' "$line"
        fi
    done <<< "$block_output"
}
