#!/usr/bin/env bash
# acceptance-coverage.sh — Level-1 of the acceptance-contract gate (ADR-036, #922).
#
# Verifies that every stable SPEC-n id declared in a design.md ```acceptance
# block has at least one assertion in the declared TESTFILES whose label
# contains the literal tag "[SPEC-n]". This is the cheap, mechanical
# tag-presence check that runs before the (expensive) Level-2 negative control.
#
# Source-only (pure functions, no side effects). Like acceptance-block.sh it
# deliberately does NOT `set -euo pipefail` at top level — that would mutate the
# options of any caller that sources it.

[[ -n "${_ACCEPTANCE_COVERAGE_LOADED:-}" ]] && return 0
_ACCEPTANCE_COVERAGE_LOADED=1

_ACCEPTANCE_COVERAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./acceptance-block.sh
source "$_ACCEPTANCE_COVERAGE_DIR/acceptance-block.sh"

# acceptance_coverage_spec_tagged <design_md> <repo_root> <spec_id>
# Returns 0 if at least one declared TESTFILE that exists on disk contains the
# literal "[<spec_id>]" tag; 1 otherwise.
acceptance_coverage_spec_tagged() {
    local design_md="${1:-}" repo_root="${2:-}" spec_id="${3:-}"
    [[ -z "$design_md" || -z "$spec_id" ]] && return 1
    local tf abs
    while IFS= read -r tf; do
        [[ -z "$tf" ]] && continue
        abs="$repo_root/$tf"
        [[ -f "$abs" ]] || continue
        # Fixed-string match on the literal tag, e.g. "[SPEC-1]".
        if grep -qF "[$spec_id]" "$abs" 2>/dev/null; then
            return 0
        fi
    done < <(acceptance_list_testfiles "$design_md")
    return 1
}

