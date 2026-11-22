#!/usr/bin/env bash
# E2E: claimants racing for one issue on the github-labels coordinator's local-fs
# store (ADR-005 §2). The store's add is checked and made under one lock, so it
# has a single winner; GitHub's label add has no such check, which is #2534's.
#
# R1 a 4-way race: no backend error, every reply is valid JSON
# R2 …exactly one claimant has acquired=true; the others acquired=false
# R3 …and the issue carries zbuild:claimed exactly once
# R4 the winner's release removes it
# R5 list_claims lists a claimed issue
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"

print_test_header "claim-coordinator race (ADR-005)"
setup_test_env "claim-race"
skip_unless_capable "flock unavailable — the local-fs claim store needs it" command -v flock

PLUGIN_DIR="$REPO_ROOT/plugins/claim-coordinator/github-labels"
export ZBUILD_CLAIM_BACKEND="local-fs"
export ZBUILD_CLAIM_STORE="$TEST_TEMP_DIR/claim-store"
unset NO_GITHUB

# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
set +e; validate_manifest "$PLUGIN_DIR/manifest.yaml" >/dev/null 2>&1; rc=$?; set -e
assert_eq "github-labels manifest validates as claim-coordinator" "0" "$rc"

ISSUE=90001841 N=4 OUT="$TEST_TEMP_DIR/race"
mkdir -p "$OUT"
pids=()
for i in $(seq 1 "$N"); do
    (
        # shellcheck source=../../plugins/claim-coordinator/github-labels/plugin.sh
        source "$PLUGIN_DIR/plugin.sh"
        rc=0; claim_coordinator_claim "$ISSUE" > "$OUT/$i.json" 2> "$OUT/$i.err" || rc=$?
        echo "$rc" > "$OUT/$i.rc"
    ) &
    pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" || true; done

winners=0 losers=0 bad=0
for i in $(seq 1 "$N"); do
    if [[ "$(cat "$OUT/$i.rc")" != "0" ]]; then bad=$((bad + 1)); continue; fi
    case "$(jq -r '.acquired' "$OUT/$i.json" 2>/dev/null || echo unparsed)" in
        true) winners=$((winners + 1)) ;;
        false) losers=$((losers + 1)) ;;
        *) bad=$((bad + 1)) ;;
    esac
done
assert_eq "[R1] no backend error or unreadable reply" "0" "$bad"
assert_eq "[R2] exactly one winner" "1" "$winners"
assert_eq "[R2] …the other $((N - 1)) are refused" "$((N - 1))" "$losers"
LABELS="$ZBUILD_CLAIM_STORE/$ISSUE/labels.txt"
assert_eq "[R3] the issue carries zbuild:claimed exactly once" "1" "$(/usr/bin/grep -cx 'zbuild:claimed' "$LABELS" || true)"

# shellcheck source=../../plugins/claim-coordinator/github-labels/plugin.sh
source "$PLUGIN_DIR/plugin.sh"
assert_eq "[R5] list_claims lists the claimed issue" "1" \
    "$(claim_coordinator_list_claims | jq --argjson i "$ISSUE" 'map(select(.issue == $i)) | length')"
claim_coordinator_release "$ISSUE"
assert_eq "[R4] release removes zbuild:claimed" "0" "$(/usr/bin/grep -cx 'zbuild:claimed' "$LABELS" || true)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
