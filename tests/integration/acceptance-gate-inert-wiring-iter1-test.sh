#!/usr/bin/env bash
# Integration (#1686 / ADR-036 Amendment #1711): the iter=1 half of the
# inert_wiring escalation — build's FIRST attempt is preserved.
#
# [SPEC-2] (GUARD): on iteration 1 (ZBUILD_CYCLE_ITER unset or 1), an
#   inert_wiring failure does NOT set fault in the result artifact.
#   Build still gets a real try before anything escalates to design.
#
# Deliberately its own file, for two reasons:
#
#  1. The escalation's [change] half (iter>=2 -> fault=specification) lives in
#     acceptance-gate-reachability-test.sh and correctly FAILS at the
#     merge-base. The [guard] negative control runs a whole testfile and keys
#     on the FILE's exit code, so a guard sharing that file is reported
#     guard_regressed by its sibling's baseline failure (#1737). That is
#     exactly what killed run 20260805103835-2415 on iterations 3, 4 and 5.
#  2. This guard must exercise the REAL gate. The first attempt to work around
#     (1) asserted `[[ "${ZBUILD_CYCLE_ITER:-1}" -ge 2 ]]` inside the test —
#     a re-implementation of the condition that passes with the entire
#     implementation deleted. Verified: reverting plugin.sh to the merge-base
#     left that assertion green.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate inert_wiring iter=1 first attempt (#1686)"
setup_test_env "acceptance-gate-inert-wiring-iter1"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# ── _run_gate: run the acceptance-gate plugin and capture results ─────────────
# Mirrors the helper in acceptance-gate-reachability-test.sh.
_run_gate() {
    local repo="$1"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    local _si_json="$state_dir/stage-inputs.json"
    printf '{"inputs":{"design":"%s"}}\n' "$state_dir/artifacts/design.md" > "$_si_json"
    export ZBUILD_STAGE_INPUTS="$_si_json"
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

# ── Fixture: the #1664 shape ─────────────────────────────────────────────────
# A CI workflow declared as the WIRING target, IN this change's diff (so it is
# not wiring_not_on_path), alongside an impl + testfile that cannot load YAML.
# Reverting the workflow flips nothing -> inert_wiring.
REPO="$(setup_git_temp_repo "inert-wiring-iter1")"
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    mkdir -p .github/workflows
    printf 'name: test\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n' \
        > .github/workflows/test.yml
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    chmod +x impl.sh
    mkdir -p tests
    cat > tests/feature-test.sh <<'TESTEOF'
#!/usr/bin/env bash
# [SPEC-1] impl provides my_feature (YAML wiring untestable by shell)
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$repo_root/impl.sh" ]] || exit 1
# shellcheck disable=SC1090
source "$repo_root/impl.sh"
my_feature
TESTEOF
    chmod +x tests/feature-test.sh
    "$GIT" add -A
    "$GIT" commit -q -m "feat: CI workflow + impl"
) >/dev/null 2>&1

cat > "$REPO/design.md" <<'EOF'
```acceptance
SPEC-1[change]: impl provides my_feature
WIRING:
.github/workflows/test.yml
TESTFILES:
tests/feature-test.sh
```
EOF

# ── iter=1: inert_wiring, but NO escalation ──────────────────────────────────
unset ZBUILD_CYCLE_ITER
set +e; _run_gate "$REPO"; set -e

assert_eq "iter=1: gate fails on the inert WIRING target (rc=1)" "1" "$RC"

_iter1_failures="$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')"
assert_contains "iter=1: failures record the inert_wiring YAML target" \
    "$_iter1_failures" "inert_wiring:.github/workflows/test.yml"

# The guard proper: the gate reached the escalation branch and declined to take
# it. Read from the RESULT ARTIFACT the aggregator consumes, not from a
# re-derived condition.
fault="$(jq -r '.fault // empty' <<<"$RESULT" 2>/dev/null || echo '')"
assert_eq "[SPEC-2] iter=1 inert_wiring sets no fault — build keeps its first attempt" \
    "" "$fault"

# Corollary: the escalation event must be silent on the first attempt, or an
# operator reading the stream would see an escalation that did not happen.
if grep -q "acceptance.gate.inert_wiring_escalated" "$EVENTS" 2>/dev/null; then
    assert_fail "[SPEC-2] iter=1 emits no inert_wiring_escalated event" \
        "event present in $EVENTS"
else
    assert_pass "[SPEC-2] iter=1 emits no inert_wiring_escalated event"
fi

# Disposition must stay recoverable so the cycle re-iterates into build rather
# than halting (ADR-036 Amendment #1585).
assert_eq "iter=1: disposition stays recoverable" "recoverable" \
    "$(jq -r '.disposition // empty' <<<"$RESULT")"
assert_eq "[SPEC-4] iter=1: inert_wiring disposition behavioral contract preserved" \
    "recoverable" "$(jq -r '.disposition // empty' <<<"$RESULT")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
