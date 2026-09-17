#!/usr/bin/env bash
# tests/unit/manifest-graph-collect-memo-test.sh — manifest_graph_collect is
# memoised on (root, stage) (#2129). Every consumer of a stage's manifest —
# pre-iter cleanup, the summaries collector, the aggregator roster, feedback
# resolution — walked plugins/ again: ~36 `find` sweeps ≈ 1.3s per cycle
# iteration. A hit is validated against the manifest on disk (still present,
# still that id) so a fixture rewritten mid-test cannot serve a stale path;
# a miss is never memoised because fixtures are created after first lookup.
# The memo is a file under $ZBUILD_STATE_DIR because nearly every caller runs
# the lookup in a `$( )` capture, where a shell variable would die.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"

print_test_header "manifest_graph_collect — memoised per (root, stage) (#2129)"
setup_test_env "manifest-graph-collect-memo"

# The callers that matter run the lookup inside `$( )`, so the memo has to
# survive a subshell: it lives under the run's state dir.
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"; mkdir -p "$ZBUILD_STATE_DIR"
PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$PROOT/tool/mg-a" "$PROOT/tool/mg-b"
printf 'id: mg-a\nname: A\nkind: tool\nversion: 0.0.1\n' > "$PROOT/tool/mg-a/manifest.yaml"
printf 'id: mg-b\nname: B\nkind: tool\nversion: 0.0.1\n' > "$PROOT/tool/mg-b/manifest.yaml"

# Count tree walks: a shell function shadows the binary inside the process
# substitution the lookup uses; the counter is a file so a subshell can bump it.
WALKS="$TEST_TEMP_DIR/walks"; : > "$WALKS"
find() { printf 'x\n' >> "$WALKS"; command find "$@"; }
_walks() { wc -l < "$WALKS" | tr -d ' '; }

p1="$(manifest_graph_collect "$PROOT" mg-a)"
assert_eq "[SPEC-1] the first lookup resolves the manifest" "$PROOT/tool/mg-a/manifest.yaml" "$p1"
assert_eq "[SPEC-1] …with one walk" "1" "$(_walks)"
p2="$(manifest_graph_collect "$PROOT" mg-a)"
assert_eq "[SPEC-2] the second lookup returns the same path" "$p1" "$p2"
assert_eq "[SPEC-2] …without walking again" "1" "$(_walks)"
_pb="$(manifest_graph_collect "$PROOT" mg-b)"
assert_eq "[SPEC-2] a different stage walks once more" "2" "$(_walks)"
: > "$WALKS"
unset ZBUILD_STATE_DIR
_pn="$(manifest_graph_collect "$PROOT" mg-a)"; _pn="$(manifest_graph_collect "$PROOT" mg-a)"
assert_eq "[SPEC-2b] with no state dir a \$( ) caller cannot be served from memory (2 walks)" "2" "$(_walks)"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"

# A miss is not memoised: the fixture may appear later.
manifest_graph_collect "$PROOT" mg-c >/dev/null 2>&1
mkdir -p "$PROOT/tool/mg-c"
printf 'id: mg-c\nname: C\nkind: tool\nversion: 0.0.1\n' > "$PROOT/tool/mg-c/manifest.yaml"
p3="$(manifest_graph_collect "$PROOT" mg-c)"
assert_eq "[SPEC-3] a stage created after a miss is found" "$PROOT/tool/mg-c/manifest.yaml" "$p3"

# A hit whose manifest was rewritten to another id is not served stale.
printf 'id: mg-renamed\nname: A\nkind: tool\nversion: 0.0.1\n' > "$PROOT/tool/mg-a/manifest.yaml"
set +e; p4="$(manifest_graph_collect "$PROOT" mg-a)"; rc4=$?; set -e
assert_eq "[SPEC-4] a memoised path whose id changed is not returned" "" "$p4"
assert_eq "[SPEC-4] …and the lookup reports the miss" "1" "$rc4"
rm -rf "$PROOT/tool/mg-b"
set +e; p5="$(manifest_graph_collect "$PROOT" mg-b)"; rc5=$?; set -e
assert_eq "[SPEC-4] a memoised path that was deleted is not returned" "" "$p5"

unset -f find
cleanup_test_env
print_test_results
exit $((FAIL > 0))
