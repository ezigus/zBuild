#!/usr/bin/env bash
# E2E (#1705): plugin.run.start/complete means ONE thing — an engine dispatch.
#
# The bug: two unrelated emitters shared one event name. The engine emitted a
# start/complete pair per hook invocation; ~15 plugins ALSO emitted
# plugin.run.complete carrying a domain result. On the audited run that gave 23
# starts against 37 completes for ~18 dispatches, so nothing downstream could
# count dispatches, and the envelope's .plugin/.kind — the fields the schema
# advertises for exactly that query — were empty on every record.
#
# These assertions run against a MOCKED FULL RUN (the parity fixture drives
# intake → plan → build → test → pr through the real engine), because that is
# the only place the two emitters actually interleave. A unit test that stubs
# emit_event cannot see either defect: the envelope is built inside the real
# event-bus, and the collision only appears when real plugins run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin lifecycle events on a mocked full run (#1705)"
setup_test_env "plugin-event-balance-full-run"

FIXTURE="$REPO_ROOT/tests/golden/parity/run-fixture.sh"
RUN_DIR="$TEST_TEMP_DIR/run"
BIN_DIR="$TEST_TEMP_DIR/bin"
mkdir -p "$RUN_DIR/events" "$BIN_DIR"

set +e
(
    unset GITHUB_ACTIONS CI GITHUB_STEP_SUMMARY RUNNER_OS 2>/dev/null || true
    FIXTURE_STATE_DIR="$RUN_DIR" FIXTURE_BIN_DIR="$BIN_DIR" \
        ZBUILD_PLAN_CONTEXT_DIR="$TEST_TEMP_DIR/pc" \
        bash "$FIXTURE" >/dev/null 2>&1
)
_run_rc=$?
set -e
assert_eq "mocked full run exits 0" "0" "$_run_rc"

EVENTS="$RUN_DIR/events/events.jsonl"
assert_file_exists "mocked full run produced events.jsonl" "$EVENTS"

_count() { jq -r --arg t "$1" 'select(.type==$t)|.type' "$EVENTS" 2>/dev/null | wc -l | tr -d ' '; }

_starts="$(_count plugin.run.start)"
_completes="$(_count plugin.run.complete)"

# ── SPEC-1: the pair balances ────────────────────────────────────────────────
# CHANGE: at baseline plugins self-emitted `complete` (and only some a `start`),
# so completes outnumbered starts and neither equalled the dispatch count.
if [[ "$_starts" -gt 0 ]]; then
    assert_pass "[SPEC-1] the run dispatched at least one plugin ($_starts)"
else
    assert_fail "[SPEC-1] the run dispatched at least one plugin" "0 plugin.run.start events"
fi
assert_eq "[SPEC-1] plugin.run.start count == plugin.run.complete count" "$_starts" "$_completes"

# ── SPEC-2: it balances PER PLUGIN, not just in total ────────────────────────
# A global total can balance while individual plugins are skewed; the audited
# run's defect was per-plugin (only some plugins self-emitted a start).
_skew="$(jq -rs '
    (map(select(.type=="plugin.run.start"))    | group_by(.plugin) | map({k:.[0].plugin, s:length})) as $st
  | (map(select(.type=="plugin.run.complete")) | group_by(.plugin) | map({k:.[0].plugin, c:length})) as $co
  | ($st|map(.k)) + ($co|map(.k)) | unique
  | map(. as $k
        | (($st[]|select(.k==$k)|.s) // 0) as $s
        | (($co[]|select(.k==$k)|.c) // 0) as $c
        | select($s != $c) | "\($k):start=\($s),complete=\($c)")
  | join(" ")' "$EVENTS" 2>/dev/null || echo "JQ_FAILED")"
if [[ -z "$_skew" ]]; then
    assert_pass "[SPEC-2] start/complete balance holds for every individual plugin"
else
    assert_fail "[SPEC-2] start/complete balance holds for every individual plugin" "$_skew"
fi

# ── SPEC-3: the envelope identifies the plugin ───────────────────────────────
# CHANGE: at baseline top-level .plugin/.kind were "" on every record, so a
# consumer filtering on the documented field matched nothing.
_empty_plugin="$(jq -r 'select(.type|startswith("plugin."))|select((.plugin//"")=="")|.type' "$EVENTS" 2>/dev/null | sort -u | tr '\n' ' ')"
if [[ -z "$_empty_plugin" ]]; then
    assert_pass "[SPEC-3] every plugin.* event carries a non-empty envelope .plugin"
else
    assert_fail "[SPEC-3] every plugin.* event carries a non-empty envelope .plugin" \
        "empty on: $_empty_plugin"
fi
_empty_kind="$(jq -r 'select(.type|startswith("plugin."))|select((.kind//"")=="")|.type' "$EVENTS" 2>/dev/null | sort -u | tr '\n' ' ')"
if [[ -z "$_empty_kind" ]]; then
    assert_pass "[SPEC-3] every plugin.* event carries a non-empty envelope .kind"
else
    assert_fail "[SPEC-3] every plugin.* event carries a non-empty envelope .kind" \
        "empty on: $_empty_kind"
fi

# ── SPEC-4: one name, one meaning ────────────────────────────────────────────
# The engine's lifecycle pair is a dispatch marker and carries no domain result.
# A plugin that resumed self-emitting under the old name would put a verdict on
# it — which is precisely how the two meanings became indistinguishable.
_domain_on_lifecycle="$(jq -r '
    select(.type=="plugin.run.start" or .type=="plugin.run.complete")
  | select((.data|type=="object") and ((.data|keys) - ["plugin","kind"] | length) > 0)
  | .type' "$EVENTS" 2>/dev/null | sort -u | tr '\n' ' ')"
if [[ -z "$_domain_on_lifecycle" ]]; then
    assert_pass "[SPEC-4] no domain payload rides on the engine's lifecycle pair"
else
    assert_fail "[SPEC-4] no domain payload rides on the engine's lifecycle pair" \
        "extra data keys on: $_domain_on_lifecycle"
fi

# ── SPEC-5: the domain result still exists, under its own name ───────────────
# Splitting the name must not silently drop the plugins' result signal.
_results="$(_count plugin.result)"
if [[ "$_results" -gt 0 ]]; then
    assert_pass "[SPEC-5] plugins report domain results as plugin.result ($_results)"
else
    assert_fail "[SPEC-5] plugins report domain results as plugin.result" \
        "no plugin.result events in a run that dispatched $_starts plugins"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
