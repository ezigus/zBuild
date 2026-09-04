#!/usr/bin/env bash
# Tests: a spawned child's DESCENDANTS are killed by an abort — on every platform.
#
# The fast-abort contract (Wave 15-G, #687) says an abort leaves nothing running.
# It was implemented with `setsid -w`, which does not exist on macOS: there the
# prefix is empty, no process group is created, and the abort kills a single PID
# while any grandchild survives. The test that would have caught this,
# `route-fast-abort-test.sh`, is `skip_unless_platform linux` — so the contract
# silently did not hold on half the supported platforms, and nothing said so.
#
# THIS FILE RUNS EVERYWHERE. That is the point: the gap existed because the only
# check was Linux-only.
#
# `set -m` is the mechanism — bash job control makes a backgrounded job a process
# group leader. POSIX, no external binary, identical on macOS and Linux, and
# already used for exactly this in core/pipeline/runner.sh:1974,
# plugins/tool/test/plugin.sh:387, and three integration tests.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
source "$REPO_ROOT/scripts/lib/proc-group.sh"

print_test_header "a spawned child's descendants die with it, on every platform (#2056)"
setup_test_env "process-group-isolation"

# A child that spawns a grandchild and records both pids. The grandchild is what
# a naive per-PID kill misses.
cat > "$TEST_TEMP_DIR/child.sh" <<'CHILD'
#!/usr/bin/env bash
sleep 300 &
echo "$!" > "$1/grandchild.pid"
echo "$$" > "$1/child.pid"
wait
CHILD
chmod +x "$TEST_TEMP_DIR/child.sh"

_spawn() {
    rm -f "$TEST_TEMP_DIR"/{child,grandchild}.pid
    set -m
    ( exec "$TEST_TEMP_DIR/child.sh" "$TEST_TEMP_DIR" ) >/dev/null 2>&1 &
    _SPAWN_PID=$!
    set +m
    local _i=0
    while [[ ! -s "$TEST_TEMP_DIR/grandchild.pid" && $_i -lt 100 ]]; do sleep 0.1; _i=$(( _i + 1 )); done
    _CHILD_PID="$(cat "$TEST_TEMP_DIR/child.pid" 2>/dev/null || true)"
    _GRAND_PID="$(cat "$TEST_TEMP_DIR/grandchild.pid" 2>/dev/null || true)"
}
_gone() { local _i=0; while kill -0 "$1" 2>/dev/null && [[ $_i -lt 50 ]]; do sleep 0.1; _i=$(( _i + 1 )); done; ! kill -0 "$1" 2>/dev/null; }

_spawn
if [[ -z "$_GRAND_PID" ]]; then
    assert_fail "harness: the child spawned a grandchild" "no grandchild pid recorded"
    print_test_results; exit 1
fi

# ── SPEC-1: `set -m` gives the spawn its own group, PGID == PID ────────────
# The property the whole contract rests on, and the one `setsid -w` did NOT
# provide: with `-w` setsid must fork to wait, so $! was the wrapper and the new
# session belonged to a process one fork below it.
_spawn_pg="$(ps -o pgid= -p "$_SPAWN_PID" 2>/dev/null | tr -d ' ' || true)"
_self_pg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
if [[ -n "$_spawn_pg" && "$_spawn_pg" == "$_SPAWN_PID" ]]; then
    assert_pass "SPEC-1: the spawn is its own process-group leader (pgid == pid)"
else
    assert_fail "SPEC-1: the spawn is its own process-group leader (pgid == pid)" \
        "pid=$_SPAWN_PID pgid=${_spawn_pg:-<none>} — a per-PID kill will miss its descendants"
fi
if [[ -n "$_spawn_pg" && "$_spawn_pg" != "$_self_pg" ]]; then
    assert_pass "SPEC-1: and that group is distinct from the runner's own"
else
    assert_fail "SPEC-1: and that group is distinct from the runner's own" \
        "spawn=$_spawn_pg runner=$_self_pg — signalling it would take the runner down"
fi

# ── SPEC-2: the engine can resolve that group ─────────────────────────────
# zbuild_pg_resolve returns empty when it cannot PROVE the group is distinct, and
# the abort then falls back to a per-PID kill. Empty here means the contract
# degrades exactly as it silently did on macOS.
_resolved="$(zbuild_pg_resolve "$_SPAWN_PID" 2>/dev/null || true)"
if [[ "$_resolved" == "$_SPAWN_PID" ]]; then
    assert_pass "SPEC-2: zbuild_pg_resolve returns the group ($_resolved)"
else
    assert_fail "SPEC-2: zbuild_pg_resolve returns the group" \
        "got '${_resolved:-<empty>}', wanted $_SPAWN_PID — empty means the abort degrades to a per-PID kill"
fi

# ── SPEC-3: killing the group takes the GRANDCHILD with it ────────────────
# The whole point. A per-PID kill leaves this process running; that is the macOS
# behaviour today and the thing the Linux-only test could never catch.
zbuild_pg_kill "$_resolved" 2>/dev/null || true
if _gone "$_GRAND_PID"; then
    assert_pass "SPEC-3: the grandchild died with the group"
else
    assert_fail "SPEC-3: the grandchild died with the group" \
        "pid $_GRAND_PID survived — descendants outlive an abort on this platform"
    kill -9 "$_GRAND_PID" 2>/dev/null || true
fi
if _gone "$_SPAWN_PID"; then
    assert_pass "SPEC-3: and so did the spawn itself"
else
    assert_fail "SPEC-3: and so did the spawn itself" "pid $_SPAWN_PID survived"
    kill -9 "$_SPAWN_PID" 2>/dev/null || true
fi

# ── SPEC-4: the router does not depend on setsid ──────────────────────────
# setsid is absent on macOS. Any spawn path that needs it is a path whose
# guarantee holds on Linux only — which is the defect, not the workaround.
# Two halves, and the second is the one that matters. Asserting only that setsid
# is GONE would pass a spawn with no isolation whatsoever — which is strictly
# worse than setsid and exactly the macOS behaviour being fixed. Verified by
# deleting the `set -m` and watching this go green when it had only the first
# half.
_route_live="$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true)"
if grep -qE '_ZBUILD_PG_PREFIX' <<< "$_route_live"; then
    assert_fail "SPEC-4: the router spawn does not depend on setsid" \
        "route.sh still uses _ZBUILD_PG_PREFIX — the contract would hold on Linux only"
else
    assert_pass "SPEC-4: the router spawn does not depend on setsid"
fi
# The loop spawn must be bracketed by job control, or it gets no group at all.
_spawn_block="$(sed -n '/_ROUTE_LOOP_CHILD_PID=\$!/,-40p' "$REPO_ROOT/core/router/route.sh" 2>/dev/null || true)"
[[ -n "$_spawn_block" ]] || _spawn_block="$(grep -B40 '_ROUTE_LOOP_CHILD_PID=\$!' "$REPO_ROOT/core/router/route.sh" | tail -45)"
if grep -qE '^\s*set -m\s*$' <<< "$_spawn_block"; then
    assert_pass "SPEC-4: and it puts the spawn in its own group with job control"
else
    assert_fail "SPEC-4: and it puts the spawn in its own group with job control" \
        "no \`set -m\` before _ROUTE_LOOP_CHILD_PID — the spawn shares the runner's group and an abort cannot signal it"
fi

print_test_results
