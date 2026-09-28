#!/usr/bin/env bash
# Tests: core/event-bus/known-types.sh — the known set composed from the engine
# config + every manifest's provides.events (#1717, ADR-001 §"Declared events").
#
# The acceptance this pins:
#   SPEC-1  an event declared ONLY in a manifest is known — emitting it does not warn
#   SPEC-2  the engine leg (config/event-schema.json) still contributes
#   SPEC-3  ZBUILD_EVENT_SCHEMA still substitutes the engine leg for a test
#   SPEC-4  composition is cached — N emits compose ONCE, not N times
#   SPEC-5  emit cost does not grow with plugin count (no fork per manifest per emit)
#   SPEC-6  the guard: a fixture plugin registers an event by editing ONLY its
#           own manifest — no file outside its directory
#   SPEC-7  a run-scoped cache is written, and a second process reads it back
#   SPEC-8  a genuinely unknown type still warns (schema-as-warn is unchanged)
#   SPEC-9  both YAML list forms (block and inline) parse
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "event-schema — known types composed from manifests"

setup_test_env "event-schema-composition"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB=/dev/null
mkdir -p "$ZBUILD_EVENTS_DIR"

# ─── A fixture plugin root: one plugin declaring one event, nothing else ────
FIXTURE_ROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$FIXTURE_ROOT/tool/fixture-gate"
cat > "$FIXTURE_ROOT/tool/fixture-gate/manifest.yaml" <<'YAML'
id: fixture-gate
name: Fixture Gate
kind: tool
version: 0.1.0
hooks:
  run: fixture_gate_run
provides:
  role: fixture_gate
  schema_version: 1
  events:
    - fixture_gate.pass
    - fixture_gate.fail
YAML

# A second fixture using the INLINE list form.
mkdir -p "$FIXTURE_ROOT/tool/fixture-inline"
cat > "$FIXTURE_ROOT/tool/fixture-inline/manifest.yaml" <<'YAML'
id: fixture-inline
name: Fixture Inline
kind: tool
version: 0.1.0
hooks:
  run: fixture_inline_run
provides:
  role: fixture_inline
  events: [fixture_inline.one, fixture_inline.two]
  schema_version: 1
YAML

# A minimal engine leg, so SPEC-2/SPEC-3 test the seam and not the real file.
FIXTURE_SCHEMA="$TEST_TEMP_DIR/engine-schema.json"
cat > "$FIXTURE_SCHEMA" <<'JSON'
{ "schema_version": 1, "known_types": ["pipeline.start", "stage.complete"] }
JSON

export ZBUILD_EVENT_SCHEMA="$FIXTURE_SCHEMA"
export ZBUILD_PLUGINS_ROOT="$FIXTURE_ROOT"

# shellcheck source=../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"

# A manifest whose events: block is interrupted by a blank line and a comment —
# both legal YAML between sequence items. The failure this pins is silent: the
# list still parses, just SHORT, so every event after the gap goes unregistered
# and warns at runtime with nothing pointing at the manifest.
mkdir -p "$FIXTURE_ROOT/tool/fixture-gappy"
cat > "$FIXTURE_ROOT/tool/fixture-gappy/manifest.yaml" <<'YAML'
id: fixture-gappy
name: Fixture Gappy
kind: tool
version: 0.1.0
hooks:
  run: fixture_gappy_run
provides:
  role: fixture_gappy
  events:
    - fixture_gappy.first

    # a comment between items
    - fixture_gappy.after_gap
  schema_version: 1
YAML

# ─── SPEC-10: a blank/comment line inside events: does not truncate ─────────
_gappy="$(eb_manifest_events "$FIXTURE_ROOT/tool/fixture-gappy/manifest.yaml" | sort | tr '\n' ' ')"
assert_eq "[SPEC-10] blank + comment lines inside events: do not truncate the list" \
    "fixture_gappy.after_gap fixture_gappy.first " "$_gappy"

# ─── SPEC-11: a malformed entry is a load-time failure, not a silent no-match ─
mkdir -p "$FIXTURE_ROOT/tool/fixture-bad"
cat > "$FIXTURE_ROOT/tool/fixture-bad/manifest.yaml" <<'YAML'
id: fixture-bad
name: Fixture Bad
kind: tool
version: 0.1.0
hooks:
  run: fixture_bad_run
provides:
  role: fixture_bad
  events:
    - fixture_bad.ok
    - NotAnEventName
