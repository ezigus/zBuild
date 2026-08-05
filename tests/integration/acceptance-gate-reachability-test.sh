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
    ( cd "$repo" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
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

# ── R4: WIRING block with ONLY unsafe (traversal/absolute) paths → FAIL CLOSED ─
# A declared WIRING section whose every target is rejected by the path-traversal
# guard must NOT silently skip Level-3 (that would let an author bypass the gate).
# Load-bearing setup (L1/L2 pass) so the run reaches Level-3.
REPO_R4="$(setup_git_temp_repo "reach-r4")"
(
    cd "$REPO_R4"
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
    "$GIT" commit -q -m "feat: wiring + tests"
) >/dev/null 2>&1

cat > "$REPO_R4/design.md" <<'EOF'
```acceptance
SPEC-1[change]: my_feature is provided by wiring.sh
WIRING:
../../etc/passwd
/etc/hosts
TESTFILES:
tests/feature-test.sh
```
EOF

set +e; _run_gate "$REPO_R4"; set -e
assert_eq "[SPEC-6] R4: only-unsafe WIRING → gate fails closed (rc=1)" "1" "$RC"
assert_eq "[SPEC-6] R4: only-unsafe WIRING → verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
r4_failures="$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')"
assert_contains "[SPEC-6] R4: failures records empty_wiring_targets" "$r4_failures" "reachability_error:empty_wiring_targets"

# ── R5: python3 runner via {files} seam → gate passes ────────────────────────
# Exercises ZBUILD_ACCEPTANCE_RUN_CMD through _reachability_run.
# Setup: wiring.py absent at merge-base, present at HEAD (feature branch).
# Test: python3 script that exits 1 when wiring.py is missing.
# Reachability: reverting wiring.py makes the python3 test fail → PASS.
# [SPEC-7] ZBUILD_ACCEPTANCE_RUN_CMD {files} seam flows through Level-3 reachability
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP R5: python3 not available" >&2
else
    REPO_R5="$(setup_git_temp_repo "reach-r5")"
    (
        cd "$REPO_R5"
        "$GIT" checkout -q -b feature
        cat > wiring.py <<'PYEOF'
# wiring: provides the feature
def my_feature():
    return True
PYEOF
        mkdir -p tests
        cat > tests/feature_test.py <<'TESTEOF'
#!/usr/bin/env python3
# [SPEC-7] my_feature is provided by wiring.py
import sys, os
repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
wiring = os.path.join(repo_root, "wiring.py")
if not os.path.isfile(wiring):
    sys.exit(1)
sys.path.insert(0, repo_root)
from wiring import my_feature
sys.exit(0 if my_feature() else 1)
TESTEOF
        chmod +x tests/feature_test.py
        "$GIT" add -A
        "$GIT" commit -q -m "feat: add wiring.py and python3 test"
    ) >/dev/null 2>&1

    cat > "$REPO_R5/design.md" <<'EOF'
```acceptance
SPEC-7[change]: ZBUILD_ACCEPTANCE_RUN_CMD {files} seam flows through Level-3 reachability
WIRING:
wiring.py
TESTFILES:
tests/feature_test.py
```
EOF

    set +e; ZBUILD_ACCEPTANCE_RUN_CMD='python3 {files}' _run_gate "$REPO_R5"; set -e
    assert_eq "[SPEC-7] R5: python3 {files} seam → gate rc=0" "0" "$RC"
    assert_eq "[SPEC-7] R5: python3 {files} seam → verdict=pass" "pass" "$(jq -r .verdict <<<"$RESULT")"
fi

# ── R6: inert_wiring at ZBUILD_CYCLE_ITER≥2 escalates to route_target=design ───
# Setup: WIRING target is a CI YAML file in the diff (the #1664 shape).
# The sole TESTFILE is a bash script that cannot source YAML, so no flip is
# possible regardless of how many build iterations run. At ZBUILD_CYCLE_ITER unset
# (iter=1), inert_wiring is emitted with no route_target — build gets a real try.
# At ZBUILD_CYCLE_ITER=2, the same still-inert target escalates to
# route_target=design via the #1711 second-measurement mechanism.
REPO_R6="$(setup_git_temp_repo "reach-r6")"
(
    cd "$REPO_R6"
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

cat > "$REPO_R6/design.md" <<'EOF'
```acceptance
SPEC-1[change]: impl provides my_feature
WIRING:
.github/workflows/test.yml
TESTFILES:
tests/feature-test.sh
```
EOF

# R6a: ZBUILD_CYCLE_ITER unset — inert_wiring with no route_target (first attempt)
unset ZBUILD_CYCLE_ITER
set +e; _run_gate "$REPO_R6"; set -e
assert_eq "[SPEC-2] R6a: iter=1 inert_wiring → rc=1" "1" "$RC"
r6a_failures="$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')"
assert_contains "[SPEC-2] R6a: iter=1 failures contain inert_wiring YAML target" \
    "$r6a_failures" "inert_wiring:.github/workflows/test.yml"
r6a_rt="$(jq -r '.route_target // empty' <<<"$RESULT" 2>/dev/null || echo '')"
assert_eq "[SPEC-2] R6a: iter=1 → no route_target (build gets first attempt)" "" "$r6a_rt"

# R6b: ZBUILD_CYCLE_ITER=2 — still-inert target escalates to route_target=design
export ZBUILD_CYCLE_ITER=2
set +e; _run_gate "$REPO_R6"; set -e
unset ZBUILD_CYCLE_ITER
assert_eq "[SPEC-1] R6b: iter=2 inert_wiring escalated → rc=1" "1" "$RC"
assert_eq "[SPEC-1] R6b: iter=2 → verdict=fail" "fail" "$(jq -r .verdict <<<"$RESULT")"
r6b_failures="$(jq -r '.failures[]' <<<"$RESULT" 2>/dev/null || echo '')"
assert_contains "[SPEC-1] R6b: iter=2 failures contain inert_wiring YAML target" \
    "$r6b_failures" "inert_wiring:.github/workflows/test.yml"
assert_eq "[SPEC-1] R6b: iter=2 → disposition=recoverable" "recoverable" \
    "$(jq -r '.disposition' <<<"$RESULT")"
assert_eq "[SPEC-1] R6b: iter=2 → route_target=design" "design" \
    "$(jq -r '.route_target // empty' <<<"$RESULT")"
assert_event_emitted "[SPEC-1] R6b: inert_wiring_escalated event emitted" \
    "$EVENTS" "acceptance.gate.inert_wiring_escalated"

cleanup_test_env
print_test_results
