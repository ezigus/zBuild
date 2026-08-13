#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — manifest YAML parsing + schema/identity/hook validation ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Split from registry.sh (#364). Owns the manifest layer: minimal YAML readers
# (yaml_get / yaml_get_list / _yaml_get_requires_core_list), the kind table
# (ZBUILD_PLUGIN_KINDS / _required_hooks_for_kind), and validate_manifest.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.

[[ -n "${_ZBUILD_REGISTRY_MANIFEST_LOADED:-}" ]] && return 0
_ZBUILD_REGISTRY_MANIFEST_LOADED=1

# The engine's declared result-contract range (#1824). Sourced, not duplicated —
# validate_manifest refuses a plugin whose declared contract falls outside it.
_ZBUILD_MANIFEST_VALIDATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../contract/version.sh
source "$_ZBUILD_MANIFEST_VALIDATION_DIR/../contract/version.sh"

# ─── Valid plugin kinds ─────────────────────────────────────────────────────
# `persona` (#1304) is a DATA-only kind: identity metadata (role + perspective),
# no plugin.sh and no hooks. See _required_hooks_for_kind (returns "" for it) and
# the persona.role requirement in validate_manifest.
ZBUILD_PLUGIN_KINDS=(agent tool recovery orchestrator claim-coordinator daemon persona)

# ─── yaml_get memoization (#1614) ───────────────────────────────────────────
# yaml_get spawned one awk per lookup and was called 6,338 times per pipeline
# run — 12.97s of a 27s run. The cache is process-scoped: manifests are static
# repo files and never change during a run.
#
# TWO arrays, not one packed string: a YAML value may legitimately contain any
# delimiter we might pick (a real manifest carries `a|b`), so there is nothing
# safe to join on.
#
# Values are cached for the process lifetime with NO mtime check. That is
# deliberate: a stamp read once and never re-compared is decorative invalidation
# — worse than none, because the next reader trusts it. Callers that deliberately
# rewrite a manifest mid-process must call yaml_cache_flush. ZBUILD_YAML_CACHE=0
# disables the cache entirely.
#
# Keys are full paths, so two plugins roots in one process (a fixture root plus
# the live tree — see tests/unit/persona-resolver-test.sh) can never collide.
# `-g` is load-bearing, not decoration: this file is sourced from INSIDE a
# function in at least one path (scripts/lib/manifest-graph.sh:289,
# _manifest_graph_ensure_yaml_get), and a bare `declare -A` inside a function
# creates a LOCAL that dies when that function returns. The arrays would then be
# undeclared at assignment time, where bash evaluates a string subscript
# ARITHMETICALLY to 0 — so every key would collide at index 0 and yaml_get would
# hand back some other key's value. Caught by
# tests/unit/runner-post-stage-capability-test.sh SPEC-2a/2b.
declare -gA _ZBUILD_YAML_OUT=()
declare -gA _ZBUILD_YAML_RC=()

# yaml_cache_flush [file] — drop cached entries for <file>, or the whole cache.
yaml_cache_flush() {
    if [[ -n "${1:-}" ]]; then
        local k
        for k in "${!_ZBUILD_YAML_RC[@]}"; do
            if [[ "$k" == "$1"$'\034'* ]]; then
                unset "_ZBUILD_YAML_RC[$k]" "_ZBUILD_YAML_OUT[$k]"
            fi
        done
    else
        _ZBUILD_YAML_OUT=()
        _ZBUILD_YAML_RC=()
    fi
}

# The key vocabulary the engine actually asks for — what prewarm populates.
# An unlisted key still works; it just takes the lazy path on first use.
_ZBUILD_YAML_PREWARM_KEYS=(
    id name kind version summary platform
    persona.role persona.perspective
    hooks.run hooks.cleanup
    provides.role provides.artifact_type provides.result_contract
)

