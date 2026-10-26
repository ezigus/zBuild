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
# the prewarm set (discovery.sh provides.alias,
# lifecycle.sh capabilities.empty_diff_legitimate, tier-resolve.sh
# config.tier_default). One-level nesting only, like yaml_get.
_ZBUILD_MIDX_KEYS=(
    id name kind version summary platform
    persona.role persona.perspective
    hooks.run hooks.cleanup
    provides.role provides.result_contract provides.alias
    capabilities.empty_diff_legitimate config.tier_default
    capabilities.writes_repository capabilities.iteration_aware
)
# -g: this file can be sourced from inside a function (see manifest-validation.sh).
declare -gA _ZBUILD_MIDX=()        # "<path>\034<key>" → value + "\n" (present keys only)
declare -gA _ZBUILD_MIDX_FILES=()  # "<root>" → newline-joined manifest paths
declare -gA _ZBUILD_MIDX_LISTED=() # "<path>" → 1 for every manifest a loaded root lists

# Trailing slashes stripped and `//` collapsed, nothing else: the runner fills
# from the env's spelling ($TMPDIR ends in /) while lifecycle.sh reads with
# `cd && pwd`'s, and the two must be one key. Symlinks are NOT resolved — index
# rows are keyed by the paths find prints under the root, and yaml_get's memo
# keys are the strings callers pass (with `//` collapsed, see _manifest_path_key).
_manifest_index_root() { local _mir; _manifest_index_root_v _mir "$1"; printf '%s' "$_mir"; }
# _manifest_index_root_v <var> <root> — the same, into <var>, with no subshell.
_manifest_index_root_v() {
    local _mirv="$2"
    while [[ "$_mirv" == *//* ]]; do _mirv="${_mirv//\/\//\/}"; done
    while [[ "$_mirv" == */ && "$_mirv" != "/" ]]; do _mirv="${_mirv%/}"; done
    printf -v "$1" '%s' "$_mirv"
}

# _manifest_path_key <var> <path> — <path> with `//` collapsed, into <var>; no fork.
_manifest_path_key() {
    local _mpk="$2"
    while [[ "$_mpk" == *//* ]]; do _mpk="${_mpk//\/\//\/}"; done
    printf -v "$1" '%s' "$_mpk"
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
    FNR == 1 { for (i = 1; i <= n; i++) { found[i] = 0; inb[i] = 0 }; inout = 0 }
    {
        # #2174: outputs.path is a LIST key — one row per `path:` line inside
        # the column-0 `outputs:` block (any indentation, quoted or not). Same
        # open/close rule as the nested scalars; emitted from this same pass.
        if ($0 ~ /^outputs:/) { inout = 1; next }
        if (inout && $0 ~ /^[a-zA-Z_]/) inout = 0
        if (inout && $0 ~ /^[[:space:]]+(-[[:space:]]+)?path:/) { v = $0; sub(/^[[:space:]]+(-[[:space:]]+)?/, "", v); printf "%s\034outputs.path\034%s\n", FILENAME, nclean(" " v) }
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
    # -L: a plugin dir linked in by a symlink (tests link the real personas
    # in) is a plugin like any other; find reports and skips a link loop.
    mapfile -t files < <(find -L "$root" -name manifest.yaml -type f 2>/dev/null)
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
    local root; _manifest_index_root_v root "$1"
    [[ -n "${_ZBUILD_MIDX_FILES[$root]+x}" ]] && return 0
    local -a files=()
    local p k v
    # The loop body runs in this shell — `< <( )`, never a pipe (a pipe would put
    # the writes in a subshell and keep nothing).
    while IFS=$'\034' read -r p k v; do
        [[ "$k" == "__file__" ]] && { files+=("$p"); _ZBUILD_MIDX_LISTED["$p"]=1; continue; }
        if [[ "$k" == "outputs.path" ]]; then
            _ZBUILD_MIDX["$p"$'\034'"$k"]+="$v"$'\n'   # list key: accumulate (#2174)
        else
            _ZBUILD_MIDX["$p"$'\034'"$k"]="$v"$'\n'
        fi
    done < <(manifest_index_build "$root")
    _ZBUILD_MIDX_FILES["$root"]="$(printf '%s\n' "${files[@]+"${files[@]}"}")"
}

# ─── manifest_index_rows <root> ──────────────────────────────────────────────
# `path\034key\034value` rows (present keys only) plus `path\034__file__\034`
# markers: from the loaded index when it exists (no fork), else streamed from a
# fresh build (one find + one awk) — the kill-switch path.
manifest_index_rows() {
    local root; _manifest_index_root_v root "$1"
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
            # The list key: one row per value, as the cold build emits it (#2174).
            if [[ -n "${_ZBUILD_MIDX["$f"$'\034'outputs.path]+x}" ]]; then
                while IFS= read -r v; do
                    [[ -n "$v" ]] && printf '%s\034outputs.path\034%s\n' "$f" "$v"
                done <<< "${_ZBUILD_MIDX["$f"$'\034'outputs.path]}"
            fi
        done <<< "${_ZBUILD_MIDX_FILES[$root]}"
        return 0
    fi
    manifest_index_build "$root"
}

# ─── manifest_index_get <path> <key> ─────────────────────────────────────────
# yaml_get's exact shape from the loaded index: present → value + newline, rc 0;
# absent key of a listed file → 0 bytes, rc 0; a file no loaded root lists → rc 2.
manifest_index_get() {
    local f k="$2"
    _manifest_path_key f "$1"
    # A lookup, not a walk of every root's file list (ADR-065 §5): it ran on
    # every manifest read, and its work grew with the number of plugins.
    [[ -n "${_ZBUILD_MIDX_LISTED[$f]+x}" ]] || return 2
    [[ -n "${_ZBUILD_MIDX["$f"$'\034'"$k"]+x}" ]] && printf '%s' "${_ZBUILD_MIDX["$f"$'\034'"$k"]}"
    return 0
}
# manifest_index_get_v <var> <manifest> <key> — the same into <var> (empty when
# the key is absent), rc 2 when no loaded root lists the file.
manifest_index_get_v() {
    local -n _migo="$1"
    local _mig_f
    _migo=""
    _manifest_path_key _mig_f "$2"
    [[ -n "${_ZBUILD_MIDX_LISTED[$_mig_f]+x}" ]] || return 2
    _migo="${_ZBUILD_MIDX["$_mig_f"$'\034'"$3"]-}"
    return 0
}

manifest_index_flush() {
    _ZBUILD_MIDX=()
    _ZBUILD_MIDX_FILES=()
    _ZBUILD_MIDX_LISTED=()
}

# ─── _inputs_scan_manifests <plugins_root> ───────────────────────────────────
# ONE pass over the plugin tree, building the id→manifest and role→manifest maps
# _inputs_stage_manifest resolves against.
#
# Why not just call resolve_stage_plugin per stage: it goes through
# discover_plugins, which costs ~8s per call on this tree. The index needs a
# manifest for EVERY stage in the flow, so a per-stage call would add ~2 minutes
# to every dispatch. One find + one awk for the whole tree (#2152) is ~40ms.
# #2152 (ADR-065 §3): every reader of these maps is a `$( )` — the fill has to
# happen in the PARENT shell, at the runner's prewarm seam, or it happens on
# every call. Bare `declare -gA` (no `=()`): route.sh re-sources this file
# lazily inside a function, and an initialiser there would wipe the fill.
declare -gA _IR_BY_ID
declare -gA _IR_BY_ROLE
[[ -n "${_IR_SCAN_KEY+x}" ]] || _IR_SCAN_KEY=""
_inputs_scan_manifests() {
    local plugins_root; _manifest_index_root_v plugins_root "$1"
    [[ "$plugins_root" == "$_IR_SCAN_KEY" ]] && return 0
    _IR_SCAN_KEY="$plugins_root"
    _IR_BY_ID=(); _IR_BY_ROLE=()
    # #2152: read from the manifest index — no awk per manifest. Rows arrive
    # file by file; a file's `__file__` marker precedes its keys, so the
    # previous file is complete when the next marker (or the end) arrives.
    manifest_index_load "$plugins_root"
    # Collect per file, commit in marker order at the end: the rows' order is
    # not a contract (the memo streams them per file, a fresh build emits every
    # `__file__` marker first — review on #2155), and first-occurrence-wins
    # needs the files in the order they were enumerated.
    local -a _files=()
    local -A _id=() _role=() _plat=()
    local m p k v
    if [[ -n "${_ZBUILD_MIDX_FILES[$plugins_root]+x}" ]]; then
        # The loaded index, read from its arrays in this shell: streaming its
        # rows as text was most of a run's shell commands (ADR-065 §5).
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            _files+=("$p")
            for k in id platform provides.role; do
                [[ -n "${_ZBUILD_MIDX["$p"$'\034'"$k"]+x}" ]] || continue
                v="${_ZBUILD_MIDX["$p"$'\034'"$k"]%$'\n'}"; v="${v%"${v##*[![:space:]]}"}"
                case "$k" in id) _id["$p"]="$v" ;; platform) _plat["$p"]="$v" ;; *) _role["$p"]="$v" ;; esac
            done
        done <<< "${_ZBUILD_MIDX_FILES[$plugins_root]}"
    else
        while IFS=$'\034' read -r p k v; do
            if [[ "$k" == "__file__" ]]; then _files+=("$p"); continue; fi
            # the old per-file awk also trimmed trailing whitespace
            v="${v%"${v##*[![:space:]]}"}"
            case "$k" in
                id) _id["$p"]="$v" ;; platform) _plat["$p"]="$v" ;; provides.role) _role["$p"]="$v" ;;
            esac
        done < <(manifest_index_rows "$plugins_root")
    fi
    for m in "${_files[@]+"${_files[@]}"}"; do
        [[ "$m" != */tests/* ]] || continue
        [[ -n "${_id[$m]:-}" && -z "${_IR_BY_ID[${_id[$m]}]:-}" ]] && _IR_BY_ID["${_id[$m]}"]="$m"
        # Platform-specific plugins never win the generic slot; the engine's own
        # resolver prefers a platform match and this module has no platform.
        if [[ -n "${_role[$m]:-}" && ( -z "${_plat[$m]:-}" || "${_plat[$m]:-}" == "null" ) && -z "${_IR_BY_ROLE[${_role[$m]}]:-}" ]]; then
            _IR_BY_ROLE["${_role[$m]}"]="$m"
        fi
    done
}

# ─── _inputs_stage_manifest <stage> <plugins_root> ───────────────────────────
# The manifest DISPATCH would actually use — role-THEN-id, the resolve_stage_plugin
# rule (dispatch.sh), applied to the single-scan maps above.
#
# NOT manifest_graph_collect: that is id-only, and against the live simple.yaml
# stage list it resolves `acceptance-gate` and `review_lenses` to no manifest at
# all — they are silently skipped by contract-validator.sh:213 today. NOT
# manifest_graph_resolve_member either: it tries id-match FIRST, so `pr` lands on
# plugins/tool/pr-open, the manifest whose own header documents it as deliberately
# unreachable at dispatch (the real plugin is plugins/agent/pr-delivery, bound by
# role). Role-first is the only rule that agrees with dispatch on all three.
#
# Fail-closed on a declared-but-unresolved role, matching resolve_stage_plugin:
# no id-match fallback once roles are declared.
_inputs_stage_manifest() {
    local _ism; _inputs_stage_manifest_v _ism "$1" "$2" || return 1
    printf '%s\n' "$_ism"
}
# _inputs_stage_manifest_v <var> <stage> <plugins_root> — the same, into <var>,
# in this shell (ADR-065 §5): asked through `$( )`, every lookup rebuilt the
# maps in a subshell, whose fill died with it.
_inputs_stage_manifest_v() {
    local -n _isv="$1"
    local stage="$2" plugins_root="$3"
    _isv=""
    _inputs_scan_manifests "$plugins_root"
    local safe="${stage//-/_}"
    local roles_var="_TPL_STAGE_ROLES_${safe}"
    local roles="${!roles_var:-}" role
    if [[ -n "$roles" ]]; then
        local -a rlist=()
        IFS=',' read -r -a rlist <<< "$roles"
        for role in "${rlist[@]}"; do
            [[ -z "$role" ]] && continue
            if [[ -n "${_IR_BY_ROLE[$role]:-}" ]]; then
                _isv="${_IR_BY_ROLE[$role]}"; return 0
            fi
        done
        return 1
    fi
    [[ -n "${_IR_BY_ID[$stage]:-}" ]] || return 1
    _isv="${_IR_BY_ID[$stage]}"
}
