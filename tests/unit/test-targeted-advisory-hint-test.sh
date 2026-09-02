#!/usr/bin/env bash
# Tests: plugins/tool/test/plugin.sh — the targeted test re-run is an ADVISORY
# HINT, not a contract (issue #1239, follow-on to ADR-034 / #846).
#
# The build_test_cycle stores the failing-test list (ZBUILD_TEST_RED_SET) so the
# next iter can re-run only the affected files. The #945 dogfood exposed two
# failure modes:
#   (T5) the red-set was written with ABSOLUTE paths into a per-iter temp dir
#        that is destroyed between iterations — on macOS the mktemp staging dir
#        is reached through a /var -> /private/var symlink, so the write-time
#        `s|^$tmp/||` strip missed and stored absolute paths. The next iter then
#        ran `bash <stale-abs-path>` -> "No such file" = PHANTOM failures (5->10),
#        inflating the health score and blocking convergence.
# The fixes pinned here:
#   (Fix B) READ: each red-set hint is resolved against the CURRENT tree; a path
#           that does not resolve is DROPPED (never run -> never a phantom fail).
#           If every hint is dead the target list is empty -> full regression.
#   (Fix C) WRITE: paths are stored durable + repo-relative even when the staging
#           dir is reached through a symlink (both logical + physical prefixes
#           are stripped), so a VALID hint survives across iterations.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "targeted test re-run is an advisory hint (durable paths; unusable -> full) (#1239)"
setup_test_env "test-targeted-advisory-hint"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$ZBUILD_EVENTS_DIR/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../plugins/tool/test/plugin.sh
source "$REPO_ROOT/plugins/tool/test/plugin.sh"

# ─── helper: write a red-set JSON file from the given path args ───────────────
_mk_red_set() {
    local out="$1"; shift
    printf '%s\n' "$@" | jq -Rn '[inputs | select(. != "")]' > "$out"
}

# ═══ Section 1: _test_compute_target_files resolves hints against the tree ════
print_test_section "1. advisory resolution: dead/absolute hints are dropped (Fix B)"

TREE="$TEST_TEMP_DIR/tree"
mkdir -p "$TREE/tests/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TREE/tests/unit/real-test.sh"

RS="$TEST_TEMP_DIR/red-a.json"

# 1a: a dead absolute path + a missing relative path -> both dropped -> empty.
_mk_red_set "$RS" "/tmp/zbuild-test-stage.GONE/tests/unit/dead-test.sh" \
                  "tests/unit/does-not-exist-test.sh"
out="$(ZBUILD_TEST_RED_SET="$RS" ZBUILD_TEST_CHANGED_FILES="" \
       _test_compute_target_files "$TREE")"
if [[ -z "$out" ]]; then
    assert_pass "1a: dead-absolute + missing-relative hints dropped -> empty target list"
else
    assert_fail "1a: unusable hints must be dropped (empty list)" "got: [$out]"
fi

# 1b: a valid relative hint that resolves against the tree survives.
_mk_red_set "$RS" "tests/unit/real-test.sh"
out="$(ZBUILD_TEST_RED_SET="$RS" ZBUILD_TEST_CHANGED_FILES="" \
       _test_compute_target_files "$TREE")"
assert_eq "1b: valid relative hint survives resolution" "tests/unit/real-test.sh" "$out"

# 1c: mixed -> only the resolving path is kept.
_mk_red_set "$RS" "tests/unit/real-test.sh" \
                  "/var/folders/x/T/zbuild-test-stage.OLD/tests/unit/real-test.sh"
out="$(ZBUILD_TEST_RED_SET="$RS" ZBUILD_TEST_CHANGED_FILES="" \
       _test_compute_target_files "$TREE")"
assert_eq "1c: mixed hint list keeps only the tree-resolving path" \
    "tests/unit/real-test.sh" "$out"

# ═══ Section 2: red-set WRITE is durable + relative under a symlinked TMPDIR ══
print_test_section "2. durable relative red-set write under symlinked staging dir (Fix C)"

