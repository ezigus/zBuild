#!/usr/bin/env bash
# tests/unit/route-missing-include-test.sh
# route.sh guards its base includes (#1624).
#
# route.sh is the base include for EVERY routing plugin, so one bad library there
# takes down all dispatch at once — not one stage, all of them. The issue asks for
# a uniform policy: a MISSING or BROKEN include must produce an error naming the
# file, and must not let the caller run on half-loaded.
#
# This file is deliberately its own, not assertions bolted onto
# core-router-route-test.sh. That file carries ~50 unrelated router tests, 21 of
# which fail whenever ZBUILD_RUN_ID leaks into the acceptance sandbox (#1644) —
# which is precisely what killed the first pipeline run on this issue. Declaring a
# not-yet-created test file only became legal in #1649; before that the design was
# forced onto the crowded file.
#
# SPEC-1: a MISSING include → non-zero exit + a diagnostic naming the file
# SPEC-2: a BROKEN include (present, syntax error) → the same treatment
# SPEC-3: the caller does NOT continue past a bad include (no half-loaded router)
# SPEC-4: every base include is guarded — uniformity, not just the two #1305 added
# SPEC-5[guard]: a healthy tree still loads cleanly (the guard costs nothing)
set -uo pipefail
# Deliberately NOT `set -e`: assert_fail returns non-zero when called without a
# detail argument, which under -e would abort before print_test_results — a
# failing test that exits 0. Same reason intake-branch-test.sh omits it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

for _dep in scripts/lib/helpers.sh scripts/lib/test-helpers.sh; do
    if [[ ! -f "$REPO_ROOT/$_dep" ]]; then
        printf 'route-missing-include-test: required dependency missing: %s\n' \
            "$REPO_ROOT/$_dep" >&2
        exit 2
    fi
done
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "route.sh base-include guards (#1624)"
setup_test_env "route-missing-include"

# The ten libraries route.sh loads at file scope.
_INCLUDES=(
    scripts/lib/helpers.sh
    core/event-bus/event-bus.sh
    core/output/stage-io.sh
    scripts/lib/env-scrub.sh
    core/redaction/scope-redaction.sh
    scripts/lib/router-rc-classify.sh
    scripts/lib/tier-resolve.sh
    # #1816: loaded under `if ! declare -F manifest_router_knob`, which is TRUE
    # in this fixture (tier-resolve.sh is a stub and defines nothing), so the
    # guard is exercised exactly like the unconditional nine.
    core/plugin-registry/manifest-validation.sh
    scripts/lib/persona-resolve.sh
    scripts/lib/vision.sh
)

# _stub_tree — a minimal install tree: route.sh verbatim, every include a stub.
# Stubs (not copies) keep the fixture cheap and make "which include is bad" the
# only variable under test.
_stub_tree() {
    local d; d="$(mktemp -d "$TEST_TEMP_DIR/tree.XXXXXX")"
    local f
    for f in "${_INCLUDES[@]}"; do
        mkdir -p "$d/$(dirname "$f")"
        printf '#!/usr/bin/env bash\n: # stub\n' > "$d/$f"
    done
    mkdir -p "$d/core/router"
    cp "$REPO_ROOT/core/router/route.sh" "$d/core/router/route.sh"
    printf '%s' "$d"
}

# _load <tree> — source route.sh from <tree> in a CHILD BASH PROCESS, capturing
# rc and stderr. A child, not a subshell: route.sh calls `exit` on a bad include,
# and the point of SPEC-3 is that this kills the caller. A subshell would mask it.
_load() {
    local tree="$1"
    _LOAD_ERR="$(mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    cat > "$TEST_TEMP_DIR/caller.sh" <<'CALLER'
source "$1/core/router/route.sh"
echo "CALLER_CONTINUED"
CALLER
    bash "$TEST_TEMP_DIR/caller.sh" "$tree" > "$TEST_TEMP_DIR/out" 2>"$_LOAD_ERR"
    _LOAD_RC=$?
    _LOAD_OUT="$(cat "$TEST_TEMP_DIR/out" 2>/dev/null || echo "")"
    _LOAD_STDERR="$(cat "$_LOAD_ERR" 2>/dev/null || echo "")"
}