# yaml_cache_prewarm [plugins_root] — fill the cache IN THE CALLING SHELL.
# This must run in the parent: 56 of 82 yaml_get call sites sit inside $( ), and
# an associative-array write inside a command substitution dies with the
# subshell — so a lazily-filled cache is never inherited and would save nothing.
# Prewarming calls the real reader rather than a bulk re-implementation, so
# equivalence is by construction and there is no second parser to keep in sync
# (yaml_get has quirks worth preserving: a block scalar returns the literal `|`).
# Cost: ~46 manifests x ~14 keys of awk once, versus 6,338 lookups per run.
# NOTE the process-substitution `< <(...)` — a pipe would put the loop body in a
# subshell and silently discard every cache write.
yaml_cache_prewarm() {
    [[ "${ZBUILD_YAML_CACHE:-1}" == "1" ]] || return 0
    local root="${1:-${ZBUILD_PLUGINS_ROOT:-${_ZBUILD_ROOT:-.}/plugins}}"
    [[ -d "$root" ]] || return 0
    local manifest key
    while IFS= read -r manifest; do
        for key in "${_ZBUILD_YAML_PREWARM_KEYS[@]}"; do
            yaml_get "$manifest" "$key" >/dev/null 2>&1
        done
    done < <(find "$root" -maxdepth 3 -name 'manifest.yaml' -type f 2>/dev/null)
}

# ─── yaml_get — minimal YAML reader (we control the schema; no full parser) ─
# Usage: yaml_get <yaml_file> <dotted_key>
# Supports: top-level scalars, single-level nested (e.g., hooks.init).
# Lists / multi-line scalars handled by yaml_get_list.
# Memoized (see above); _yaml_get_uncached holds the parsing itself.
yaml_get() {
    local file="$1" key="$2"
    if [[ "${ZBUILD_YAML_CACHE:-1}" != "1" ]]; then
        _yaml_get_uncached "$file" "$key"
        return $?
    fi
    local ck="${file}"$'\034'"${key}"
    if [[ -n "${_ZBUILD_YAML_RC[$ck]+set}" ]]; then
        printf '%s' "${_ZBUILD_YAML_OUT[$ck]}"
        return "${_ZBUILD_YAML_RC[$ck]}"
    fi
    # The \034 sentinel preserves BOTH the exact trailing bytes and the exit
    # status in one capture, with no extra fork. Needed because the observable
    # contract distinguishes three cases that `v="$(...)"` alone would flatten:
    # missing file -> rc=2 + 0 bytes; missing key -> rc=0 + 0 bytes;
    # a present-but-empty value (`key:`) -> rc=0 + exactly one newline.
    # `set +e` here is belt-and-braces, scoped to this subshell only (the caller's
    # errexit is untouched). It guarantees the sentinel printf runs even if a
    # future change makes the reader's failure trip errexit inside the capture.
    # Measured, so the comment does not overclaim: with and without it, cached and
    # uncached agree exactly under `set -euo pipefail` — a caught failure
    # (`if yaml_get …` / `… || rc=$?`) yields rc=2 either way, and a BARE
    # `v="$(yaml_get missing)"` terminates the caller either way, because under
    # errexit an assignment from a failing command substitution is itself fatal.
    # That last part is pre-existing bash behaviour, not something this cache
    # introduced. SPEC-11 pins the parity.
    local raw rc
    raw="$(set +e; _yaml_get_uncached "$file" "$key"; printf '\034%s' "$?")"
    rc="${raw##*$'\034'}"
    raw="${raw%$'\034'*}"
    # Defensive: `return` on a non-numeric is fatal. Unreachable while the
    # sentinel always fires; costs nothing to guarantee.
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=0
    _ZBUILD_YAML_OUT[$ck]="$raw"
    _ZBUILD_YAML_RC[$ck]="$rc"
    printf '%s' "$raw"
    return "$rc"
}

