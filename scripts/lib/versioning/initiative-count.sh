#!/usr/bin/env bash
# scripts/lib/versioning/initiative-count.sh
# Default built-in versioning strategy (ADR-011 `versioning` backend, ADR-048).
#
# Produces the 4-part w.x.y.z scheme:
#   w.x = the last COMPLETED initiative, anchored by the latest vw.x.0.0 tag.
#   y   = release count — the Nth release cut since the vw.x.0.0 initiative release.
#   z   = number of issues closed since the vw.x.0.0 initiative release.
# Example: 1.0.0.0 -> 1.0.1.12 -> 1.0.2.13 -> ... -> 1.1.0.0
# On a minor/major cut both y and z reset to 0, producing w.(x+1).0.0 / (w+1).0.0.0.
#
# Sourced library: inherits caller's pipefail; no set -euo pipefail here.

[[ -n "${_ZBUILD_VERSIONING_INITIATIVE_COUNT_LOADED:-}" ]] && return 0
_ZBUILD_VERSIONING_INITIATIVE_COUNT_LOADED=1

# Emit a fail-loud message to stderr (uses helpers' `error` when available).
_iv_err() {
    if declare -F error >/dev/null 2>&1; then error "$*"; else echo "$*" >&2; fi
}

# ─── compute_version <anchor_xy> <release_count> <issues_since> ──────────────
# PURE: no net / gh / git calls. Assembles + validates the 4-part A.B.C.D version.
#   anchor_xy      — "A.B" (last completed initiative), each part a non-negative int.
#   release_count  — C, a non-negative int (Nth release since the A.B.0.0 release).
#   issues_since   — D, a non-negative int (issues closed since A.B.0.0).
# Prints "A.B.C.D" on stdout. Fails loud (rc=1, message on stderr) on malformed input.
compute_version() {
    local anchor_xy="${1-}" release_count="${2-}" issues_since="${3-}"

    if [[ $# -ne 3 ]]; then
        _iv_err "compute_version: expected 3 args (anchor_xy release_count issues_since), got $#"
        return 1
    fi

    # anchor_xy must be exactly "A.B" with non-negative integer parts.
    if [[ ! "$anchor_xy" =~ ^[0-9]+\.[0-9]+$ ]]; then
        _iv_err "compute_version: malformed anchor '$anchor_xy' (want A.B, e.g. 1.0)"
        return 1
    fi

    # C and D must each be a bare non-negative integer.
    if [[ ! "$release_count" =~ ^[0-9]+$ ]]; then
        _iv_err "compute_version: malformed release_count '$release_count' (want a non-negative integer)"
        return 1
    fi
    if [[ ! "$issues_since" =~ ^[0-9]+$ ]]; then
        _iv_err "compute_version: malformed issues_since '$issues_since' (want a non-negative integer)"
        return 1
    fi

    local version="${anchor_xy}.${release_count}.${issues_since}"

    # Self-validate the assembled 4-part shape (defence in depth).
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _iv_err "compute_version: assembled version '$version' is not 4-part A.B.C.D"
        return 1
    fi

    printf '%s\n' "$version"
}

# ─── _versioning_latest_anchor ──────────────────────────────────────────────
# Gathering helper (NOT pure): find the A.B of the latest vA.B.0.0 initiative tag.
# Prints "A.B" or empty if none. Uses git; safe to call outside a repo (prints nothing).
_versioning_latest_anchor() {
    local tag ab best=""
    while IFS= read -r tag; do
        [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.0\.0$ ]] || continue
        ab="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        best="$ab"   # git tag output is version-sorted; last match wins
    done < <(git tag --sort=version:refname 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.0\.0$' 2>/dev/null || true)

    # Fall back to a legacy 3-part vA.B.0 initiative tag (e.g. v1.0.0) if no 4-part
    # tag exists yet — the current repo state (v1.0.0 exists, treat its A.B as 1.0).
    if [[ -z "$best" ]]; then
        while IFS= read -r tag; do
            [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.0$ ]] || continue
            best="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        done < <(git tag --sort=version:refname 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.0$' 2>/dev/null || true)
    fi

    printf '%s' "$best"
}

# ─── _versioning_release_count <anchor_xy> ──────────────────────────────────
# Gathering helper (NOT pure): count prior release tags under this A.B, i.e.
# tags vA.B.C.D with C>0 (or legacy vA.B.Z, Z>0). Prints an integer.
_versioning_release_count() {
    local anchor_xy="$1" a b count
    a="${anchor_xy%%.*}"; b="${anchor_xy##*.}"
    # Robust outside a git worktree / when git is absent (e.g. an installed tree
    # without .git): a missing tag history just means zero prior releases. Never
    # abort the caller's errexit/pipefail — guard git, and shield the pipeline
    # (grep no-match returns 1 under pipefail) behind `|| true`.
    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
        printf '0'; return 0
    fi
    count="$( { git tag 2>/dev/null \
        | grep -E "^v${a}\.${b}\.[0-9]+(\.[0-9]+)?$" \
        | grep -vE "^v${a}\.${b}\.0(\.0)?$" \
        | wc -l | tr -d '[:space:]'; } 2>/dev/null || true )"
    printf '%s' "${count:-0}"
}

# ─── initiative-count_version ───────────────────────────────────────────────
# Strategy entrypoint (NOT pure): gather A.B / C / D from git+gh, then delegate
# to the pure compute_version. Prints the resolved 4-part version.
# Inputs may be overridden for testing via env: ZBUILD_VERSION_ANCHOR,
# ZBUILD_VERSION_RELEASE_COUNT, ZBUILD_VERSION_ISSUES_SINCE.
# Cadence is read from ZBUILD_VERSION_CADENCE (patch/minor/major; default: patch).
initiative-count_version() {
    local anchor="${ZBUILD_VERSION_ANCHOR:-}"
    local rcount="${ZBUILD_VERSION_RELEASE_COUNT:-}"
    local issues="${ZBUILD_VERSION_ISSUES_SINCE:-}"
    local cadence="${ZBUILD_VERSION_CADENCE:-patch}"

    [[ -z "$anchor" ]] && anchor="$(_versioning_latest_anchor)"
    [[ -z "$anchor" ]] && anchor="1.0"   # no tags yet: inaugural initiative

    [[ -z "$rcount" ]] && rcount="$(_versioning_release_count "$anchor")"
    [[ -z "$rcount" ]] && rcount="0"

    # D (issues closed since anchor) is a gathering concern owned by REL-B's
    # release cutter (it needs gh + the anchor tag date). REL-A supplies a
    # deterministic 0 when not provided so the pure assembly stays testable.
    [[ -z "$issues" ]] && issues="0"

    # Apply cadence: --minor bumps x (resets y and z); --major bumps w (resets x, y and z).
    # Guard on a well-formed 2-part anchor via BASH_REMATCH — a malformed override
    # (e.g. ZBUILD_VERSION_ANCHOR="1.2.3") is passed through UNTOUCHED so the pure
    # compute_version fails loud below, rather than tripping non-integer arithmetic
    # here (${anchor#*.} on "1.2.3" is "2.3", which breaks $((...))).
    if [[ "$anchor" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        local _a="${BASH_REMATCH[1]}" _b="${BASH_REMATCH[2]}"
        if [[ "$cadence" == "minor" ]]; then
            anchor="${_a}.$((_b + 1))"
            rcount="0"
            issues="0"
        elif [[ "$cadence" == "major" ]]; then
            anchor="$((_a + 1)).0"
            rcount="0"
            issues="0"
        fi
    fi

    compute_version "$anchor" "$rcount" "$issues"
}
