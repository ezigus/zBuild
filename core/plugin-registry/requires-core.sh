#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  plugin-registry — requires.core vocabulary + resolution (#2065)           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# `requires.core` used to be validated as TEXT and never resolved: the only
# checks were "a kind: agent list contains the literal string redaction" and
# "the block is a YAML list". Nothing mapped an entry to a module, so a plugin
# could declare the router and load nothing and still be dispatched — which is
# exactly what test-author, spec-coverage and spec-correspondence did for months
# (#2060/#2061/#2062), reporting the absence as a degraded verdict rather than
# as the contract violation it was.
#
# This file is the one place the vocabulary and its resolution rules live, so
# the validator, the guard test and any future linter cannot disagree about
# what a declaration means.
#
# Depends on `yaml_get` / `_yaml_get_requires_core_list` from manifest-validation.sh,
# which sources this file — the same facade arrangement lifecycle.sh uses. Both
# are called from function bodies only, never at source time, so the load order
# between the two files does not matter.
# Sourced library: inherits caller's pipefail settings; do not add set -euo pipefail.
#
# ─── Why resolution is STATIC and at LOAD, not a runtime marker assertion ────
# The obvious shape — `declare -F <marker>` inside plugin_hook_call right after
# `source "$plugin_sh"` — is a TAUTOLOGY for half the vocabulary on this engine.
# core/pipeline/runner.sh sources core/event-bus/event-bus.sh and all five
# core/state/*.sh into the ENGINE shell before any stage runs, and
# plugin_hook_call dispatches in a SUBSHELL of that shell, which inherits them.
# The assertion would pass whether or not the plugin loaded anything, and would
# additionally bless plugins that quietly depend on ambient engine functions.
# tests/unit/requires-core-resolution-test.sh SPEC-8 pins that measurement, so
# if the engine ever stops pre-loading them this reasoning fails loudly instead
# of rotting. Resolution therefore runs in validate_manifest — the gate
# discovery.sh:48 already applies to every plugin — where an unsatisfiable
# declaration stops the plugin registering.
#
# ─── The three classes, and why the vocabulary is not uniform ───────────────
#   plugin-loaded  The engine does NOT pre-load it; the plugin must source it.
#                  Falsifiable directly. Only `router`.
#   conditional    Required only on a model-reaching path. Only `redaction`:
#                  ADR-004 makes the DECLARATION mandatory for every kind:agent
#                  as a policy statement, while ADR-043 §Consequences says a new
#                  LLM stage sources route.sh and writes "no scope-redaction.sh
#                  source, no apply_scope_redaction call". ADR-004's own intake
#                  note records the same for a stage that emits no LLM-bound
#                  text. Demanding a literal load would force deploy, validate
#                  and review-aggregator — three plugins documented as making no
#                  LLM calls — to source a redactor they must never invoke.
#   engine-ambient The engine pre-loads it before dispatch, so the declaration
#                  is satisfied by construction and a plugin-side source line is
#                  optional. `event-bus` and `state`.
#
# ─── The recorded decision on `state` (#2065 DoD) ───────────────────────────
# `state` KEEPS its place in the vocabulary and is classed engine-ambient. It
# gets no marker function. The alternatives were both worse:
#   - Give it a marker. There is no single one: it is five files
#     (atomic/layout/resume/artifact-persist/issue-lock) exporting five
#     unrelated function families. Any single pick is arbitrary, and 24 of the
#     26 plugins declaring `state` source none of them — a marker rule reports
#     almost the whole tree broken while nothing is actually wrong.
#   - Drop it from the vocabulary. That edits 24 manifests to delete a true
#     statement: those plugins DO run against engine state.
# Classing it ambient keeps the declaration honest and moves the falsifiable
# part to where it actually lives — the ENGINE side. SPEC-8 asserts runner.sh
# sources all five; if one is dropped, the ambience claim is false and the test
# says so, instead of 24 manifests quietly becoming fiction.
# Known limit, deliberately not papered over: the `map:` work unit
# (core/pipeline/strategies/common.sh) sources event-bus but NOT core/state, so
# `state` ambience does not hold on that arm. No map-dispatched plugin calls a
# state function today, so this is a latent gap rather than a live defect; it is
# reported rather than fixed here because closing it means changing the map
# preamble, which is outside this issue.

[[ -n "${_ZBUILD_REQUIRES_CORE_LOADED:-}" ]] && return 0
_ZBUILD_REQUIRES_CORE_LOADED=1

