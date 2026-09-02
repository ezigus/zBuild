#!/usr/bin/env bash
# Tests: the ADR-062 .pgid records are READ after a hard kill (#2018).
#
# ADR-062 §1 made the engine record, at dispatch, the process group it just
# spawned. On a normal exit teardown frees every recorded group. Nothing read
# those records on a LATER invocation, so `kill -9` on zbuild itself — a closed
# lid, a reclaimed CI runner — left the groups running and the records on disk.
# That is #1748 reached by a different route.
#
# The danger the sweep must not create is PID RECYCLING: a pgid whose number the
# kernel has handed to something else. Signalling it kills a stranger. So the
# sweep proves identity before it acts, and when it cannot prove identity it
# skips and says why — never guesses.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "pgid sweep — records are read, identity is proven (#2018)"
setup_test_env "pgid-sweep"

source "$REPO_ROOT/scripts/lib/proc-group.sh"
source "$REPO_ROOT/scripts/lib/cleanup.sh"

DR="$TEST_TEMP_DIR/data"
RUNTIME="$DR/repos/zbuild/issues/4242/runs/20260901120000-1111/runtime/stages"
mkdir -p "$RUNTIME"

# A real, killable process group we own: setsid-less, so we make a child in its
# own group via a subshell that reports its pgid.
_spawn_group() {
    local _out="$1"
    ( set -m; sleep 300 & echo "$!" > "$_out"; wait ) >/dev/null 2>&1 &
    local _i=0
    while [[ ! -s "$_out" && $_i -lt 50 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
    cat "$_out" 2>/dev/null
}

_starttime_of() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'; }

# ── SPEC-1: a record whose process is gone is stale, not a kill target ──────
DEAD_PID="$( ( sleep 0.1 ) & echo $! )"; wait "$DEAD_PID" 2>/dev/null || true
printf '%s\t%s\n' "$DEAD_PID" "some old start time" > "$RUNTIME/build.pgid"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"build.pgid"*$'\t'stale$'\t'* ]]; then
    assert_pass "SPEC-1: a record with no live process is stale"
else
    assert_fail "SPEC-1: a record with no live process is stale" "got: $plan"
fi

# ── SPEC-2: a live group whose recorded start time MATCHES is ours ──────────
LIVE_PID="$(_spawn_group "$TEST_TEMP_DIR/live.pid")"
LIVE_PGID="$(ps -o pgid= -p "$LIVE_PID" 2>/dev/null | tr -d ' ')"
printf '%s\t%s\n' "$LIVE_PGID" "$(_starttime_of "$LIVE_PGID")" > "$RUNTIME/test.pgid"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"test.pgid"*$'\t'kill$'\t'* ]]; then
    assert_pass "SPEC-2: a live group with a matching start time is a kill target"
else
    assert_fail "SPEC-2: a live group with a matching start time is a kill target" "got: $plan"
fi

# ── SPEC-3: a live pgid whose start time DIFFERS is recycled — never killed ─
printf '%s\t%s\n' "$LIVE_PGID" "Mon Jan 1 00:00:00 2001" > "$RUNTIME/recycled.pgid"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"recycled.pgid"*$'\t'skip$'\t'*recycled* ]]; then
    assert_pass "SPEC-3: a recycled pgid is skipped, and says so"
else
    assert_fail "SPEC-3: a recycled pgid is skipped, and says so" "got: $plan"
fi
rm -f "$RUNTIME/recycled.pgid"

# ── SPEC-4: a legacy bare-pgid record cannot be proven — skip, do not guess ─
printf '%s' "$LIVE_PGID" > "$RUNTIME/legacy.pgid"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"legacy.pgid"*$'\t'skip$'\t'* ]]; then
    assert_pass "SPEC-4: a record with no start time is skipped, not killed"
else
    assert_fail "SPEC-4: a record with no start time is skipped, not killed" "got: $plan"
fi
rm -f "$RUNTIME/legacy.pgid"

# ── SPEC-5: dry-run kills nothing ───────────────────────────────────────────
_cleanup_apply_pgid_plan "$plan" "true" "$DR" >/dev/null 2>&1 || true
if kill -0 "$LIVE_PID" 2>/dev/null; then
    assert_pass "SPEC-5: dry-run leaves the group alive"
else
    assert_fail "SPEC-5: dry-run leaves the group alive" "process $LIVE_PID died on a dry run"
fi

# ── SPEC-6: --apply kills the proven group and removes its record ───────────
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
_cleanup_apply_pgid_plan "$plan" "false" "$DR" >/dev/null 2>&1 || true
_i=0; while kill -0 "$LIVE_PID" 2>/dev/null && [[ $_i -lt 40 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
if ! kill -0 "$LIVE_PID" 2>/dev/null; then
    assert_pass "SPEC-6: apply frees the proven group"
else
    assert_fail "SPEC-6: apply frees the proven group" "process $LIVE_PID still alive"
fi
if [[ ! -f "$RUNTIME/test.pgid" ]]; then
    assert_pass "SPEC-6: the record is removed once the group is gone"
else
    assert_fail "SPEC-6: the record is removed once the group is gone" "$RUNTIME/test.pgid still exists"
fi

# ── SPEC-7: the stale record is reaped too, so runtime/ is not a graveyard ──
if [[ ! -f "$RUNTIME/build.pgid" ]]; then
    assert_pass "SPEC-7: a stale record is removed on apply"
else
    assert_fail "SPEC-7: a stale record is removed on apply" "build.pgid survived"
fi

# ── SPEC-8: the sweep refuses our OWN process group ─────────────────────────
SELF_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
printf '%s\t%s\n' "$SELF_PGID" "$(_starttime_of "$SELF_PGID")" > "$RUNTIME/self.pgid"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"self.pgid"*$'\t'skip$'\t'* ]]; then
    assert_pass "SPEC-8: the sweep refuses its own process group"
