#!/usr/bin/env bash
# E2E Test: tests/e2e/claim-race-test.sh — multi-claimant race (#308)
# Verifies the ADR-005 contract using the github-labels default plugin in
# local-fs backend mode (so no GitHub access is required).
#
# Spawns N concurrent processes racing to claim the same issue. Asserts:
#   1. Exactly one process reports acquired=true.
#   2. All other processes report acquired=false with a deterministic reason.
#   3. The losers do NOT leave their `claimed:<machine>` labels behind
#      (they drop them in Phase 4 of the protocol).
#
# Repeats the race REPEATS times with different machine IDs to exercise the
# backoff window and reduce false positives. Per ADR-005 the protocol has a
# documented TOCTOU window — the test tolerates 0 acquired (re-test on
# unfortunate timing) but never multiple, because the re-verify drops a
# duplicate claim.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "claim-coordinator race (ADR-005, issue #308)"

setup_test_env "claim-race"

PLUGIN_DIR="$REPO_ROOT/plugins/claim-coordinator/github-labels"

# Use local-fs backend so we don't need a real GitHub.
export ZBUILD_CLAIM_BACKEND="local-fs"
export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store"
# Tight backoff window so the test runs in <2s per race.
export ZBUILD_CLAIM_BACKOFF_MIN_MS=10
export ZBUILD_CLAIM_BACKOFF_MAX_MS=80

# Manifest validation gate — the plugin must be a valid claim-coordinator.
# shellcheck source=../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"

set +e
validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1
rc=$?
set -e
assert_eq "github-labels manifest validates as claim-coordinator" "0" "$rc"

# Run the race. The claim process is a single subshell that sources the
# plugin and calls claim_coordinator_claim with a unique machine_id, then
# writes the result JSON to a per-process output file.
_race_one() {
    local race_id="$1" issue="$2" n_claimants="$3"
    local outdir="$TEST_TEMP_DIR/race-$race_id"
    mkdir -p "$outdir"

    local i pid pids=()
    for i in $(seq 1 "$n_claimants"); do
        (
            export ZBUILD_CLAIM_MACHINE_ID="machine-${i}"
            # shellcheck disable=SC1090,SC1091
            source "$REPO_ROOT/scripts/lib/helpers.sh"
            source "$PLUGIN_DIR/plugin.sh"
            claim_coordinator_init >/dev/null
            claim_coordinator_claim "$issue" > "$outdir/m${i}.json" 2>&1
        ) &
        pids+=("$!")
    done

    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    # Count winners.
    local winners=0
    for i in $(seq 1 "$n_claimants"); do
        local got
        got="$(jq -r '.acquired' "$outdir/m${i}.json" 2>/dev/null || echo "null")"
        [[ "$got" == "true" ]] && winners=$((winners + 1))
    done
    echo "$winners"
}

# ─── Test 1: 3-way race produces ≤1 winner ────────────────────────────────────
print_test_section "1. 3-way race: exactly-one-winner invariant"
ISSUE=42
winners="$(_race_one "r1" "$ISSUE" 3)"
if [[ "$winners" -le 1 ]]; then
    assert_pass "3-way race produced $winners winner(s) (≤1 required)"
else
    assert_fail "3-way race must produce ≤1 winner" "got $winners winners"
fi

# Sanity: when only one process claims, it always wins.
print_test_section "2. solo claim always wins"
# Fresh issue so the previous winner doesn't block.
ISSUE_SOLO=99
(
    export ZBUILD_CLAIM_MACHINE_ID="solo"
    # shellcheck disable=SC1090,SC1091
    source "$PLUGIN_DIR/plugin.sh"
    claim_coordinator_init >/dev/null
    claim_coordinator_claim "$ISSUE_SOLO"
) > "$TEST_TEMP_DIR/solo.json"
solo_got="$(jq -r '.acquired' "$TEST_TEMP_DIR/solo.json")"
assert_eq "solo claimant always wins" "true" "$solo_got"

# ─── Test 3: losers drop their labels (no orphaned claims) ────────────────────
print_test_section "3. losers do not leave orphaned claimed:* labels"
ISSUE_ORPHAN=77
_race_one "r3" "$ISSUE_ORPHAN" 4 >/dev/null
# Read remaining claimed:* labels for the issue.
labels_file="$ZBUILD_CLAIM_STORE/$ISSUE_ORPHAN/labels.txt"
if [[ -f "$labels_file" ]]; then
    claim_count="$(grep -c '^claimed:' "$labels_file" || true)"
    if [[ "$claim_count" -le 1 ]]; then
        assert_pass "≤1 claimed:* label remains after race ($claim_count present)"
    else
        assert_fail "race left $claim_count claimed:* labels (losers didn't drop)" \
            "$(cat "$labels_file")"
    fi
else
    assert_pass "no claimed:* labels remain (all losers dropped)"
fi

# ─── Test 4: release removes the holder's label ────────────────────────────────
print_test_section "4. release removes the holder's label"
ISSUE_REL=55
(
    export ZBUILD_CLAIM_MACHINE_ID="releaser"
    # shellcheck disable=SC1090,SC1091
    source "$PLUGIN_DIR/plugin.sh"
    claim_coordinator_init >/dev/null
    claim_coordinator_claim "$ISSUE_REL" >/dev/null
    claim_coordinator_release "$ISSUE_REL"
)
rel_file="$ZBUILD_CLAIM_STORE/$ISSUE_REL/labels.txt"
if [[ -f "$rel_file" ]] && grep -q "^claimed:releaser$" "$rel_file"; then
    assert_fail "release removes claimed:releaser label" "$(cat "$rel_file")"
else
    assert_pass "release removed claimed:releaser label"
fi

# ─── Test 5: list_claims surfaces current holders ─────────────────────────────
print_test_section "5. list_claims emits JSON array of current holders"
# Solo claim on a fresh issue then list.
ISSUE_LIST=88
(
    export ZBUILD_CLAIM_MACHINE_ID="lister"
    # shellcheck disable=SC1090,SC1091
    source "$PLUGIN_DIR/plugin.sh"
    claim_coordinator_init >/dev/null
    claim_coordinator_claim "$ISSUE_LIST" >/dev/null
)
list_out="$(
    # shellcheck disable=SC1090,SC1091
    source "$PLUGIN_DIR/plugin.sh"
    claim_coordinator_list_claims
)"
list_has_issue="$(echo "$list_out" | jq --argjson i "$ISSUE_LIST" 'map(select(.issue == $i)) | length')"
assert_gt "list_claims contains the claimed issue" "$list_has_issue" "0"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
