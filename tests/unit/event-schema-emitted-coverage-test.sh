#!/usr/bin/env bash
# Tests: every event type emitted (as a string literal) anywhere under
# plugins/ + core/ is KNOWN — and, for a plugin, known because the plugin's OWN
# manifest declares it.
#
# Widened from the original cq-*-only scope (#862) to all stages + core (#915)
# after the #867 dogfood shipped an unregistered test_assessment event the
# cq-scoped test could not see. Re-pointed at the COMPOSED set (#1717): the
# known set is now config/event-schema.json (engine namespaces) UNION every
# manifest's provides.events, so this guard reads it through
# eb_compose_known_types rather than jq-ing the config file.
#
# Two directions are checked, and the second is the one #1717 adds:
#   1. every emitted literal is known (the original guard);
#   2. an event emitted by a plugin is declared in THAT plugin's manifest —
#      not merely somewhere in the composed set. Without (2) a plugin could
#      free-ride on a sibling's declaration and the ownership split would rot.
# Engine-namespace events (config/event-schema.json) are exempt from (2): a
# plugin may legitimately emit the engine's own envelope events
# (plugin.run.complete, loop.git_diff_failed, …).
#
# Coverage limitation: this matches only STRING-LITERAL event names. Three
# dynamic call sites emit via a variable and are structurally invisible here —
# core/pipeline/cycle-orchestrator.sh (`_cycle_emit` wrapper, eb_emit_event
# "$type"), core/event-bus/event-bus.sh (`eb_emit_event "$@"` pass-through),
# and core/router/route.sh (eb_emit_event "$override_event"). The literals that
# flow into those vars are emitted as literals elsewhere or already registered,
# so there is no hidden gap today — but a NEW dynamic-only type would slip past.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/core/event-bus/known-types.sh"

print_test_header "event-schema emitted-⊆-composed known types (all plugins + core)"

SCHEMA="$REPO_ROOT/config/event-schema.json"

# The emit-site pattern. Beyond `emit_event "x.y"` / `eb_emit_event "x.y"` (the
# `eb_`/`_cycle_` prefixes are absorbed by the leading `.*`), it now also matches
# the per-plugin wrapper form the gate plugins use — `_sf_emit "shape_floor.pass"`,
# `_cg_emit …` — which the old `emit_event`-only pattern could not see, leaving
# every gate plugin's events structurally unguarded.
_EMIT_RE='(emit_event|_[a-z][a-z0-9_]*_emit)[[:space:]]+"[a-z][a-z0-9._-]+"'

# ─── The composed known set + the engine leg ────────────────────────────────
_known_types="$(eb_compose_known_types "$SCHEMA" "$REPO_ROOT/plugins")"
_engine_types="$(jq -r '.known_types[]' "$SCHEMA")"

# ─── 1. Every emitted literal (plugins/ + core/) is in the composed set ─────
# `plugins/` — not just `plugins/agent/` — so tool plugins are covered too.
_emitted_types="$(grep -rh --include='*.sh' -E "$_EMIT_RE" \
    "$REPO_ROOT/plugins/" \
    "$REPO_ROOT/core/" \
    2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | sed -E 's/.*(emit_event|_[a-z][a-z0-9_]*_emit)[[:space:]]+"([a-z][a-z0-9._-]+)".*/\2/' \
    | sort -u \
    || true)"

if [[ -z "$_emitted_types" ]]; then
    assert_fail "emitted-coverage: extraction" "no emit_event literal sites found under plugins + core"
    print_test_results
    exit $((FAIL > 0))
fi

_missing=()
while IFS= read -r _type; do
    [[ -z "$_type" ]] && continue
    # Here-string, NOT `printf ... | grep -q`: grep -q exits on first match, which
    # SIGPIPEs the still-writing printf; under `set -o pipefail` that turns a FOUND
    # match into a non-zero pipeline → false "not registered". The flake surfaced
    # once the unit tier went parallel-by-default (#984). A here-string has no pipe.
    if ! grep -qxF "$_type" <<< "$_known_types"; then
        _missing+=("$_type")
    fi
done <<< "$_emitted_types"

