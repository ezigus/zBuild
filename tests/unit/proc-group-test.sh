#!/usr/bin/env bash
# tests/unit/proc-group-test.sh
# Unit cover for scripts/lib/proc-group.sh (#1748): argument validation, the
# no-op paths, and the self-group refusal. The process-group behaviour that
# needs a live setsid is covered by tests/integration/test-stage-proc-group*.
#
# This tier is also what scripts/check-coverage.sh traces, so proc-group.sh is
# only visible to the CI floor from here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "proc-group.sh — shared process-group helpers (#1748)"
setup_test_env "proc-group-unit"

# shellcheck source=../../scripts/lib/proc-group.sh
source "$REPO_ROOT/scripts/lib/proc-group.sh"

# ─── U1: the include guard is idempotent ────────────────────────────────────
print_test_section "U1. sourcing twice is a no-op"

source "$REPO_ROOT/scripts/lib/proc-group.sh"
if declare -F zbuild_pg_kill >/dev/null 2>&1 && declare -F zbuild_pg_resolve >/dev/null 2>&1; then
    assert_pass "U1: helpers survive a second source"
else
    assert_fail "U1: helpers survive a second source" "a helper went missing"
fi

# ─── U2: the prefix survives the fresh-shell scrub ──────────────────────────
# The `_ZBUILD_` spelling is load-bearing — every consumer reads the prefix
# AFTER _zbuild_make_fresh_shell, whose pattern is ^(ZBUILD_|_TPL_). A rename
# to ZBUILD_PG_PREFIX would silently disable process groups everywhere, and
# #1873's scrub now clears empty arrays that previously slipped through.
print_test_section "U2. _ZBUILD_PG_PREFIX is not swept by _zbuild_make_fresh_shell"

_u2_out="$(bash -c '
    source "'"$REPO_ROOT/scripts/lib/env-scrub.sh"'"
    source "'"$REPO_ROOT/scripts/lib/proc-group.sh"'"
    ( _zbuild_make_fresh_shell
      declare -p _ZBUILD_PG_PREFIX >/dev/null 2>&1 && printf "SURVIVED\n" || printf "SCRUBBED\n" )
' 2>/dev/null || true)"
if [[ "$_u2_out" == "SURVIVED" ]]; then
    assert_pass "U2: the prefix survives the ZBUILD_* scrub"
else
    assert_fail "U2: the prefix survives the ZBUILD_* scrub" "got: '$_u2_out'"
fi

# ─── U3: zbuild_pg_resolve rejects non-numeric and empty input ──────────────
print_test_section "U3. zbuild_pg_resolve validates its argument"

for _bad in "" "abc" "12x" "-5" "1 2"; do
    _got="$(zbuild_pg_resolve "$_bad" 2>/dev/null || true)"
    if [[ -z "$_got" ]]; then
        assert_pass "U3: resolve('$_bad') yields nothing"
    else
        assert_fail "U3: resolve('$_bad') yields nothing" "got: '$_got'"
    fi
done

# ─── U4: our own group never resolves ───────────────────────────────────────
# Signalling a group we belong to would take down the runner, so "cannot prove
# it is distinct" must read as empty rather than as our own PGID.
print_test_section "U4. zbuild_pg_resolve refuses to hand back our own group"

_u4_got="$(zbuild_pg_resolve "$$" 2>/dev/null || true)"
if [[ -z "$_u4_got" ]]; then
    assert_pass "U4: resolve(self) yields nothing (same group)"
else
    assert_fail "U4: resolve(self) yields nothing (same group)" "got: '$_u4_got'"
fi

# ─── U5: zbuild_pg_kill is a safe no-op on junk input ───────────────────────
print_test_section "U5. zbuild_pg_kill validates its argument"

for _bad in "" "abc" "-1"; do
    zbuild_pg_kill "$_bad" >/dev/null 2>&1
    _rc=$?
    if [[ "$_rc" -eq 0 ]]; then
        assert_pass "U5: kill('$_bad') returns 0 without signalling"
    else
        assert_fail "U5: kill('$_bad') returns 0 without signalling" "rc=$_rc"
    fi
done

# ─── U6: a dead group is a no-op, and returns before the grace elapses ──────
# The early return on a drained group is what keeps teardown cheap; a helper
# that always slept the full grace would add a second to every stage.
print_test_section "U6. zbuild_pg_kill returns immediately when the group is gone"

_u6_start="${EPOCHSECONDS:-$(date -u +%s)}"
zbuild_pg_kill 2147483646 3 >/dev/null 2>&1
_u6_rc=$?
_u6_elapsed=$(( ${EPOCHSECONDS:-$(date -u +%s)} - _u6_start ))
if [[ "$_u6_rc" -eq 0 ]]; then
    assert_pass "U6: kill of an absent group returns 0"
else
    assert_fail "U6: kill of an absent group returns 0" "rc=$_u6_rc"
fi
if [[ "$_u6_elapsed" -lt 3 ]]; then
    assert_pass "U6: returns before the grace window elapses (${_u6_elapsed}s < 3s)"
else
    assert_fail "U6: returns before the grace window elapses" "took ${_u6_elapsed}s"
fi

# ─── U7: the caller's own group is refused by the kill helper too ───────────
# `set -m` makes the probe its own group leader, so a regressed guard kills the
# probe rather than the group this suite runs in.
print_test_section "U7. zbuild_pg_kill refuses the caller's own PGID"

