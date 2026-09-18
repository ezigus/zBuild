#!/usr/bin/env bash
# Tests: the run-status comment's GitHub I/O (#2131, ADR-064, keeper e-1).
#
# One comment per run: POST once, PATCH forever after, id persisted
# atomically, rediscovered by the hidden marker when the id file is lost.
# Every failure is advisory — rc 0, one line in status-comment.log, nothing
# else. `gh` is a recording fake; no test here can reach GitHub.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "run-status-comment — GitHub I/O (#2131)"
setup_test_env "rsc-gh"

LIB="$REPO_ROOT/scripts/lib/run-status-comment.sh"
if ! source "$LIB" 2>/dev/null || ! declare -F rsc_upsert >/dev/null 2>&1; then
    assert_fail "[SPEC-0] rsc_upsert is defined" "missing"
    print_test_results; exit 1
fi
assert_pass "[SPEC-0] rsc_upsert is defined"

STATE="$TEST_TEMP_DIR/state"; mkdir -p "$STATE"
GH_LOG="$TEST_TEMP_DIR/gh.log"; GH_BODIES="$TEST_TEMP_DIR/bodies"; mkdir -p "$GH_BODIES"
GH_MODE="$TEST_TEMP_DIR/gh.mode"; printf 'ok' > "$GH_MODE"
GH_LIST="$TEST_TEMP_DIR/gh.list"; printf '[]' > "$GH_LIST"
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=5

