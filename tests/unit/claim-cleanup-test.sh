#!/usr/bin/env bash
# tests/unit/claim-cleanup-test.sh — the claim label is cleared whatever happened
# to the run (#2589, ADR-005).
#
# CL1 [change] CI's clean-up removes zbuild:claimed when the issue's newest
#              run-status comment names this run as the holder (#2532 run
#              45102665787: the run's own release failed and the label stayed)
# CL2 [guard]  ...never when it names another run
# CL3 [guard]  ...nor when no comment names a holder
# CL5 [change] the run's events say whether it took the claim and never released
#              it (rsc_claim_left): yes after acquired with no release, no after
#              a release, no when nothing was claimed
# CL6 [change] the workflows wire it: the pipeline job reports claim_left, and
#              the clean-up job removes this run's claim before it finalizes the
#              run-status comment
# CL8 [change] the status sidecar, seeing that marker, stops the run once
# CL7 [change] the end of such a run says why in plain words
# CL4 [change] a GitHub call refused for bad credentials leaves a marker for the
#              run to stop on (rsc_gh), saying so
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the claim label is always cleared (#2589)"
setup_test_env "claim-cleanup"
# shellcheck source=../../scripts/lib/run-status-comment.sh
source "$REPO_ROOT/scripts/lib/run-status-comment.sh"

ST="$TEST_TEMP_DIR/state"; mkdir -p "$ST/runtime"
GHLOG="$TEST_TEMP_DIR/gh.log"; COMMENTS="$TEST_TEMP_DIR/comments.json"
ME="https://github.com/o/r/actions/runs/111"
# A fake gh: the issue's comments from $COMMENTS; every call logged.
cat > "$TEST_TEMP_DIR/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GHLOG"
case "\$*" in
  *"/comments"*) cat "$COMMENTS" ;;
  *"--method DELETE"*) printf '[]' ;;
  *"FAIL401"*) printf 'HTTP 401: Bad credentials (https://api.github.com/graphql)\n' >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$TEST_TEMP_DIR/bin/gh"; export PATH="$TEST_TEMP_DIR/bin:$PATH"
[[ "$(command -v gh)" == "$TEST_TEMP_DIR/bin/gh" ]] || { echo "the fake gh is not first on PATH" >&2; exit 1; }

_comments() {  # <holder or empty>
    local body="${_RSC_MARKER_PREFIX} run_id=r1 -->"
    [[ -n "$1" ]] && body+=$'\n'"${_RSC_HOLDER_PREFIX}$1 -->"
    jq -nc --arg b "$body" '[{user: {login: "github-actions[bot]"}, author_association: "NONE", body: $b}]' > "$COMMENTS"
}
_deleted() { /usr/bin/grep -c -- "--method DELETE.*labels/zbuild:claimed" "$GHLOG" || true; }

print_test_section "CL1-CL3: CI's clean-up"
_comments "$ME"; : > "$GHLOG"
rsc_claim_cleanup "$ST" o/r 4242 "$ME"
assert_eq "[CL1] this run's claim: the label is removed" "1" "$(_deleted)"
_comments "https://github.com/o/r/actions/runs/999"; : > "$GHLOG"
rsc_claim_cleanup "$ST" o/r 4242 "$ME"
assert_eq "[CL2] another run's claim: untouched" "0" "$(_deleted)"
_comments ""; : > "$GHLOG"
rsc_claim_cleanup "$ST" o/r 4242 "$ME"
assert_eq "[CL3] no holder named: untouched" "0" "$(_deleted)"

print_test_section "CL4: a rejected login leaves a marker"
rm -f "$ST/runtime/github-login-rejected" "$ST/runtime/github-login-401-seen"
rsc_gh "$ST" "$TEST_TEMP_DIR/out" api FAIL401 >/dev/null 2>&1 || true
assert_eq "[CL4] one 401 is not yet a rejected login (it can be a blip)" "no" "$([[ -f "$ST/runtime/github-login-rejected" ]] && echo yes || echo no)"
rsc_gh "$ST" "$TEST_TEMP_DIR/out" api FAIL401 >/dev/null 2>&1 || true
assert_eq "[CL4] a second 401 in a row is: the marker is there" "yes" "$([[ -f "$ST/runtime/github-login-rejected" ]] && echo yes || echo no)"
assert_contains "[CL4] ...saying why" "$(cat "$ST/runtime/github-login-rejected" 2>/dev/null)" "Bad credentials"
rm -f "$ST/runtime/github-login-rejected" "$ST/runtime/github-login-401-seen"
rsc_gh "$ST" "$TEST_TEMP_DIR/out" api FAIL401 >/dev/null 2>&1 || true
rsc_gh "$ST" "$TEST_TEMP_DIR/out" api repos/o/r >/dev/null 2>&1 || true
rsc_gh "$ST" "$TEST_TEMP_DIR/out" api FAIL401 >/dev/null 2>&1 || true
assert_eq "[CL4] a call that works in between starts the count again" "no" "$([[ -f "$ST/runtime/github-login-rejected" ]] && echo yes || echo no)"

