#!/usr/bin/env bash
# Integration: acceptance-gate Level-3 reachability check (ADR-036 Level-3, #956).
# Exercises the live acceptance-gate plugin for the reachability gate.
#
# [SPEC-5] acceptance-gate Level-3 passes when reverting the declared WIRING file
#          causes ≥1 SPEC-tagged test to flip pass→fail (wiring is load-bearing).
# [SPEC-6] acceptance-gate Level-3 fails with inert_wiring in failures[] when no
#          SPEC-tagged test flips pass→fail after reverting the WIRING file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "acceptance-gate Level-3 reachability (#956)"
setup_test_env "acceptance-gate-reachability"

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
GIT="$(command -v git)"

# ── _run_gate: run the acceptance-gate plugin and capture results ─────────────
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
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/acceptance-gate/plugin.sh" \
        && acceptance_gate_run "acceptance-gate" "$state_dir/pipeline-state.json" )
    RC=$?
    RESULT="$(cat "$state_dir/artifacts/acceptance-gate-result.json" 2>/dev/null || echo '{}')"
    EVENTS="$ZBUILD_EVENTS_JSONL"
}

# ── R1: wiring is load-bearing → gate passes ─────────────────────────────────
# Setup: wiring.sh is ABSENT at merge-base (main), PRESENT at HEAD (feature).
# Test: checks that wiring.sh exists and provides my_feature().
# Negctl: test fails at baseline (wiring absent) → NEGCTL PASS for SPEC-1.
# Reachability: wiring.sh declared as WIRING target; reverting it makes test
# fail (wiring absent) → at least one test flips → REACHABILITY PASS.
REPO_R1="$(setup_git_temp_repo "reach-r1")"
(
    cd "$REPO_R1"
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > wiring.sh
    chmod +x wiring.sh
    mkdir -p tests
    cat > tests/feature-test.sh <<'TESTEOF'
#!/usr/bin/env bash
# [SPEC-1] my_feature is provided by wiring.sh
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$repo_root/wiring.sh" ]] || exit 1
# shellcheck disable=SC1090
source "$repo_root/wiring.sh"
my_feature
TESTEOF
    chmod +x tests/feature-test.sh
    "$GIT" add -A
    "$GIT" commit -q -m "feat: add wiring.sh and tests"
) >/dev/null 2>&1

cat > "$REPO_R1/design.md" <<'EOF'
```acceptance
SPEC-1[change]: my_feature is provided by wiring.sh
WIRING:
wiring.sh
TESTFILES:
tests/feature-test.sh
```
EOF

set +e; _run_gate "$REPO_R1"; set -e
assert_eq "[SPEC-5] R1: load-bearing wiring → gate rc=0" "0" "$RC"
assert_eq "[SPEC-5] R1: load-bearing wiring → verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"

# ── R2: wiring is inert (revert doesn't flip any test) → gate fails ──────────
# Setup: impl.sh is the real implementation (test depends on it).
#        inert-wiring.sh is the declared WIRING target but the test ignores it.
# Negctl: test fails at baseline (impl.sh absent) → NEGCTL PASS for SPEC-1.
# Reachability: reverting inert-wiring.sh doesn't affect the test (impl.sh at
# HEAD) → no flip → REACHABILITY FAIL inert_wiring.
REPO_R2="$(setup_git_temp_repo "reach-r2")"
(
    cd "$REPO_R2"
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nmy_feature() { return 0; }\n' > impl.sh
    chmod +x impl.sh
    printf '# registration stub (inert)\n' > inert-wiring.sh
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
    chmod +x tests/feature-test.sh
    "$GIT" add -A
    "$GIT" commit -q -m "feat: impl + inert wiring"
) >/dev/null 2>&1

cat > "$REPO_R2/design.md" <<'EOF'
```acceptance
SPEC-1[change]: impl provides my_feature
WIRING:
inert-wiring.sh
TESTFILES:
tests/feature-test.sh
```
EOF

set +e; _run_gate "$REPO_R2"; set -e
assert_eq "[SPEC-6] R2: inert wiring → gate rc=1" "1" "$RC"
assert_eq "[SPEC-6] R2: inert wiring → verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
r2_failures="$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')"
assert_contains "[SPEC-6] R2: failures contains inert_wiring" "$r2_failures" "inert_wiring:inert-wiring.sh"
assert_event_emitted "[SPEC-6] R2: inert_wiring event emitted" "$EVENTS" "acceptance.gate.inert_wiring"

# ── R3: WIRING: none → exempt, gate passes ───────────────────────────────────
# Setup: util.sh is a pure-utility helper with no live dispatch wiring.
# Design declares WIRING: none (explicit exemption).
# Gate must pass and emit wiring_exempt event.
REPO_R3="$(setup_git_temp_repo "reach-r3")"
(
    cd "$REPO_R3"
    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\nmy_util() { return 0; }\n' > util.sh
    chmod +x util.sh
    mkdir -p tests
    cat > tests/util-test.sh <<'TESTEOF'
#!/usr/bin/env bash
# [SPEC-1] my_util function exists
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$repo_root/util.sh" ]] || exit 1
# shellcheck disable=SC1090
source "$repo_root/util.sh"
my_util
TESTEOF
    chmod +x tests/util-test.sh
    "$GIT" add -A
    "$GIT" commit -q -m "feat: add util"
) >/dev/null 2>&1

cat > "$REPO_R3/design.md" <<'EOF'
```acceptance
SPEC-1[change]: my_util function exists
WIRING: none
TESTFILES:
tests/util-test.sh
```
EOF

set +e; _run_gate "$REPO_R3"; set -e
assert_eq "R3: WIRING: none → gate rc=0" "0" "$RC"
assert_eq "R3: WIRING: none → verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
assert_event_emitted "R3: wiring_exempt event emitted" "$EVENTS" "acceptance.gate.wiring_exempt"

cleanup_test_env
print_test_results
