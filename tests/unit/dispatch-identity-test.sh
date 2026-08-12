#!/usr/bin/env bash
# Tests: ADR-054 §3 — the engine exports stage+plugin identity at dispatch (#1862)
# Covers SPEC-1 through SPEC-6.
#
# This file must NEVER export ZBUILD_PLUGIN / ZBUILD_PLUGIN_KIND / ZBUILD_PLUGIN_DIR
# itself. The gap this issue closes survived for the life of the project precisely
# because the three tests covering the readers each exported the value they then
# asserted, so every production read resolving to "" reddened nothing. Every
# assertion below reads what plugin_hook_call actually set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

print_test_header "dispatch-identity — ADR-054 §3 engine-exported stage+plugin identity"

setup_test_env "dispatch-identity"

# Prove the preconditions rather than assume them: nothing ambient may be
# supplying the values under test.
unset ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND ZBUILD_PLUGIN_DIR ZBUILD_CURRENT_STAGE 2>/dev/null || true
_saved_plugins_root="${ZBUILD_PLUGINS_ROOT-__UNSET__}"
unset ZBUILD_PLUGINS_ROOT 2>/dev/null || true

# ─── Fixture ─────────────────────────────────────────────────────────────────
# id ≠ stage name, deliberately: that divergence is the whole point. In the tree
# `review_lenses` (template stage) is served by `review-lens` (plugin id) via
# role `review_lens` — three namespaces, and a plugin introspecting itself can
# only ever produce the second.
_FIX_DIR="$TEST_TEMP_DIR/identity-fixture"
_FIX_STAGE="lens_fixtures"
_FIX_ID="identity-fixture"
mkdir -p "$_FIX_DIR"
cat > "$_FIX_DIR/manifest.yaml" <<EOF
id: $_FIX_ID
name: Identity Fixture
kind: agent
version: 0.0.1
hooks:
  run: idf_run
EOF

# The hook records everything it can see about its own identity, so one dispatch
# feeds several SPECs. $_IDF_OUT / $_IDF_ROOT are baked in at construction —
# they are not ZBUILD_* and so are unaffected by the scrub under test.
{
    printf '_IDF_ROOT=%q\n' "$REPO_ROOT"
    printf '_IDF_OUT=%q\n'  "$TEST_TEMP_DIR/idf-seen.txt"
    cat <<'FIXTURE'
idf_run() {
    {
        printf 'stage=%s\n'      "${ZBUILD_CURRENT_STAGE-<unset>}"
        printf 'plugin=%s\n'     "${ZBUILD_PLUGIN-<unset>}"
        printf 'kind=%s\n'       "${ZBUILD_PLUGIN_KIND-<unset>}"
        printf 'dir=%s\n'        "${ZBUILD_PLUGIN_DIR-<unset>}"
        printf 'plugins_root=%s\n' "${ZBUILD_PLUGINS_ROOT-<unset>}"

        # Can the plugin reach its OWN manifest without its call site handing
        # over the path? This is the capability #1816 needs from route.sh.
        _self_id=""
        if [[ -n "${ZBUILD_PLUGIN_DIR:-}" && -f "${ZBUILD_PLUGIN_DIR}/manifest.yaml" ]]; then
            _self_id="$(yaml_get "${ZBUILD_PLUGIN_DIR}/manifest.yaml" "id" 2>/dev/null || true)"
        fi
        printf 'self_resolved_id=%s\n' "${_self_id:-<none>}"

        # ADR-024: identity is pipeline state, so the claude-spawn subshell must
        # NOT see it. Capture what survives the scrub.
        source "$_IDF_ROOT/scripts/lib/env-scrub.sh"
        _scrubbed="$(
            _zbuild_make_fresh_shell
            printf '%s|%s|%s' "${ZBUILD_PLUGIN-}" "${ZBUILD_PLUGIN_DIR-}" "${ZBUILD_CURRENT_STAGE-}"
        )"
        printf 'scrubbed=%s\n' "$_scrubbed"
    } > "$_IDF_OUT"
    return 0
}
FIXTURE
} > "$_FIX_DIR/plugin.sh"

