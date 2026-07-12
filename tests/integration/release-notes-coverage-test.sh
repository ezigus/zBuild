#!/usr/bin/env bash
# Tests: scripts/lib/release-notes-coverage.sh + its wiring into scripts/release.sh
# (REL-E, #876). Mocked gh + a stub doc-style checker.
#
# Behavioral coverage for the DoD:
# - The per-issue coverage gate PASSES when every closed milestone issue appears
#   (linked) in the generated notes.
# - The gate FAILS and NAMES the missing issue when one closed issue is absent
#   from the notes.
# - Substring false-match is avoided (#12 not "covered" by #123's link).
# - The doc-style gate FAILS the combined gate when lint-doc-style would fail
#   (stubbed non-conforming doc), and PASSES when the stub conforms.
# - The release FLOW (release.sh) REFUSES to cut when the doc-style gate fails,
#   and --force bypasses both gates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release-notes-coverage.sh — per-issue coverage gate + doc-style gate (REL-E / #876)"
setup_test_env "release-notes-coverage"

# ─── Mock gh: same shape as release-sh-test.sh (serves closed issues/PRs) ────
mock_binary "gh" '
GH_CALLS_LOG="${GH_CALLS_LOG:-'"$TEST_TEMP_DIR"'/gh-calls.log}"
echo "gh $*" >> "$GH_CALLS_LOG"
jq_filter=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "--jq" ]]; then j=$((i+1)); jq_filter="${!j}"; break; fi
done
_emit() {
    local src="$1"
    if [[ -n "$jq_filter" && -s "$src" ]]; then jq -r "$jq_filter" < "$src"; else cat "$src"; fi
}
case "${1:-} ${2:-}" in
    "repo view")  echo "ezigus/zBuild"; exit 0 ;;
    "issue list") _emit "${MOCK_ISSUE_LIST_JSON:-/dev/null}"; exit 0 ;;
    "pr list")    _emit "${MOCK_PR_LIST_JSON:-/dev/null}"; exit 0 ;;
    *) echo "[mock-gh] unhandled: $*" >&2; exit 1 ;;
esac
'

export ZBUILD_RELEASE_REPO="ezigus/zBuild"

# Empty since-window so every mocked closed issue is in scope (no date filter).
export ZBUILD_RELEASE_SINCE=""

# Three closed issues in the milestone: #101, #102, #123 (123 chosen so a naive
# substring match could confuse it with #12 — see T2b).
export MOCK_ISSUE_LIST_JSON="$TEST_TEMP_DIR/issues.json"
cat > "$MOCK_ISSUE_LIST_JSON" <<'EOF'
[
  {"number":101,"title":"add release notes generator","labels":[{"name":"enhancement"}],"closedAt":"2026-07-05T10:00:00Z"},
  {"number":102,"title":"fix torn-write in changelog prepend","labels":[{"name":"bug"}],"closedAt":"2026-07-06T10:00:00Z"},
  {"number":123,"title":"update wiki release model","labels":[{"name":"documentation"}],"closedAt":"2026-07-07T10:00:00Z"}
]
EOF
export MOCK_PR_LIST_JSON="$TEST_TEMP_DIR/prs.json"
echo '[]' > "$MOCK_PR_LIST_JSON"

# Source the gate library under test (with the mocked gh on PATH via setup).
# shellcheck source=../../scripts/lib/release-notes-coverage.sh
source "$REPO_ROOT/scripts/lib/release-notes-coverage.sh"

MILESTONE="Initiative 1.1"

# ─── T1: coverage PASSES when every closed issue is linked in the notes ──────
full_notes="$(release_notes_generate "1.2.3.4" "$MILESTONE" "")"
if release_notes_coverage_check "$MILESTONE" "" "$full_notes" >/dev/null 2>&1; then
    assert_pass "T1: coverage gate passes when all closed issues are in the notes"
else
    assert_fail "T1: coverage gate should pass on complete notes"
fi

# ─── T2: coverage FAILS and NAMES the missing issue when one is absent ───────
# Drop issue #102's link from the notes → the gate must fail and name #102.
notes_missing="${full_notes//\/issues\/102)/\/issues\/XXX)}"
cov_err="$(release_notes_coverage_check "$MILESTONE" "" "$notes_missing" 2>&1 >/dev/null || true)"
if release_notes_coverage_check "$MILESTONE" "" "$notes_missing" >/dev/null 2>&1; then
    assert_fail "T2: coverage gate should FAIL when an issue is missing"
else
    assert_pass "T2: coverage gate fails when a closed issue is absent from the notes"
fi
assert_contains "T2: names the missing issue #102" "$cov_err" "missing #102"
# The still-present issues must NOT be reported as missing.
if [[ "$cov_err" == *"missing #101"* ]]; then
    assert_fail "T2: falsely reported #101 as missing"
else
    assert_pass "T2: does not report covered issue #101 as missing"
fi

# ─── T2b: no substring false-match (#12 does not "cover" #123) ───────────────
# Notes that link only #12 must NOT be treated as covering #123.
fake_notes="- something ([#12](https://github.com/ezigus/zBuild/issues/12))"
if release_notes_coverage_check "$MILESTONE" "" "$fake_notes" >/dev/null 2>&1; then
    assert_fail "T2b: #12 link should not satisfy coverage for #123"
else
    assert_pass "T2b: exact /issues/N) match — #12 does not cover #123"