_yaml_get_uncached() {
    local file="$1"
    local key="$2"
    if [[ "$key" == *.* ]]; then
        # Nested key like hooks.init: find "<parent>:" then indented "<child>:"
        local parent="${key%.*}"
        local child="${key#*.}"
        awk -v parent="$parent" -v child="$child" '
        $0 ~ "^"parent":" { in_block = 1; next }
        in_block && /^[a-zA-Z_]/ { in_block = 0 }
        in_block && $0 ~ "^[[:space:]]+"child":" {
            sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null
    else
        # Top-level scalar
        awk -v key="$key" '
        $0 ~ "^"key":" {
            sub(/^[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
        ' "$file" 2>/dev/null
    fi
}

# ─── yaml_get_list — extract a simple list value (inline or multi-line) ─────
# Usage: yaml_get_list <yaml_file> <key>
# Handles: key: [a, b, c]  OR  key:\n  - a\n  - b
yaml_get_list() {
    local file="$1"
    local key="$2"
    awk -v key="$key" '
    $0 ~ "^"key":[[:space:]]*\\[" {
        sub(/^[^[]*\[/, "")
        sub(/\].*$/, "")
        n = split($0, items, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", items[i])
            if (items[i] != "") print items[i]
        }
        exit
    }
    $0 ~ "^"key":[[:space:]]*$" { in_list = 1; next }
    in_list && /^[[:space:]]*-[[:space:]]/ {
        item = $0
        gsub(/^[[:space:]]*-[[:space:]]*/, "", item)
        gsub(/[[:space:]]*#.*/, "", item)
        gsub(/^["'"'"']|["'"'"']$/, "", item)
        gsub(/[[:space:]]*$/, "", item)
        if (item != "") print item
    }
    in_list && /^[a-zA-Z_]/ { exit }
    ' "$file" 2>/dev/null
}

# ─── _yaml_get_requires_core_list — parse requires: → core: list ────────────
# Emits one core item per line. Structurally parses ONLY the `requires:` →
# `core:` sub-block — so a stray `- redaction` outside that block does NOT
# satisfy the membership check (closes the #294 bypass surface).
# Handles both inline `core: [a, b]` and multi-line:
#   requires:
#     core:
#       - a
#       - b
_yaml_get_requires_core_list() {
    local file="$1"
    awk '
        # Find requires: block at column 0
        /^requires:[[:space:]]*$/ { in_requires = 1; next }
        # Exit requires: block if we hit another top-level key
        in_requires && /^[a-zA-Z_]/ { in_requires = 0 }

        # Inside requires, find core:
        in_requires && /^[[:space:]]+core:[[:space:]]*\[/ {
            # Inline list: core: [a, b, c]
            line = $0
            sub(/^[^[]*\[/, "", line)
            sub(/\].*$/, "", line)
            n = split(line, items, /,[[:space:]]*/)
            for (i = 1; i <= n; i++) {
                gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", items[i])
                if (items[i] != "") print items[i]
            }
            in_requires = 0
            exit
        }
        in_requires && /^[[:space:]]+core:[[:space:]]*$/ {
            in_core = 1
            # Compute the indent depth of the `-` items: must be deeper than
            # the indent of `core:` itself.
            match($0, /^[[:space:]]+/)
            core_indent = RLENGTH
            next
        }
        # While inside core block, accept `<deeper-indent> - <item>` lines.
        in_core {
            if (match($0, /^[[:space:]]+-[[:space:]]+/)) {
                # Verify the indent is deeper than core: indent.
                indent_len = index($0, "-") - 1
                if (indent_len > core_indent) {
                    item = $0
                    gsub(/^[[:space:]]*-[[:space:]]*/, "", item)
                    gsub(/[[:space:]]*#.*/, "", item)
                    gsub(/^["'"'"']|["'"'"']$/, "", item)
                    gsub(/[[:space:]]*$/, "", item)
                    if (item != "") print item
                }
                next
            }
            # Any other content at the same or shallower indent ends the block.
            in_core = 0
        }
    ' "$file" 2>/dev/null
}

# ─── manifest router budget — ADR-017 §11 (#1816) ───────────────────────────
# A plugin declares its own resource needs in `config.router.*`, alongside the
# `config.tier_default` precedent. The knob set is closed and mirrors the
# template's: anything else under that block is a typo, and a typo'd budget is
# inert rather than merely wrong — so the validator refuses it.
#
# The ranges are the template's ranges (_tpl_validate_io_knobs), deliberately:
# one value, two places it can be written, one notion of "valid".
_ZBUILD_MANIFEST_ROUTER_KNOBS="timeout_s max_turns retries"

# _manifest_router_range <knob> → "<min> <max>", empty for an unknown knob.
_manifest_router_range() {
    case "$1" in
        timeout_s) echo "1 3600" ;;   # ADR-017 (#455)
        max_turns) echo "0 200" ;;    # ADR-018 (#466); 0 = omit --max-turns (#762)
        retries)   echo "0 10" ;;     # ADR-029 (#1230); 0 = opt-out
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
# The single parse of the `config:` → `router:` sub-block. Both readers above
# it (the accessor and the validator) go through this, so "which keys are
# declared" and "what did key K resolve to" can never disagree.
_manifest_router_block() {
    local manifest="${1:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    awk '
        function indent(s,   i) { i = 0; while (substr(s, i+1, 1) == " ") i++; return i }
        /^config:[[:space:]]*$/ { in_cfg = 1; in_router = 0; next }
        # Any other column-0 key closes `config:` (and with it `router:`).
        in_cfg && /^[^[:space:]#]/ { in_cfg = 0; in_router = 0 }
        in_cfg && !in_router && /^[[:space:]]+router:[[:space:]]*$/ {
            in_router = 1; router_ind = indent($0); next
        }
        # A line at or shallower than `router:` ends the block; it may itself be
        # another config key, so this rule only clears the flag and falls through.
        in_router && /[^[:space:]]/ && indent($0) <= router_ind { in_router = 0 }
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

# ─── _required_hooks_for_kind — ADR-001 §"Required hooks per kind" ──────────
# Returns space-separated required hook names for the given plugin kind.
# Empty output = "no specifically required hooks" (still allow cleanup).
_required_hooks_for_kind() {
    case "$1" in
        agent)             echo "run" ;;
        tool)              echo "run" ;;
        recovery)          echo "classify act" ;;
        orchestrator)      echo "run" ;;
        claim-coordinator) echo "claim release heartbeat list_claims" ;;
        daemon)            echo "tick" ;;
        *)                 echo "" ;;
    esac
}

# ─── validate_manifest ──────────────────────────────────────────────────────
# Checks required fields, kind validity, kind-specific hook presence, and the
# ADR-004 redaction requirement for agent plugins. Returns 0 if valid, 1 if not.
# Issues #287, #294: expands beyond the original 4-field check.
validate_manifest() {
    local manifest="$1"
    local errors=0

    if [[ ! -f "$manifest" ]]; then
        error "validate_manifest: file not found: $manifest"
        return 1
    fi

    for field in id name kind version; do
        local val; val="$(yaml_get "$manifest" "$field")"
        if [[ -z "$val" ]]; then
            error "validate_manifest($manifest): missing required field: $field"
            errors=$((errors + 1))
        fi
    done

    local kind; kind="$(yaml_get "$manifest" "kind")"
    if [[ -n "$kind" ]]; then
        local valid=0
        for k in "${ZBUILD_PLUGIN_KINDS[@]}"; do
            [[ "$k" == "$kind" ]] && valid=1
        done
        if [[ "$valid" -eq 0 ]]; then
            error "validate_manifest($manifest): invalid kind: $kind (expected one of: ${ZBUILD_PLUGIN_KINDS[*]})"
            errors=$((errors + 1))
        fi
    fi

    # kind: agent plugins MUST declare requires.core includes redaction (ADR-004 enforcement)
    # Structural check via _yaml_get_requires_core_list — a `- redaction` line
    # outside `requires.core` no longer satisfies this (closes #294 bypass).
    if [[ "$kind" == "agent" ]]; then
        local core_items; core_items="$(_yaml_get_requires_core_list "$manifest")"
        if ! grep -Fxq "redaction" <<< "$core_items"; then
            error "validate_manifest($manifest): kind: agent plugins MUST declare 'redaction' inside requires.core (got: $(echo "$core_items" | tr '\n' ',' | sed 's/,$//'))"
            errors=$((errors + 1))
        fi
    fi

    # kind: persona plugins (#1304) are DATA — a professional identity, no
    # plugin.sh and no hooks. They MUST declare a non-empty persona.role: the
    # noun phrase that slots into the stage/lens framing ("You are {role} …").
    # kind:persona is intentionally exempt from the kind:agent redaction check
    # above — persona text is redaction-covered at injection by the router
    # (ADR-043), not by the plugin declaring requires.core.redaction.
    if [[ "$kind" == "persona" ]]; then
        local _block_scalar_re='^[>|][-+]?$'
        local persona_role; persona_role="$(yaml_get "$manifest" "persona.role")"
        if [[ -z "$persona_role" ]]; then
            error "validate_manifest($manifest): kind: persona requires a non-empty 'persona.role' (the noun phrase for 'You are {role} for the target project.')"
            errors=$((errors + 1))
        elif [[ "$persona_role" =~ $_block_scalar_re ]]; then
            error "validate_manifest($manifest): 'persona.role' must be a single-line string, not a block scalar ('$persona_role'); use a plain value on the same line as the key"
            errors=$((errors + 1))
        fi
        local persona_perspective; persona_perspective="$(yaml_get "$manifest" "persona.perspective")"
        if [[ -z "$persona_perspective" ]]; then
            error "validate_manifest($manifest): kind: persona requires a non-empty 'persona.perspective' (#1569 — the behavior injected into the stage prompt). A persona with a role but no perspective is indistinguishable from an absent persona at the seam, so it is rejected loudly here."
            errors=$((errors + 1))
        elif [[ "$persona_perspective" =~ $_block_scalar_re ]]; then
            error "validate_manifest($manifest): 'persona.perspective' must be a single-line string, not a block scalar ('$persona_perspective'); use a plain value on the same line as the key"
            errors=$((errors + 1))
        fi
    fi

    # ─── #1824: result-contract version negotiation ─────────────────────────
    # A plugin declares which result contract it writes; the engine declares the
    # range it can read (core/contract/version.sh). Refused HERE, at load, so an
    # unreadable plugin cannot register — not at dispatch, where the run has
    # already paid for the stage and the misread looks like a bad result rather
    # than an unspeakable one. Never a warning: a version the engine cannot read
    # means every verdict it produces is uninterpretable.
    #
    # NB `provides.result_contract`, NOT `provides.schema_version` — the latter
    # is taken and versions the ARTIFACT's own schema, independently per artifact
    # type (build-summary.json is at 4, #602). Same distinction verdict.sh:209
    # draws for the result file's own key.
    # Checked UNCONDITIONALLY — an absent declaration is a declaration of v1, and
    # it has to travel the same path as a stated one. Short-circuiting on empty
    # looks equivalent today (v1 is in range, so both accept) and stops being
    # equivalent the moment #1850 raises the floor: the undeclared plugins are
    # exactly the ones that must then be refused, and a guard here would wave
    # every one of them through while the declared stragglers got caught. That
    # would make the acceptance — "an absent version becomes a structural failure
    # when the v1 reader is dropped" — quietly false, and #1850 would no longer
    # be a one-line change. contract_version_check owns the absent case.
    local _decl_contract
    _decl_contract="$(yaml_get "$manifest" "provides.result_contract" 2>/dev/null || true)"
    local _pid_c; _pid_c="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
    local _msg
    if ! _msg="$(contract_version_check "$_decl_contract" "plugin '${_pid_c:-unknown}'")"; then
        error "validate_manifest($manifest): $_msg"
        errors=$((errors + 1))
    fi

    # ─── #287/#294: hooks per kind ──────────────────────────────────────────
    # Every kind-required hook must be declared in the manifest's hooks: block.
    # Backend plugins (those declaring `provides.role`) are invoked through
    # contract layers (cache_pull, memory_put, etc.) — not plugin_hook_call —
    # so they don't need lifecycle hooks. The check skips when role is set.
    if [[ -n "$kind" ]]; then
        local provides_role; provides_role="$(yaml_get "$manifest" "provides.role" 2>/dev/null || true)"
        if [[ -z "$provides_role" ]]; then
            local required_hooks; required_hooks="$(_required_hooks_for_kind "$kind")"
            if [[ -n "$required_hooks" ]]; then
                local plugin_id_for_err; plugin_id_for_err="$(yaml_get "$manifest" "id" 2>/dev/null || true)"
                local h
                for h in $required_hooks; do
                    local fn; fn="$(yaml_get "$manifest" "hooks.$h" 2>/dev/null || true)"
                    if [[ -z "$fn" ]]; then
                        error "validate_manifest: plugin '${plugin_id_for_err:-unknown}' (kind: $kind) requires hook '$h' (declare under hooks: in the manifest)"
                        errors=$((errors + 1))
                    fi
                done
            fi
        fi
    fi

    # ─── #287/#294: requires.core must be a YAML-structured list ────────────
    # Detect malformed `requires.core: redaction` (scalar instead of list).
    # Scoped to the requires: block so an unrelated `core:` line elsewhere
    # in the manifest doesn't falsely trigger.
    local has_requires
    has_requires="$(awk '/^requires:[[:space:]]*$/{print "y"; exit}' "$manifest")"
    if [[ "$has_requires" == "y" ]]; then
        local scalar_core
        scalar_core="$(awk '
            /^requires:[[:space:]]*$/ { in_req = 1; next }
            in_req && /^[a-zA-Z_]/ { in_req = 0 }
            in_req && /^[[:space:]]+core:[[:space:]]*[^[[:space:]]/ {
                # core: has non-whitespace, non-[ content on the same line.
                # Inline list is OK (handled by _yaml_get_requires_core_list)
                # but a bare scalar (e.g. `core: redaction`) is rejected.
                if ($0 !~ /^[[:space:]]+core:[[:space:]]*\[/) {
                    print "bad"
                    exit
                }
            }
        ' "$manifest")"
        if [[ "$scalar_core" == "bad" ]]; then
            error "validate_manifest($manifest): requires.core must be a YAML list (use 'core: [redaction, ...]' or '  - redaction')"
            errors=$((errors + 1))
        fi
    fi

    # ─── Optional doc fields: summary + usage ────────────────────────────────
    # If declared, each must be a non-empty string. Absent = fine; present-but-
    # empty = misconfiguration (declared doc field with no content).
    #
    # Presence + value are resolved in ONE awk pass with a LITERAL, TOP-LEVEL
    # match: `index($0, key":")==1` is true only when the line begins with the
    # exact key at column 0 — so it never matches an indented/nested key or a
    # line inside a block scalar, and (being index(), not a regex) the field
    # name is never interpreted as a pattern. Emits OK / EMPTY / (nothing).
    local doc_field doc_state
    for doc_field in summary usage; do
        doc_state="$(awk -v k="$doc_field" '
            index($0, k":") == 1 {
                v = $0
                sub(/^[^:]*:[[:space:]]*/, "", v)   # strip "key:" + leading ws
                sub(/[[:space:]]*#.*/, "", v)        # strip trailing comment
                gsub(/^["'"'"']|["'"'"']$/, "", v)   # strip surrounding quotes
                print (v == "" ? "EMPTY" : "OK")
                exit
            }
        ' "$manifest" 2>/dev/null)"
        if [[ "$doc_state" == "EMPTY" ]]; then
            error "validate_manifest($manifest): '$doc_field' is declared but empty (must be a non-empty string)"
            errors=$((errors + 1))
        fi
    done

    # ─── Optional config.router budget block — ADR-017 §11 (#1816) ──────────
    # A declared budget is load-bearing at dispatch, so it is checked here
    # rather than at read time: the resolver ignores anything it cannot use,
    # and an ignored budget is a stage silently running on the wrong one.
    local _rk _rv _rrange
    while read -r _rk _rv; do
        [[ -n "$_rk" ]] || continue
        _rrange="$(_manifest_router_range "$_rk")"
        if [[ -z "$_rrange" ]]; then
            error "validate_manifest($manifest): unknown key '$_rk' under config.router (valid: $_ZBUILD_MANIFEST_ROUTER_KNOBS)"
            errors=$((errors + 1))
            continue
        fi
        local _min="${_rrange% *}" _max="${_rrange#* }"
        if ! [[ "$_rv" =~ ^[0-9]+$ ]] || [[ "$_rv" -lt "$_min" ]] || [[ "$_rv" -gt "$_max" ]]; then
            error "validate_manifest($manifest): config.router.$_rk must be an integer in $_min..$_max, got: ${_rv:-<empty>}"
            errors=$((errors + 1))
        fi
    done < <(_manifest_router_block "$manifest")

    return $((errors > 0))
}
