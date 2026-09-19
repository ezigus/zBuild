#!/usr/bin/env bash
# Tests: `zbuild status-comment` — re-attach the run-status comment sidecar to
# a run by hand (#2131, ADR-064). Resolves the run's state dir through the
# same layout globs `--attach` and cleanup use (ADR-059 shapes included), then
# renders once (`--once`) or follows the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "zbuild status-comment (#2131)"
setup_test_env "cli-status-comment"

CLI="$REPO_ROOT/scripts/zbuild"
GH_LOG="$TEST_TEMP_DIR/gh.log"
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$*" in "auth status"*) exit 0 ;; *--paginate*) echo '[]' ;; *"-X PATCH"*) echo '{}' ;; *issues/*/comments*) echo 4242 ;; esac
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# ─── SPEC-1: usage lists the command ────────────────────────────────────────
assert_contains "[SPEC-1] usage lists status-comment" "$(bash "$CLI" --help 2>&1)" 'status-comment'

# ─── fixtures: one run in the ADR-059 layout, one flat ──────────────────────
export ZBUILD_STATE_ROOT="$TEST_TEMP_DIR/zb"
REPO="$TEST_TEMP_DIR/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" remote add origin https://github.com/testuser/testrepo.git
mk_run() {   # mk_run <dir> <run_id> <issue>
    mkdir -p "$1/artifacts"
    jq -cn --arg r "$2" --argjson i "$3" '{schema_version:1, run_id:$r, issue:$i, engine_sha:"abc1234", status:"running", stage_statuses:{}}' > "$1/pipeline-state.json"
    jq -cn --arg r "$2" --argjson i "$3" '{ts:"2026-09-17T12:00:00.000Z", run_id:$r, issue:$i, type:"pipeline.start", plugin:"", kind:"", data:{run_id:$r, issue:($i|tostring), engine_sha:"abc1234", engine_branch:"main"}, schema_version:1}' > "$1/events.jsonl"
    jq -cn --arg r "$2" --argjson i "$3" '{ts:"2026-09-17T12:00:01.000Z", run_id:$r, issue:$i, type:"plugin.run.start", plugin:"", kind:"", stage:"intake", seq:"1", data:{plugin:"intake",kind:"agent"}, schema_version:1}' >> "$1/events.jsonl"
}
NESTED="$ZBUILD_STATE_ROOT/repos/testuser/testrepo/issues/90000042/runs/r-nested"
FLAT="$ZBUILD_STATE_ROOT/runs/r-flat"
mk_run "$NESTED" r-nested 90000042
mk_run "$FLAT" r-flat 90000043
jq -n '{schema_version:1, repo:"testuser/testrepo", issue:90000043, run_id:"r-flat", comment_id:777, created_at:"x"}' > "$FLAT/status-comment.json"

# ─── SPEC-2: --state-dir --once renders and posts once ─────────────────────
: > "$GH_LOG"
( cd "$REPO" && bash "$CLI" status-comment --state-dir "$NESTED" --once ); rc=$?
assert_eq "[SPEC-2] exits 0" "0" "$rc"
assert_eq "[SPEC-2] one POST (no id file yet)" "1" "$(grep -c -E '^api repos/testuser/testrepo/issues/90000042/comments' "$GH_LOG")"
assert_eq "[SPEC-2] id persisted beside the run" "4242" "$(jq -r .comment_id "$NESTED/status-comment.json")"

# ─── SPEC-3: --run resolves the ADR-059 nested layout and the flat one ─────
: > "$GH_LOG"
( cd "$REPO" && bash "$CLI" status-comment --run r-nested --once ); rc=$?
assert_eq "[SPEC-3] --run (nested layout) exits 0" "0" "$rc"
assert_eq "[SPEC-3] …and PATCHes the persisted id" "1" "$(grep -c 'issues/comments/4242 .*-X PATCH' "$GH_LOG")"
: > "$GH_LOG"
( cd "$REPO" && bash "$CLI" status-comment --run r-flat --once ); rc=$?
assert_eq "[SPEC-3] --run (flat layout) exits 0" "0" "$rc"
assert_eq "[SPEC-3] …identity comes from status-comment.json (issue 90000043, id 777)" "1" "$(grep -c 'issues/comments/777 .*-X PATCH' "$GH_LOG")"

# ─── SPEC-4: unknown run → rc 1, says so, no gh call ───────────────────────
: > "$GH_LOG"
out="$( cd "$REPO" && bash "$CLI" status-comment --run r-nope --once 2>&1 )"; rc=$?
assert_eq "[SPEC-4] unknown run id → rc 1" "1" "$rc"
assert_contains "[SPEC-4] names the run id" "$out" 'r-nope'
assert_eq "[SPEC-4] no gh call" "0" "$(wc -l < "$GH_LOG" | tr -d ' ')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
