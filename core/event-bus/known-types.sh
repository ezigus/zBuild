#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  event-bus — the known-type set, composed from engine config + manifests  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# ADR-001 §"Declared events" (#1717). `config/event-schema.json` used to
# enumerate every plugin's events, so a plugin could not register an event it
# emits without editing a file in the engine's config/ directory. It now holds
# only the engine's own namespaces; a plugin declares its events in its own
# manifest under `provides.events`, and the known set is COMPOSED here.
#
# Deliberately dependency-free (bash + awk + jq + find only). The registry is
# the natural place to read a manifest, but the event-bus cannot reach for it:
# `discover_plugins` itself emits `registry.discovery`, so composing through the
# registry would make every emit re-enter the composer. This file is therefore
# sourced by BOTH event-bus.sh and manifest-validation.sh, so the `provides.events`
# reader has exactly one implementation.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail here.

[[ -n "${_ZBUILD_EVENT_KNOWN_TYPES_LOADED:-}" ]] && return 0
_ZBUILD_EVENT_KNOWN_TYPES_LOADED=1

_ZBUILD_KNOWN_TYPES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ZBUILD_ROOT_FOR_KNOWN_TYPES="$(cd "$_ZBUILD_KNOWN_TYPES_DIR/../.." && pwd)"

# ─── eb_manifest_events <manifest> [manifest...] ────────────────────────────
# Print every event name declared under `provides:` → `events:`, one per line.
# Handles both the inline (`events: [a, b]`) and block (`- a`) list forms, and
# takes MANY manifests in ONE awk process — the whole point is that composition
# costs a fixed number of forks, not one per plugin. FNR==1 resets the parse
# state so a file that ends mid-block cannot leak into the next one.
eb_manifest_events() {
    [[ $# -gt 0 ]] || return 0
    awk '
    FNR == 1 { in_provides = 0; in_events = 0 }

    # provides: at column 0 opens the block; any other column-0 key closes it.
    /^provides:[[:space:]]*$/ { in_provides = 1; in_events = 0; next }
    in_provides && /^[a-zA-Z_]/ { in_provides = 0; in_events = 0 }

    # Inline form: events: [a.b, c.d]
    in_provides && /^[[:space:]]+events:[[:space:]]*\[/ {
        line = $0
        sub(/^[^[]*\[/, "", line)
        sub(/\].*$/, "", line)
        n = split(line, items, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", items[i])
            if (items[i] != "") print items[i]
        }
        next
    }

    # Block form: events:\n  - a.b
    in_provides && /^[[:space:]]+events:[[:space:]]*$/ {
        in_events = 1
        match($0, /^[[:space:]]+/)
        events_indent = RLENGTH
        next
    }
    in_events {
        # A `- item` indented DEEPER than `events:` is a member; anything else
        # (a sibling key, a shallower list) ends the block.
        if (match($0, /^[[:space:]]+-[[:space:]]+/) && (index($0, "-") - 1) > events_indent) {
            item = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", item)
            sub(/[[:space:]]*#.*/, "", item)
            gsub(/^["'"'"']|["'"'"']$/, "", item)
            sub(/[[:space:]]*$/, "", item)
            if (item != "") print item
            next
        }
        in_events = 0
    }
    ' "$@" 2>/dev/null
}

# ─── eb_compose_known_types [schema] [plugins_root] ─────────────────────────
# The composed set: engine-declared types + every discovered manifest's
# `provides.events`. Sorted and de-duplicated; prints nothing when neither leg
# exists (the caller treats an empty set as "permissive", exactly as a missing
# schema file behaved before).
eb_compose_known_types() {
    local schema="${1:-${ZBUILD_EVENT_SCHEMA:-${_ZBUILD_ROOT_FOR_KNOWN_TYPES}/config/event-schema.json}}"
    local root="${2:-${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT_FOR_KNOWN_TYPES}/plugins}}"
    {
        [[ -f "$schema" ]] && jq -r '.known_types[]?' "$schema" 2>/dev/null
        if [[ -d "$root" ]]; then
            local -a _manifests=()
            local _m
            while IFS= read -r _m; do
                [[ -n "$_m" ]] && _manifests+=("$_m")
            done < <(find "$root" -maxdepth 3 -name 'manifest.yaml' -type f 2>/dev/null)
            [[ ${#_manifests[@]} -gt 0 ]] && eb_manifest_events "${_manifests[@]}"
        fi
    } | sort -u
}

# ─── The in-memory set ──────────────────────────────────────────────────────
# `-g` is load-bearing: this file is sourced from inside a function on at least
# one path (event-bus.sh is itself sourced by libraries that are sourced from
# functions), and a bare `declare -A` inside a function creates a LOCAL that
# dies on return — after which bash evaluates a string subscript ARITHMETICALLY
# to 0 and every key collides. Same trap manifest-validation.sh documents for
# the yaml_get cache.
declare -gA _ZBUILD_EB_KNOWN=()
# The (schema, plugins_root) pair the loaded set was composed from. Comparing it
# on every check costs one string compare and makes a mid-process seam change
# (a test repointing ZBUILD_EVENT_SCHEMA at a fixture) recompose instead of
# silently answering from the previous root's set.
_ZBUILD_EB_KNOWN_KEY=''
# Composition counter — how many times this process paid for a compose. Read by
# tests to pin "composed once, not once per emit"; never load-bearing at runtime.
_ZBUILD_EB_COMPOSE_COUNT=0

# eb_known_types_flush — drop the in-memory set (next check recomposes).
eb_known_types_flush() {
    _ZBUILD_EB_KNOWN=()
    _ZBUILD_EB_KNOWN_KEY=''
}

# ─── The run-scoped file cache ──────────────────────────────────────────────
# A pipeline run is dozens of processes, and each one would otherwise pay the
# compose (jq + find + awk) on its first emit. The first process writes the
# composed set to the run's events dir; the rest read it back with no forks at
# all. Line 1 is the key the set was composed from, so a cache written for a
# different schema/plugins root is never mistaken for this one's.
#
# Manifests are static repo files for the duration of a run — the same
# assumption the yaml_get cache documents. A caller that rewrites a manifest
# mid-run must call eb_known_types_flush AND remove this file.
_eb_known_types_cache_path() {
    [[ -n "${ZBUILD_EVENTS_DIR:-}" ]] || return 1
    printf '%s/known-event-types.cache' "$ZBUILD_EVENTS_DIR"
}

_eb_known_types_cache_write() {
    local key="$1"; shift
    local cache; cache="$(_eb_known_types_cache_path)" || return 0
    [[ -d "$(dirname "$cache")" ]] || return 0
    # Atomic replace: concurrent stage processes read this file while another
    # writes it, and a torn read would silently drop event names.
    local tmp
    tmp="$(mktemp "${cache}.XXXXXX" 2>/dev/null)" || return 0
    {
        printf '%s\n' "$key"
        printf '%s\n' "$@"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

# ─── eb_known_types_load — populate the set once per process ────────────────
eb_known_types_load() {
    local schema="${ZBUILD_EVENT_SCHEMA:-${_ZBUILD_ROOT_FOR_KNOWN_TYPES}/config/event-schema.json}"
    local root="${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT_FOR_KNOWN_TYPES}/plugins}"
    local key="${schema}"$'\034'"${root}"
    [[ "$_ZBUILD_EB_KNOWN_KEY" == "$key" ]] && return 0

    _ZBUILD_EB_KNOWN=()
    local -a types=()
    local t

    # Fast path: a run-scoped cache composed from the same inputs.
    local cache cached_key=''
    if cache="$(_eb_known_types_cache_path)" && [[ -f "$cache" ]]; then
        local first=1
        while IFS= read -r t; do
            if [[ "$first" == 1 ]]; then cached_key="$t"; first=0; continue; fi
            [[ -n "$t" ]] && types+=("$t")
        done < "$cache"
        [[ "$cached_key" == "$key" ]] || types=()
    fi

    if [[ ${#types[@]} -eq 0 ]]; then
        while IFS= read -r t; do
            [[ -n "$t" ]] && types+=("$t")
        done < <(eb_compose_known_types "$schema" "$root")
        _ZBUILD_EB_COMPOSE_COUNT=$((_ZBUILD_EB_COMPOSE_COUNT + 1))
        [[ ${#types[@]} -gt 0 ]] && _eb_known_types_cache_write "$key" "${types[@]}"
    fi

    for t in "${types[@]}"; do
        _ZBUILD_EB_KNOWN["$t"]=1
    done
    _ZBUILD_EB_KNOWN_KEY="$key"
    return 0
}

# ─── eb_known_types_has <type> ──────────────────────────────────────────────
# 0 = known (or the composed set is empty, which stays permissive — a checkout
# with no schema and no manifests must not warn on every event).
eb_known_types_has() {
    eb_known_types_load
    [[ ${#_ZBUILD_EB_KNOWN[@]} -eq 0 ]] && return 0
    [[ -n "${_ZBUILD_EB_KNOWN[$1]:-}" ]]
}
