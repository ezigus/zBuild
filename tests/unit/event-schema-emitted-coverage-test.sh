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

# ─── 3. [SPEC-1717-2] the engine's file carries ONLY engine namespaces ───────
# The whole point of the split: a plugin namespace back in config/event-schema.json
# means a plugin has to edit engine config again to register an event.
_PLUGIN_NS_RE='^(intake|plan|design|impact|build|acceptance|validate|deploy|monitor|review|review_lens|review_report|review_aggregator|test|test_assessment|shape_floor|coverage_gate|lint_gate|mutation_gate|secret_scan|design_gate|gate_aggregator|teardown|release|claim)\.'
_leaked="$(grep -E "$_PLUGIN_NS_RE" <<< "$_engine_types" || true)"
if [[ -z "$_leaked" ]]; then
    assert_pass "[SPEC-1717-2] config/event-schema.json carries no plugin-owned namespace"
else
    assert_fail "[SPEC-1717-2] config/event-schema.json carries no plugin-owned namespace" \
        "plugin-owned names still in engine config: $(tr '\n' ' ' <<< "$_leaked")"
fi

# ─── 4. [SPEC-1717-3] the #1711 casualty is declared and no longer warns ─────
# `acceptance.gate.wiring_not_on_path` is the event the #1686 build un-registered
# rather than edit an out-of-scope engine file — the incident that motivated
# this issue. It must be known through spec-acceptance's OWN manifest.
_sa_events="$(eb_manifest_events "$REPO_ROOT/plugins/agent/spec-acceptance/manifest.yaml")"
if grep -qxF "acceptance.gate.wiring_not_on_path" <<< "$_sa_events"; then
    assert_pass "[SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself"
else
    assert_fail "[SPEC-1717-3] acceptance.gate.wiring_not_on_path is declared by spec-acceptance itself" \
        "absent from plugins/agent/spec-acceptance/manifest.yaml provides.events"
fi

# [SPEC-5] redaction.marker_neutralized must remain known (engine namespace).
if grep -qxF "redaction.marker_neutralized" <<< "$_engine_types"; then
    assert_pass "[SPEC-5] redaction.marker_neutralized is registered in event-schema.json known_types"
else
    assert_fail "[SPEC-5] redaction.marker_neutralized is NOT registered in event-schema.json known_types"
fi

print_test_results
exit $((FAIL > 0))
