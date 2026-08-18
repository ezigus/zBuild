#!/usr/bin/env bash
# core/plugin-registry/manifest-router-budget.sh — a plugin's own declared
# router budget (ADR-017 §11, #1816).
#
# `timeout_s`, `max_turns` and `retries` used to resolve only from the template,
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
_ZBUILD_MANIFEST_ROUTER_KNOBS="timeout_s max_turns retries retry_on_exhaustion"

# _manifest_router_range <knob> → "<min> <max>", empty for an unknown knob.
# The ranges are the template's ranges (_tpl_validate_io_knobs), deliberately:
# one value, two places it can be written, one notion of "valid".
_manifest_router_range() {
    case "$1" in
        timeout_s) echo "1 3600" ;;   # ADR-017 (#455)
        max_turns) echo "0 200" ;;    # ADR-018 (#466); 0 = omit --max-turns (#762)
        retries)   echo "0 10" ;;     # ADR-029 (#1230); 0 = opt-out
        # #1879: retry-on-budget-exhaustion. Its own knob, NOT a widening of
        # `retries` (which is timeout/rc=124-only) — `impact` sets `retries`
        # today and its semantics must not change underneath it. Capped low: a
        # retry is only useful because the stage resumes from its checkpoint, and
        # more than a couple of attempts means the issue is too large to plan.
        retry_on_exhaustion) echo "0 5" ;;
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
    _manifest_router_block "$manifest" | awk -v knob="$knob" '
        $1 == knob { print $2; exit }
    '
}

# ─── _manifest_router_block <manifest> → "<key> <value>" per line ───────────
# The single parse of the `config:` → `router:` sub-block. Both readers go
# through this, so "which keys are declared" and "what did key K resolve to"
# can never disagree.
_manifest_router_block() {
    local manifest="${1:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    awk '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        # A trailing comment on the block header is legal YAML and is exactly
        # where a manifest explains WHY the numbers below it are what they are —
        # the reasoning this block exists to keep next to the value.
        /^config:[[:space:]]*(#.*)?$/ { in_cfg = 1; in_router = 0; next }
        # Any other column-0 key closes `config:` (and with it `router:`).
        in_cfg && /^[^[:space:]#]/ { in_cfg = 0; in_router = 0 }
        in_cfg && !in_router && /^[[:space:]]+router:[[:space:]]*(#.*)?$/ {
            in_router = 1; router_ind = indent($0); next
        }
        # A line at or shallower than `router:` ends the block; it may itself be
        # another config key, so this rule only clears the flag and falls through.
        # Comment-only lines are excluded exactly as they are for `config:`
        # above: a comment carries no indentation meaning, and treating one as a
        # block terminator would silently drop every knob declared after a
        # left-aligned comment (claude-review on PR #1870).
        in_router && /^[[:space:]]*[^[:space:]#]/ && indent($0) <= router_ind { in_router = 0 }
        in_router && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            key = line; sub(/:.*$/, "", key)
            val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
            sub(/[[:space:]]*#.*/, "", val)
            gsub(/^["'"'"']|["'"'"']$/, "", val)
            gsub(/[[:space:]]/, "", val)
            printf "%s %s\n", key, val
        }
    ' "$manifest" 2>/dev/null
}