if [[ ${#_missing[@]} -eq 0 ]]; then
    assert_pass "all emitted plugin + core event types are in the composed known set"
else
    for _t in "${_missing[@]}"; do
        assert_fail "emitted type '$_t' is in the composed known set" \
            "not in config/event-schema.json nor any manifest's provides.events"
    done
fi

# ─── 2. [SPEC-1717-1] a plugin's own events are declared in its own manifest ──
_undeclared=()
while IFS= read -r _plugin_dir; do
    [[ -z "$_plugin_dir" ]] && continue
    _manifest="$_plugin_dir/manifest.yaml"
    [[ -f "$_manifest" ]] || continue
    _declared="$(eb_manifest_events "$_manifest")"
    while IFS= read -r _type; do
        [[ -z "$_type" ]] && continue
        # The engine's own events are declared centrally; a plugin emitting one
        # is expected and is not an ownership violation.
        grep -qxF "$_type" <<< "$_engine_types" && continue
        grep -qxF "$_type" <<< "$_declared" && continue
        _undeclared+=("${_plugin_dir#"$REPO_ROOT/"} → $_type")
    done <<< "$(grep -rh --include='*.sh' -E "$_EMIT_RE" "$_plugin_dir" 2>/dev/null \
        | grep -vE '^[[:space:]]*#' \
        | sed -E 's/.*(emit_event|_[a-z][a-z0-9_]*_emit)[[:space:]]+"([a-z][a-z0-9._-]+)".*/\2/' \
        | sort -u || true)"
done <<< "$(find "$REPO_ROOT/plugins" -maxdepth 3 -name 'manifest.yaml' -type f -exec dirname {} \;)"

if [[ ${#_undeclared[@]} -eq 0 ]]; then
    assert_pass "[SPEC-1717-1] every plugin-emitted event is declared in that plugin's own manifest"
else
    for _u in "${_undeclared[@]}"; do
        assert_fail "[SPEC-1717-1] $_u" \
            "emitted by this plugin but absent from its provides.events (and not an engine event)"
    done
fi

# ─── 3. [SPEC-1717-3] the #1711 casualty is declared and no longer warns ─────
# `acceptance.gate.wiring_not_on_path` is the event the #1686 build un-registered
# rather than edit an out-of-scope engine file — the incident that motivated
# this issue. It must be known through spec-acceptance's OWN manifest.
_sa_events="$(eb_manifest_events "$REPO_ROOT/plugins/tool/test/manifest.yaml")"
if grep -qxF "acceptance.gate.wiring_not_on_path" <<< "$_sa_events"; then
    assert_pass "[SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself"
else
    assert_fail "[SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself" \
        "absent from plugins/tool/test/manifest.yaml provides.events"
fi

# [SPEC-5] redaction.marker_neutralized must remain known (engine namespace).
if grep -qxF "redaction.marker_neutralized" <<< "$_engine_types"; then
    assert_pass "[SPEC-5] redaction.marker_neutralized is registered in event-schema.json known_types"
else
    assert_fail "[SPEC-5] redaction.marker_neutralized is NOT registered in event-schema.json known_types"
fi

# [#2032] cycle.member_unfinished.suppressed_convergence is emitted dynamically via
# _cycle_emit (structurally invisible to the emit-site scan above), so it must be
# explicitly confirmed present in the engine known_types.
if grep -qxF "cycle.member_unfinished.suppressed_convergence" <<< "$_engine_types"; then
    assert_pass "[#2032] cycle.member_unfinished.suppressed_convergence is registered in event-schema.json known_types"
else
    assert_fail "[#2032] cycle.member_unfinished.suppressed_convergence is NOT registered in event-schema.json known_types"
fi

# ─── 5. [#1951/SPEC-1] event-schema.json must not carry plugin-namespace events ─
# The namespace of every event a plugin declares in its manifest is a plugin-owned
# namespace. If event-schema.json also carries events in that namespace, both sides
# claim ownership — the split has rotted. The guard derives the plugin namespaces
# from the manifests themselves, never from a hand-written list.

# The engine's namespaces and the one exception are read from ADR-001
# §"Declared events" — the spec — so this test keeps no list of its own.
# _1951_adr_ownership <adr> — sets _1951_ENGINE_NS (" pipeline plugin … "),
# _1951_EXC_NS (plugin.pr_open) and _1951_EXC_OWNER (pr-open).
_1951_adr_ownership() {
    local line sec="" exc="" t
    _1951_ENGINE_NS=" "; _1951_EXC_NS=""; _1951_EXC_OWNER=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "- **Engine**"*) sec=engine ;;
            "- **Exception:**"*) sec=exception ;;
            "- "*|"#"*|"") sec="" ;;
        esac
        if [[ "$sec" == engine ]]; then
            t="$line"
            while [[ "$t" =~ \`([a-z0-9_-]+)\.\*\`(.*) ]]; do
                _1951_ENGINE_NS+="${BASH_REMATCH[1]} "; t="${BASH_REMATCH[2]}"
            done
        elif [[ "$sec" == exception ]]; then
            exc+=" $line"
        fi
    done < "$1"
    [[ "$exc" =~ \`(plugin\.[a-z0-9_-]+)\.\*\` ]] && _1951_EXC_NS="${BASH_REMATCH[1]}"
    [[ "$exc" =~ belongs\ to[[:space:]]+\`([a-z0-9-]+)\` ]] && _1951_EXC_OWNER="${BASH_REMATCH[1]}"
    return 0
}

# _1951_spec1_violations <engine_types> <plugins_root> <adr> — every engine-config
# event outside the engine's namespaces, one per line, with why: a plugin
# manifest declares its namespace (the namespaces are read from the manifests),
# or ADR-001 does not give it to the engine. A namespace is an event's first part.
_1951_spec1_violations() {
    local types="$1" root="$2" m ev ns
    local -a mf=(); local -A pns=()
    _1951_adr_ownership "$3"
    [[ "$_1951_ENGINE_NS" != " " ]] || { printf 'ERROR: %s names no engine namespace\n' "$3"; return 0; }
    while IFS= read -r m; do [[ -n "$m" ]] && mf+=("$m"); done \
        < <(find "$root" -maxdepth 3 -name 'manifest.yaml' -type f 2>/dev/null)
    if [[ ${#mf[@]} -gt 0 ]]; then
        while IFS= read -r ev; do
            ns="${ev%%.*}"
            [[ -n "$ev" && "$_1951_ENGINE_NS" != *" $ns "* ]] && pns[$ns]=1
        done < <(eb_manifest_events "${mf[@]}")
    fi
    while IFS= read -r ev; do
        [[ -n "$ev" ]] || continue
        ns="${ev%%.*}"
        if [[ -n "${pns[$ns]:-}" ]]; then printf '%s (a plugin manifest declares %s)\n' "$ev" "$ns"
        elif [[ "$_1951_ENGINE_NS" != *" $ns "* ]]; then printf '%s (ADR-001 does not give %s to the engine)\n' "$ev" "$ns"
        fi
    done <<< "$types"
    return 0
}

_1951_spec1_viol="$(_1951_spec1_violations "$_engine_types" "$REPO_ROOT/plugins" "$REPO_ROOT/docs/adr/ADR-001-plugin-contract.md")"
if [[ -z "$_1951_spec1_viol" ]]; then
    assert_pass "[#1951/SPEC-1] event-schema.json carries no event in a plugin-owned namespace"
else
    while IFS= read -r _1951_t; do
        assert_fail "[#1951/SPEC-1] event-schema.json has ${_1951_t}" \
            "remove this entry from config/event-schema.json; the plugin that owns it declares it (ADR-001 §\"Declared events\")"
    done <<< "$_1951_spec1_viol"
fi

# ─── 6. [#1951/SPEC-2] plugin manifests must not declare engine-namespace events ─
# ADR-001 §"Declared events" lists the namespaces owned by the engine, and one
# exception: plugin.pr_open.* belongs to pr-open.

# _1951_spec2_violations <plugins_root> <adr> — "<plugin dir> → <event>" for every
# event a manifest declares in an engine namespace, one per line. Only the
# exception's owner may declare the exception's namespace.
_1951_spec2_violations() {
    local root="$1" m d ev
    _1951_adr_ownership "$2"
    [[ "$_1951_ENGINE_NS" != " " ]] || { printf 'ERROR: %s names no engine namespace\n' "$2"; return 0; }
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        d="${m%/*}"
        while IFS= read -r ev; do
            [[ -n "$ev" && "$_1951_ENGINE_NS" == *" ${ev%%.*} "* ]] || continue
            [[ -n "$_1951_EXC_NS" && "$ev" == "$_1951_EXC_NS".* && "${d##*/}" == "$_1951_EXC_OWNER" ]] && continue
            printf 'plugins/%s → %s\n' "${d#"$root/"}" "$ev"
        done < <(eb_manifest_events "$m")
    done < <(find "$root" -maxdepth 3 -name 'manifest.yaml' -type f 2>/dev/null)
    return 0
}

_1951_spec2_viol="$(_1951_spec2_violations "$REPO_ROOT/plugins" "$REPO_ROOT/docs/adr/ADR-001-plugin-contract.md")"
if [[ -z "$_1951_spec2_viol" ]]; then
    assert_pass "[#1951/SPEC-2] no plugin manifest declares an event in an engine-owned namespace"
else
    while IFS= read -r _1951_v2; do
        assert_fail "[#1951/SPEC-2] plugin declares engine-namespace event: $_1951_v2" \
            "the engine owns this namespace; remove it from the plugin's provides.events (ADR-001 §\"Declared events\")"
    done <<< "$_1951_spec2_viol"
fi

# ─── 7. [#1951/SPEC-3] persist.* and hydrate.* absent from event-schema.json ───
# After the change, these namespaces are declared canonically in the plugin manifests
# (plugins/tool/persist and plugins/tool/hydrate). The engine schema must not
# duplicate them.
_1951_persist="$(grep -E '^persist\.' <<< "$_engine_types" || true)"
if [[ -z "$_1951_persist" ]]; then
    assert_pass "[#1951/SPEC-3] persist.* events are absent from config/event-schema.json known_types"
else
    assert_fail "[#1951/SPEC-3] persist.* events must be absent from config/event-schema.json known_types" \
        "still present: $(tr '\n' ' ' <<< "$_1951_persist")"
fi
_1951_hydrate="$(grep -E '^hydrate\.' <<< "$_engine_types" || true)"
if [[ -z "$_1951_hydrate" ]]; then
    assert_pass "[#1951/SPEC-3] hydrate.* events are absent from config/event-schema.json known_types"
else
    assert_fail "[#1951/SPEC-3] hydrate.* events must be absent from config/event-schema.json known_types" \
        "still present: $(tr '\n' ' ' <<< "$_1951_hydrate")"
fi

# Canonical declarations must remain in the plugin manifests: at least one
# persist.* event must be declared by the persist plugin, and at least one
# hydrate.* event by the hydrate plugin.
_1951_persist_mf_ev="$(eb_manifest_events "$REPO_ROOT/plugins/tool/persist/manifest.yaml")"
_1951_persist_in_mf="$(grep -E '^persist\.' <<< "$_1951_persist_mf_ev" || true)"
if [[ -n "$_1951_persist_in_mf" ]]; then
    assert_pass "[#1951/SPEC-3] persist plugin manifest declares at least one persist.* event (canonical declaration)"
else
    assert_fail "[#1951/SPEC-3] persist plugin manifest must carry canonical persist.* declarations" \
        "no persist.* events found in plugins/tool/persist/manifest.yaml provides.events"
fi
_1951_hydrate_mf_ev="$(eb_manifest_events "$REPO_ROOT/plugins/tool/hydrate/manifest.yaml")"
_1951_hydrate_in_mf="$(grep -E '^hydrate\.' <<< "$_1951_hydrate_mf_ev" || true)"
if [[ -n "$_1951_hydrate_in_mf" ]]; then
    assert_pass "[#1951/SPEC-3] hydrate plugin manifest declares at least one hydrate.* event (canonical declaration)"
else
    assert_fail "[#1951/SPEC-3] hydrate plugin manifest must carry canonical hydrate.* declarations" \
        "no hydrate.* events found in plugins/tool/hydrate/manifest.yaml provides.events"
fi

# ─── 8. [#1951/SPEC-4] plugin.result absent from security-lens and merge manifests ─
# plugin.* is an engine-owned namespace (ADR-001 §"Declared events"). Neither
# security-lens nor merge is entitled to declare plugin.result in their manifests.
_1951_sl_ev="$(eb_manifest_events "$REPO_ROOT/plugins/agent/security-lens/manifest.yaml")"
if grep -qxF "plugin.result" <<< "$_1951_sl_ev"; then
    assert_fail "[#1951/SPEC-4] plugin.result must be absent from plugins/agent/security-lens/manifest.yaml provides.events" \
        "plugin.result is an engine-owned event (plugin.* namespace); remove it from provides.events"
else
    assert_pass "[#1951/SPEC-4] plugin.result is absent from plugins/agent/security-lens/manifest.yaml provides.events"
fi
_1951_mg_ev="$(eb_manifest_events "$REPO_ROOT/plugins/tool/merge/manifest.yaml")"
if grep -qxF "plugin.result" <<< "$_1951_mg_ev"; then
    assert_fail "[#1951/SPEC-4] plugin.result must be absent from plugins/tool/merge/manifest.yaml provides.events" \
        "plugin.result is an engine-owned event (plugin.* namespace); remove it from provides.events"
else
    assert_pass "[#1951/SPEC-4] plugin.result is absent from plugins/tool/merge/manifest.yaml provides.events"
fi
# Also verify the pre-existing test sub-assertions for plugin.result have been removed.
# The [SPEC-16] block in security-lens-test.sh previously asserted
# "manifest provides.events contains plugin.result" — that sub-assertion must be gone.
# _1951_file_lacks <file> <text> — 0 when <file> does not contain <text>.
# A missing file is not clean: it is not there to read (lens review).
_1951_file_lacks() { [[ -f "$1" ]] && ! grep -qF -- "$2" "$1"; }
_1951_sl_testfile="$REPO_ROOT/plugins/agent/security-lens/tests/security-lens-test.sh"
if ! _1951_file_lacks "$_1951_sl_testfile" "manifest provides.events contains plugin.result"; then
    assert_fail "[#1951/SPEC-4] the [SPEC-16] plugin.result sub-assertion must be absent from security-lens-test.sh" \
        "old sub-assertion 'manifest provides.events contains plugin.result' is still present in plugins/agent/security-lens/tests/security-lens-test.sh"
else
    assert_pass "[#1951/SPEC-4] the [SPEC-16] plugin.result sub-assertion is absent from security-lens-test.sh"
fi
# The [SPEC-1] block in merge-v2-result-test.sh previously asserted
# "manifest provides.events includes plugin.result" — that sub-assertion must be gone.
_1951_mg_testfile="$REPO_ROOT/tests/unit/merge-v2-result-test.sh"
if ! _1951_file_lacks "$_1951_mg_testfile" "manifest provides.events includes plugin.result"; then
    assert_fail "[#1951/SPEC-4] the [SPEC-1] plugin.result sub-assertion must be absent from merge-v2-result-test.sh" \
        "old sub-assertion 'manifest provides.events includes plugin.result' is still present in tests/unit/merge-v2-result-test.sh"
else
    assert_pass "[#1951/SPEC-4] the [SPEC-1] plugin.result sub-assertion is absent from merge-v2-result-test.sh"
fi

# ─── 9. [#1951 lens review] the guard's rules, on fixtures ────────────────────
# The real tree passes sections 5, 6 and 8 today, so their rules are checked on
# fixtures here: each one is a leak the real tree does not happen to have.
_1951_fx="$(mktemp -d "${TMPDIR:-/tmp}/zb-1951-fx.XXXXXX")"
trap 'rm -rf "${_1951_fx:?}"' EXIT
_1951_fx_plugin() {   # _1951_fx_plugin <root> <kind/name> <event>...
    local root="$1" d="$1/$2"; shift 2
    mkdir -p "$d"
    { printf 'id: %s\nprovides:\n  events:\n' "${d##*/}"; printf '    - %s\n' "$@"; } > "$d/manifest.yaml"
}
cat > "$_1951_fx/adr.md" <<'ADR'
**Ownership rule.**

- **Engine** (`config/event-schema.json`): `pipeline.*`, `plugin.*`,
  `newengine.*`, `e2e.*`.
- **Plugin** (its `provides.events`): every other namespace.
- **Exception:** `plugin.pr_open.*` is engine-namespaced but names a single plugin, so it belongs to
  `pr-open`.
ADR
_1951_fx_plugin "$_1951_fx/p1" tool/foo plugin.foo.started
_1951_fx_plugin "$_1951_fx/p1" tool/pr-open plugin.pr_open.branch_fallback_used
_1951_fx_plugin "$_1951_fx/p1" tool/bar newengine.tick
_1951_fx_plugin "$_1951_fx/p1" tool/baz e2e.ran
_1951_fx_v2="$(_1951_spec2_violations "$_1951_fx/p1" "$_1951_fx/adr.md")"
assert_contains "[#1951/R2] plugin.<name>.* is the engine's for every plugin but pr-open" \
    "$_1951_fx_v2" "plugins/tool/foo → plugin.foo.started"
assert_eq "[#1951/R2] pr-open keeps plugin.pr_open.*" "" "$(grep 'pr_open' <<< "$_1951_fx_v2" || true)"
assert_contains "[#1951/R3] the engine's namespaces are read from ADR-001, not a list in this test" \
    "$_1951_fx_v2" "plugins/tool/bar → newengine.tick"
assert_contains "[#1951/R3] … including a namespace with a digit" "$_1951_fx_v2" "plugins/tool/baz → e2e.ran"

sed 's/plugin\.pr_open\.\*/plugin.step2.*/; s/`pr-open`/`step2`/' "$_1951_fx/adr.md" > "$_1951_fx/adr2.md"
_1951_fx_plugin "$_1951_fx/p3" tool/step2 plugin.step2.done
assert_eq "[#1951/R2] an exception's namespace may carry a digit" "" \
    "$(_1951_spec2_violations "$_1951_fx/p3" "$_1951_fx/adr2.md")"

_1951_fx_plugin "$_1951_fx/p2" tool/widget widget.result.write_failed
assert_contains "[#1951/R1] a namespace is an event's first part, so a three-part event still claims it" \
    "$(_1951_spec1_violations $'widget.start\npipeline.start' "$_1951_fx/p2" "$_1951_fx/adr.md")" \
    "widget.start (a plugin manifest declares widget)"
assert_contains "[#1951/R1] engine config carries only the namespaces ADR-001 gives the engine" \
    "$(_1951_spec1_violations $'persistx.start\npipeline.start' "$_1951_fx/p2" "$_1951_fx/adr.md")" \
    "persistx.start (ADR-001 does not give persistx to the engine)"
assert_eq "[#1951/R1] … and an engine namespace is not flagged" "" \
    "$(_1951_spec1_violations $'pipeline.start\nplugin.result' "$_1951_fx/p2" "$_1951_fx/adr.md")"

if _1951_file_lacks "$_1951_fx/no-such-test.sh" "anything"; then
    assert_fail "[#1951/SPEC-4] a test file that is missing is not taken as clean" "a missing file read as lacking the text"
else
    assert_pass "[#1951/SPEC-4] a test file that is missing is not taken as clean"
fi

# ─── 10. [#1951/SPEC-6] the old hardcoded plugin-namespace guard is gone ───────
# After the change, the hardcoded plugin-namespace enumeration variable introduced
# by SPEC-1717-2 must not appear anywhere in this file: the dynamic manifest-based
# check (SPEC-1 above) fully replaces it.
#
# The variable name is assembled from two parts below so that this assertion
# itself does not introduce the literal as a contiguous character sequence in the
# file — a self-referential literal would make the check always fail.
_1951_s6_ns_var='_PLUGIN_NS'"_RE"   # evaluates to the target name; never a literal occurrence
if ! grep -qF "$_1951_s6_ns_var" "${BASH_SOURCE[0]}"; then
    assert_pass "[#1951/SPEC-6] the hardcoded plugin-namespace guard variable is absent from this file"
else
    assert_fail "[#1951/SPEC-6] the hardcoded plugin-namespace guard variable must be absent from this file" \
        "old SPEC-1717-2 hardcoded list is still present; the guard block was not removed"
fi

print_test_results
exit $((FAIL > 0))
