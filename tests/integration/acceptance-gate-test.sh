#!/usr/bin/env bash
# Integration: the acceptance-gate plugin (ADR-036 #922) end-to-end through its
# run hook — load-bearing → pass, tautological → fail, no block → skipped no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate plugin — end-to-end (#922)"
setup_test_env "acceptance-gate-plugin"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# build a repo whose `main` lacks impl and whose feature HEAD adds impl + tests
_build_repo() {  # _build_repo <name> <head_test_body>
    local name="$1" body="$2"
    local repo; repo="$(setup_git_temp_repo "$name")"
    (
        cd "$repo"
        "$GIT" checkout -q -b feature
        mkdir -p tests
        printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
        printf '%s\n' "$body" > tests/feature-test.sh
        chmod +x tests/feature-test.sh impl.sh
        "$GIT" add -A; "$GIT" commit -q -m "feat"
    )
    printf '%s' "$repo"
}

_run_gate() {  # _run_gate <repo> → sets RC, RESULT, EVENTS
    local repo="$1"
    local state_dir="$repo/.zbuild-state"
    mkdir -p "$state_dir/artifacts"
    export ZBUILD_EVENTS_DIR="$state_dir/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
    export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
    cp "$repo/design.md" "$state_dir/artifacts/design.md" 2>/dev/null || true
    # fresh plugin load per call (guard var would block re-source)
    unset _ZBUILD_ACCEPTANCE_GATE_LOADED
    # shellcheck disable=SC1090
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/acceptance-gate/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" )
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}

# ── S1: load-bearing tagged test → verdict=pass ───────────────────────────────
REPO1="$(_build_repo gate-lb '#!/usr/bin/env bash
# [SPEC-1] feature is implemented
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1
source "$impl"; my_feature')"
cat > "$REPO1/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO1"; set -e
assert_eq "S1: load-bearing → rc=0" "0" "$RC"
assert_eq "S1: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_event_emitted "S1: complete event" "$EVENTS" "acceptance.gate.complete"

# ── S2: tautological tagged test → verdict=fail ───────────────────────────────
REPO2="$(_build_repo gate-taut '#!/usr/bin/env bash
# [SPEC-1] always true
exit 0')"
cat > "$REPO2/design.md" <<'EOF'
```acceptance
SPEC-1: always true
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO2"; set -e
assert_eq "S2: tautological → rc=1" "1" "$RC"
assert_eq "S2: verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
assert_event_emitted "S2: tautology event" "$EVENTS" "acceptance.gate.tautology"

# ── S3: untagged SPEC → verdict=fail (Level-1) ────────────────────────────────
REPO3="$(_build_repo gate-untagged '#!/usr/bin/env bash
# no spec tag here
impl="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$impl" ]] || exit 1')"
cat > "$REPO3/design.md" <<'EOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
EOF
set +e; _run_gate "$REPO3"; set -e
assert_eq "S3: untagged → rc=1" "1" "$RC"
assert_event_emitted "S3: untagged_spec event" "$EVENTS" "acceptance.gate.untagged_spec"

# ── S4: no acceptance block → no-op pass (skipped) ────────────────────────────
REPO4="$(_build_repo gate-noblock '#!/usr/bin/env bash
# [SPEC-1] x
exit 0')"
printf '# Design\nNo acceptance block here.\n' > "$REPO4/design.md"
set +e; _run_gate "$REPO4"; set -e
assert_eq "S4: no block → rc=0" "0" "$RC"
assert_eq "S4: verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_eq "S4: reason=skipped" "skipped" "$(jq -r .reason <<<"$RESULT")"
assert_event_emitted "S4: skipped event" "$EVENTS" "acceptance.gate.skipped"

cleanup_test_env
print_test_results  # exits with $FAIL
