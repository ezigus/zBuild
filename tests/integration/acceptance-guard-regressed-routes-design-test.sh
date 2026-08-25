#!/usr/bin/env bash
# Integration (#1777): a `guard_regressed` acceptance failure is DESIGN-ROOTED,
# and the rewind it triggers must carry the reason with it.
#
# #1809 rewound correctly and still could not converge. The acceptance gate
# reported `guard_regressed:SPEC-5` but set no route_target, so the gate-
# aggregator partitioned it into residual[] and wrote it to the BUILD-facing
# gate-feedback.md. The winning route_target came from shape-floor, so
# design-feedback.md — the payload the route_back carries to the
# design_verify_cycle — named only shape-floor and never mentioned the
# mislabelled SPEC. Design re-authored nothing; build re-ran; the same guard
# failed again; the run was aborted at iteration 3 of 5.
#
# Both halves are driven through the REAL plugins. Asserting the condition in
# the test instead would stay green with the implementation deleted — the
# #1686 lesson recorded in acceptance-gate-inert-wiring-iter1-test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "guard_regressed routes to design, and design-feedback says why (#1777)"
setup_test_env "guard-regressed-routes-design"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_EVENTS_DB="/dev/null"
export ZBUILD_NEGCTL_TIMEOUT="${ZBUILD_NEGCTL_TIMEOUT:-30}"
GIT="$(command -v git)"

# ── Fixture: #1777's own shape ───────────────────────────────────────────────
# baseline: doctor.sh carries a warn line.  HEAD: the line is removed.
# SPEC-1 is tagged [guard] but asserts the REMOVAL — impossible at the baseline.
REPO="$(setup_git_temp_repo "guard-routes")"
(
    cd "$REPO"
    mkdir -p scripts tests
    printf '#!/usr/bin/env bash\necho "bash 4 functional but 5 recommended"\n' > scripts/doctor.sh
    chmod +x scripts/doctor.sh
    "$GIT" add -A && "$GIT" commit -q -m "baseline: doctor warns"

    "$GIT" checkout -q -b feature
    printf '#!/usr/bin/env bash\necho ok\n' > scripts/doctor.sh
    chmod +x scripts/doctor.sh
    cat > tests/guard-bad-test.sh <<'EOF'
#!/usr/bin/env bash
# [SPEC-1] doctor.sh no longer carries the bash-4 warn
root="$(cd "$(dirname "$0")/.." && pwd)"
if grep -q "functional but 5 recommended" "$root/scripts/doctor.sh"; then
    echo "✗ [SPEC-1] warn line still present"
    exit 1
fi
echo "✓ [SPEC-1] warn line removed"
EOF
    chmod +x tests/guard-bad-test.sh
    cat > design.md <<'EOF'
# Design

```scope
scripts/doctor.sh
```

```acceptance
SPEC-1[guard]: doctor.sh no longer carries the bash-4 warn
TESTFILES:
SPEC-1: tests/guard-bad-test.sh
WIRING: scripts/doctor.sh
```
EOF
    "$GIT" add -A && "$GIT" commit -q -m "feat: drop the warn line"
)

# ── Half 1: the acceptance gate marks guard_regressed design-rooted ──────────
STATE_DIR="$REPO/.zbuild-state"
ART="$STATE_DIR/artifacts"
mkdir -p "$ART"
export ZBUILD_EVENTS_DIR="$STATE_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"; : > "$ZBUILD_EVENTS_JSONL"
cp "$REPO/design.md" "$ART/design.md"

unset _ZBUILD_ACCEPTANCE_GATE_LOADED _ACCEPTANCE_REACHABILITY_LOADED \
      _ACCEPTANCE_NEGCTL_LOADED _ACCEPTANCE_BLOCK_LOADED _ZBUILD_MERGE_BASE_LOADED \
      _ACCEPTANCE_COVERAGE_LOADED