else
    assert_fail "SPEC-8: the sweep refuses its own process group" "got: $plan"
fi
rm -f "$RUNTIME/self.pgid"

# ── SPEC-9: the WRITER records a start time ─────────────────────────────────
# Without it every record lands in SPEC-4's unprovable bucket and the sweep can
# never act — the reading half would be inert the way the writing half was.
#
# The writer moved in #2024: it was the dispatch seam in lifecycle.sh, which
# could only ever observe the ENGINE's own group, so the record it wrote was
# unkillable. Groups are registered by whoever creates them now, so this asserts
# on zbuild_pg_register — and on lifecycle.sh NOT writing one, because a record
# from that seam is unactionable by construction.
if grep -qE 'lstart' "$REPO_ROOT/scripts/lib/proc-group.sh"; then
    assert_pass "SPEC-9: the registered record includes a start time"
else
    assert_fail "SPEC-9: the registered record includes a start time" \
        "zbuild_pg_register writes a bare pgid — nothing the sweep can prove identity from"
fi
if grep -qE '\.pgid"' "$REPO_ROOT/core/plugin-registry/lifecycle.sh"; then
    assert_fail "SPEC-9: the dispatch seam writes no record (#2024)" \
        "lifecycle.sh writes a pgid again — at that seam it can only be the engine's own, and unkillable"
else
    assert_pass "SPEC-9: the dispatch seam writes no record (#2024)"
fi

# ── SPEC-10: both run layouts are found, and the run id is read from either ─
# ADR-059 §1 keys by path, and two shapes exist on disk: `state/runs/<rid>/` for
# a plain run and `repos/<r>/issues/<n>/runs/<rid>/` for an issue. The scanner
# globs recursively and takes the run id four components up, so it is meant to
# be layout-agnostic. Asserting that, because every SPEC above uses only one of
# the two shapes — a scanner that silently saw half the tree would pass them all.
ALT="$DR/state/runs/20260901130000-2222/runtime/stages"
mkdir -p "$ALT"
ALT_DEAD="$( ( sleep 0.1 ) & echo $! )"; wait "$ALT_DEAD" 2>/dev/null || true
printf '%s\t%s\n' "$ALT_DEAD" "an old start time" > "$ALT/design.pgid"
plan="$(_cleanup_scan_pgids "$DR" 2>/dev/null || true)"
if [[ "$plan" == *"state/runs/20260901130000-2222"*"design.pgid"*$'\t'stale$'\t'* ]]; then
    assert_pass "SPEC-10: the state/runs/ layout is scanned too"
else
    assert_fail "SPEC-10: the state/runs/ layout is scanned too" "got: $plan"
fi

# ── SPEC-11: one reader understands BOTH record formats ────────────────────
# Adding the start-time field to the dispatch record nearly broke ADR-062 §2 —
# the path that runs on every normal exit. teardown read the record with `cat`
# and guarded on `^[0-9]+$`; a TSV record fails that guard, hits `continue`, and
# teardown then kills nothing while reporting success. Nothing caught it: no
# test asserts teardown's kill COUNT, so the silent-nothing was invisible.
#
# Two formats are legitimately on disk — the engine's dispatch record with a
# start time, tool/test's bare `test-stage.pgid`, and any record written before
# #2018 — so the guard is that ONE reader handles all of them.
printf '%s\t%s\n' "4242" "Tue Sep 1 10:00:00 2026" > "$TEST_TEMP_DIR/tsv.pgid"
printf '%s\n' "4243" > "$TEST_TEMP_DIR/bare.pgid"
printf '%s\n' "not-a-pgid" > "$TEST_TEMP_DIR/junk.pgid"
_r_tsv="$(zbuild_pg_record_pgid "$TEST_TEMP_DIR/tsv.pgid" || true)"
_r_bare="$(zbuild_pg_record_pgid "$TEST_TEMP_DIR/bare.pgid" || true)"
_r_junk="$(zbuild_pg_record_pgid "$TEST_TEMP_DIR/junk.pgid" || true)"
if [[ "$_r_tsv" == "4242" && "$_r_bare" == "4243" && -z "$_r_junk" ]]; then
    assert_pass "SPEC-11: one reader handles TSV, bare, and junk records"
else
    assert_fail "SPEC-11: one reader handles TSV, bare, and junk records" \
        "tsv='$_r_tsv' (want 4242) bare='$_r_bare' (want 4243) junk='$_r_junk' (want empty)"
fi

# And the consumers must actually USE it — a shared reader nothing calls is the
# same defect one layer up.
for _consumer in "$REPO_ROOT/plugins/tool/teardown/plugin.sh" \
                 "$REPO_ROOT/plugins/tool/test/plugin.sh"; do
    if grep -q 'zbuild_pg_record_pgid' "$_consumer"; then
        assert_pass "SPEC-11: $(basename "$(dirname "$_consumer")") uses the shared reader"
    else
        assert_fail "SPEC-11: $(basename "$(dirname "$_consumer")") uses the shared reader" \
            "still parsing the record itself — a format change will silently disable it"
    fi
done

print_test_results