# ─── Dispatch once, with events captured ─────────────────────────────────────
_EVENTS="$TEST_TEMP_DIR/identity-events.jsonl"
_old_dir="${ZBUILD_EVENTS_DIR:-}"; _old_jsonl="${ZBUILD_EVENTS_JSONL:-}"; _old_db="${ZBUILD_EVENTS_DB:-}"
ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR"
ZBUILD_EVENTS_JSONL="$_EVENTS"
ZBUILD_EVENTS_DB="/dev/null"

set +e
plugin_hook_call "$_FIX_DIR" run "$_FIX_STAGE" "$TEST_TEMP_DIR/pipeline-state.json" >/dev/null 2>&1
_dispatch_rc=$?
set -e

ZBUILD_EVENTS_DIR="$_old_dir"; ZBUILD_EVENTS_JSONL="$_old_jsonl"; ZBUILD_EVENTS_DB="$_old_db"

_SEEN="$TEST_TEMP_DIR/idf-seen.txt"
_seen() { grep "^$1=" "$_SEEN" 2>/dev/null | head -1 | cut -d= -f2-; }

assert_eq "[SETUP] fixture dispatch succeeded" "0" "$_dispatch_rc"

# ─── SPEC-1: the event envelope's .plugin / .kind are populated ──────────────
# CHANGE: at the merge-base every record ever written carried "plugin":"" and
# "kind":"" — event-bus.sh reads ZBUILD_PLUGIN / ZBUILD_PLUGIN_KIND, which
# nothing in core/, scripts/ or plugins/ assigned. Asserted on the ENVELOPE
# (top-level), not on .data, which callers populate by hand.
_env_plugin="$(jq -r 'select(.type=="plugin.run.start") | .plugin' "$_EVENTS" 2>/dev/null | head -1)"
_env_kind="$(jq -r 'select(.type=="plugin.run.start") | .kind' "$_EVENTS" 2>/dev/null | head -1)"
assert_eq "[SPEC-1] envelope .plugin is the serving plugin's id" "$_FIX_ID" "$_env_plugin"
assert_eq "[SPEC-1] envelope .kind is the serving plugin's kind" "agent" "$_env_kind"

# The lifecycle's own start/complete pair fires OUTSIDE the plugin subshell.
# Both must be stamped, or `local -x` was placed too late in the function.
_env_complete="$(jq -r 'select(.type=="plugin.run.complete") | .plugin' "$_EVENTS" 2>/dev/null | head -1)"
assert_eq "[SPEC-1] envelope .plugin is stamped on plugin.run.complete too" "$_FIX_ID" "$_env_complete"

# ─── SPEC-2: a plugin resolves its own manifest from ZBUILD_PLUGIN_DIR ───────
# CHANGE: ZBUILD_PLUGIN_DIR did not exist in the tree at the merge-base. This is
# the capability #1816 needs — route.sh runs inside the plugin, serves 25 of
# them, and had no way to reach the manifest of the one it was serving.
assert_eq "[SPEC-2] ZBUILD_PLUGIN_DIR is the serving plugin's directory" "$_FIX_DIR" "$(_seen dir)"
assert_eq "[SPEC-2] the plugin resolved its own manifest id, unhanded" "$_FIX_ID" "$(_seen self_resolved_id)"

# ─── SPEC-3: the stage name is the TEMPLATE's word, not the plugin's id ──────
# The axis a plugin can never self-resolve. If these two were allowed to
# collapse, a role-bound stage would report its plugin id to the timeline.
assert_eq "[SPEC-3] ZBUILD_CURRENT_STAGE is the dispatching stage name" "$_FIX_STAGE" "$(_seen stage)"
assert_eq "[SPEC-3] ZBUILD_PLUGIN is the plugin id, and differs from the stage" "$_FIX_ID" "$(_seen plugin)"
if [[ "$(_seen stage)" != "$(_seen plugin)" ]]; then
    assert_pass "[SPEC-3] stage name and plugin id remain distinct namespaces"
else
    assert_fail "[SPEC-3] stage name and plugin id remain distinct namespaces" \
        "both resolved to: $(_seen stage)"
fi