_u7_script="$TEST_TEMP_DIR/u7-probe.sh"
cat > "$_u7_script" <<U7EOF
source "$REPO_ROOT/scripts/lib/proc-group.sh"
_self="\$(ps -o pgid= -p \$\$ 2>/dev/null | tr -d ' ')"
zbuild_pg_kill "\$_self"
printf 'SURVIVED\n'
U7EOF
( set -m; bash "$_u7_script" > "$TEST_TEMP_DIR/u7-out.txt" 2>/dev/null & wait $! ) || true
_u7_out="$(cat "$TEST_TEMP_DIR/u7-out.txt" 2>/dev/null || echo '')"
if [[ "$_u7_out" == "SURVIVED" ]]; then
    assert_pass "U7: the caller survives killing its own PGID"
else
    assert_fail "U7: the caller survives killing its own PGID" "got: '$_u7_out'"
fi

# ─── U9: the grace window is real — a TERM handler gets to run ──────────────
# The escalation is the whole contract. Asserting only "the process is dead"
# passes just as well against a bare SIGKILL, which is the defect this design
# exists to prevent — a suite that flushes coverage on TERM would lose it.
print_test_section "U9. TERM lands before KILL, and the handler has time to act"

for _fn in zbuild_pid_kill zbuild_pg_kill; do
    _u9_flag="$TEST_TEMP_DIR/u9-handled-$_fn"
    _u9_ready="$TEST_TEMP_DIR/u9-ready-$_fn"
    rm -f "$_u9_flag" "$_u9_ready"
    # `sleep & wait`, not a foreground `sleep`: bash defers a trap until the
    # foreground child returns, so a foreground sleep would swallow the TERM for
    # its full duration and this would measure bash's scheduling, not the grace.
    cat > "$TEST_TEMP_DIR/u9-victim.sh" <<U9EOF
trap 'printf handled > "$_u9_flag"; exit 0' TERM
printf ready > "$_u9_ready"
sleep 10 &
wait
U9EOF
    # Job control must be on in THIS shell for the child to lead its own group —
    # the same reason plugin.sh sets it at the spawn site rather than inside.
    set -m
    bash "$TEST_TEMP_DIR/u9-victim.sh" >/dev/null 2>&1 &
    _u9_child=$!
    set +m

    _w=0
    while [[ ! -s "$_u9_ready" && "$_w" -lt 30 ]]; do sleep 0.1 2>/dev/null || true; _w=$((_w + 1)); done

    if [[ "$_fn" == "zbuild_pid_kill" ]]; then
        zbuild_pid_kill "$_u9_child"
    else
        zbuild_pg_kill "$(ps -o pgid= -p "$_u9_child" 2>/dev/null | tr -d ' ' || true)"
    fi
    wait "$_u9_child" 2>/dev/null || true

    if [[ -s "$_u9_flag" ]]; then
        assert_pass "U9: $_fn — the TERM handler ran before escalation"
    else
        assert_fail "U9: $_fn — the TERM handler ran before escalation" \
            "no handler output; TERM and KILL landed together"
    fi
    if kill -0 "$_u9_child" 2>/dev/null; then
        assert_fail "U9: $_fn — the process is gone afterwards" "still alive"
        kill -KILL "$_u9_child" 2>/dev/null || true
    else
        assert_pass "U9: $_fn — the process is gone afterwards"
    fi
done

# ─── U10: a non-numeric grace does not collapse into a bare KILL ────────────
# `_grace * 10` in an arithmetic context turns junk into 0, which would zero the
# poll loop and skip straight to SIGKILL — silently losing the escalation.
print_test_section "U10. a non-numeric grace clamps to the default"

for _g in "" "fast" "0" "-3" "2"; do
    _want=$([[ "$_g" =~ ^[0-9]+$ && "$_g" -gt 0 ]] && printf '%s' "$_g" || printf '1')
    _got="$(_zbuild_pg_grace "$_g")"
    if [[ "$_got" == "$_want" ]]; then
        assert_pass "U10: grace('$_g') → $_want"
    else
        assert_fail "U10: grace('$_g') → $_want" "got: '$_got'"
    fi
done

# ─── U8: the probe is populated iff setsid -w works ─────────────────────────
print_test_section "U8. _ZBUILD_PG_PREFIX agrees with the platform"

if command -v setsid >/dev/null 2>&1 && setsid -w true >/dev/null 2>&1; then
    if [[ ${#_ZBUILD_PG_PREFIX[@]} -gt 0 && "${_ZBUILD_PG_PREFIX[0]}" == "setsid" ]]; then
        assert_pass "U8: setsid usable → prefix is (setsid -w)"
    else
        assert_fail "U8: setsid usable → prefix is (setsid -w)" \
            "prefix: '${_ZBUILD_PG_PREFIX[*]:-}'"
    fi
else
    if [[ ${#_ZBUILD_PG_PREFIX[@]} -eq 0 ]]; then
        assert_pass "U8: setsid unusable → prefix empty (PID-kill fallback)"
    else
        assert_fail "U8: setsid unusable → prefix empty (PID-kill fallback)" \
            "prefix: '${_ZBUILD_PG_PREFIX[*]}'"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