# _acceptance_trim_label <line>  (#1684)
# Strips leading whitespace and truncates to 100 chars with '…'.
_acceptance_trim_label() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    if [[ ${#s} -gt 100 ]]; then
        printf '%s…\n' "${s:0:100}"
    else
        printf '%s\n' "$s"
    fi
}

# acceptance_find_assertion_label <repo_root> <spec_id> <testfiles...>  (#1684)
# Echoes the label of an assertion that actually runs for <spec_id>, trimmed by
# _acceptance_trim_label. Empty string when the tag appears nowhere.
#
# Two passes, and the reason is the whole point of this function. These testfiles
# routinely contain [<spec_id>] as FIXTURE text — tests-of-the-gate write sandbox
# repos whose bodies carry tags, and a fixture line is not an assertion. Taking
# the first textual match therefore reports a label that was never asserted,
# which is worse than reporting nothing: it reads as confirmation. Pass 1 takes
# the first line that INVOKES an assertion helper; only when no declared file has
# one does pass 2 fall back to any tagged line.
#
# Residual: SPEC ids are file-global, so a file carrying the same id for a
# DIFFERENT design's SPEC can still win pass 1 — see #1691.
# _acceptance_strip_comment <line>
# Drops a trailing comment, but only a real one. Comments are how a SPEC
# sentence leaks into an assertion and buys a false `corresponds`, so they must
# go — but a naive split on '#' also severs any assertion message containing
# one, which corrupts the very text being judged. Track quoting; cut only a '#'
# that actually starts a comment.
_acceptance_strip_comment() {
    local line="${1-}" out="" q="" c i=0 n
    # Separate statement: bash expands every word of a `local` BEFORE the
    # locals exist, so `n=${#line}` on the line that assigns `line` reads the
    # OUTER scope and silently yields 0 — the loop then never runs.
    n=${#line}
    while (( i < n )); do
        c="${line:i:1}"
        if [[ -n "$q" ]]; then
            [[ "$c" == "$q" ]] && q=""
            out+="$c"
        elif [[ "$c" == '"' || "$c" == "'" ]]; then
            q="$c"; out+="$c"
        elif [[ "$c" == "#" ]] && { (( i == 0 )) || [[ "${line:i-1:1}" == [[:space:]] ]]; }; then
            break
        else
            out+="$c"
        fi
        (( i++ ))
    done
    # shellcheck disable=SC2001
    printf '%s' "$(sed 's/[[:space:]]*$//' <<< "$out")"
}

# ─── acceptance_find_assertion_sources <repo_root> <spec_id> <testfiles...> ──
# EVERY assertion tagged with the SPEC, in full, with its enclosing stanza.
#
# Distinct from acceptance_find_assertion_label above, which is the OPERATOR
# readout: first match, trimmed to 100 chars. Judging correspondence from that
# fragment is garbage-in — the repo's dominant shape is
# `if <predicate>; then assert_pass "[SPEC-n] …"`, where all the meaning lives
# in the predicate. Stripping it leaves a bare label that reads as a vacuous
# test, and a reader will (correctly) report exactly that about the mutilation.
#
# The stanza is the contiguous non-blank run containing the tagged line.
# Comments are stripped: pasting the SPEC sentence beside a weak assertion is
# the one gaming vector this input has.
acceptance_find_assertion_sources() {
    local repo_root="${1:-}" spec_id="${2:-}"; shift 2
    local tf abs i n a b line first=1
    for tf in "$@"; do
        [[ -z "$tf" ]] && continue
        abs="$repo_root/$tf"
        [[ -f "$abs" ]] || continue
        local -a lines=()
        while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$abs"
        n=${#lines[@]}
        local -a starts=()
        for (( i = 0; i < n; i++ )); do
            [[ "${lines[i]}" == *"[$spec_id]"* ]] || continue
            [[ "${lines[i]}" =~ ^[[:space:]]*assert[a-z_]*[[:space:]] ]] || continue
            a=$i; while (( a > 0 )) && [[ -n "${lines[a-1]// }" ]]; do (( a-- )); done
            b=$i; while (( b < n - 1 )) && [[ -n "${lines[b+1]// }" ]]; do (( b++ )); done
            # One stanza is emitted once however many tagged lines it holds.
            local seen=0 s
            for s in ${starts[@]+"${starts[@]}"}; do [[ "$s" == "$a:$b" ]] && seen=1; done
            (( seen )) && continue
            starts+=("$a:$b")
            (( first )) || printf '\n'
            first=0
            for (( ; a <= b; a++ )); do
                line="$(_acceptance_strip_comment "${lines[a]}")"
                [[ -n "${line// }" ]] && printf '%s\n' "$line"
            done
        done
    done
    return 0
}

acceptance_find_assertion_label() {
    local repo_root="${1:-}" spec_id="${2:-}"; shift 2
    local pass tf abs match
    for pass in assert any; do
        for tf in "$@"; do
            [[ -z "$tf" ]] && continue
            abs="$repo_root/$tf"
            [[ -f "$abs" ]] || continue
            if [[ "$pass" == "assert" ]]; then
                match="$(grep -m1 -E "^[[:space:]]*assert[a-z_]*[[:space:]].*\[$spec_id\]" "$abs" 2>/dev/null || true)"
            else
                match="$(grep -m1 -F "[$spec_id]" "$abs" 2>/dev/null || true)"
            fi
            if [[ -n "$match" ]]; then
                _acceptance_trim_label "$match"
                return 0
            fi
        done
    done
    return 0
}

# acceptance_coverage_check <design_md> <repo_root>
# Level-1 gate over the [change] SPEC-n ids in the design's acceptance block.
# Prints one "UNTAGGED <spec_id>" line per spec with no backing tagged
# assertion. Returns 0 when every gated SPEC-n is tagged (or there are no
# SPEC-n ids / no acceptance block — those are handled as a no-op pass by the
# caller), 1 when at least one gated SPEC-n is untagged.
#
# #1255: [guard] SPECs are EXEMPT — they assert invariants, not new behavior, so
# (mirroring the acceptance-gate's negctl guard exemption) they need not carry a
# [SPEC-n]-tagged test. Classification reuses acceptance_spec_classifier (the
# same [change]|[guard] parser the design-gate's C3 check uses).
acceptance_coverage_check() {
    local design_md="${1:-}" repo_root="${2:-}"
    local spec_id rc=0
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        [[ "$(acceptance_spec_classifier "$design_md" "$spec_id")" == "guard" ]] && continue
        if ! acceptance_coverage_spec_tagged "$design_md" "$repo_root" "$spec_id"; then
            printf 'UNTAGGED %s\n' "$spec_id"
            rc=1
        fi
    done < <(acceptance_list_spec_ids "$design_md" 2>/dev/null || true)
    return "$rc"
}
