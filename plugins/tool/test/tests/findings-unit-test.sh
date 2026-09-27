#!/usr/bin/env bash
# plugins/tool/test/tests/findings-unit-test.sh — the test stage names what to
# fix: every failing file with a one-line reason, and the file(s) a failure
# POINTS AT, so the engine can route the finding to whoever owns them.
#
# Why: #1845 run 36274909946 lost four iterations to a lint guard that failed
# on a line test-author wrote (validate-test.sh:333). The result named only the
# guard file, `about` was null, so the finding went to build — which may not
# edit test-author's files — and every rebuild changed 0 files. A second file
# died after `✓ T1` with no ✗ at all, and every downstream stage was left to
# guess why.
#
# F1  a guard failure: the failing file, its ✗ line as the reason, and the
#     offending file it names (path:line:) under points_at
# F2  the result carries data.failures and a top-level `about` = the pointed-at
#     files, newline-separated (#2180's shape, which the engine resolves to an
#     owner)
# F3  the stage summary opens with a "Failing files" section: file — reason
# F4  a ✗ followed by its expected/got detail line: both are the reason
# F5  a file that exits non-zero after its last passing check with no ✗ says
#     exactly that, naming the last check — never an empty or ✓ reason
# F6  a TIMEOUT says it timed out
# F7  points_at never names the failing file itself, a path that does not
#     exist in the tree, or a path outside it
# F8  a failure that points at nothing leaves `about` unset (the fault-class
#     routing applies, as today)
# F9  consecutive ✗ lines are two checks, not a check and its detail
#     (claude-review on #2210)
# F10 a staging path containing a space still names the failing file
#     (claude-review on #2210)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin: test stage names what to fix (failing files, reasons, about)"

setup_test_env "test-stage-findings"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

ARTIFACT_DIR="$TEST_TEMP_DIR/state/artifacts"
mkdir -p "$ARTIFACT_DIR"
export ZBUILD_ARTIFACT_DIR="$ARTIFACT_DIR"

# A target repo holding the files the fake suite names.
REPO="$TEST_TEMP_DIR/repo"
export ZBUILD_REPO_ROOT="$REPO"
mkdir -p "$REPO/tests/unit" "$REPO/plugins/x/tests" "$REPO/bin"
printf '#!/usr/bin/env bash\n' > "$REPO/tests/unit/guard-test.sh"
printf '#!/usr/bin/env bash\n' > "$REPO/tests/unit/slow-test.sh"
printf '#!/usr/bin/env bash\n' > "$REPO/tests/unit/state-test.sh"
printf '#!/usr/bin/env bash\n' > "$REPO/plugins/x/tests/authored-test.sh"

# The fake suite prints run-tests.sh's shape. $PWD is the stage's rsync'd copy
# at run time, so the paths carry the same staging prefix a real run's do.
cat > "$REPO/bin/fake-suite.sh" <<'EOF'
#!/usr/bin/env bash
cat <<OUT
unit: FAIL $PWD/tests/unit/guard-test.sh

  forbidden-pipe guard

  offending lines (forbidden pipe — convert to a here-string):
$PWD/plugins/x/tests/authored-test.sh:12:if forbidden_pipe x y; then
$PWD/tests/unit/guard-test.sh:3:# the guard's own fixture line
$PWD/plugins/x/tests/missing-test.sh:9:not a real file
/etc/hosts:1:outside the tree
  ✗ all tiers free of the forbidden-pipe antipattern
    found 1 occurrence(s); see list above
unit: 3/4 passed
total: 3/4 passed
OUT
exit 1
EOF
chmod +x "$REPO/bin/fake-suite.sh"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name="zbuild-test" -c user.email="test@zbuild" commit -q -m init

source "$REPO_ROOT/plugins/tool/test/plugin.sh"

: > "$ARTIFACT_DIR/diff.patch"
OUT_JSON="$ARTIFACT_DIR/test-results.json"
set +e
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO" "$OUT_JSON" "bash bin/fake-suite.sh"
set -e
assert_eq "precondition: the fake suite reads as a failing run" "fail" "$(jq -r '.verdict' "$OUT_JSON")"

print_test_section "F1/F2: the result names the failing file, why, and what it points at"
_f_file="$(jq -r '.data.failures[0].file // empty' "$OUT_JSON" 2>/dev/null || true)"
_f_reason="$(jq -r '.data.failures[0].reason // empty' "$OUT_JSON" 2>/dev/null || true)"
_f_points="$(jq -r '.data.failures[0].points_at // [] | join(",")' "$OUT_JSON" 2>/dev/null || true)"
assert_eq "[F1] the failing file, repo-relative" "tests/unit/guard-test.sh" "$_f_file"
assert_contains "[F1] the reason is the failing check" "$_f_reason" "all tiers free of the forbidden-pipe antipattern"
assert_eq "[F1] points_at is the offending file the guard named" "plugins/x/tests/authored-test.sh" "$_f_points"
assert_eq "[F2] about names the pointed-at file (the engine resolves its owner)" \
    "plugins/x/tests/authored-test.sh" "$(jq -r '.about // empty' "$OUT_JSON" 2>/dev/null || true)"

