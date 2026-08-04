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
# Stops at the TESTFILES: sentinel so per-SPEC binding lines (SPEC-n: path)
# in the TESTFILES section are not misidentified as spec-id declarations.
acceptance_list_spec_ids() {
    local design_md="${1:-}"
    local block_output line ids_found=0
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    [[ -z "$block_output" ]] && return 1
    while IFS= read -r line; do
        # Stop scanning once we enter the TESTFILES section — per-SPEC binding
        # lines (SPEC-n: path) share the SPEC id regex and must not be emitted.
        [[ "$line" == "TESTFILES:" ]] && break
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

# _acceptance_build_run_cmd <template> <testfile>
# Expands a {files}-template for a single acceptance testfile.
# Prints each command token NUL-separated for safe array construction by callers.
# Returns 1 when the template contains no {files} token (misconfiguration guard).
#
# The template is whitespace-tokenized (read -ra) and the resulting array is
# exec'd DIRECTLY by callers — the testfile path never passes through a shell,
# so a filename cannot inject shell metacharacters. This is deliberate and is
# why templates are simple whitespace-separated tokens (bash {files},
# pytest {files}, jest {files}, cargo test {files}); a template embedding a
# quoted multi-word argument (e.g. python3 -c 'import sys') is NOT supported —
# honoring shell quoting would require eval, reintroducing the injection risk
# this array-exec design avoids. ZBUILD_ACCEPTANCE_RUN_CMD is operator-declared
# config (same trust model as ZBUILD_TEST_CMD_TARGETED), not untrusted input.
_acceptance_build_run_cmd() {
    local template="$1" testfile="$2"
    [[ "$template" != *'{files}'* ]] && return 1
    local -a parts
    read -ra parts <<< "$template"
    local part
    for part in "${parts[@]}"; do
        if [[ "$part" == '{files}' ]]; then
            printf '%s\0' "$testfile"
        else
            printf '%s\0' "$part"
        fi
    done
    return 0
}

# _acceptance_timeout_prefix <timeout_s>  (#1660)
# Fills the global array _ACCEPTANCE_TOUT with the `timeout` prefix tokens that
# bound one testfile run — empty when no usable timeout binary exists
# (best-effort, same convention as core/router/route.sh). Always returns 0.
#
# Sets a global rather than printing because the probe below is memoized, and a
# `$(...)`/`< <(...)` caller would run it in a subshell where the memo dies.
#
# `-k` is what makes the bound real: plain `timeout` sends TERM only, so a child
# that traps or ignores TERM runs unbounded — the 9h22m hang in #1611. The grace
# is ZBUILD_NEGCTL_KILL_GRACE (default 10s).
#
# `-k` is probed, not assumed. GNU coreutils has had it since 7.0, but a
# `timeout` lacking it exits 125 on the unknown flag, and 125 is not a timeout rc
# — every bounded run would fall through to the ordinary control comparison and
# report `tautology`/`not_passing_at_head`, condemning correct changes. That is
# strictly worse than the hang this replaces, so support is verified once before
# the flag is used, and a `timeout` without it degrades to the old TERM-only
# bound instead of failing every run.
_acceptance_timeout_prefix() {
    local timeout_s="$1"
    local kill_grace="${ZBUILD_NEGCTL_KILL_GRACE:-10}"
    _ACCEPTANCE_TOUT=()
    local bin=""
    # gtimeout first, same order as run-tests.sh: where both exist gtimeout is
    # unambiguously GNU, while `timeout` may be a thinner platform build.
    if   command -v gtimeout >/dev/null 2>&1; then bin="gtimeout"
    elif command -v timeout  >/dev/null 2>&1; then bin="timeout"
    else return 0
    fi
    if [[ -z "${_ACCEPTANCE_TIMEOUT_KILL_OK:-}" ]]; then
        if "$bin" -k 1 1 true >/dev/null 2>&1; then
            _ACCEPTANCE_TIMEOUT_KILL_OK=yes
        else
            _ACCEPTANCE_TIMEOUT_KILL_OK=no
        fi
    fi
    _ACCEPTANCE_TOUT=("$bin")
    [[ "$_ACCEPTANCE_TIMEOUT_KILL_OK" == "yes" ]] && _ACCEPTANCE_TOUT+=("-k" "$kill_grace")
    _ACCEPTANCE_TOUT+=("$timeout_s")
    return 0
}

# acceptance_list_testfiles <design_md>  (ADR-036 / #922)
# Prints the repo-relative TESTFILES paths from the ```acceptance block, one
# per line. Includes both bare paths AND paths declared with a SPEC-n: prefix
# (stripping the prefix to expose the bare path). Mirrors the path-traversal
# guard used by build (never surfaces an absolute or ".."-containing path).
# Empty when the block/TESTFILES is absent.
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
            # Strip SPEC-n: prefix — emit the bare path(s) into the union
            if [[ "$line" =~ ^SPEC-[0-9]+:[[:space:]]+(.*) ]]; then
                local _bound_str="${BASH_REMATCH[1]}"
                local -a _bound_parts
                read -ra _bound_parts <<< "$_bound_str"
                local _bp
                for _bp in "${_bound_parts[@]}"; do
                    [[ -z "$_bp" || "$_bp" == /* || "/$_bp/" == *"/../"* ]] && continue
                    printf '%s\n' "$_bp"
                done
                continue
            fi
            [[ "$line" == /* || "/$line/" == *"/../"* ]] && continue
            printf '%s\n' "$line"
        fi
    done <<< "$block_output"
}

# acceptance_has_per_spec_binding <design_md>  (#1480)
# Returns 0 when the TESTFILES section contains ≥1 SPEC-n: prefixed binding line,
# indicating that per-SPEC binding mode is active. Returns 1 otherwise.
acceptance_has_per_spec_binding() {
    local design_md="${1:-}"
    [[ -z "$design_md" || ! -f "$design_md" ]] && return 1
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    local in_testfiles=0 line
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then in_testfiles=1; continue; fi
        if [[ $in_testfiles -eq 1 ]]; then
            [[ "$line" == 'WIRING:'* ]] && break
            [[ "$line" =~ ^SPEC-[0-9]+:[[:space:]] ]] && return 0
        fi
    done <<< "$block_output"
    return 1
}

# acceptance_spec_has_binding <design_md> <spec_id>  (#1480)
# Returns 0 when the TESTFILES section has ≥1 SPEC-<id>: prefixed line for the
# given spec_id. Returns 1 otherwise (caller should use tag-scan fallback in negctl).
acceptance_spec_has_binding() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 1
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 1
    local in_testfiles=0 line
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then in_testfiles=1; continue; fi
        if [[ $in_testfiles -eq 1 ]]; then
            [[ "$line" == 'WIRING:'* ]] && break
            # Match SPEC-<id>: <path> (no classifier bracket in TESTFILES prefix syntax)
            if [[ "$line" =~ ^${spec_id}:[[:space:]] ]]; then return 0; fi
        fi
    done <<< "$block_output"
    return 1
}

# acceptance_spec_desc <design_md> <spec_id>  (#1684)
# Echoes the description text from the SPEC-n line in the acceptance block —
# the text after the colon on the matching `SPEC-<id>[classifier]: <text>` line.
# Truncates to 100 characters with '…' when longer — long enough that the
# clause distinguishing one SPEC from another survives, which is the point of
# showing it. Returns empty string (not an error) when the SPEC id is not found.
# Stops scanning at TESTFILES: to avoid misidentifying per-SPEC binding lines
# in the TESTFILES section.
acceptance_spec_desc() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    local line
    while IFS= read -r line; do
        [[ "$line" == "TESTFILES:" ]] && break
        if [[ "$line" =~ ^${spec_id}(\[[a-z]+\])?:[[:space:]]*(.*) ]]; then
            local text="${BASH_REMATCH[2]}"
            if [[ ${#text} -gt 100 ]]; then
                printf '%s…\n' "${text:0:100}"
            else
                printf '%s\n' "$text"
            fi
            return 0
        fi
    done <<< "$block_output"
    return 0
}

# acceptance_list_testfiles_for_spec <design_md> <spec_id>  (#1480)
# Returns testfile paths for the given SPEC-id:
#   - When SPEC-<id>: prefixed lines exist → returns those bound paths only.
#   - When no SPEC-<id>: prefix → returns the unqualified global paths (backward-compat).
# Multiple space-separated paths on a SPEC-n: line are emitted one per line.
# Path-traversal guard applied (same as acceptance_list_testfiles).
acceptance_list_testfiles_for_spec() {
    local design_md="${1:-}" spec_id="${2:-}"
    [[ -z "$design_md" || -z "$spec_id" || ! -f "$design_md" ]] && return 0
    local block_output
    block_output="$(extract_acceptance_block "$design_md" 2>/dev/null)" || return 0
    local in_testfiles=0 line
    local -a per_spec=() global=()
    while IFS= read -r line; do
        if [[ "$line" == "TESTFILES:" ]]; then in_testfiles=1; continue; fi
        if [[ $in_testfiles -eq 1 && -n "$line" ]]; then
            line="${line%$'\r'}"
            [[ -z "$line" ]] && continue
            [[ "$line" == 'WIRING:'* ]] && break
            if [[ "$line" =~ ^(SPEC-[0-9]+):[[:space:]]+(.*) ]]; then
                local _bid="${BASH_REMATCH[1]}" _bpaths="${BASH_REMATCH[2]}"
                if [[ "$_bid" == "$spec_id" ]]; then
                    local -a _bparts; read -ra _bparts <<< "$_bpaths"
                    local _bp
                    for _bp in "${_bparts[@]}"; do
                        [[ -z "$_bp" || "$_bp" == /* || "/$_bp/" == *"/../"* ]] || per_spec+=("$_bp")
                    done
                fi
            else
                [[ "$line" == /* || "/$line/" == *"/../"* ]] || global+=("$line")
            fi
        fi
    done <<< "$block_output"
    # Return per-SPEC paths when bound; else fall back to global unqualified pool.
    if [[ ${#per_spec[@]} -gt 0 ]]; then
        printf '%s\n' "${per_spec[@]}"
    else
        printf '%s\n' "${global[@]+"${global[@]}"}"
    fi
}