# Force the exact macOS failure class: mktemp's staging dir is reached through a
# symlink, so a full run whose FAIL lines carry the PHYSICAL path differs from
# the logical $tmp string. A write that only strips the logical prefix would
# store an absolute path (the T5 bug); the fix strips the physical prefix too.
mkdir -p "$TEST_TEMP_DIR/realtmp"
ln -s "$TEST_TEMP_DIR/realtmp" "$TEST_TEMP_DIR/linktmp"

REPO2="$TEST_TEMP_DIR/repo2"
mkdir -p "$REPO2/tests/unit"
printf '#!/usr/bin/env bash\nexit 1\n' > "$REPO2/tests/unit/b.sh"   # fails
git -C "$REPO2" init -q
git -C "$REPO2" -c user.name=t -c user.email=t@t add -A
git -C "$REPO2" -c user.name=t -c user.email=t@t commit -q -m seed

ART2="$TEST_TEMP_DIR/art2"; mkdir -p "$ART2"
DIFF2="$ART2/diff.patch"; : > "$DIFF2"
OUT2="$ART2/test-results.json"

# Runner emits a FAIL line whose path is the PHYSICAL staging path (pwd -P),
# mirroring how a real runner globs its tests dir off a resolved cwd.
RUNNER2="$TEST_TEMP_DIR/runner2.sh"
cat > "$RUNNER2" <<'RUN'
printf 'unit: FAIL %s/tests/unit/b.sh\n' "$(pwd -P)"
printf 'unit: 0/1 passed\n'
exit 1
RUN

(
    export TMPDIR="$TEST_TEMP_DIR/linktmp"
    unset ZBUILD_TEST_RED_SET ZBUILD_TEST_CHANGED_FILES ZBUILD_TEST_FULL_SUITE_GATE
    _test_run_inner "$DIFF2" "$REPO2" "$OUT2" "bash $RUNNER2" >/dev/null 2>&1 || true
)

RSW="$ART2/test-red-set.json"
assert_file_exists "2: test-red-set.json written on failure" "$RSW"
stored="$(jq -r '.[0] // ""' "$RSW" 2>/dev/null)"
assert_eq "2: red-set stores the DURABLE repo-relative path (not an abs temp path)" \
    "tests/unit/b.sh" "$stored"

# ═══ Section 3: dead-only red-set -> full regression, no phantom failures ═════
print_test_section "3. all-dead red-set falls back to full regression (Fix B, run level)"

REPO3="$TEST_TEMP_DIR/repo3"
mkdir -p "$REPO3/tests/unit"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO3/tests/unit/ok-test.sh"
git -C "$REPO3" init -q
git -C "$REPO3" -c user.name=t -c user.email=t@t add -A
git -C "$REPO3" -c user.name=t -c user.email=t@t commit -q -m seed

ART3="$TEST_TEMP_DIR/art3"; mkdir -p "$ART3"
DIFF3="$ART3/diff.patch"; : > "$DIFF3"
OUT3="$ART3/test-results.json"

# A red-set that resolves to NOTHING in the current tree (stale temp paths).
RS3="$TEST_TEMP_DIR/red-dead.json"
_mk_red_set "$RS3" "/tmp/zbuild-test-stage.DESTROYED/tests/unit/ok-test.sh"

# Runner: no args -> full pass; any args -> also pass but records it ran targeted.
RUNNER3="$TEST_TEMP_DIR/runner3.sh"
cat > "$RUNNER3" <<'RUN'
printf 'unit: 1/1 passed\n'
exit 0
RUN

(
    unset ZBUILD_TEST_CHANGED_FILES ZBUILD_TEST_FULL_SUITE_GATE
    export ZBUILD_TEST_RED_SET="$RS3"
    export ZBUILD_TEST_CMD_TARGETED="bash $RUNNER3 {files}"
    _test_run_inner "$DIFF3" "$REPO3" "$OUT3" "bash $RUNNER3" >/dev/null 2>&1 || true
)

run_mode3="$(jq -r '.data.run_mode // "?"' "$OUT3" 2>/dev/null)"
verdict3="$(jq -r '.verdict // "?"' "$OUT3" 2>/dev/null)"
assert_eq "3: all-dead red-set -> full regression (never a broken targeted run)" \
    "full" "$run_mode3"
assert_eq "3: full regression sees the real (passing) result, zero phantom fails" \
    "pass" "$verdict3"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