print_test_section "F3: the summary opens with what to fix"
_sum="$(cat "$ARTIFACT_DIR/test-failures-summary.md" 2>/dev/null || true)"
assert_contains "[F3] a Failing files section" "$_sum" "## Failing files"
assert_contains "[F3] file — reason" "$_sum" "tests/unit/guard-test.sh — ✗ all tiers free of the forbidden-pipe antipattern"
assert_contains "[F3] and the file it points at" "$_sum" "points at: plugins/x/tests/authored-test.sh"
_ff_line="$(grep -n '^## Failing files' <<< "$_sum" | cut -d: -f1 || true)"
_fl_line="$(grep -n '^## Failing lines' <<< "$_sum" | cut -d: -f1 || true)"
if [[ -n "$_ff_line" && -n "$_fl_line" && "$_ff_line" -lt "$_fl_line" ]]; then
    assert_pass "[F3] it comes before the raw extraction"
else
    assert_fail "[F3] it comes before the raw extraction" "failing-files@${_ff_line:-none} failing-lines@${_fl_line:-none}"
fi

print_test_section "F4–F8: the per-file extraction"
T="$REPO"   # the staging prefix the extraction strips
RAW="$(cat <<EOF
unit: FAIL $T/tests/unit/state-test.sh

  per-run state isolation

  ✓ T1: run-aaa exits 0
unit: FAIL $T/tests/unit/slow-test.sh
  ✓ step one
unit: TIMEOUT $T/tests/unit/slow-test.sh
integration: FAIL $T/plugins/x/tests/authored-test.sh
  ✗ [SPEC-9] validate exits 0 in dry-run
    expected: 0, got: 1
unit: 1/4 passed
EOF
)"
_fj="$(_test_failure_findings "$RAW" "$T" 2>/dev/null || true)"
_reason_of() { jq -r --arg f "$1" '[.[] | select(.file == $f) | .reason][0] // empty' <<< "$_fj" 2>/dev/null || true; }
assert_contains "[F4] the ✗ line" "$(_reason_of plugins/x/tests/authored-test.sh)" "✗ [SPEC-9] validate exits 0 in dry-run"
assert_contains "[F4] and its detail line" "$(_reason_of plugins/x/tests/authored-test.sh)" "expected: 0, got: 1"
assert_contains "[F5] a silent death says so" "$(_reason_of tests/unit/state-test.sh)" "exited non-zero without a failing check"
assert_contains "[F5] naming the last check that passed" "$(_reason_of tests/unit/state-test.sh)" "T1: run-aaa exits 0"
assert_contains "[F6] a timeout says so" "$(_reason_of tests/unit/slow-test.sh)" "timed out"
_n_slow="$(jq '[.[] | select(.file == "tests/unit/slow-test.sh")] | length' <<< "$_fj" 2>/dev/null || echo 0)"
assert_eq "[F6] one entry per file, even when FAIL and TIMEOUT both name it" "1" "$_n_slow"

_pj="$(_test_failure_findings "$(cat <<EOF
unit: FAIL $T/tests/unit/guard-test.sh
$T/tests/unit/guard-test.sh:3:self
$T/plugins/x/tests/missing-test.sh:9:gone
/etc/hosts:1:outside
  ✗ guard
unit: 0/1 passed
EOF
)" "$T" 2>/dev/null || true)"
assert_eq "[F7] no self, no missing file, nothing outside the tree" "" \
    "$(jq -r '.[0].points_at // [] | join(",")' <<< "$_pj" 2>/dev/null || echo "<unparseable>")"

print_test_section "F9/F10: review findings on #2210"
_f9="$(_test_failure_findings "$(cat <<EOF
unit: FAIL $T/tests/unit/state-test.sh
  ✗ check A
  ✗ check B
    expected: 0, got: 1
unit: 0/2 passed
EOF
)" "$T" 2>/dev/null || true)"
_f9_reason="$(jq -r '.[0].reason // empty' <<< "$_f9" 2>/dev/null || true)"
if grep -qF "check B" <<< "$_f9_reason"; then
    assert_fail "[F9] the next ✗ is not taken as the first one's detail" "reason: $_f9_reason"
else
    assert_contains "[F9] the next ✗ is not taken as the first one's detail" "$_f9_reason" "✗ check A"
fi

SP="$TEST_TEMP_DIR/staging with space"
mkdir -p "$SP/tests/unit"
printf '#!/usr/bin/env bash\n' > "$SP/tests/unit/state-test.sh"
_f10="$(_test_failure_findings "$(printf 'unit: FAIL %s/tests/unit/state-test.sh\n  ✗ spaced\nunit: 0/1 passed\n' "$SP")" "$SP" 2>/dev/null || true)"
assert_eq "[F10] a staging path with a space still names the file" "tests/unit/state-test.sh" \
    "$(jq -r '.[0].file // empty' <<< "$_f10" 2>/dev/null || true)"

print_test_section "F8: a failure that points at nothing sets no owner"
cat > "$REPO/bin/fake-suite.sh" <<'EOF'
#!/usr/bin/env bash
printf 'unit: FAIL %s/tests/unit/state-test.sh\n  ✗ state isolates\nunit: 0/1 passed\ntotal: 0/1 passed\n' "$PWD"
exit 1
EOF
git -C "$REPO" -c user.name="zbuild-test" -c user.email="test@zbuild" commit -q -am f8
OUT8="$ARTIFACT_DIR/test-results-8.json"
set +e
_test_run_inner "$ARTIFACT_DIR/diff.patch" "$REPO" "$OUT8" "bash bin/fake-suite.sh"
set -e
assert_eq "[F8] precondition: the failure is listed" "tests/unit/state-test.sh" \
    "$(jq -r '.data.failures[0].file // empty' "$OUT8" 2>/dev/null || true)"
assert_eq "[F8] no about" "null" "$(jq -r '.about' "$OUT8" 2>/dev/null || echo "<unparseable>")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