set +e
( cd "$REPO" && source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh" \
    && acceptance_gate_run "acceptance-gate" "$STATE_DIR/pipeline-state.json" ) >/dev/null 2>&1
set -e
AG_RESULT="$(cat "$ART/acceptance-gate-result.json" 2>/dev/null || echo '{}')"

assert_contains "[SPEC-1] the gate reports guard_regressed for the mislabelled SPEC" \
    "$(jq -rc '.failures // []' <<< "$AG_RESULT")" "guard_regressed:SPEC-1"
assert_eq "[SPEC-2] guard_regressed sets route_target=design — build cannot fix a mislabelled tag" \
    "design" "$(jq -r '.route_target // "ABSENT"' <<< "$AG_RESULT")"
assert_eq "[SPEC-3] the disposition stays recoverable, so the aggregator still reads route_target" \
    "recoverable" "$(jq -r '.disposition // "MISSING"' <<< "$AG_RESULT")"

# ── Half 2: the aggregator carries it into design-feedback.md ───────────────
# _ga_build_roster falls back to the legacy must-pass set with no cycle in
# scope, so the other gates read as `missing` (fail-closed) and land in
# residual[] — precisely the mixed failure set #1757 fixed the partition for.
_run_aggregator() {
    local art="$1"
    unset _ZBUILD_GATE_AGGREGATOR_LOADED
    set +e
    (
        export ZBUILD_ARTIFACT_DIR="$art"
        # shellcheck disable=SC1090
        source "$REPO_ROOT/plugins/tool/gate-aggregator/plugin.sh"
        gate_aggregator_run "gate-aggregator" ""
    ) >/dev/null 2>&1
    set -e
    GA_RESULT="$(cat "$art/gate-aggregator-result.json" 2>/dev/null || echo '{}')"
    DESIGN_FB="$(cat "$art/design-feedback.md" 2>/dev/null || true)"
    GATE_FB="$(cat "$art/gate-feedback.md" 2>/dev/null || true)"
}

AGG_DIR="$TEST_TEMP_DIR/agg"; mkdir -p "$AGG_DIR"
cp "$ART/acceptance-gate-result.json" "$AGG_DIR/acceptance-gate-result.json"
_run_aggregator "$AGG_DIR"

assert_eq "[SPEC-4] the aggregate verdict is route_design" \
    "route_design" "$(jq -r '.verdict // "MISSING"' <<< "$GA_RESULT")"
assert_file_exists "[SPEC-4] design-feedback.md is written for the rewind" \
    "$AGG_DIR/design-feedback.md"
assert_contains "[SPEC-5] design-feedback.md names the acceptance gate that routed" \
    "$DESIGN_FB" "acceptance-gate"
assert_contains "[SPEC-5] design-feedback.md names the offending SPEC — the #1809 gap" \
    "$DESIGN_FB" "guard_regressed:SPEC-1"

# ── Additive guard: a non-acceptance route_design still renders as today ────
# shape-floor's missing_floor_files was the ONLY thing #1809's design-feedback
# did carry; that path must be untouched by this change.
SF_DIR="$TEST_TEMP_DIR/agg-shapefloor"; mkdir -p "$SF_DIR"
jq -n '{verdict:"fail",reason:"missing_floor_files: tests/golden/x.golden",route_target:"design"}' \
    > "$SF_DIR/shape-floor-result.json"
_run_aggregator "$SF_DIR"
assert_eq "[SPEC-6] a shape-floor-rooted route_design is unchanged by this issue" \
    "route_design" "$(jq -r '.verdict // "MISSING"' <<< "$GA_RESULT")"
assert_contains "[SPEC-6] its design-feedback still carries the shape-floor reason" \
    "$DESIGN_FB" "missing_floor_files"

# ── Guard: a build-fixable failure still reaches BUILD, not design (#1583) ──
# tautology deliberately carries NO route_target so build re-authors its own
# assertion. C6 and the guard_regressed routing must not have widened that.
TA_DIR="$TEST_TEMP_DIR/agg-tautology"; mkdir -p "$TA_DIR"
jq -n '{verdict:"fail",disposition:"recoverable",reason:"acceptance SPEC violations",
        failures:["tautology:SPEC-9"]}' > "$TA_DIR/acceptance-gate-result.json"
_run_aggregator "$TA_DIR"
assert_eq "[SPEC-7] a tautology failure still yields a plain fail, not route_design" \
    "fail" "$(jq -r '.verdict // "MISSING"' <<< "$GA_RESULT")"
assert_contains "[SPEC-7] and its detail goes to the BUILD-facing gate-feedback.md" \
    "$GATE_FB" "tautology:SPEC-9"

print_test_results
exit $((FAIL > 0))