# Recording fake: one line per call, the stdin body (when `body=@-`) saved,
# behaviour switched by a mode file so failure paths need no second stub.
cat > "$TEST_TEMP_DIR/bin/gh" <<MOCK
#!/usr/bin/env bash
args="\$*"
# Body first, log line second: a test that waits on the log must find the body already there.
case "\$args" in *body=@*) f="\${args##*body=@}"; f="\${f%% *}"; n="\$(ls "$GH_BODIES" | wc -l | tr -d ' ')"; cp "\$f" "$GH_BODIES/body-\$((n+1)).txt" ;; esac
printf '%s\n' "\$*" >> "$GH_LOG"
mode="\$(cat "$GH_MODE")"
case "\$args" in
  "auth status"*) exit 0 ;;
  *--paginate*) cat "$GH_LIST"; exit 0 ;;
  *"-X PATCH"*)
      case "\$mode" in
        fail404patch) echo "HTTP 404: Not Found" >&2; exit 1 ;;
        fail500) echo "HTTP 500: boom" >&2; exit 1 ;;
      esac
      echo '{}'; exit 0 ;;
  *issues/*/comments*)
      case "\$mode" in
        fail422) echo "HTTP 422: Validation Failed" >&2; exit 1 ;;
        fail500) echo "HTTP 500: boom" >&2; exit 1 ;;
      esac
      case "\$args" in *"--jq .id"*) echo 4242 ;; *) echo '{"id":4242}' ;; esac
      exit 0 ;;
esac
exit 1
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

BODY="$TEST_TEMP_DIR/body.md"
printf '<!-- zbuild-run-status run_id=r-2131 -->\n### zbuild run `r-2131`\n**1 intake** · running\n' > "$BODY"

posts() { grep -c -E '^api repos/testuser/testrepo/issues/90000042/comments' "$GH_LOG" 2>/dev/null || true; }
patches() { grep -c -E '^api repos/testuser/testrepo/issues/comments/4242 .*-X PATCH' "$GH_LOG" 2>/dev/null || true; }

# ─── SPEC-1: first upsert creates; id persisted atomically ──────────────────
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"; rc=$?
assert_eq "[SPEC-1] rsc_upsert returns 0" "0" "$rc"
assert_eq "[SPEC-1] exactly one POST to the issue's comments" "1" "$(posts)"
assert_eq "[SPEC-1] no PATCH yet" "0" "$(patches)"
assert_file_exists "[SPEC-1] status-comment.json written" "$STATE/status-comment.json"
assert_eq "[SPEC-1] comment id persisted" "4242" "$(jq -r '.comment_id' "$STATE/status-comment.json")"
assert_eq "[SPEC-1] run id persisted" "r-2131" "$(jq -r '.run_id' "$STATE/status-comment.json")"
assert_eq "[SPEC-1] no temp file left beside the id" "0" "$(find "$STATE" -name 'status-comment.json.*' | wc -l | tr -d ' ')"
assert_contains "[SPEC-1] the body travelled as a file, verbatim" "$(cat "$GH_BODIES/body-1.txt")" 'run_id=r-2131'
assert_eq "[SPEC-1] rsc_id_load reads it back" "4242" "$(rsc_id_load "$STATE")"

# ─── SPEC-2: later upserts PATCH the same comment ───────────────────────────
printf '<!-- zbuild-run-status run_id=r-2131 -->\n### zbuild run `r-2131`\n**2 plan** · running\n' > "$BODY"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
assert_eq "[SPEC-2] POST count still 1" "1" "$(posts)"
assert_eq "[SPEC-2] two PATCHes to …/issues/comments/4242" "2" "$(patches)"
assert_contains "[SPEC-2] PATCH carries the new body" "$(cat "$GH_BODIES/body-3.txt")" '**2 plan**'

# ─── SPEC-3: lost id file → rediscover by marker, never a second POST ───────
rm -f "$STATE/status-comment.json"
printf '[{"id":11,"body":"unrelated"},{"id":4242,"body":"<!-- zbuild-run-status run_id=r-2131 -->\\nold"}]' > "$GH_LIST"
: > "$GH_LOG"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
assert_eq "[SPEC-3] no POST after rediscovery" "0" "$(posts)"
assert_eq "[SPEC-3] one PATCH to the rediscovered id" "1" "$(patches)"
assert_eq "[SPEC-3] id file re-persisted" "4242" "$(rsc_id_load "$STATE")"
assert_eq "[SPEC-3] one paginated list call" "1" "$(grep -c -- '--paginate' "$GH_LOG")"

# A run id with jq-hostile characters still rediscovers (matched with --arg, never interpolated).
rm -f "$STATE/status-comment.json"
jq -n '[{id:4242, body:("<!-- zbuild-run-status run_id=" + "r\"q" + " -->")}]' > "$GH_LIST"
: > "$GH_LOG"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 'r"q' "$BODY"
assert_eq "[SPEC-3] a quote in run_id does not break rediscovery (no POST)" "0" "$(posts)"
assert_eq "[SPEC-3] …the marked comment is PATCHed" "1" "$(patches)"

# A marker for a DIFFERENT run must not be adopted.
rm -f "$STATE/status-comment.json"
printf '[{"id":99,"body":"<!-- zbuild-run-status run_id=r-other -->"}]' > "$GH_LIST"
: > "$GH_LOG"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
assert_eq "[SPEC-3] another run's marker is not adopted → POST" "1" "$(posts)"
assert_eq "[SPEC-3] …and no PATCH of the foreign comment" "0" "$(grep -c 'comments/99' "$GH_LOG")"

# ─── SPEC-4: failures are advisory ──────────────────────────────────────────
rm -f "$STATE/status-comment.json" "$STATE/status-comment.log"; printf '[]' > "$GH_LIST"
printf 'fail422' > "$GH_MODE"; : > "$GH_LOG"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"; rc=$?
assert_eq "[SPEC-4] 422 on create → rc 0" "0" "$rc"
assert_file_not_exists "[SPEC-4] 422 on create → no id persisted" "$STATE/status-comment.json"
assert_contains "[SPEC-4] 422 logged" "$(cat "$STATE/status-comment.log")" '422'
assert_eq "[SPEC-4] the sidecar wrote no events.jsonl" "0" "$(find "$STATE" -name 'events.jsonl' | wc -l | tr -d ' ')"

printf 'ok' > "$GH_MODE"; : > "$GH_LOG"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"     # create → 4242
printf 'fail500' > "$GH_MODE"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"; rc=$?
assert_eq "[SPEC-4] 500 on PATCH → rc 0" "0" "$rc"
assert_eq "[SPEC-4] 500 on PATCH keeps the id" "4242" "$(rsc_id_load "$STATE")"
assert_contains "[SPEC-4] 500 logged" "$(cat "$STATE/status-comment.log")" '500'

# ─── SPEC-5: PATCH 404 (comment deleted) → one re-create, then stop ────────
printf 'fail404patch' > "$GH_MODE"; : > "$GH_LOG"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
assert_eq "[SPEC-5] 404 on PATCH → one re-create" "1" "$(posts)"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"
assert_eq "[SPEC-5] a second 404 never fans out into more POSTs" "1" "$(posts)"

# ─── SPEC-5b: the body field is `-F` (reads @file), never `-f` (literal) ───
# The fake above resolves `@file` for either flag; the real `gh api` does so
# only for --field. The first real run (#2137) posted its own temp path as the
# comment body — a defect no fake can show, so the flag is pinned as text.
assert_eq "[SPEC-5b] both gh writes use -F body=@file" "2" "$(grep -c -- '-F "body=@' "$LIB")"
assert_eq "[SPEC-5b] no gh write uses -f body=@file (a literal, not a file)" "0" "$(grep -c -- '-f "body=@' "$LIB")"

# ─── SPEC-6: gh call is bounded by the watchdog ─────────────────────────────
cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
sleep 30
MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"
rm -f "$STATE/status-comment.json"
_RSC_GIVEN_UP=0; _RSC_RECREATED=0     # SPEC-5 gave up for that "run"; fresh process semantics here
export ZBUILD_STATUS_COMMENT_GH_TIMEOUT=1
t0=$(date +%s)
rsc_upsert "$STATE" "testuser/testrepo" 90000042 "r-2131" "$BODY"; rc=$?
t1=$(date +%s)
assert_eq "[SPEC-6] hung gh → rc 0" "0" "$rc"
if [[ $(( t1 - t0 )) -le 8 ]]; then
    assert_pass "[SPEC-6] hung gh is killed by the watchdog ($(( t1 - t0 ))s)"
else
    assert_fail "[SPEC-6] hung gh is killed by the watchdog" "took $(( t1 - t0 ))s"
fi
assert_contains "[SPEC-6] timeout logged" "$(cat "$STATE/status-comment.log")" 'timeout'

cleanup_test_env
print_test_results
exit $((FAIL > 0))