# ─── The table ──────────────────────────────────────────────────────────────
# One row per entry: <entry>|<class>|<marker>|<provider>[,<provider>...]
# Providers are repo-relative. Sourcing ANY of them satisfies the entry, which
# is how the transitive case is expressed: route.sh sources scope-redaction.sh
# by construction (ADR-043), so it PROVIDES `redaction` as well as `router`.
# That edge is not taken on trust — SPEC-7 asserts route.sh really does source
# it, because the leniency is only sound while it holds.
_ZBUILD_REQUIRES_CORE_TABLE=(
    "router|plugin-loaded|route_to_model|core/router/route.sh"
    "redaction|conditional|apply_scope_redaction|core/router/route.sh,core/redaction/scope-redaction.sh"
    "event-bus|engine-ambient|eb_emit_event|core/event-bus/event-bus.sh"
    "state|engine-ambient||core/state/atomic.sh,core/state/layout.sh,core/state/resume.sh,core/state/artifact-persist.sh,core/state/issue-lock.sh"
)

_requires_core_row() {
    local want="${1:-}" row
    for row in "${_ZBUILD_REQUIRES_CORE_TABLE[@]}"; do
        [[ "${row%%|*}" == "$want" ]] && { printf '%s' "$row"; return 0; }
    done
    return 1
}

# requires_core_vocabulary — the accepted entries, one per line.
requires_core_vocabulary() {
    local row
    for row in "${_ZBUILD_REQUIRES_CORE_TABLE[@]}"; do printf '%s\n' "${row%%|*}"; done
}

# requires_core_class <entry> — plugin-loaded | conditional | engine-ambient.
# Empty output + rc 1 for an entry outside the vocabulary.
requires_core_class() {
    local row; row="$(_requires_core_row "${1:-}")" || return 1
    row="${row#*|}"; printf '%s\n' "${row%%|*}"
}

# requires_core_marker <entry> — the function whose presence proves the module
# loaded. Empty for `state`, which is five files with no single marker.
requires_core_marker() {
    local row; row="$(_requires_core_row "${1:-}")" || return 1
    row="${row#*|}"; row="${row#*|}"; printf '%s\n' "${row%%|*}"
}

# requires_core_providers <entry> — repo-relative paths, one per line.
requires_core_providers() {
    local row; row="$(_requires_core_row "${1:-}")" || return 1
    printf '%s\n' "${row##*|}" | tr ',' '\n'
}

# ─── _requires_core_code <file> — the file with comments removed ────────────
# Two substitutions, not a character walk: drop a whole-line comment, then drop
# a trailing one introduced by whitespace. Anchoring on whitespace is what keeps
# `$#` and `${#arr[@]}` — where `#` follows `$` or `{` — out of it. Known limit,
# shared with the #2063 guard: a `#` inside a quoted string truncates the line
# early, which can only ever HIDE a call, never invent one.
_requires_core_code() {
    sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1" 2>/dev/null
}

# _requires_core_sources <file> <provider> — rc 0 when <file> has a real source
# line naming <provider>. Comment-stripped first, so a bare `# shellcheck
# source=` directive never counts as the real thing (the exact false accept the
# #2063 guard's SPEC-6 fixture exists to rule out).
#
# The provider is interpolated into an ERE with only `.` escaped. Every other
# metacharacter would be interpreted — harmless for the four plain
# `core/<dir>/<file>.sh` paths in the table, and wrong the moment one contains
# `+ ? * [ ] ( ) { } | ^ $ \`. The input is GUARDED rather than the pattern
# escaped, and that is a choice, not an oversight: a correct escape needs a
# `sed` subshell per provider per plugin on the discovery hot path (the path
# yaml_get is memoised to keep cheap — 6,338 spawns cost 12.97s of a 27s run),
# or a pipe, which is the SIGPIPE-under-pipefail shape that already bit this
# repo (#1015), or a dozen lines of parameter-expansion chaining. The table is
# engine-internal and only we edit it, so requires-core-resolution-test.sh
# SPEC-9 asserts every provider path matches ^[A-Za-z0-9_/.-]+$ instead. If a
# future provider needs a metacharacter, that assertion fails loudly and the
# escaping gets written then.
_requires_core_sources() {
    local code; code="$(_requires_core_code "$1")"
    grep -qE "^[[:space:]]*(source|\.)[[:space:]]+.*${2//./\\.}([\"'[:space:]]|$)" <<<"$code"
}