# ─── SPEC-1: a MISSING include is named, not silent ─────────────────────────
_t1="$(_stub_tree)"; rm -f "$_t1/scripts/lib/helpers.sh"
_load "$_t1"
assert_gt "[SPEC-1] a missing include → non-zero exit" "$_LOAD_RC" "0"
assert_contains "[SPEC-1] the diagnostic names the missing file" \
    "$_LOAD_STDERR" "scripts/lib/helpers.sh"
assert_contains "[SPEC-1] the diagnostic is zbuild's, not a bare bash error" \
    "$_LOAD_STDERR" "zbuild: fatal: missing include:"

# ─── SPEC-2: a BROKEN include gets the same treatment ───────────────────────
# The issue asks for "missing OR broken". An existence check alone leaves this
# case: the file is present, so the guard passes, `source` fails on the syntax
# error, and — because nothing checks source's status — the caller runs on with
# the router half-loaded. Bash prints its own parse error, but execution
# continues, which is the more dangerous half.
_t2="$(_stub_tree)"
printf '#!/usr/bin/env bash\nif [ -z ; then\n' > "$_t2/scripts/lib/tier-resolve.sh"
_load "$_t2"
assert_gt "[SPEC-2] a broken include → non-zero exit" "$_LOAD_RC" "0"
assert_contains "[SPEC-2] the diagnostic names the broken file" \
    "$_LOAD_STDERR" "scripts/lib/tier-resolve.sh"
assert_contains "[SPEC-2] the diagnostic is zbuild's, not a bare bash error" \
    "$_LOAD_STDERR" "zbuild: fatal: broken include:"
# Naming the file is not enough: bash's parse error carries the line and token,
# and discarding it would leave the operator worse off than before the guard.
assert_contains "[SPEC-2] bash's parse detail is forwarded, not swallowed" \
    "$_LOAD_STDERR" "syntax error"

# ─── SPEC-3: the caller does not continue past a bad include ────────────────
# The whole point: dispatch must stop, not proceed half-loaded.
# $_LOAD_OUT is still SPEC-2's load (the broken tier-resolve.sh) — reused on
# purpose, so do not reorder these blocks without adding a _load call here.
# NB: there is no assert_not_contains in test-helpers.sh. Calling one would print
# "command not found" and still leave the file reporting all-passed — an inert
# assertion. Spelled out with pass/fail instead.
if grep -qF "CALLER_CONTINUED" <<<"$_LOAD_OUT"; then
    assert_fail "[SPEC-3] the caller must NOT run on past a broken include" "got: $_LOAD_OUT"
else
    assert_pass "[SPEC-3] the caller does not run on past a broken include"
fi
_t3="$(_stub_tree)"; rm -f "$_t3/core/redaction/scope-redaction.sh"
_load "$_t3"
if grep -qF "CALLER_CONTINUED" <<<"$_LOAD_OUT"; then
    assert_fail "[SPEC-3] the caller must NOT run on past a missing include" "got: $_LOAD_OUT"
else
    assert_pass "[SPEC-3] the caller does not run on past a missing include"
fi

# ─── SPEC-4: uniformity — EVERY include is guarded ──────────────────────────
# The issue is explicit that a half-guarded file is worse than an unguarded one,
# because the guards imply the unguarded lines were considered safe. Removing any
# one include must be caught, not just the two #1305 added.
_unguarded=""
for _inc in "${_INCLUDES[@]}"; do
    _t="$(_stub_tree)"; rm -f "$_t/$_inc"
    _load "$_t"
    if [[ "$_LOAD_RC" -eq 0 ]] || ! grep -qF "missing include" <<<"$_LOAD_STDERR"; then
        _unguarded="${_unguarded:+$_unguarded }$_inc"
    fi
done
if [[ -z "$_unguarded" ]]; then
    assert_pass "[SPEC-4] all ${#_INCLUDES[@]} base includes are guarded uniformly"
else
    assert_fail "[SPEC-4] every base include must be guarded" "unguarded:$_unguarded"
fi

# ─── SPEC-5[guard]: a healthy tree still loads ──────────────────────────────
# The guard must cost nothing on the happy path — this is an invariant, so it
# passes at the merge-base too and is not contorted to fail there.
_t5="$(_stub_tree)"
_load "$_t5"
assert_eq "[SPEC-5] a healthy tree loads cleanly (rc=0)" "0" "$_LOAD_RC"
assert_contains "[SPEC-5] the caller continues past a healthy load" \
    "$_LOAD_OUT" "CALLER_CONTINUED"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
