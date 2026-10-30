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
# claim ownership — the split has rotted. This check derives the plugin namespaces
# from the actual manifests, so it catches any namespace a manifest declares (not
# just the hardcoded set in SPEC-1717-2).
#
# "Namespace" here means ALL components except the final event token (all-but-last).
# `persist.start` → namespace `persist`; `plugin.pr_open.branch_fallback_used` →
# namespace `plugin.pr_open`.  Using all-but-last rather than only the first token
# prevents the ADR-001 `plugin.pr_open.*` exception (owned by plugins/tool/pr-open)
# from polluting the top-level `plugin` namespace and falsely flagging engine events.
#
# Fails before the change: persist plugin provides persist.start (namespace 'persist')
# and event-schema.json also carries persist.start; likewise hydrate.*.
# Passes after SPEC-3 removes persist.*/hydrate.* from event-schema.json.
_1951_mf=()
while IFS= read -r _1951_m; do
    [[ -n "$_1951_m" ]] && _1951_mf+=("$_1951_m")
done < <(find "$REPO_ROOT/plugins" -maxdepth 3 -name 'manifest.yaml' -type f 2>/dev/null)

_1951_all_plugin_ev=""
[[ ${#_1951_mf[@]} -gt 0 ]] && _1951_all_plugin_ev="$(eb_manifest_events "${_1951_mf[@]}")"

# Extract all-but-last-component as the namespace for each plugin-declared event.
# %.*  removes the shortest suffix matching  .*  (i.e., dot + final token).
_1951_plugin_ns=""
while IFS= read -r _1951_pev; do
    [[ -z "$_1951_pev" ]] && continue
    _1951_plugin_ns+="${_1951_pev%.*}"$'\n'
done <<< "$_1951_all_plugin_ev"
# Deduplicate with here-string to avoid pipe (sigpipe-ok: sort reads all input, no early exit,
# but use here-string to be fully safe).
_1951_plugin_ns="$(sort -u <<< "$_1951_plugin_ns")"

_1951_spec1_viol=()
while IFS= read -r _1951_t; do
    [[ -z "$_1951_t" ]] && continue
    # Compare full all-but-last namespace: persist.start → 'persist'; plugin.run.start → 'plugin.run'
    _1951_ns="${_1951_t%.*}"
    if grep -qxF "$_1951_ns" <<< "$_1951_plugin_ns"; then
        _1951_spec1_viol+=("$_1951_t")
    fi
done <<< "$_engine_types"

if [[ ${#_1951_spec1_viol[@]} -eq 0 ]]; then
    assert_pass "[#1951/SPEC-1] event-schema.json carries no event in a plugin-owned namespace"
else
    for _1951_t in "${_1951_spec1_viol[@]}"; do
        assert_fail "[#1951/SPEC-1] event-schema.json has '${_1951_t}' in a plugin-owned namespace" \
            "namespace '${_1951_t%.*}' is declared by a plugin manifest; remove this entry from config/event-schema.json (ADR-001 §\"Declared events\")"
    done
fi

# ─── 6. [#1951/SPEC-2] plugin manifests must not declare engine-namespace events ─
# ADR-001 §"Declared events" lists the namespaces owned by the engine. A plugin
# that lists an engine-namespace event under provides.events steals ownership from
# the engine — it is not entitled to that event name and the validator must reject it.
#
# ADR-001 exception: a plugin may declare events in the sub-namespace
# `plugin.<plugin_name>.*` where <plugin_name> is derived from the plugin's own
# directory basename (dashes → underscores).  For example, plugins/tool/pr-open may
# declare `plugin.pr_open.*` events.  These are carved out before the engine-namespace
# check so they do not produce false violations.
#
# Fails before the change: security-lens and merge both declare plugin.result;
# 'plugin' is an engine-owned namespace and plugin.result is NOT a plugin.security_lens.*
# or plugin.merge.* sub-namespace event, so the exception does not apply.
# Passes after SPEC-4: plugin.result is removed from both manifests.
_ENGINE_OWNED_NS_RE='^(pipeline|stage|stage_io|plugin|cycle|router|loop|state|registry|parallel|redaction|template|strategy|artifact|model|cost|orch|memory|backend|detection|llm|selfhost)\.'
_1951_spec2_viol=()
while IFS= read -r _1951_pd; do
    [[ -z "$_1951_pd" ]] && continue
    _1951_mf2="$_1951_pd/manifest.yaml"
    [[ -f "$_1951_mf2" ]] || continue
    # ADR-001 exception: derive the allowed plugin.* sub-namespace from the directory name.
    _1951_pname2="$(basename "$_1951_pd")"
    _1951_pname2_ns="${_1951_pname2//-/_}"  # pr-open → pr_open
    _1951_decl2="$(eb_manifest_events "$_1951_mf2")"
    while IFS= read -r _1951_ev2; do
        [[ -z "$_1951_ev2" ]] && continue
        # Skip events in the plugin's own plugin.* sub-namespace (ADR-001 §"Declared events" exception).
        # The pattern requires a third component (must be plugin.<name>.<event>, not plugin.<name>),
        # so a bare `plugin.name` (no sub-event) is still a violation.
        [[ "$_1951_ev2" == "plugin.${_1951_pname2_ns}."* ]] && continue
        if grep -qE "$_ENGINE_OWNED_NS_RE" <<< "$_1951_ev2"; then
            _1951_spec2_viol+=("${_1951_pd#"$REPO_ROOT/"} → $_1951_ev2")
        fi
    done <<< "$_1951_decl2"
done <<< "$(find "$REPO_ROOT/plugins" -maxdepth 3 -name 'manifest.yaml' -type f -exec dirname {} \;)"

if [[ ${#_1951_spec2_viol[@]} -eq 0 ]]; then
    assert_pass "[#1951/SPEC-2] no plugin manifest declares an event in an engine-owned namespace"
else
    for _1951_v2 in "${_1951_spec2_viol[@]}"; do
        assert_fail "[#1951/SPEC-2] plugin declares engine-namespace event: $_1951_v2" \
            "engine namespaces (pipeline, stage, plugin, cycle, ...) are owned by the engine; remove this from the plugin's provides.events (ADR-001 §\"Declared events\")"
    done
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
_1951_sl_testfile="$REPO_ROOT/plugins/agent/security-lens/tests/security-lens-test.sh"
if grep -qF "manifest provides.events contains plugin.result" "$_1951_sl_testfile" 2>/dev/null; then
    assert_fail "[#1951/SPEC-4] the [SPEC-16] plugin.result sub-assertion must be absent from security-lens-test.sh" \
        "old sub-assertion 'manifest provides.events contains plugin.result' is still present in plugins/agent/security-lens/tests/security-lens-test.sh"
else
    assert_pass "[#1951/SPEC-4] the [SPEC-16] plugin.result sub-assertion is absent from security-lens-test.sh"
fi
# The [SPEC-1] block in merge-v2-result-test.sh previously asserted
# "manifest provides.events includes plugin.result" — that sub-assertion must be gone.
_1951_mg_testfile="$REPO_ROOT/tests/unit/merge-v2-result-test.sh"
if grep -qF "manifest provides.events includes plugin.result" "$_1951_mg_testfile" 2>/dev/null; then
    assert_fail "[#1951/SPEC-4] the [SPEC-1] plugin.result sub-assertion must be absent from merge-v2-result-test.sh" \
        "old sub-assertion 'manifest provides.events includes plugin.result' is still present in tests/unit/merge-v2-result-test.sh"
else
    assert_pass "[#1951/SPEC-4] the [SPEC-1] plugin.result sub-assertion is absent from merge-v2-result-test.sh"
fi

# ─── 9. [#1951/SPEC-6] the old hardcoded plugin-namespace guard is gone ───────
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
