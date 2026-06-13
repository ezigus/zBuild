#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  scripts/lib/scope-governance.sh — governed scope expansion core (#840)    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# The testable heart of governed scope expansion (ADR-030). Build emits a
# scope_expansion_request; the cycle orchestrator resolves it through the pure
# functions here. Three concerns, three layers:
#
#   1. Security floor (scope_floor_denied) — HARD, non-bypassable. legacy/,
#      secrets/.env, out-of-repo. No template knob and no class can breach it.
#      ADR-004 "no exceptions" discipline extended to write-scope. EVERY grant
#      routes through this.
#   2. Collateral class detector (scope_collateral_class) — path-shape only.
#      Maps a path to a closed class {collateral_tests,collateral_config,
#      collateral_docs,structural}. The template's auto_grant names these.
#   3. Resolver (scope_resolve_request) — pure decision over request + policy +
#      floor. Returns {action: grant|escalate|deny, granted[], denied[], reason}.
#
# No I/O beyond reading the requested file for the evidence check. No global
# state. Deterministic — unit-testable in isolation.

[[ -n "${_ZBUILD_SCOPE_GOVERNANCE_LOADED:-}" ]] && return 0
_ZBUILD_SCOPE_GOVERNANCE_LOADED=1

# ─── Security floor ──────────────────────────────────────────────────────
# scope_floor_denied <path>
#   rc 0 = DENIED (on the floor), rc 1 = past the floor (may be grantable).
#   Build write-scope may NEVER reach these regardless of policy:
#     - legacy/* — frozen upstream (ADR-002); the migration prune protocol is
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
        legacy/*|legacy) return 0 ;;
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

# ─── Collateral class detector (path-shape only, no content) ─────────────
# scope_collateral_class <path> → echoes one of:
#   collateral_tests | collateral_config | collateral_docs | structural
# Pure path-shape classification. Floor paths are NOT special-cased here — the
# resolver applies the floor first; this only names the structural category.
scope_collateral_class() {
    local path="$1"
    case "$path" in
        tests/*|*.golden) echo "collateral_tests"; return 0 ;;
        config/*|*.json)  echo "collateral_config"; return 0 ;;
        docs/*|*.md)      echo "collateral_docs"; return 0 ;;
    esac
    # Everything else (core/, scripts/, plugins/ source, etc.) is structural.
    echo "structural"
}

# ─── Evidence check ──────────────────────────────────────────────────────
# scope_evidence_present <path> <evidence>
#   rc 0 if the file at <path> contains the literal <evidence> token. Guards
#   against build requesting an unrelated file: it must point at a real token
#   that links the file to the change, and we verify the token exists. Empty
#   evidence is treated as "not present" (structural asks carry no evidence and
#   are resolved by escalation, never by collateral auto-grant).
scope_evidence_present() {
    local path="$1" evidence="$2"
    [[ -z "$evidence" ]] && return 1
    [[ -f "$path" ]] || return 1
    LC_ALL=C grep -qF -- "$evidence" "$path" 2>/dev/null
}

# ─── Resolver (pure) ─────────────────────────────────────────────────────
# scope_resolve_request <request_json> <expandable> <auto_grant_csv> <escalate>
#   request_json: {"files":[{"path","category","evidence","reason"}]}
#   Echoes decision JSON:
#     {"action":"grant|escalate|deny","granted":[...],"denied":[...],"reason":"..."}
#   Disposition is per-file, then aggregated conservatively:
#     - any file DENY  → overall deny  (build re-requests a cleaner set)
#     - else any ESCALATE → overall escalate
#     - else → grant all
#   (on_deny is a cycle-level outcome the orchestrator applies — the resolver
#   only decides grant/escalate/deny; it does not own the abandon action.)
scope_resolve_request() {
    local req="$1" expandable="$2" auto_grant_csv="$3" escalate="$4"
    local granted=() denied=() escalated=() reasons=()

    if [[ "$expandable" != "true" ]]; then
        jq -nc '{action:"deny", granted:[], denied:[], reason:"cycle scope_policy not expandable"}'
        return 0
    fi

    local n; n="$(jq -r '.files | length' <<<"$req" 2>/dev/null || echo 0)"
    if [[ -z "$n" || "$n" == "0" ]]; then
        jq -nc '{action:"deny", granted:[], denied:[], reason:"empty request"}'
        return 0
    fi

    local i path category evidence cls
    for (( i=0; i<n; i++ )); do
        path="$(jq -r ".files[$i].path // empty" <<<"$req")"
        category="$(jq -r ".files[$i].category // empty" <<<"$req")"
        evidence="$(jq -r ".files[$i].evidence // empty" <<<"$req")"

        # Floor is absolute.
        if scope_floor_denied "$path"; then
            denied+=("$path"); reasons+=("floor:$path"); continue
        fi
        # Trust but verify the claimed category against path-shape.
        cls="$(scope_collateral_class "$path")"
        if [[ -n "$category" && "$category" != "$cls" ]]; then
            # Claimed category disagrees with shape — distrust, use shape.
            :
        fi
        if [[ "$cls" == "structural" ]]; then
            if [[ "$escalate" == "structural" ]]; then
                escalated+=("$path")
            else
                denied+=("$path"); reasons+=("structural-not-escalatable:$path")
            fi
            continue
        fi
        # Collateral class — must be enabled in auto_grant AND have evidence.
        if [[ ",$auto_grant_csv," != *",$cls,"* ]]; then
            denied+=("$path"); reasons+=("class-not-enabled:$cls:$path"); continue
        fi
        if ! scope_evidence_present "$path" "$evidence"; then
            denied+=("$path"); reasons+=("no-evidence:$path"); continue
        fi
        granted+=("$path")
    done

    local action reason
    if (( ${#denied[@]} > 0 )); then
        action="deny"
        reason="denied: ${reasons[*]}"
    elif (( ${#escalated[@]} > 0 )); then
        action="escalate"
        reason="escalate structural: ${escalated[*]}"
    else
        action="grant"
        reason="granted ${#granted[@]} collateral file(s)"
    fi

    # Build JSON arrays safely via jq.
    local granted_json denied_json
    granted_json="$(printf '%s\n' "${granted[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
    denied_json="$(printf '%s\n' "${denied[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"
    jq -nc --arg a "$action" --arg r "$reason" \
        --argjson g "$granted_json" --argjson d "$denied_json" \
        '{action:$a, granted:$g, denied:$d, reason:$r}'
}
