#!/usr/bin/env bash
# tests/integration/release-repo-agnostic-test.sh — #1487.
#
# The release path must target the repo being released (ZBUILD_REPO_ROOT / CWD /
# git-toplevel), NOT the install dir where the scripts live. Proven by pointing
# ZBUILD_REPO_ROOT at a FIXTURE repo distinct from $REPO_ROOT (the source tree
# these scripts live in) and asserting the tooling reads the FIXTURE.
#
#   SPEC-1: lint-doc-style.sh honors ZBUILD_REPO_ROOT — a NON-conforming page in
#           the fixture makes the gate fail and names the FIXTURE page (so it read
#           the fixture, not the source, whose pages conform)
#   SPEC-2: a CONFORMING fixture passes the gate via ZBUILD_REPO_ROOT
#   SPEC-3: release.sh resolves REPO_ROOT to ZBUILD_REPO_ROOT (not the script dir)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Capture the source tree's ACTUAL VERSION up front, not a hardcoded literal.
# On a release-prep branch (e.g. release/<version>, created by `zbuild release`
# or `--ship`), VERSION legitimately differs from "1.0.0" — the whole point of
# that branch is to carry the bump. SPEC-3 below proves the FIXTURE run doesn't
# touch the source tree, so it must compare against whatever VERSION already
# was, not assume the pre-release value.
_SOURCE_VERSION_BEFORE="$(cat "$REPO_ROOT/VERSION")"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release path is repo-agnostic — targets ZBUILD_REPO_ROOT, not the install dir (#1487)"
setup_test_env "release-repo-agnostic"

# ── Fixture "target repo" distinct from the source tree the scripts live in ───
FIX="$TEST_TEMP_DIR/target"
mkdir -p "$FIX/docs/wiki"
printf '# Fixture\n\nThis fixture repo is a plain-language newcomer opening sentence.\n' > "$FIX/README.md"

# ── SPEC-1: gate reads the FIXTURE — a non-conforming fixture page fails ───────
print_test_section "SPEC-1: lint-doc-style honors ZBUILD_REPO_ROOT (targets fixture)"
printf '# Home\n\n**Bold label** and nothing that reads as a sentence\n' > "$FIX/docs/wiki/Home.md"
set +e
out1="$(ZBUILD_REPO_ROOT="$FIX" bash "$REPO_ROOT/scripts/lib/lint-doc-style.sh" 2>&1)"; rc1=$?
set -e
assert_eq "[SPEC-1] gate fails on the fixture's non-conforming page" "1" "$rc1"
assert_contains "[SPEC-1] output names the FIXTURE page (read fixture, not source)" "$out1" "Home.md"

# ── SPEC-2: a conforming fixture passes via ZBUILD_REPO_ROOT ───────────────────
print_test_section "SPEC-2: conforming fixture passes via ZBUILD_REPO_ROOT"
printf '# Home\n\nThis page opens with a clear newcomer sentence that reads as prose.\n' > "$FIX/docs/wiki/Home.md"
set +e
ZBUILD_REPO_ROOT="$FIX" bash "$REPO_ROOT/scripts/lib/lint-doc-style.sh" >/dev/null 2>&1; rc2=$?
set -e
assert_eq "[SPEC-2] conforming fixture passes the doc-style gate" "0" "$rc2"

# ── SPEC-3: release.sh resolves the target repo to ZBUILD_REPO_ROOT ────────────
# Run release.sh with the gate bypassed (--force) + publish skipped (NO_GITHUB) so
# the only observable is where it stamps VERSION. Point ZBUILD_RELEASE_VERSION_FILE
# INTO the fixture and assert release.sh, run from a NEUTRAL cwd with
# ZBUILD_REPO_ROOT=fixture, writes there — i.e. it honored the target, not $PWD.
print_test_section "SPEC-3: release.sh targets ZBUILD_REPO_ROOT"
printf '1.0.0\n' > "$FIX/VERSION"
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n- initial\n' > "$FIX/CHANGELOG.md"
# Make the fixture a real git repo (tag v1.0.0) so the tarball + version backend work.
( cd "$FIX"
  git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init && git tag v1.0.0 ) >/dev/null 2>&1
_neutral="$TEST_TEMP_DIR/neutral"; mkdir -p "$_neutral"
set +e
( cd "$_neutral"
  ZBUILD_REPO_ROOT="$FIX" \
  ZBUILD_RELEASE_LAST_TAG="v1.0.0" \
  ZBUILD_RELEASE_SINCE="2026-01-01T00:00:00Z" \
  ZBUILD_VERSION_ANCHOR="1.0" ZBUILD_VERSION_ISSUES_SINCE="0" \
  ZBUILD_RELEASE_VERSION_FILE="$FIX/VERSION" \
  ZBUILD_RELEASE_CHANGELOG="$FIX/CHANGELOG.md" \
  ZBUILD_RELEASE_OUTDIR="$TEST_TEMP_DIR/out" \
  NO_GITHUB=true \
  bash "$REPO_ROOT/scripts/release.sh" --minor --force >/dev/null 2>&1 )
_rc3=$?
set -e
_stamped="$(cat "$FIX/VERSION" 2>/dev/null || echo MISSING)"
assert_eq "[SPEC-3] release.sh exits 0 releasing the fixture repo" "0" "$_rc3"
assert_eq "[SPEC-3] VERSION stamped in the FIXTURE to the --minor version (1.1.0.0)" "1.1.0.0" "$_stamped"
# The tarball was built from the fixture's own git-tracked files (repo-agnostic).
assert_file_exists "[SPEC-3] tarball built for the fixture repo" "$TEST_TEMP_DIR/out/zbuild-v1.1.0.0.tar.gz"
# And the source tree's own VERSION was NOT touched.
assert_eq "[SPEC-3] the source tree's VERSION was not modified" "$_SOURCE_VERSION_BEFORE" "$(cat "$REPO_ROOT/VERSION")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
