#!/usr/bin/env bash
# scripts/lib/manifest-valid-verdicts.sh — read a manifest's
# config.valid_verdicts. Shared by the runtime reader (core/pipeline/verdict.sh,
# #2242: an undeclared verdict fails the stage) and the lints (lint-verdict-
# classify, lint-verdict-words), so the three read the same list the same way.

[[ -n "${_ZBUILD_MANIFEST_VALID_VERDICTS_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_VALID_VERDICTS_LOADED=1

# manifest_valid_verdicts_state <manifest> → one line:
#   absent            — no valid_verdicts key anywhere in the manifest
#   empty             — declared as an explicit inline [] (or a key with no items)
#   list <v1> <v2> …  — declared block list or flow sequence
#   invalid <raw>     — a bare scalar where a list is required
# Scoped to the `config:` block so an unrelated key elsewhere cannot satisfy it.
manifest_valid_verdicts_state() {
    # Pure bash, no subprocess: the runtime reader calls this for every stage
    # read, and the suite is fork-bound (ADR-065, #2236).
    local f="$1" line in_cfg=0 in_list=0 found=0 inline="" v
    local -a vals=()
    [[ -f "$f" ]] || { printf 'absent\n'; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^config:[[:space:]]*$ ]]; then in_cfg=1; continue; fi
        [[ $in_cfg -eq 1 && "$line" =~ ^[a-zA-Z_] ]] && { in_cfg=0; in_list=0; }
        [[ $in_cfg -eq 1 ]] || continue
        if [[ "$line" =~ ^[[:space:]]*valid_verdicts:[[:space:]]*(.*)$ ]]; then
            found=1; inline="${BASH_REMATCH[1]}"; inline="${inline%%#*}"
            inline="${inline%"${inline##*[![:space:]]}"}"
            in_list=1; continue
        fi
        if [[ $in_list -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*([^[:space:]].*)$ ]]; then
                v="${BASH_REMATCH[1]}"; v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"
                [[ -n "$v" ]] && vals+=("$v")
                continue
            fi
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]+[^-[:space:]] ]] && in_list=0
        fi
    done < "$f"
    if [[ $found -eq 0 ]]; then printf 'absent\n'; return 0; fi
    if [[ ${#vals[@]} -gt 0 ]]; then printf 'list %s\n' "${vals[*]}"; return 0; fi
    # YAML flow sequence: `valid_verdicts: [pass, fail]`.
    if [[ "$inline" == "["*"]" ]]; then
        inline="${inline#[}"; inline="${inline%]}"
        inline="${inline//,/ }"; inline="${inline//\"/}"; inline="${inline//\'/}"
        read -ra vals <<< "$inline"
        if [[ ${#vals[@]} -eq 0 ]]; then printf 'empty\n'; else printf 'list %s\n' "${vals[*]}"; fi
        return 0
    fi
    # A bare scalar (`valid_verdicts: pass`) is not a list (review #2247):
    # report it, never read it as a one-item list.
    if [[ -z "$inline" ]]; then printf 'empty\n'; else printf 'invalid %s\n' "$inline"; fi
}

# manifest_verdict_declared <manifest> <word> — rc 0 when <word> is in the
# declared list, rc 1 when a list is declared and <word> is not in it, rc 2 when
# the manifest declares no list (nothing to check against).
manifest_verdict_declared() {
    local state w
    state="$(manifest_valid_verdicts_state "$1" 2>/dev/null)"
    [[ "$state" == list\ * ]] || return 2
    for w in ${state#list }; do
        [[ "$w" == "$2" ]] && return 0
    done
    return 1
}
