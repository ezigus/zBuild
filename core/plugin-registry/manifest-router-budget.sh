#!/usr/bin/env bash
# core/plugin-registry/manifest-router-budget.sh — a plugin's own declared
# router budget (ADR-017 §11, #1816).
#
# `timeout_s` and `max_turns` used to resolve only from the template,
# so a stage's budget was a property of whichever flow ran it rather than of the
# work it does. This file is the manifest half of the fix: the reader for
# `config.router.*` and the ranges that make a declaration valid.
#
# Two consumers, one parse: `validate_manifest` (the loud gate, at load) and
# `_route_manifest_knob` in core/router/route.sh (fail-safe, on the hot path).
# They must never disagree about what a manifest declares, which is why the
# block is parsed here once rather than read twice.
#
# Split from manifest-validation.sh to keep that file under the 500-line
# convention; it sources this one, so every existing reader keeps working
# unchanged. Sourced library: inherits the caller's shell options.

[[ -n "${_ZBUILD_MANIFEST_ROUTER_BUDGET_LOADED:-}" ]] && return 0
_ZBUILD_MANIFEST_ROUTER_BUDGET_LOADED=1

# The knob set is closed and mirrors the template's: anything else under
# `config.router` is a typo, and a typo'd budget is inert rather than merely
# wrong — so validate_manifest refuses it.
# #2439 (ADR-054 §6a): `retries` and `retry_on_exhaustion` are gone — a stage
# never repeats a model call; the template's per-stage `retry:` is the one retry.
_ZBUILD_MANIFEST_ROUTER_KNOBS="timeout_s max_turns"

# _manifest_router_range <knob> → "<min> <max>", empty for an unknown knob.
# The ranges are the template's ranges (_tpl_validate_io_knobs), deliberately:
# one value, two places it can be written, one notion of "valid".
_manifest_router_range() {
    case "$1" in
        timeout_s) echo "1 3600" ;;   # ADR-017 (#455)
        max_turns) echo "0 200" ;;    # ADR-018 (#466); 0 = omit --max-turns (#762)
        *)         echo "" ;;
    esac
}

# ─── manifest_router_knob <manifest> <knob> ─────────────────────────────────
# Read `config.router.<knob>` from a plugin manifest. Prints the raw value, or
# nothing when the file, the block, or the key is absent — absence is the
# common case (no plugin is required to declare anything) and must never be an
# error. Addressed BY PATH: a top-level `router:` block is a different key and
# is not read. yaml_get cannot express this — its nested form is one level deep
# (`parent.child`) and would match a `timeout_s:` at any depth under `config:`.
manifest_router_knob() {
    local manifest="${1:-}" knob="${2:-}"
    [[ -n "$manifest" && -f "$manifest" && -n "$knob" ]] || return 0
    case " $_ZBUILD_MANIFEST_ROUTER_KNOBS " in *" $knob "*) ;; *) return 0 ;; esac
    _manifest_router_block "$manifest" "$knob"
}

# ─── _manifest_router_block <manifest> [knob] → "<key> <value>" per line ─────
# The single parse of the `config:` → `router:` sub-block. Both readers go
# through this, so "which keys are declared" and "what did key K resolve to"
# can never disagree. With <knob>, it prints only that key's first value and
# stops: one awk per lookup, not a parse piped into a second (ADR-065).
_manifest_router_block() { local _mrb; _manifest_router_block_v _mrb "$@"; printf '%s' "$_mrb"; }
# _manifest_router_block_v <var> <manifest> [knob] — the same lines into <var>.
# Its locals are its own, so no <var> is hidden by one.
_manifest_router_block_v() {
    local -n _mrbo="$1"; shift
    _mrbo=""
    local manifest="${1:-}" knob="${2:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    # Read by the shell, rule for rule as the awk it replaced (ADR-065 §5):
    # this runs in the stage's own process, so no memo outlives it.
    local line rest key val lead in_cfg=0 in_router=0 router_ind=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # A trailing comment on the block header is legal YAML and is exactly
        # where a manifest explains WHY the numbers below it are what they are.
        if [[ "$line" =~ ^config:[[:space:]]*(#.*)?$ ]]; then in_cfg=1; in_router=0; continue; fi
        # Any other column-0 key closes `config:` (and with it `router:`).
        if (( in_cfg )) && [[ "$line" =~ ^[^[:space:]#] ]]; then in_cfg=0; in_router=0; fi
        if (( in_cfg && !in_router )) && [[ "$line" =~ ^[[:space:]]+router:[[:space:]]*(#.*)?$ ]]; then
            lead="${line%%[! ]*}"; in_router=1; router_ind=${#lead}; continue
        fi
        # A line at or shallower than `router:` ends the block. Comment-only
        # lines carry no indentation meaning and never end it (PR #1870).
        if (( in_router )) && [[ "$line" =~ ^[[:space:]]*[^[:space:]#] ]]; then
            lead="${line%%[! ]*}"; (( ${#lead} <= router_ind )) && in_router=0
        fi
        if (( in_router )) && [[ "$line" =~ ^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*: ]]; then
            rest="${line#"${line%%[![:space:]]*}"}"
            key="${rest%%:*}"
            val="${rest#*:}"; val="${val#"${val%%[![:space:]]*}"}"
            if [[ "$val" == *#* ]]; then val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}"; fi
            val="${val#[\"\']}"; val="${val%[\"\']}"
            val="${val//[[:space:]]/}"
            if [[ -n "$knob" ]]; then
                [[ "$key" == "$knob" ]] && { _mrbo="$val"$'\n'; return 0; }
                continue
            fi
            _mrbo+="$key $val"$'\n'
        fi
    done 2>/dev/null < "$manifest"
    return 0
}