# ─── SPEC-4: identity is scoped to one dispatch — no bleed ──────────────────
# `local -x` and not `export`: a plain export would trade a blank envelope field
# for a stale one, which is strictly harder to detect.
#
# Asserted as a PAIR — "unset afterwards" is vacuously true at the merge-base,
# where it was never set at all. The transition is the claim, so the assertion
# has to carry both halves or it is a guard nothing verifies.
# ZBUILD_CURRENT_STAGE is included: this file unsets it at the top and no outer
# export exists here, so the `local -x` scoping claim is checkable for all FOUR
# variables. In production a caller owns that one (cycle-orchestrator.sh:1466)
# and the unwind restores its value rather than clearing it — which is the
# behaviour SPEC-6 of dispatch-rc-signal-boundary-test.sh depends on.
_after_unset=1
for _v in ZBUILD_PLUGIN ZBUILD_PLUGIN_KIND ZBUILD_PLUGIN_DIR ZBUILD_CURRENT_STAGE; do
    if [[ -v "$_v" ]]; then _after_unset=0; fi
done
_bleed="set_during=$([[ "$(_seen plugin)" != "<unset>" ]] && echo yes || echo no)"
_bleed="$_bleed unset_after=$([[ "$_after_unset" == "1" ]] && echo yes || echo no)"
assert_eq "[SPEC-4] identity is set during the dispatch and unset in the caller after it" \
    "set_during=yes unset_after=yes" "$_bleed"

# A second dispatch must see its OWN identity, never the first's.
_FIX2_DIR="$TEST_TEMP_DIR/identity-fixture-2"
mkdir -p "$_FIX2_DIR"
cat > "$_FIX2_DIR/manifest.yaml" <<'EOF'
id: identity-fixture-2
name: Identity Fixture Two
kind: tool
version: 0.0.1
hooks:
  run: idf2_run
EOF
{
    printf '_IDF2_OUT=%q\n' "$TEST_TEMP_DIR/idf2-seen.txt"
    cat <<'FIXTURE2'
idf2_run() {
    printf 'stage=%s\nplugin=%s\nkind=%s\n' \
        "${ZBUILD_CURRENT_STAGE-<unset>}" "${ZBUILD_PLUGIN-<unset>}" "${ZBUILD_PLUGIN_KIND-<unset>}" \
        > "$_IDF2_OUT"
    return 0
}
FIXTURE2
} > "$_FIX2_DIR/plugin.sh"

_old_jsonl2="${ZBUILD_EVENTS_JSONL:-}"; _old_db2="${ZBUILD_EVENTS_DB:-}"
ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/identity-events-2.jsonl"; ZBUILD_EVENTS_DB="/dev/null"
set +e
plugin_hook_call "$_FIX2_DIR" run "second_stage" "$TEST_TEMP_DIR/pipeline-state.json" >/dev/null 2>&1
set -e
ZBUILD_EVENTS_JSONL="$_old_jsonl2"; ZBUILD_EVENTS_DB="$_old_db2"

_SEEN2="$TEST_TEMP_DIR/idf2-seen.txt"
_seen2() { grep "^$1=" "$_SEEN2" 2>/dev/null | head -1 | cut -d= -f2-; }
assert_eq "[SPEC-4] a second dispatch sees its own stage, not the first's" "second_stage" "$(_seen2 stage)"
assert_eq "[SPEC-4] a second dispatch sees its own plugin id" "identity-fixture-2" "$(_seen2 plugin)"
assert_eq "[SPEC-4] a second dispatch sees its own kind" "tool" "$(_seen2 kind)"

# ─── SPEC-5: identity does NOT survive the fresh-shell scrub ────────────────
# ADR-024 / route.sh:700 — the claude spawn "MUST NOT see ZBUILD_* pipeline
# state", and identity is pipeline state. Every consumer (the router's knob
# resolver, stage_io_begin, envelope stamping) runs in the parent scope BEFORE
# the spawn. Asserted as a PAIR for the same reason as SPEC-4: "absent after the
# scrub" is trivially true when nothing ever set it.
_scrub="visible_to_plugin=$([[ "$(_seen plugin)" != "<unset>" ]] && echo yes || echo no)"
_scrub="$_scrub scrubbed=$(_seen scrubbed)"
assert_eq "[SPEC-5] identity reaches the plugin and is fully scrubbed inside _zbuild_make_fresh_shell" \
    "visible_to_plugin=yes scrubbed=||" "$_scrub"

