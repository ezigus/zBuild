#!/usr/bin/env bash
# Tests: golden file harness — proves assert_golden works with 3 minimal snapshots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/golden.sh"

print_test_header "golden contracts — assert_golden harness (E.1 seed set)"

# ─── G1: event shape golden ─────────────────────────────────────────────────
actual='{"event":"redaction.applied","version":"1"}'
set +e
assert_golden "redaction-applied-shape" "$actual"
g1_rc=$?
set -e
if [[ $g1_rc -eq 0 ]]; then
    assert_pass "G1: redaction.applied event shape matches golden"
else
    assert_fail "G1: redaction.applied event shape matches golden" "assert_golden returned $g1_rc"
fi

# ─── G2: init_state shape golden ────────────────────────────────────────────
actual='{"schema_version":"1","status":"pending"}'
set +e
assert_golden "init-state-shape" "$actual"
g2_rc=$?
set -e
if [[ $g2_rc -eq 0 ]]; then
    assert_pass "G2: init_state JSON shape matches golden"
else
    assert_fail "G2: init_state JSON shape matches golden" "assert_golden returned $g2_rc"
fi

# ─── G3: dry-run output golden ──────────────────────────────────────────────
actual="zbuild pipeline start --dry-run: ok"
set +e
assert_golden "cli-dry-run" "$actual"
g3_rc=$?
set -e
if [[ $g3_rc -eq 0 ]]; then
    assert_pass "G3: CLI dry-run output matches golden"
else
    assert_fail "G3: CLI dry-run output matches golden" "assert_golden returned $g3_rc"
fi

# ─── G4: plugin lifecycle event types golden ────────────────────────────────
# Verifies canonical hook outcome event names (plugin.*.complete, not *.done).
# Any future drift from "complete" → "done" (or new suffix) fails this golden.
# ADR-056: only run and cleanup remain as lifecycle hooks (init/finalize deleted).
_lifecycle_types="$(jq -r '
  .known_types[]
  | select(test("^plugin\\.(run|cleanup)\\.complete$"))
' "$REPO_ROOT/config/event-schema.json" | sort)"
set +e
assert_golden "plugin-lifecycle-event-types" "$_lifecycle_types"
g4_rc=$?
set -e
if [[ $g4_rc -eq 0 ]]; then
    assert_pass "G4: canonical plugin lifecycle event types match golden"
else
    assert_fail "G4: canonical plugin lifecycle event types" "assert_golden returned $g4_rc"
fi

# ─── SPEC-6: init/finalize complete events must be absent from event schema ──
# CHANGE: before ADR-056, plugin.init.complete and plugin.finalize.complete were
# present in event-schema.json; this assertion fails at that baseline.
_inf_count="$(jq -r '[.known_types[] | select(test("^plugin\\.(init|finalize)\\.complete$"))] | length' \
    "$REPO_ROOT/config/event-schema.json" 2>/dev/null)"
assert_eq "[SPEC-6] plugin.init/finalize complete events absent from event schema" "0" "$_inf_count"

# ─── SPEC-7: golden file has exactly two lifecycle entries (run and cleanup) ──
# CHANGE: before ADR-056 the golden had 4 entries (init, run, finalize, cleanup);
# after removal it must have exactly 2.
_golden_count="$(grep -c . "$REPO_ROOT/tests/golden/plugin-lifecycle-event-types.golden" 2>/dev/null)" || _golden_count=0
assert_eq "[SPEC-7] plugin lifecycle golden has exactly 2 event types (run + cleanup)" "2" "$_golden_count"

# ─── G5: router success event sequence golden ────────────────────────────────
# Verifies that a successful route_to_model T2 call emits events in the
# canonical order: precondition → route → outcome.
_ROUTER_TMP="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$_ROUTER_TMP'" EXIT

mkdir -p "$_ROUTER_TMP/events" "$_ROUTER_TMP/bin" "$_ROUTER_TMP/home/.zbuild"
printf '#!/usr/bin/env bash\necho "mock-response"\nexit 0\n' > "$_ROUTER_TMP/bin/claude"
chmod +x "$_ROUTER_TMP/bin/claude"

OLDPATH="$PATH"
export PATH="$_ROUTER_TMP/bin:$PATH"
OLDHOME="${HOME:-}"
export HOME="$_ROUTER_TMP/home"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"

OLDSCOPE="${ZBUILD_SCOPE_OVERRIDE:-}"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID

OLDDIR="${ZBUILD_EVENTS_DIR:-}" OLDJSONL="${ZBUILD_EVENTS_JSONL:-}"
OLDDB="${ZBUILD_EVENTS_DB:-}" OLDSCHEMA="${ZBUILD_EVENT_SCHEMA:-}"
export ZBUILD_EVENTS_DIR="$_ROUTER_TMP/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

source "$REPO_ROOT/core/router/route.sh"
set +e
route_to_model "T2" "test prompt" --skip-precondition 2>/dev/null
_rrc=$?
set -e

if [[ "$_rrc" -eq 0 && -f "$ZBUILD_EVENTS_JSONL" ]]; then
    _seq="$(jq -r '.type' "$ZBUILD_EVENTS_JSONL" 2>/dev/null)"
    set +e
    assert_golden "router-success-event-sequence" "$_seq"
    g5_rc=$?
    set -e
    if [[ $g5_rc -eq 0 ]]; then
        assert_pass "G5: router success event sequence matches golden"
    else
        assert_fail "G5: router success event sequence" "assert_golden returned $g5_rc"
    fi

    _keys="$(jq -r 'select(.type=="model.route") | .data | keys[]' "$ZBUILD_EVENTS_JSONL" 2>/dev/null | sort)"
    set +e
    assert_golden "router-model-route-event-keys" "$_keys"
    g5b_rc=$?
    set -e
    if [[ $g5b_rc -eq 0 ]]; then
        assert_pass "G5b: model.route event data keys match golden"
    else
        assert_fail "G5b: model.route event data keys" "assert_golden returned $g5b_rc"
    fi
else
    assert_fail "G5: router success event sequence" "route_to_model rc=$_rrc or no events file"
    assert_fail "G5b: model.route event data keys" "router call failed"
fi

export PATH="$OLDPATH"
export HOME="$OLDHOME"
if [[ -n "$OLDSCOPE" ]]; then export ZBUILD_SCOPE_OVERRIDE="$OLDSCOPE"; else unset ZBUILD_SCOPE_OVERRIDE; fi
if [[ -n "$OLDDIR" ]]; then export ZBUILD_EVENTS_DIR="$OLDDIR"; else unset ZBUILD_EVENTS_DIR; fi
if [[ -n "$OLDJSONL" ]]; then export ZBUILD_EVENTS_JSONL="$OLDJSONL"; else unset ZBUILD_EVENTS_JSONL; fi
if [[ -n "$OLDDB" ]]; then export ZBUILD_EVENTS_DB="$OLDDB"; else unset ZBUILD_EVENTS_DB; fi
if [[ -n "$OLDSCHEMA" ]]; then export ZBUILD_EVENT_SCHEMA="$OLDSCHEMA"; else unset ZBUILD_EVENT_SCHEMA; fi

# (#979) G6 removed: the retired cq.* event types were struck from
# config/event-schema.json and tests/golden/cq-event-types.golden was deleted
# together with the compound-quality lattice.

print_test_results
exit $((FAIL > 0))
