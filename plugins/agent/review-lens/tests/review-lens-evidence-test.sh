#!/usr/bin/env bash
# plugins/agent/review-lens/tests/review-lens-evidence-test.sh — a lens is
# given what it needs of the change, not all of it (ADR-038 §2).
#
# Why: on #1944 (2026-10-28) a lens prompt was ~115 KB, ~98 KB of it the diff,
# and 68 KB of that the new test files. Every lens read all of it before it
# could start, and five of six ran out of time. A lens reviews the code; a test
# file it wants it can open itself — it runs in the worktree with its tools.
#
# E1 [change] a source file's diff is in the prompt in full
# E2 [change] a test file's diff is not
# E3 [change] each changed test file is named, with its lines added and
#             removed, and the lens is told it can read them
# E4 [change] which paths are tests is the repository's own list
#             (.zbuild/test-paths.txt, ADR-069 §10), never a guess
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
print_test_header "a lens is given what it needs of the change (ADR-038)"
setup_test_env "review-lens-evidence"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"; mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
# shellcheck source=../../../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh"
# shellcheck source=../plugin.sh
source "$REPO_ROOT/plugins/agent/review-lens/plugin.sh"

TGT="$TEST_TEMP_DIR/target"; mkdir -p "$TGT"
export ZBUILD_REPO_ROOT="$TGT"
state="$TEST_TEMP_DIR/state"; art="$state/artifacts"; mkdir -p "$art"
export ZBUILD_STATE_DIR="$state"
evidence="$art/branch-diff.patch"
cat > "$evidence" <<'EOF'
diff --git a/core/thing.sh b/core/thing.sh
index 1111111..2222222 100644
--- a/core/thing.sh
+++ b/core/thing.sh
@@ -1,2 +1,3 @@
 a
+SOURCE_LINE_ADDED
 b
diff --git a/tests/unit/thing-test.sh b/tests/unit/thing-test.sh
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/tests/unit/thing-test.sh
@@ -0,0 +1,3 @@
+TEST_BODY_ONE
+TEST_BODY_TWO
+TEST_BODY_THREE
diff --git a/spec/odd_place.sh b/spec/odd_place.sh
index 4444444..5555555 100644
--- a/spec/odd_place.sh
+++ b/spec/odd_place.sh
@@ -1,2 +1,1 @@
-SPEC_REMOVED
 keep
EOF

PROMPT="$TEST_TEMP_DIR/prompt.txt"
# shellcheck disable=SC2329
route_to_model() { printf '%s' "$2" > "$PROMPT"; printf '{"score":9,"findings":[]}'; }
_run() {
    ( export ZBUILD_MAP_ELEMENT=correctness ZBUILD_REVIEW_LENS_ID=correctness
      _review_lens_run_inner correctness "" "$evidence" "$art/lens-correctness.json" "$art" ) >/dev/null 2>&1
}

print_test_section "E1-E3: with the engine's test folders"
_run
p="$(cat "$PROMPT" 2>/dev/null)"
assert_contains "[E1] the source file's diff is in full" "$p" "+SOURCE_LINE_ADDED"
assert_eq "[E2] the test file's diff is not" "0" "$(grep -c 'TEST_BODY_' <<< "$p" || true)"
assert_contains "[E3] the test file is named, with its lines" "$p" "tests/unit/thing-test.sh (+3 -0)"
assert_contains "[E3] ...and the lens is told it can read it" "$p" "open any of them in the worktree"
assert_contains "[E4] a path outside the test folders is source" "$p" "-SPEC_REMOVED"

print_test_section "E4: the repository's own list"
mkdir -p "$TGT/.zbuild"; printf 'spec/*\n' > "$TGT/.zbuild/test-paths.txt"
_run
p="$(cat "$PROMPT" 2>/dev/null)"
assert_eq "[E4] the repository's test folder's diff is not in the prompt" "0" "$(grep -c 'SPEC_REMOVED' <<< "$p" || true)"
assert_contains "[E4] ...it is named instead" "$p" "spec/odd_place.sh (+0 -1)"
assert_contains "[E4] ...and the engine's default no longer applies" "$p" "TEST_BODY_ONE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
