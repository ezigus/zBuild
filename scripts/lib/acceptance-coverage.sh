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

# acceptance_find_assertion_label <repo_root> <spec_id> <testfiles...>  (#1684)
# Scans each declared testfile for the first line containing the literal tag
# [<spec_id>] and returns it (stripped of leading whitespace) truncated to
# 60 characters with '…'. Returns empty string when no matching line is found.
acceptance_find_assertion_label() {
    local repo_root="${1:-}" spec_id="${2:-}"; shift 2
    local tf abs match
    for tf in "$@"; do
        [[ -z "$tf" ]] && continue
        abs="$repo_root/$tf"
        [[ -f "$abs" ]] || continue
        match="$(grep -m1 -F "[$spec_id]" "$abs" 2>/dev/null || true)"
        if [[ -n "$match" ]]; then
            match="${match#"${match%%[![:space:]]*}"}"
            if [[ ${#match} -gt 60 ]]; then
                printf '%s…\n' "${match:0:60}"
            else
                printf '%s\n' "$match"
            fi
            return 0
        fi
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
