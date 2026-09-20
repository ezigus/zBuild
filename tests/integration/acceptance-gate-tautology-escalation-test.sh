#!/usr/bin/env bash
# Integration (#2157): a tautological [change] SPEC that survives to iteration 2
# is design's, not test-author's.
#
# [guard]: on iteration 1 a tautology:<id> failure declares NO fault (#1583 —
#   test-author gets one honest re-authoring try).
# [SPEC-1] (CHANGE): on iteration >= 2 the same tautology sets
#   fault=specification in the result artifact and emits
#   acceptance.gate.tautology_escalated — no assertion for behaviour that
#   already exists at the baseline can be made to fail at the baseline, so the
#   [change] tag is the defect and design owns the tag (#1840 run 5 looped two
#   iterations on SPEC-16/17, true on main since #2000).
# [SPEC-2] (CHANGE): severity stays recoverable at iter>=2 — terminal would
#   halt the cycle before the aggregator reads the fault and routes to design.
#
# Mirrors acceptance-gate-npah-escalation-test.sh (#2097); the fixture differs:
# the assertion passes at BOTH the merge-base and HEAD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate tautology iter>=2 escalation (#2157)"
setup_test_env "acceptance-gate-tautology-escalation"

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

# ── Fixture: a tautology — a [change] SPEC whose assertion passes at BOTH the
# baseline and HEAD (#1840 run 5: SPEC-16/17 described behaviour already on
# main; no honest assertion for it can fail at baseline). ───────────────────
REPO="$(setup_git_temp_repo "tautology-escalation")"
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nother_change() { return 0; }\n' > impl.sh
    printf '#!/usr/bin/env bash\necho "✓ [SPEC-1] already true everywhere"\nexit 0\n' > tests/feature-test.sh
    chmod +x tests/feature-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat"
) >/dev/null 2>&1

cat > "$REPO/design.md" <<'EOF2'
```acceptance
SPEC-1[change]: behaviour that was already true at the baseline
TESTFILES:
tests/feature-test.sh
```
EOF2

# ── iter=1: test-author's honest try — the gate names it, blames nobody ──────
export ZBUILD_CYCLE_ITER=1
set +e; _run_gate "$REPO"; set -e
assert_eq "iter=1: gate fails (rc=1)" "1" "$RC"
assert_contains "iter=1: failures record tautology:SPEC-1" \
    "$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')" "tautology:SPEC-1"
assert_eq "[guard] iter=1 declares no fault (#1583 — re-authoring gets one try)" \
    "" "$(jq -r '.fault // empty' <<<"$RESULT" 2>/dev/null || echo '')"

# ── iter=2: still tautological → the premise is what is wrong → design ───────
export ZBUILD_CYCLE_ITER=2
set +e; _run_gate "$REPO"; set -e
assert_eq "iter=2: gate fails (rc=1)" "1" "$RC"
fault="$(jq -r '.fault // empty' <<<"$RESULT" 2>/dev/null || echo '')"
assert_eq "[SPEC-1] iter=2 tautology sets fault=specification" "specification" "$fault"
if grep -q "acceptance.gate.tautology_escalated" "$EVENTS" 2>/dev/null; then
    assert_pass "[SPEC-1] iter=2 emits tautology_escalated"
else
    assert_fail "[SPEC-1] iter=2 emits tautology_escalated" "event absent from $EVENTS"
fi
assert_contains "[SPEC-1] the event names the SPEC" \
    "$(grep 'tautology_escalated' "$EVENTS" 2>/dev/null || echo '')" "SPEC-1"
assert_eq "[SPEC-2] iter=2 severity stays recoverable" "recoverable" \
    "$(jq -r '.severity // empty' <<<"$RESULT")"

unset ZBUILD_CYCLE_ITER
cleanup_test_env
print_test_results
exit $((FAIL > 0))
