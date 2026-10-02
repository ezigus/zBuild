#!/usr/bin/env bash
# tests/unit/artifact-persist-batch-test.sh — a snapshot stages its files in two
# git calls, not two per file (#2249).
#
# Why: _artifact_persist_snapshot ran `git hash-object -w` and `git update-index
# --add --cacheinfo` once per file. A run snapshots after every stage — 34 times
# in #1844 run 36969128968, 54 in #2032 run 36969130031, over 250–290 files — so
# bookkeeping alone launched thousands of git processes per run, and 1,072 of
# the mocked full run's 6,280.
#
# B1 [change] staging N files costs one hash-object and one update-index call,
#             whatever N is
# B2 [guard]  every file is in the snapshot, at artifacts/<rel>
# B3 [guard]  an unreadable file costs only itself (#1878): the rest are saved
#             and the skip is counted
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "a snapshot stages its files in two git calls (#2249)"
setup_test_env "artifact-persist-batch"
ISSUE="$(zb_test_issue)"
REAL_GIT="$(command -v git)"

fx="$TEST_TEMP_DIR/repo"; mkdir -p "$fx"
( cd "$fx" && "$REAL_GIT" init -q -b main && "$REAL_GIT" config user.email t@t.t \
  && "$REAL_GIT" config user.name t && echo code > app.txt && "$REAL_GIT" add app.txt \
  && "$REAL_GIT" commit -q -m base ) >/dev/null 2>&1
state="$fx/state"; mkdir -p "$state/artifacts/attempts/build"
for i in $(seq 1 10); do printf 'artifact %s\n' "$i" > "$state/artifacts/a-$i.json"; done
printf 'nested\n' > "$state/artifacts/attempts/build/x.md"
printf '# scope\n' > "$state/scope-manifest.md"

# A git on PATH that logs each subcommand, then runs the real one.
LOG="$TEST_TEMP_DIR/git-calls.log"; : > "$LOG"
cat > "$TEST_TEMP_DIR/bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in hash-object|update-index) echo "\$a" >> "$LOG"; break ;; esac; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TEST_TEMP_DIR/bin/git"

print_test_section "B1/B2: twelve files"
_artifact_persist_snapshot "$state" "$ISSUE" "$fx" >/dev/null 2>&1; rc=$?
assert_eq "fixture: the snapshot succeeds" "0" "$rc"
assert_eq "[B1] one hash-object call for 12 files" "1" "$(grep -c '^hash-object$' "$LOG" || true)"
assert_eq "[B1] one update-index call for 12 files" "1" "$(grep -c '^update-index$' "$LOG" || true)"
TREE="$("$REAL_GIT" -C "$fx" ls-tree -r --name-only "$(_artifact_persist_branch "$ISSUE")" 2>/dev/null)"
assert_contains "[B2] a top-level artifact is saved" "$TREE" "artifacts/a-7.json"
assert_contains "[B2] a nested artifact is saved" "$TREE" "artifacts/attempts/build/x.md"
assert_contains "[B2] the scope manifest is saved" "$TREE" "scope-manifest.md"

print_test_section "B3: one unreadable file"
printf 'secret\n' > "$state/artifacts/locked.json"; chmod 000 "$state/artifacts/locked.json"
printf 'artifact 11\n' > "$state/artifacts/a-11.json"
_artifact_persist_snapshot "$state" "$ISSUE" "$fx" >/dev/null 2>&1; rc=$?
chmod 600 "$state/artifacts/locked.json"
TREE="$("$REAL_GIT" -C "$fx" ls-tree -r --name-only "$(_artifact_persist_branch "$ISSUE")" 2>/dev/null)"
assert_eq "[B3] the snapshot still succeeds" "0" "$rc"
assert_contains "[B3] the readable files are saved" "$TREE" "artifacts/a-11.json"
assert_eq "[B3] ...and the skip is counted" "1" "${_ARTIFACT_PERSIST_LAST_SKIPPED:-}"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
