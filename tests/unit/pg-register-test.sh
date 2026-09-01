#!/usr/bin/env bash
# Tests: process groups are registered by whoever CREATES them (#2024).
#
# ADR-062 §1 had the engine record a stage's process group at dispatch. It could
# not: a stage is a bash function call, not a subprocess, so at dispatch there is
# no group to record. The code took the only pid at hand — `$$` — and wrote
# zbuild's OWN group. teardown then skips it, correctly, because signalling your
# own group takes the runner down with it.
#
# So every record was unkillable, every record was skipped, and §2's kill loop
# has never freed anything. The number on disk looked entirely plausible, which
# is why it survived #2001, #2018 and an ADR.
#
# The direction reverses here: whoever makes a group registers it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/proc-group.sh"

print_test_header "process groups are registered by their creator (#2024)"
setup_test_env "pg-register"

SD="$TEST_TEMP_DIR/state"
mkdir -p "$SD"

# ── SPEC-1: registering your OWN group is refused ───────────────────────────
# This is the whole defect, turned into an invariant. A record naming the
# registrar's own group can never be acted on, and writing one is worse than
# writing nothing: it makes the mechanism look live while it does nothing.
SELF_PG="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
ZBUILD_STATE_DIR="$SD" ZBUILD_CURRENT_STAGE="selftest" \
    zbuild_pg_register "$SELF_PG" 2>/dev/null || true
if [[ ! -f "$SD/runtime/stages/selftest.pgid" ]]; then
    assert_pass "SPEC-1: registering our own group is refused, not recorded"
else
    assert_fail "SPEC-1: registering our own group is refused, not recorded" \
        "wrote an unkillable record: $(cat "$SD/runtime/stages/selftest.pgid")"
fi

# ── SPEC-2: a FOREIGN group is recorded, in the #2018 format ────────────────
( set -m; sleep 300 & echo "$!" > "$TEST_TEMP_DIR/c.pid"; wait ) >/dev/null 2>&1 &
_i=0; while [[ ! -s "$TEST_TEMP_DIR/c.pid" && $_i -lt 50 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
CHILD="$(cat "$TEST_TEMP_DIR/c.pid" 2>/dev/null)"
CHILD_PG="$(ps -o pgid= -p "$CHILD" 2>/dev/null | tr -d ' ')"
ZBUILD_STATE_DIR="$SD" ZBUILD_CURRENT_STAGE="test" \
    zbuild_pg_register "$CHILD_PG" 2>/dev/null || true
REC="$SD/runtime/stages/test.pgid"
if [[ -f "$REC" ]]; then
    IFS=$'\t' read -r _rp _rs < "$REC"
    if [[ "$_rp" == "$CHILD_PG" && -n "${_rs:-}" ]]; then
        assert_pass "SPEC-2: a foreign group is recorded with its start time"
    else
        assert_fail "SPEC-2: a foreign group is recorded with its start time" \
            "pgid='$_rp' (want $CHILD_PG) start='${_rs:-<empty>}'"
    fi
else
    assert_fail "SPEC-2: a foreign group is recorded with its start time" "no record written"
fi

# ── SPEC-3: what was recorded is actually killable ─────────────────────────
# The property the old record lacked. Asserting the OUTCOME, because "a number
# was written" was true of the broken version too.
if declare -F zbuild_pg_record_pgid >/dev/null 2>&1; then
    _kp="$(zbuild_pg_record_pgid "$REC" || true)"
else
    _kp=""
fi
zbuild_pg_kill "$_kp" 2>/dev/null || true
_i=0; while kill -0 "$CHILD" 2>/dev/null && [[ $_i -lt 40 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
if ! kill -0 "$CHILD" 2>/dev/null; then
    assert_pass "SPEC-3: the recorded group can actually be killed"
else
    assert_fail "SPEC-3: the recorded group can actually be killed" \
        "pid $CHILD survived — the record names something unkillable, as before"
    kill -9 -- "-$CHILD_PG" 2>/dev/null || true
fi

# ── SPEC-4: the inert dispatch record is GONE ──────────────────────────────
# lifecycle.sh must no longer write `$$`'s group. Leaving it would keep a record
# on disk that nothing can act on, next to real ones — and the sweep would then
# report skips for records that were never actionable in the first place.
if grep -qE 'zbuild_pg_resolve "\$\$"|ps -o pgid= -p "\$\$"' "$REPO_ROOT/core/plugin-registry/lifecycle.sh"; then
    assert_fail "SPEC-4: the dispatch seam no longer records its own group" \
        "lifecycle.sh still derives the pgid from \$\$ — that is the unkillable record"
else
    assert_pass "SPEC-4: the dispatch seam no longer records its own group"
fi

# ── SPEC-5: the two sites that MAKE groups register them ───────────────────
# A registration helper nothing calls is the same defect one layer up.
for _site in "$REPO_ROOT/plugins/tool/test/plugin.sh" "$REPO_ROOT/core/router/route.sh"; do
    if grep -q 'zbuild_pg_register' "$_site"; then
        assert_pass "SPEC-5: $(basename "$_site") registers the group it creates"
    else
        assert_fail "SPEC-5: $(basename "$_site") registers the group it creates" \
            "it creates a process group the engine cannot see"
    fi
done

print_test_results
