#!/usr/bin/env bash
# Integration: the run-status comment the sidecar posts names the claim's holder
# — and only for a run that has the claim (ADR-005 §2, issue #1764 R1).
#
# H1 a run that claimed the issue: the comment it posts carries
#    <!-- zbuild-holder: run_id=<id> machine=<machine> pid=<pid> -->
# H2 a run that made no claim (its coordinator failed; the run went on): no
#    holder line in any body it posts
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../lib/claim-runner-fixture.sh
source "$REPO_ROOT/tests/lib/claim-runner-fixture.sh"

print_test_header "the run-status comment names the claim's holder (ADR-005 §2)"
setup_test_env "claim-holder-status-comment"
claim_fixture_setup
claim_fixture_stage ":"

# A recording gh: every comment body the sidecar sends is kept.
BODIES="$TEST_TEMP_DIR/bodies"; mkdir -p "$BODIES"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; cp "\$f" "$BODIES/body-\$\$-\$RANDOM.txt" ;; esac
case "\$args" in
  "auth status"*) exit 0 ;;
  api*--paginate*) echo '[]' ;;
  api*"-X PATCH"*) echo '{}' ;;
  api*issues/*/comments*) echo 4242 ;;
esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
git -C "$CLAIM_REPO" remote remove origin >/dev/null 2>&1 || true
git -C "$CLAIM_REPO" remote add origin https://github.com/testuser/testrepo.git
export ZBUILD_STATUS_COMMENT=1 ZBUILD_STATUS_COMMENT_MIN_INTERVAL=0 ZBUILD_STATUS_COMMENT_POLL=0.2
export ZBUILD_STATUS_COMMENT_REAP_TIMEOUT=10 ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5
unset NO_GITHUB GITHUB_ACTIONS
export ZBUILD_CLAIM_MACHINE_ID="box-h"

_bodies_with_holder() { /usr/bin/grep -l '^<!-- zbuild-holder: ' "$BODIES"/*.txt 2>/dev/null | wc -l | tr -d ' '; }

print_test_section "H1 claimed"
rm -f "$BODIES"/*; claim_fixture_stub_coordinator '{"acquired": true}'
ZBUILD_RUN_ID="holder-run-1" claim_fixture_run h1 --issue 90001831
n="$(find "$BODIES" -name '*.txt' | wc -l | tr -d ' ')"
assert_eq "[H1] setup: the sidecar sent at least one body" "1" "$(( n > 0 ))"
# #2589: the holder also carries the runner's pid, so a later run on this
# machine can tell a live holder from a crashed one.
if /usr/bin/grep -qxE '<!-- zbuild-holder: run_id=holder-run-1 machine=box-h pid=[0-9]+ -->' "$BODIES"/*.txt 2>/dev/null; then
    assert_pass "[H1] the comment names the holder: run id and machine"
else
    assert_fail "[H1] the comment names the holder: run id and machine" \
        "bodies: $(head -3 "$BODIES"/*.txt 2>/dev/null); log: $(tail -5 "$ZBUILD_STATE_DIR/status-comment.log" 2>/dev/null)"
fi

print_test_section "H2 no claim made"
rm -f "$BODIES"/*; claim_fixture_stub_coordinator '{"acquired": false, "reason": "backend_error"}' 'return 1'
ZBUILD_RUN_ID="holder-run-2" claim_fixture_run h2 --issue 90001832
n="$(find "$BODIES" -name '*.txt' | wc -l | tr -d ' ')"
assert_eq "[H2] setup: the sidecar sent at least one body" "1" "$(( n > 0 ))"
assert_eq "[H2] no body names a holder" "0" "$(_bodies_with_holder)"

print_test_results
exit $((FAIL > 0))