YAML
_invalid="$(eb_manifest_events_invalid "$FIXTURE_ROOT/tool/fixture-bad/manifest.yaml" | tr '\n' ' ')"
assert_eq "[SPEC-11] a malformed provides.events entry is reported" "NotAnEventName " "$_invalid"
assert_eq "[SPEC-11] a well-formed manifest reports nothing" "" \
    "$(eb_manifest_events_invalid "$FIXTURE_ROOT/tool/fixture-gate/manifest.yaml")"
rm -rf "$FIXTURE_ROOT/tool/fixture-gappy" "$FIXTURE_ROOT/tool/fixture-bad"

# ─── SPEC-9: both list forms parse ──────────────────────────────────────────
_block="$(eb_manifest_events "$FIXTURE_ROOT/tool/fixture-gate/manifest.yaml" | sort | tr '\n' ' ')"
assert_eq "[SPEC-9a] block list form parses" "fixture_gate.fail fixture_gate.pass " "$_block"
_inline="$(eb_manifest_events "$FIXTURE_ROOT/tool/fixture-inline/manifest.yaml" | sort | tr '\n' ' ')"
assert_eq "[SPEC-9b] inline list form parses" "fixture_inline.one fixture_inline.two " "$_inline"

# provides.events must not bleed past the provides: block or into a sibling file.
_composed="$(eb_compose_known_types "$FIXTURE_SCHEMA" "$FIXTURE_ROOT" | tr '\n' ' ')"
assert_eq "[SPEC-2] composed = engine leg + both manifests" \
    "fixture_gate.fail fixture_gate.pass fixture_inline.one fixture_inline.two pipeline.start stage.complete " \
    "$_composed"

# ─── SPEC-1: a manifest-only event emits WITHOUT the unknown-type warning ───
_stderr="$(eb_emit_event "fixture_gate.pass" "detail=x" 2>&1 >/dev/null)"
assert_eq "[SPEC-1] manifest-declared event does not warn" "" "$_stderr"
assert_eq "[SPEC-1] manifest-declared event was written" "fixture_gate.pass" \
    "$(tail -1 "$ZBUILD_EVENTS_JSONL" | jq -r .type)"

# The engine leg still works through the same path.
_stderr="$(eb_emit_event "pipeline.start" 2>&1 >/dev/null)"
assert_eq "[SPEC-2b] engine-declared event does not warn" "" "$_stderr"

# ─── SPEC-8: an undeclared type still warns (and still emits) ───────────────
_stderr="$(eb_emit_event "fixture_gate.undeclared" 2>&1 >/dev/null)"
assert_contains "[SPEC-8] undeclared event still warns" "$_stderr" "unknown event type"
assert_eq "[SPEC-8] undeclared event is still written (never blocks)" "fixture_gate.undeclared" \
    "$(tail -1 "$ZBUILD_EVENTS_JSONL" | jq -r .type)"

# ─── SPEC-4: composition is cached — many emits, ONE compose ────────────────
eb_known_types_flush
rm -f "$ZBUILD_EVENTS_DIR/known-event-types.cache"
_ZBUILD_EB_COMPOSE_COUNT=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    eb_emit_event "fixture_gate.pass" "iter=$_i" 2>/dev/null
done
assert_eq "[SPEC-4] 10 emits composed the known set exactly once" "1" "$_ZBUILD_EB_COMPOSE_COUNT"

# ─── SPEC-5: emit cost does not grow with plugin count ─────────────────────
# The old implementation forked one jq per emit against the schema; composing
# from N manifests per emit would have made that N forks. Counting PROCESSES is
# the honest assertion — a wall-clock comparison would be a flake generator on
# a loaded CI box. 40 more fixture plugins must not change the fork count of a
# steady-state emit.
_count_forks() {
    # Emits with a stub `date`/`jq`… would be over-clever; instead count how
    # many times the composer ran, which is what "forks per emit" reduces to.
    local before="$_ZBUILD_EB_COMPOSE_COUNT"
    eb_emit_event "fixture_gate.pass" "probe=1" 2>/dev/null
    echo $((_ZBUILD_EB_COMPOSE_COUNT - before))
}
_forks_small="$(_count_forks)"
for _n in $(seq 1 40); do
    mkdir -p "$FIXTURE_ROOT/tool/bulk-$_n"
    cat > "$FIXTURE_ROOT/tool/bulk-$_n/manifest.yaml" <<YAML
