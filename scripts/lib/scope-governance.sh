#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/lib/scope-governance.sh — the security floor (ADR-030 §3)        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# The paths no write may reach: legacy-DoNotUse/, secrets/.env, out-of-repo.
# A per-repo prompt override is refused on it (ADR-032). #2508 (ADR-030 §8):
# governed scope expansion — the collateral classes, the evidence check and the
# resolver — is gone with build's file list; build may change any file outside
# the test folders, and there is nothing to widen.
#
# No I/O. No global state. Deterministic — unit-testable in isolation.

[[ -n "${_ZBUILD_SCOPE_GOVERNANCE_LOADED:-}" ]] && return 0
_ZBUILD_SCOPE_GOVERNANCE_LOADED=1

# ─── Security floor ──────────────────────────────────────────────────────
# scope_floor_denied <path>
#   rc 0 = DENIED (on the floor), rc 1 = past the floor.
#   No write may reach these:
#     - legacy-DoNotUse/* — frozen upstream (ADR-002); a keeper prune (git rm) is
#       the only legitimate writer, never build.
#     - secrets: .env, *secret*, *credential*, *.pem/*.key (ADR-004 spirit).
#     - absolute paths / repo escapes (../, leading /).
scope_floor_denied() {
    local path="$1"
    # Absolute or escaping paths — out of repo.
    case "$path" in
        /*|*/../*|../*|*/..) return 0 ;;
    esac
    # Legacy frozen tree.
    case "$path" in
        legacy-DoNotUse/*|legacy-DoNotUse) return 0 ;;
    esac
    # Secret-ish paths (match on basename and full path, case-insensitive-ish).
    local lower="${path,,}"
    case "$lower" in
        .env|*/.env|*.env) return 0 ;;
        *secret*|*credential*) return 0 ;;
        *.pem|*.key|*.p12|*.pfx) return 0 ;;
    esac
    return 1
}
