#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  contract/version — the result-contract versions this engine speaks        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-054 §5 / #1824. ADR-001 closed with a deferred open question — "versioning
# across breaking manifest changes: bump policy TBD" — and it stayed deferred, so
# an engine could not tell a plugin it understands from one it does not. A
# breaking change surfaced as a runtime misread instead of a refusal.
#
# Phase 0 makes that urgent: v1 and v2 result files coexist while ~25 plugins
# migrate one at a time (#1833-#1849), so something has to say which versions are
# legible RIGHT NOW, in one place, versioned with the engine.
#
# THE RANGE BELOW IS THAT ONE PLACE. Dropping v1 (#1850) is a one-line change:
# set _ZBUILD_CONTRACT_MIN=2. A guard test asserts no second copy of these bounds
# exists anywhere in core/, scripts/ or plugins/ — a duplicated bound is how a
# range becomes advisory.
#
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CONTRACT_VERSION_LOADED:-}" ]] && return 0
_ZBUILD_CONTRACT_VERSION_LOADED=1

# ─── The declared range ─────────────────────────────────────────────────────
_ZBUILD_CONTRACT_MIN=1
_ZBUILD_CONTRACT_MAX=2

# The version at which a result carries the ADR-054 shape (disposition, reason,
# result_contract). Named rather than spelled `2` at each reader: verdict.sh's
# "is this a v2 result" branch and this range have to move together, and a bare
# literal at the reader is precisely the second copy #1824 exists to prevent.
_ZBUILD_CONTRACT_V2=2

# The version assumed when a plugin or result file declares none. Coexistence
# reads an undeclared contract as v1; when v1 leaves the range this default stops
# being legible on its own and contract_version_check refuses it — which is the
# point, and is what makes #1850 a one-line change rather than a sweep.
_ZBUILD_CONTRACT_DEFAULT=1

# ─── contract_version_range ─────────────────────────────────────────────────
# Human-facing "1..2", for refusal messages. Never parsed.
contract_version_range() {
    printf '%s..%s' "$_ZBUILD_CONTRACT_MIN" "$_ZBUILD_CONTRACT_MAX"
}

# ─── contract_version_default ───────────────────────────────────────────────
contract_version_default() { printf '%s' "$_ZBUILD_CONTRACT_DEFAULT"; }

# ─── contract_version_supported <version> ───────────────────────────────────
# rc=0 when the engine can read that contract, rc=1 otherwise. A non-integer is
# unsupported, not defaulted: a typo'd version must refuse rather than silently
# read as v1, which is the failure mode this whole file exists to remove.
contract_version_supported() {
    local v="${1:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    (( v >= _ZBUILD_CONTRACT_MIN && v <= _ZBUILD_CONTRACT_MAX )) || return 1
    return 0
}

# ─── contract_version_resolve <declared> ────────────────────────────────────
# Echo the effective version for a declaration that may be absent. Empty → the
# coexistence default. Anything else is echoed verbatim for the caller to check;
# resolving is not accepting.
contract_version_resolve() {
    local declared="${1:-}"
    if [[ -z "$declared" ]]; then printf '%s' "$_ZBUILD_CONTRACT_DEFAULT"; return 0; fi
    printf '%s' "$declared"
}

# ─── contract_version_check <declared> <subject> ────────────────────────────
# The refusal path. Echoes a message naming the subject, the version it declared
# and the range the engine accepts, then returns 1. Callers decide whether that
# is fatal — at manifest load it is (#1824: at load, not at dispatch, and never
# a warning).
contract_version_check() {
    local declared="${1:-}" subject="${2:-plugin}"
    local eff; eff="$(contract_version_resolve "$declared")"
    if contract_version_supported "$eff"; then return 0; fi
    local shown="${declared:-<absent>}"
    printf '%s declares result contract %s; this engine speaks %s' \
        "$subject" "$shown" "$(contract_version_range)"
    return 1
}