print_test_section "CL5: the run's events say whether the claim was left"
EV="$TEST_TEMP_DIR/events.jsonl"
printf '%s\n' '{"type":"pipeline.claim.acquired","data":{"issue":"4242"}}' '{"type":"pipeline.claim.release_failed","data":{"issue":"4242"}}' > "$EV"
assert_eq "[CL5] acquired, the release failed → left" "yes" "$(rsc_claim_left "$EV")"
printf '%s\n' '{"type":"pipeline.claim.acquired","data":{"issue":"4242"}}' > "$EV"
assert_eq "[CL5] acquired, never released (killed) → left" "yes" "$(rsc_claim_left "$EV")"
printf '%s\n' '{"type":"pipeline.claim.acquired","data":{"issue":"4242"}}' '{"type":"plugin.release.complete","data":{}}' > "$EV"
assert_eq "[CL5] acquired and released → not left" "no" "$(rsc_claim_left "$EV")"
printf '%s\n' '{"type":"pipeline.claim.skipped","data":{"issue":"4242"}}' > "$EV"
assert_eq "[CL5] nothing claimed → not left" "no" "$(rsc_claim_left "$EV")"
assert_eq "[CL5] no events file → unknown, not 'released'" "unknown" "$(rsc_claim_left "$TEST_TEMP_DIR/none.jsonl")"

print_test_section "CL6: the workflows wire it"
PW="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"; DW="$REPO_ROOT/.github/workflows/zbuild-daemon.yml"
assert_contains "[CL6] the pipeline job reports claim_left" "$(cat "$PW")" "claim_left: \${{ steps.abort.outputs.claim_left }}"
_a="$(/usr/bin/grep -n "Remove this run's claim label if it was left" "$DW" | cut -d: -f1)"
_b="$(/usr/bin/grep -n "Finalize the run-status comment" "$DW" | cut -d: -f1)"
assert_contains "[CL6] the holder fallback runs only when the run left no record" "$(cat "$DW")" 'elif [[ -z "${CLAIM_LEFT:-}" || "${CLAIM_LEFT:-}" == "unknown" ]]; then'
assert_eq "[CL6] the clean-up removes the claim before finalizing the comment" "yes" "$([[ -n "$_a" && -n "$_b" && "$_a" -lt "$_b" ]] && echo yes || echo no)"

print_test_section "CL7: the end words"
# shellcheck source=../../scripts/lib/run-open-items.sh
source "$REPO_ROOT/scripts/lib/run-open-items.sh"
assert_contains "[CL7] a rejected login is named" "$(run_end_words github_login_rejected 0)" "GitHub no longer accepts this run's login"

print_test_section "CL8: the sidecar stops the run"
sleep 60 & _parent=$!
ST8="$TEST_TEMP_DIR/st8"; mkdir -p "$ST8/runtime"; : > "$ST8/events.jsonl"
printf 'HTTP 401: Bad credentials\n' > "$ST8/runtime/github-login-rejected"
ZBUILD_STATUS_COMMENT_POLL=0.1 rsc_tail_loop "$ST8/events.jsonl" "$ST8" "$_parent" o/r 4242 run-1 >/dev/null 2>&1 &
_loop=$!
for _ in $(seq 1 100); do kill -0 "$_parent" 2>/dev/null || break; sleep 0.1; done
assert_eq "[CL8] the run is stopped" "gone" "$(kill -0 "$_parent" 2>/dev/null && echo alive || echo gone)"
kill "$_parent" "$_loop" 2>/dev/null; wait "$_parent" "$_loop" 2>/dev/null
assert_contains "[CL8] ...and the sidecar says why" "$(cat "$ST8"/status-comment.log 2>/dev/null)" "GitHub rejected the run's login"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
