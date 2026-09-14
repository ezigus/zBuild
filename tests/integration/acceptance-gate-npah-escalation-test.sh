#!/usr/bin/env bash
# Integration (#2097): the iter>=2 half of the not_passing_at_head escalation.
#
# [SPEC-1] (CHANGE): on iteration >= 2 a not_passing_at_head failure sets
#   fault=specification in the result artifact and emits
#   acceptance.gate.not_passing_at_head_escalated — build had one honest try
#   (iter 1, see S14 in acceptance-gate-test.sh: no fault) and the assertion
#   STILL does not pass at HEAD, so the design's premise is what is suspect.
# [SPEC-2] (CHANGE): disposition is recoverable at iter>=2 — terminal would halt
#   the cycle before the aggregator reads the fault and routes to design
#   (the #1686/#1711 rationale, verbatim).
#
# Its own file, for the #1737 reason the inert_wiring iter1 test records: the
# iter=1 [guard] half lives in acceptance-gate-test.sh (S14) and must not share
# a TESTFILE with a [change] that fails at the merge-base.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate not_passing_at_head iter>=2 escalation (#2097)"
setup_test_env "acceptance-gate-npah-escalation"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# Mirrors the helper in acceptance-gate-inert-wiring-iter1-test.sh.
_run_gate() {
    local repo="$1"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
          _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
          _ACCEPTANCE_COVERAGE_LOADED
    # shellcheck disable=SC1090
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" )
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}

# ── Fixture: the S14 shape — a [change] SPEC whose test fails at BOTH baseline
# and HEAD (a real not_passing_at_head, not a tautology). ────────────────────
REPO="$(setup_git_temp_repo "npah-escalation")"
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    printf '#!/usr/bin/env bash\n# [SPEC-1] change: never passes anywhere\nexit 1\n' > tests/feature-test.sh
    chmod +x tests/feature-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat"
) >/dev/null 2>&1

cat > "$REPO/design.md" <<'EOF2'
```acceptance
SPEC-1[change]: new behavior introduced
TESTFILES:
tests/feature-test.sh
```
EOF2

# ── iter=2: escalate ─────────────────────────────────────────────────────────
export ZBUILD_CYCLE_ITER=2
set +e; _run_gate "$REPO"; set -e

assert_eq "iter=2: gate fails (rc=1)" "1" "$RC"
assert_contains "iter=2: failures record not_passing_at_head:SPEC-1" \
    "$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')" "not_passing_at_head:SPEC-1"

fault="$(jq -r '.fault // empty' <<<"$RESULT" 2>/dev/null || echo '')"
assert_eq "[SPEC-1] iter=2 not_passing_at_head sets fault=specification" \
    "specification" "$fault"

if grep -q "acceptance.gate.not_passing_at_head_escalated" "$EVENTS" 2>/dev/null; then
    assert_pass "[SPEC-1] iter=2 emits not_passing_at_head_escalated"
else
    assert_fail "[SPEC-1] iter=2 emits not_passing_at_head_escalated" \
        "event absent from $EVENTS"
fi
assert_contains "[SPEC-1] the event names the SPEC" \
    "$(grep 'not_passing_at_head_escalated' "$EVENTS" 2>/dev/null || echo '')" "SPEC-1"

assert_eq "[SPEC-2] iter=2 disposition is recoverable, not terminal" "recoverable" \
    "$(jq -r '.disposition // empty' <<<"$RESULT")"

# [guard] a class that IS design-authored structure still outranks: the
# escalation must not turn a malformed block into a recoverable one.
unset ZBUILD_CYCLE_ITER
cleanup_test_env
print_test_results
exit $((FAIL > 0))
