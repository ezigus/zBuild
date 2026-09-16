#!/usr/bin/env bash
# tests/integration/acceptance-gate-npah-from-reachability-test.sh — #2109
# The gate's Level-3 check names a TESTFILE that is red at HEAD for what it is
# (not_passing_at_head), never as inert wiring — and the plugin classifies and
# escalates it exactly like negctl's per-SPEC finding (#2097).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate: reachability reports not_passing_at_head, not inert_wiring (#2109)"
setup_test_env "acceptance-gate-npah-reach"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

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
    # shellcheck disable=SC2034  # RC is part of the shared driver contract
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}


REPO="$(setup_git_temp_repo "npah-reach")"
(
    cd "$REPO"
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    chmod +x impl.sh
    mkdir -p tests
    # Red at HEAD: the assertion wants my_feature_v2, which the build never wrote.
    cat > tests/feature-test.sh <<'TESTEOF'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$repo_root/impl.sh" ]] && source "$repo_root/impl.sh"
if declare -F my_feature_v2 >/dev/null; then echo "  ✓ [SPEC-1] impl provides my_feature_v2"; exit 0; fi
echo "  ✗ [SPEC-1] impl provides my_feature_v2"; exit 1
TESTEOF
    chmod +x tests/feature-test.sh
    "$GIT" add -A
    "$GIT" commit -q -m "feat: impl (v2 missing)"
) >/dev/null 2>&1
cat > "$REPO/design.md" <<'EOF'
```acceptance
SPEC-1[change]: impl provides my_feature_v2
WIRING:
impl.sh
TESTFILES:
SPEC-1: tests/feature-test.sh
```
EOF

# ── iter 1 ───────────────────────────────────────────────────────────────────
unset ZBUILD_CYCLE_ITER
set +e; _run_gate "$REPO" >/dev/null 2>&1; set -e
_f1="$(jq -r '.failures[]? // empty' <<<"$RESULT" | tr '\n' ' ')"
assert_contains "[#2109] iter=1: reachability's finding lands as not_passing_at_head naming the TESTFILE" \
    "$_f1" "not_passing_at_head:tests/feature-test.sh"
assert_eq "[#2109] iter=1: no inert_wiring for a TESTFILE that is red at HEAD" \
    "" "$(grep -o 'inert_wiring:[^ ]*' <<<"$_f1" || true)"
assert_eq "[#2109] iter=1: acceptance.gate.not_passing_at_head emitted with source=reachability" \
    "1" "$(grep -c '"acceptance.gate.not_passing_at_head"' "$EVENTS" || true)"
assert_contains "[#2109] iter=1: the event names the WIRING target" \
    "$(grep '"acceptance.gate.not_passing_at_head"' "$EVENTS" || true)" '"source":"reachability"'
assert_eq "[#2109] iter=1: recoverable — build gets its honest retry" "recoverable" \
    "$(jq -r '.disposition // empty' <<<"$RESULT")"
assert_eq "[#2109] iter=1: no fault" "" "$(jq -r '.fault // empty' <<<"$RESULT")"
assert_contains "[#2109] iter=1: the reason says not passing at HEAD, not inert" \
    "$(jq -r '.reason // empty' <<<"$RESULT")" "not passing at HEAD"

# ── iter 2: the #2097 escalation applies to the same class ───────────────────
export ZBUILD_CYCLE_ITER=2
set +e; _run_gate "$REPO" >/dev/null 2>&1; set -e
assert_eq "[#2109] iter=2: still not passing at HEAD → fault=specification (same as #2097)" \
    "specification" "$(jq -r '.fault // empty' <<<"$RESULT")"
unset ZBUILD_CYCLE_ITER

cleanup_test_env
print_test_results
exit $((FAIL > 0))