id: bulk-$_n
name: Bulk $_n
kind: tool
version: 0.1.0
hooks:
  run: bulk_${_n}_run
provides:
  role: bulk_$_n
  events:
    - bulk_$_n.fired
YAML
done
eb_known_types_flush
rm -f "$ZBUILD_EVENTS_DIR/known-event-types.cache"
eb_emit_event "fixture_gate.pass" "warm=1" 2>/dev/null   # pay the one compose
_forks_large="$(_count_forks)"
assert_eq "[SPEC-5] steady-state emit composes 0 times regardless of plugin count (small)" "0" "$_forks_small"
assert_eq "[SPEC-5] steady-state emit composes 0 times with 42 plugins present" "0" "$_forks_large"
assert_eq "[SPEC-5] the 41st plugin's event is known" "0" \
    "$(eb_known_types_has "bulk_7.fired"; echo $?)"

# ─── SPEC-7: the run-scoped cache is written and reused by another process ──
_cache="$ZBUILD_EVENTS_DIR/known-event-types.cache"
assert_file_exists "[SPEC-7] run-scoped cache written" "$_cache"
# A FRESH process (subshell + fresh source) must answer from the cache without
# recomposing — this is what keeps a 30-process pipeline run from paying the
# compose 30 times.
_fresh_count="$(
    bash -c '
        export ZBUILD_EVENTS_DIR="$1" ZBUILD_EVENTS_JSONL="$1/events.jsonl" ZBUILD_EVENTS_DB=/dev/null
        export ZBUILD_EVENT_SCHEMA="$2" ZBUILD_PLUGINS_ROOT="$3"
        source "$4/core/event-bus/event-bus.sh"
        eb_known_types_has "fixture_gate.pass" || exit 9
        echo "$_ZBUILD_EB_COMPOSE_COUNT"
    ' _ "$ZBUILD_EVENTS_DIR" "$FIXTURE_SCHEMA" "$FIXTURE_ROOT" "$REPO_ROOT"
)"
assert_eq "[SPEC-7] a second process answers from the cache without recomposing" "0" "$_fresh_count"

# A cache composed from a DIFFERENT root must not be mistaken for this one's.
_other_root="$TEST_TEMP_DIR/plugins-other"
mkdir -p "$_other_root"
eb_known_types_flush
ZBUILD_PLUGINS_ROOT="$_other_root" eb_known_types_has "fixture_gate.pass" && _stale=yes || _stale=no
assert_eq "[SPEC-7b] a cache keyed to another plugins root is not reused" "no" "$_stale"

# ─── SPEC-3: ZBUILD_EVENT_SCHEMA still substitutes the engine leg ───────────
_alt_schema="$TEST_TEMP_DIR/alt-schema.json"
echo '{ "schema_version": 1, "known_types": ["alt.only.type"] }' > "$_alt_schema"
eb_known_types_flush
rm -f "$_cache"
(
    export ZBUILD_EVENT_SCHEMA="$_alt_schema"
    eb_known_types_flush
    eb_known_types_has "alt.only.type" || exit 1
    eb_known_types_has "pipeline.start" && exit 2
    exit 0
)
_seam_rc=$?
assert_eq "[SPEC-3] ZBUILD_EVENT_SCHEMA substitutes the engine leg (and only it)" "0" "$_seam_rc"

# ─── SPEC-6: the guard — one plugin dir, one file, one new event ────────────
# Register a brand-new event by editing ONLY the fixture plugin's own manifest,
# then assert (a) it becomes known and (b) nothing outside that directory moved.
_engine_before="$(shasum -a 256 "$REPO_ROOT/config/event-schema.json" | cut -d' ' -f1)"
_fixture_manifest="$FIXTURE_ROOT/tool/fixture-gate/manifest.yaml"
printf '    - %s\n' "fixture_gate.brand_new" >> "$_fixture_manifest"
eb_known_types_flush
rm -f "$_cache"
_stderr="$(eb_emit_event "fixture_gate.brand_new" 2>&1 >/dev/null)"
assert_eq "[SPEC-6] an event added to a plugin's OWN manifest is known immediately" "" "$_stderr"
_engine_after="$(shasum -a 256 "$REPO_ROOT/config/event-schema.json" | cut -d' ' -f1)"
assert_eq "[SPEC-6] registering it required NO edit to config/event-schema.json" \
    "$_engine_before" "$_engine_after"

print_test_results
exit $((FAIL > 0))