# _requires_core_reaches_model <file> — rc 0 when route_to_model survives
# comment stripping. Substring, not whole word: route_to_model_loop is the same
# function from the same file, and build/design reach the model only through it.
_requires_core_reaches_model() {
    local code; code="$(_requires_core_code "$1")"
    grep -qF 'route_to_model' <<<"$code"
}

# ─── requires_core_unresolved <plugin_dir> ──────────────────────────────────
# The resolver. Prints one `<entry><TAB><reason>` line per declared entry that
# cannot be satisfied, and returns 1 if there were any.
#
# A plugin with no plugin.sh is not skipped: kind:persona manifests are DATA,
# and one declaring `router` would be a manifest bug worth naming rather than
# waving through. Ambient entries still resolve for them.
requires_core_unresolved() {
    local plugin_dir="${1:-}"
    local manifest="$plugin_dir/manifest.yaml"
    [[ -f "$manifest" ]] || return 0

    local entries; entries="$(_yaml_get_requires_core_list "$manifest")"
    [[ -n "$entries" ]] || return 0

    # Providers are stated repo-relative and matched against the TEXT of the
    # source line, so this never resolves a repo root — a plugin's source line
    # names the path however its own root variable spells it. Whether that path
    # resolves to a real file on disk is #2063's SPEC-5, deliberately not
    # re-asked here; the table's own paths are checked by this file's SPEC-9.
    local plugin_sh="$plugin_dir/plugin.sh"

    local found=0 entry class prov satisfied prov_list
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue

        if ! class="$(requires_core_class "$entry")"; then
            printf '%s\tis not a core module (accepted: %s)\n' \
                "$entry" "$(requires_core_vocabulary | tr '\n' ' ' | sed 's/ $//')"
            found=1
            continue
        fi

        # The engine pre-loads it; the declaration is true without a source line.
        [[ "$class" == "engine-ambient" ]] && continue

        # `redaction` binds only on a path that actually reaches a model.
        if [[ "$class" == "conditional" ]]; then
            [[ -f "$plugin_sh" ]] || continue
            _requires_core_reaches_model "$plugin_sh" || continue
        fi

        satisfied=0
        prov_list=""
        while IFS= read -r prov; do
            [[ -n "$prov" ]] || continue
            prov_list="${prov_list:+$prov_list or }$prov"
            [[ -f "$plugin_sh" ]] && _requires_core_sources "$plugin_sh" "$prov" && satisfied=1
        done < <(requires_core_providers "$entry")

        if [[ "$satisfied" -eq 0 ]]; then
            if [[ ! -f "$plugin_sh" ]]; then
                printf '%s\tis declared but the plugin has no plugin.sh to load it from\n' "$entry"
            else
                printf '%s\tis declared but plugin.sh never sources %s\n' "$entry" "$prov_list"
            fi
            found=1
        fi
    done <<< "$entries"

    return "$found"
}

# ─── requires_core_check <manifest> ─────────────────────────────────────────
# The single entry point validate_manifest calls. Prints one
# `<entry><TAB><reason>` line per problem; rc 1 if there were any.
#
# It carries the ADR-004 declaration requirement as well as resolution, so
# there is ONE requires.core site in the validator rather than a hardcoded
# string grep alongside a resolver that disagrees with it. The declaration rule
# is unchanged and deliberately unweakened — every kind:agent still MUST name
# `redaction`, and CLAUDE.md's "no exceptions" stands. What is new is that
# naming it is no longer sufficient: if the plugin reaches a model, a redactor
# must be on its source path (directly, or via route.sh per ADR-043).
requires_core_check() {
    local manifest="${1:-}"
    [[ -f "$manifest" ]] || return 0
    local plugin_dir; plugin_dir="$(dirname "$manifest")"
    local found=0

    local kind; kind="$(yaml_get "$manifest" "kind" 2>/dev/null || true)"
    if [[ "$kind" == "agent" ]]; then
        local declared; declared="$(_yaml_get_requires_core_list "$manifest")"
        if ! grep -Fxq "redaction" <<< "$declared"; then
            printf 'redaction\tis MUST for kind: agent and is not declared inside requires.core (ADR-004; got: %s)\n' \
                "$(echo "$declared" | tr '\n' ',' | sed 's/,$//')"
            found=1
        fi
    fi

    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '%s\n' "$line"
        found=1
    done < <(requires_core_unresolved "$plugin_dir")

    return "$found"
}
