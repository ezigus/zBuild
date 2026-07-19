#!/usr/bin/env bash
# Tests: docs/test-parallelism-audit.md (issue #988) — keep the audit honest.
#
# An audit doc rots silently. This guard asserts (a) the doc exists, (b) every
# tests/integration/*.sh file it names actually exists (no hallucinated/stale
# references), (c) the "clean class" invariants the audit relied on still hold,
# (d) exactly the 2 documented files skip setup_test_env (review M2), and (e) no
# leaked $REPO_ROOT/.deferred-drift sentinel (canary for the C1 real-repo write)
# — so a future change that reintroduces a hermeticity hazard trips here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "test-parallelism audit integrity (#988)"

AUDIT="$REPO_ROOT/docs/test-parallelism-audit.md"
ITDIR="$REPO_ROOT/tests/integration"
UTDIR="$REPO_ROOT/tests/unit"

# ── 1: the audit doc exists ──────────────────────────────────────────────────
assert_file_exists "audit doc exists" "$AUDIT"

# ── 2: every integration test the audit names exists (no rot / no hallucination)
# Extract bare `<name>-test.sh` tokens referenced in the doc and confirm each is
# a real file under tests/integration/.
_missing=0; _checked=0
while IFS= read -r _name; do
    [[ -z "$_name" ]] && continue
    _checked=$((_checked + 1))
    [[ -f "$ITDIR/$_name" ]] || [[ -f "$UTDIR/$_name" ]] || { _missing=1; echo "  missing: $_name"; }
done < <(grep -oE '[a-z0-9][a-z0-9-]*-test\.sh' "$AUDIT" | sort -u)
assert_eq "audit references only real integration or unit tests (checked=$_checked)" "0" "$_missing"

# Non-empty floor (review #1005): the existence check above passes vacuously if
# the doc names zero *-test.sh files (e.g. an edit strips/renames every mention).
# The audit cites well over 10 distinct test files; a floor catches that rot.
if [[ "$_checked" -ge 10 ]]; then
    assert_pass "audit names a substantial test list (checked=$_checked ≥ 10)"
else
    assert_fail "audit names a substantial test list" "checked=$_checked (<10) — the doc lost its file references"
fi

# ── 3: clean-class invariant — no git worktree / global config in integration ─
# The audit certified these classes empty; a new offender must re-open the audit.
# `|| true`: grep exits 1 when there are no matches, which would abort under
# `set -euo pipefail` before the assertion can run.
_gw="$( { grep -rlE 'git worktree|git config --global' "$ITDIR" 2>/dev/null || true; } | wc -l | tr -d ' ')"
assert_eq "no git worktree / git config --global in integration tests" "0" "$_gw"

# ── 4: no NEW non-isolated test — exactly the 2 documented files skip setup_test_env
# Assert the SPECIFIC filenames, not just the count (review M2): a count-only check
# passes if one documented file gains setup_test_env while a new offender appears.
_nosetup="$( { grep -L 'setup_test_env' "$ITDIR"/*.sh 2>/dev/null || true; } | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "exactly the 2 documented files skip setup_test_env (review M2)" \
    "daemon-workflow-test.sh llm-agent-renderer-interop-test.sh" "$_nosetup"

# ── 5: no leaked real-repo sentinel — canary for the C1 $REPO_ROOT write hazard ─
# deferred-tracker-integration-test.sh writes $REPO_ROOT/.deferred-drift with no
# trap (audit "Real-repo writes" table). A leaked sentinel here means a prior run
# crashed mid-test and polluted the working tree — fail loud so it gets cleaned.
if [[ -e "$REPO_ROOT/.deferred-drift" ]]; then
    assert_fail "no leaked .deferred-drift sentinel in repo root (C1)" "found $REPO_ROOT/.deferred-drift — a deferred-tracker test leaked it; rm it and add the #990 trap"
else
    assert_pass "no leaked .deferred-drift sentinel in repo root (C1 canary)"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
