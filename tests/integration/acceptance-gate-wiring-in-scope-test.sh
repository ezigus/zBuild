#!/usr/bin/env bash
# Integration (#2252 C): who owns a WIRING target the change did not touch.
#
# `wiring_not_on_path` fires when design's declared WIRING target is not in the
# commit's diff. The gate blamed design every time (#1686: "design named a file
# unrelated to the change"). But when the target IS in the change's scope, design
# asked for a real edit and build did not make it — #2032 run 36969130031: build
# forgot to register an event in config/event-schema.json, the gate blamed
# design, and the run's only route-back to design was spent on build's slip.
#
# W1 [change] target in the change's scope, iter 1 → no specification fault:
#             build gets its turn to make the edit
# W2 [guard]  target in scope, iter 2 → specification (build had its try)
# W3 [guard]  target NOT in the change's scope → specification at once — build
#             may not edit it, only design can fix the declaration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate: an untouched in-scope WIRING target is build's first (#2252 C)"
setup_test_env "acceptance-gate-wiring-in-scope"
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

# ── Fixture: impl changed; registry.json (the WIRING target) NOT changed ─────
REPO="$(setup_git_temp_repo "wiring-in-scope")"
(
    cd "$REPO"
    printf '{"events":[]}\n' > registry.json
    printf '{"x":1}\n' > other.json
    "$GIT" add -A; "$GIT" commit -q -m "base"
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    mkdir -p tests
    cat > tests/feature-test.sh <<'TESTEOF'
#!/usr/bin/env bash
# [SPEC-1] impl provides my_feature
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$repo_root/impl.sh" ]] || exit 1
# shellcheck disable=SC1090
source "$repo_root/impl.sh"
my_feature
TESTEOF
    chmod +x tests/feature-test.sh impl.sh
    "$GIT" add -A; "$GIT" commit -q -m "feat: impl"
) >/dev/null 2>&1

_design() {  # _design <wiring target>
    cat > "$REPO/design.md" <<EOF
\`\`\`scope
impl.sh
registry.json
tests/feature-test.sh
\`\`\`

\`\`\`acceptance
SPEC-1[change]: impl provides my_feature
WIRING:
$1
TESTFILES:
tests/feature-test.sh
\`\`\`
EOF
}
_fault() { jq -r '.fault // empty' <<<"$RESULT" 2>/dev/null || true; }

_design registry.json
unset ZBUILD_CYCLE_ITER
set +e; _run_gate "$REPO"; set -e
assert_contains "fixture: the gate reports the untouched target" \
    "$(jq -r '.failures[]?' <<<"$RESULT" 2>/dev/null)" "wiring_not_on_path:registry.json"
assert_eq "[W1] in scope, iter 1 → no specification fault (build's turn)" "" "$(_fault)"

export ZBUILD_CYCLE_ITER=2
set +e; _run_gate "$REPO"; set -e
assert_eq "[W2] in scope, iter 2 → specification" "specification" "$(_fault)"

_design other.json
unset ZBUILD_CYCLE_ITER
set +e; _run_gate "$REPO"; set -e
assert_eq "[W3] not in scope → specification at once" "specification" "$(_fault)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