fi

# ─── T3: doc-style gate — stub a NON-conforming checker → combined gate fails ─
# release_docs_style_check delegates to lint-doc-style.sh via ZBUILD_DOC_STYLE_LINT.
bad_lint="$TEST_TEMP_DIR/bad-lint.sh"
cat > "$bad_lint" <<'EOF'
#!/usr/bin/env bash
echo "lint-doc-style: docs/wiki/plugins/foo.md — no plain-language newcomer opening" >&2
exit 1
EOF
chmod +x "$bad_lint"
if ZBUILD_DOC_STYLE_LINT="$bad_lint" release_docs_style_check >/dev/null 2>&1; then
    assert_fail "T3: doc-style gate should fail on a non-conforming page"
else
    assert_pass "T3: doc-style gate fails when lint-doc-style reports a non-conforming page"
fi

# Combined gate fails closed even when coverage is fine, because docs don't conform.
if ZBUILD_DOC_STYLE_LINT="$bad_lint" \
    release_docs_and_coverage_gate "$MILESTONE" "" "$full_notes" >/dev/null 2>&1; then
    assert_fail "T3: combined gate should fail when doc-style fails"
else
    assert_pass "T3: combined gate fails closed on a doc-style violation"
fi

# ─── T4: doc-style gate PASSES with a conforming stub → combined gate passes ─
good_lint="$TEST_TEMP_DIR/good-lint.sh"
cat > "$good_lint" <<'EOF'
#!/usr/bin/env bash
echo "lint-doc-style: OK"
exit 0
EOF
chmod +x "$good_lint"
if ZBUILD_DOC_STYLE_LINT="$good_lint" \
    release_docs_and_coverage_gate "$MILESTONE" "" "$full_notes" >/dev/null 2>&1; then
    assert_pass "T4: combined gate passes when docs conform AND coverage is complete"
else
    assert_fail "T4: combined gate should pass on conforming docs + complete coverage"
fi

# ─── T5: the release FLOW refuses to cut when the doc-style gate fails ────────
# Run scripts/release.sh (non-dry-run, no --force) with the non-conforming lint
# stub. It must exit non-zero and NOT mutate the sandbox CHANGELOG.
sandbox_cl="$TEST_TEMP_DIR/CHANGELOG-flow.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_cl"
before="$(shasum -a 256 "$sandbox_cl" | awk '{print $1}')"
export ZBUILD_VERSION_ANCHOR="1.0"
export ZBUILD_VERSION_RELEASE_COUNT="1"
export ZBUILD_RELEASE_LAST_TAG="v1.0.0"
flow_rc=0
ZBUILD_DOC_STYLE_LINT="$bad_lint" ZBUILD_RELEASE_CHANGELOG="$sandbox_cl" \
    bash "$REPO_ROOT/scripts/release.sh" --milestone "$MILESTONE" >/dev/null 2>&1 || flow_rc=$?
if [[ "$flow_rc" -ne 0 ]]; then
    assert_pass "T5: release flow REFUSES (rc!=0) when doc-style gate fails"
else
    assert_fail "T5: release flow should refuse when doc-style gate fails"
fi
after="$(shasum -a 256 "$sandbox_cl" | awk '{print $1}')"
assert_eq "T5: refused release did not mutate the CHANGELOG" "$before" "$after"

# ─── T6: --force bypasses both gates (release proceeds despite bad lint) ─────
force_rc=0
ZBUILD_DOC_STYLE_LINT="$bad_lint" ZBUILD_RELEASE_CHANGELOG="$sandbox_cl" \
    ZBUILD_RELEASE_NO_PUSH=1 \
    bash "$REPO_ROOT/scripts/release.sh" --force --milestone "$MILESTONE" >/dev/null 2>&1 || force_rc=$?
if [[ "$force_rc" -eq 0 ]]; then
    assert_pass "T6: --force bypasses the doc/coverage gate (release proceeds)"
else
    assert_fail "T6: --force should bypass the gate (rc=$force_rc)"
fi
forced="$(shasum -a 256 "$sandbox_cl" | awk '{print $1}')"
if [[ "$before" != "$forced" ]]; then
    assert_pass "T6: --force run DID mutate the CHANGELOG (gate bypassed, release cut)"
else
    assert_fail "T6: --force run should have prepended to the CHANGELOG"
fi

# ─── T7: --dry-run runs the gate but mutates nothing ─────────────────────────
sandbox_dry="$TEST_TEMP_DIR/CHANGELOG-dry.md"
cp "$REPO_ROOT/CHANGELOG.md" "$sandbox_dry"
dry_before="$(shasum -a 256 "$sandbox_dry" | awk '{print $1}')"
# Passing (good) lint stub → dry-run succeeds and mutates nothing.
dry_rc=0
ZBUILD_DOC_STYLE_LINT="$good_lint" ZBUILD_RELEASE_CHANGELOG="$sandbox_dry" \
    bash "$REPO_ROOT/scripts/release.sh" --dry-run --milestone "$MILESTONE" >/dev/null 2>&1 || dry_rc=$?
assert_eq "T7: --dry-run with passing gate exits 0" "0" "$dry_rc"
dry_after="$(shasum -a 256 "$sandbox_dry" | awk '{print $1}')"
assert_eq "T7: --dry-run mutates nothing even though the gate ran" "$dry_before" "$dry_after"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
