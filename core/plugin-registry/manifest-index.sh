#!/usr/bin/env bash
# manifest-index.sh — one pass over every manifest under a plugins root (#2152,
# ADR-065 §3/§4).
#
# Before this file, every reader of manifest scalars forked once per manifest
# per key: yaml_cache_prewarm ran 55 × 12 = 660 awks at every `source runner.sh`,
# and _inputs_scan_manifests ran 55 awks on each of its 41 calls per run because
# its memo was never filled in the parent shell. The index is ONE find and ONE
# awk (FNR == 1 resets per file) that reproduces _yaml_get_uncached byte for
# byte for a fixed key list; the memos are then filled from it in the parent, so
# every `$( )` reader inherits them. A key outside the list still takes yaml_get's
# lazy path — nothing about that path changes.
#
# The equivalence with _yaml_get_uncached is a tested contract
# (tests/unit/manifest-index-test.sh SPEC-1, every real manifest plus an
# adversarial corpus); the awk below mirrors the reader's rules on purpose and
# must change with it.
[[ -n "${_ZBUILD_MANIFEST_INDEX_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_INDEX_LOADED=1

# The 12 prewarm keys plus the four the census found read from `$( )` outside
# the prewarm set (discovery.sh provides.alias, contract-validator.sh convergence,
# lifecycle.sh capabilities.empty_diff_legitimate, tier-resolve.sh
# config.tier_default). One-level nesting only, like yaml_get.
_ZBUILD_MIDX_KEYS=(
    id name kind version summary platform
    persona.role persona.perspective
    hooks.run hooks.cleanup
    provides.role provides.result_contract provides.alias
    convergence capabilities.empty_diff_legitimate config.tier_default
)
# -g: this file can be sourced from inside a function (see manifest-validation.sh).
declare -gA _ZBUILD_MIDX=()        # "<path>\034<key>" → value + "\n" (present keys only)
declare -gA _ZBUILD_MIDX_FILES=()  # "<root>" → newline-joined manifest paths

# Trailing slashes stripped, nothing else: index rows are keyed by the paths
# find prints under the root AS GIVEN, and yaml_get's memo keys are the exact
# strings callers pass — resolving symlinks here would make the two disagree.
_manifest_index_root() {
    local root="$1"
    while [[ "$root" == */ && "$root" != "/" ]]; do root="${root%/}"; done
    printf '%s' "$root"
}

# The one awk. Mirrors _yaml_get_uncached (manifest-validation.sh): strip
# through the first colon and spaces, then a trailing comment, then ONE leading
# and ONE trailing quote; first match per key per file wins; a nested key's
# `^parent:` line opens its block and is consumed (never a child match), any
# column-0 identifier closes it, the child matches at any indentation.
# shellcheck disable=SC2016
_ZBUILD_MIDX_AWK='
    BEGIN {
        n = split(keys, k, " ")
        for (i = 1; i <= n; i++) {
            if (index(k[i], ".") > 0) { parent[i] = substr(k[i], 1, index(k[i], ".") - 1); child[i] = substr(k[i], index(k[i], ".") + 1) }
            else { parent[i] = ""; child[i] = "" }
        }
    }
    # Mirrors _yaml_get_uncached: strip through the first colon and spaces,
    # then a trailing comment, then ONE leading and ONE trailing quote.
    function clean(v) { sub(/^[^:]+:[[:space:]]*/, "", v); sub(/[[:space:]]*#.*/, "", v); gsub(/^["\047]|["\047]$/, "", v); return v }
    function nclean(v) { sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", v); sub(/[[:space:]]*#.*/, "", v); gsub(/^["\047]|["\047]$/, "", v); return v }
    FNR == 1 { for (i = 1; i <= n; i++) { found[i] = 0; inb[i] = 0 } }
    {
        for (i = 1; i <= n; i++) {
            if (found[i]) continue
            if (parent[i] == "") {
                if ($0 ~ ("^" k[i] ":")) { found[i] = 1; printf "%s\034%s\034%s\n", FILENAME, k[i], clean($0) }
                continue
            }
            # nested: a `^parent:` line opens the block and is consumed (`next`
            # in the reader — it is never a child match); any column-0
            # identifier closes it; the child matches at any indentation.
            if ($0 ~ ("^" parent[i] ":")) { inb[i] = 1; continue }
            if (inb[i] && $0 ~ /^[a-zA-Z_]/) inb[i] = 0
            if (inb[i] && $0 ~ ("^[[:space:]]+" child[i] ":")) { found[i] = 1; printf "%s\034%s\034%s\n", FILENAME, k[i], nclean($0) }
        }
    }'

# ─── manifest_index_build <root> ─────────────────────────────────────────────
# Streams `path\034key\034value` rows for every present key of every manifest
# under root (any depth; callers filter), plus one `path\034__file__\034`
# marker per manifest so a file with no matching key (an empty file never fires
# FNR == 1) is still listed. Exactly one find and one awk. No memo — see
# manifest_index_load.
manifest_index_build() {
    local root="$1" f
    local -a files=()
    mapfile -t files < <(find "$root" -name manifest.yaml -type f 2>/dev/null)
    for f in "${files[@]+"${files[@]}"}"; do printf '%s\034__file__\034\n' "$f"; done
    (( ${#files[@]} > 0 )) || return 0
    awk -v keys="${_ZBUILD_MIDX_KEYS[*]}" "$_ZBUILD_MIDX_AWK" "${files[@]}" 2>/dev/null
}

# ─── manifest_index_load <root> ──────────────────────────────────────────────
# Fills the in-process index for root once. Honours the yaml cache kill switch
# (ZBUILD_YAML_CACHE=0 → no index; readers stream manifest_index_build instead).
# Call it in the PARENT shell: a `$( )` caller's fill dies with the subshell.
manifest_index_load() {
    [[ "${ZBUILD_YAML_CACHE:-1}" == "1" ]] || return 0
    local root; root="$(_manifest_index_root "$1")"
    [[ -n "${_ZBUILD_MIDX_FILES[$root]+x}" ]] && return 0
    local -a files=()
    local p k v
    # The loop body runs in this shell — `< <( )`, never a pipe (a pipe would put
    # the writes in a subshell and keep nothing).
    while IFS=$'\034' read -r p k v; do
        [[ "$k" == "__file__" ]] && { files+=("$p"); continue; }
        _ZBUILD_MIDX["$p"$'\034'"$k"]="$v"$'\n'
    done < <(manifest_index_build "$root")
    _ZBUILD_MIDX_FILES["$root"]="$(printf '%s\n' "${files[@]+"${files[@]}"}")"
}

# ─── manifest_index_rows <root> ──────────────────────────────────────────────
# `path\034key\034value` rows (present keys only) plus `path\034__file__\034`
# markers: from the loaded index when it exists (no fork), else streamed from a
# fresh build (one find + one awk) — the kill-switch path.
manifest_index_rows() {
    local root; root="$(_manifest_index_root "$1")"
    if [[ -n "${_ZBUILD_MIDX_FILES[$root]+x}" ]]; then
        local f k v
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            printf '%s\034__file__\034\n' "$f"
            for k in "${_ZBUILD_MIDX_KEYS[@]}"; do
                [[ -n "${_ZBUILD_MIDX["$f"$'\034'"$k"]+x}" ]] || continue
                v="${_ZBUILD_MIDX["$f"$'\034'"$k"]}"
                printf '%s\034%s\034%s\n' "$f" "$k" "${v%$'\n'}"
            done
        done <<< "${_ZBUILD_MIDX_FILES[$root]}"
        return 0
    fi
    manifest_index_build "$root"
}

# ─── manifest_index_get <path> <key> ─────────────────────────────────────────
# yaml_get's exact shape from the loaded index: present → value + newline, rc 0;
# absent key of a listed file → 0 bytes, rc 0; a file no loaded root lists → rc 2.
manifest_index_get() {
    local f="$1" k="$2" root listed=0
    for root in "${!_ZBUILD_MIDX_FILES[@]}"; do
        [[ "$f" == "$root"/* ]] || continue
        while IFS= read -r p; do [[ "$p" == "$f" ]] && { listed=1; break; }; done <<< "${_ZBUILD_MIDX_FILES[$root]}"
        (( listed )) && break
    done
    (( listed )) || return 2
    [[ -n "${_ZBUILD_MIDX["$f"$'\034'"$k"]+x}" ]] && printf '%s' "${_ZBUILD_MIDX["$f"$'\034'"$k"]}"
    return 0
}

manifest_index_flush() {
    _ZBUILD_MIDX=()
    _ZBUILD_MIDX_FILES=()
}