# ─── SPEC-6: the engine does not export ZBUILD_PLUGINS_ROOT ─────────────────
# It is an operator override, not identity: ~20 readers spell it
# `${ZBUILD_PLUGINS_ROOT:-<repo default>}`, and persona-resolve.sh forbids
# relying on it as a root (ADR-024). Engine-setting it would turn an override
# into a permanent pin. Guards against a later change quietly adding it.
# Paired against a variable the engine DOES set, so the assertion distinguishes
# "the engine declined to set this one" from "the engine set nothing at all".
_root_guard="identity_set=$([[ "$(_seen plugin)" != "<unset>" ]] && echo yes || echo no)"
_root_guard="$_root_guard plugins_root=$(_seen plugins_root)"
assert_eq "[SPEC-6] the engine sets identity but does NOT set ZBUILD_PLUGINS_ROOT" \
    "identity_set=yes plugins_root=<unset>" "$_root_guard"

# ─── SPEC-7: the map: arm — the reason this is the choke point ──────────────
# `_strategy_make_work_unit` writes a standalone script and runs it. The runner
# cannot export into that process; it can only bake literals into the heredoc,
# which is exactly why ZBUILD_CURRENT_STAGE is absent from it (#1706). But
# plugin_hook_call is that script's LAST LINE, so identity arrives anyway.
#
# Asserted rather than argued: this arm is the whole justification for choosing
# lifecycle.sh over the four dispatch sites, and it had no coverage at all.
# shellcheck source=../../core/pipeline/strategies/common.sh
source "$REPO_ROOT/core/pipeline/strategies/common.sh"

_MAP_STAGE="review_lenses"
{
    printf '_IDF3_OUT=%q\n' "$TEST_TEMP_DIR/idf3-seen.txt"
    cat <<'FIXTURE3'
idf_run() {
    printf 'stage=%s\nplugin=%s\nkind=%s\ndir=%s\nelement=%s\n' \
        "${ZBUILD_CURRENT_STAGE-<unset>}" "${ZBUILD_PLUGIN-<unset>}" \
        "${ZBUILD_PLUGIN_KIND-<unset>}" "${ZBUILD_PLUGIN_DIR-<unset>}" \
        "${ZBUILD_MAP_ELEMENT-<unset>}" > "$_IDF3_OUT"
    return 0
}
FIXTURE3
} > "$_FIX_DIR/plugin.sh"

_MAP_EVENTS="$TEST_TEMP_DIR/map-events.jsonl"
_old_jsonl3="${ZBUILD_EVENTS_JSONL:-}"; _old_db3="${ZBUILD_EVENTS_DB:-}"
ZBUILD_EVENTS_JSONL="$_MAP_EVENTS"; ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_EVENTS_JSONL ZBUILD_EVENTS_DB

set +e
_wu="$(_strategy_make_work_unit "$_FIX_DIR" "$_MAP_STAGE" "$TEST_TEMP_DIR/pipeline-state.json" \
        "generic" "security" "lenses" "" 2>/dev/null)"
_wu_rc=$?
if [[ $_wu_rc -eq 0 && -x "$_wu" ]]; then "$_wu" >/dev/null 2>&1; _wu_rc=$?; fi
set -e

ZBUILD_EVENTS_JSONL="$_old_jsonl3"; ZBUILD_EVENTS_DB="$_old_db3"

_SEEN3="$TEST_TEMP_DIR/idf3-seen.txt"
_seen3() { grep "^$1=" "$_SEEN3" 2>/dev/null | head -1 | cut -d= -f2-; }

assert_eq "[SPEC-7] generated map work unit ran" "0" "$_wu_rc"
assert_eq "[SPEC-7] a map member receives the group's stage name" "$_MAP_STAGE" "$(_seen3 stage)"
assert_eq "[SPEC-7] a map member receives the plugin id" "$_FIX_ID" "$(_seen3 plugin)"
assert_eq "[SPEC-7] a map member receives the plugin dir" "$_FIX_DIR" "$(_seen3 dir)"
# The element is what distinguishes the six members; stage alone cannot.
assert_eq "[SPEC-7] ZBUILD_MAP_ELEMENT still distinguishes members" "security" "$(_seen3 element)"
_map_env_plugin="$(jq -r 'select(.type=="plugin.run.start") | .plugin' "$_MAP_EVENTS" 2>/dev/null | head -1)"
assert_eq "[SPEC-7] a map member's event envelope is stamped" "$_FIX_ID" "$_map_env_plugin"

if [[ "$_saved_plugins_root" != "__UNSET__" ]]; then
    export ZBUILD_PLUGINS_ROOT="$_saved_plugins_root"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
