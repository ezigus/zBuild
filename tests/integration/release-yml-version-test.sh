#!/usr/bin/env bash
# Tests: VERSION file is included in the release PR commit (#1483).
#
# #1490 moved the release-PR commit OUT of the workflow YAML and INTO release.sh's
# PREPARE path (branch → commit → PR → publish). The invariant is unchanged — the
# release commit MUST stage VERSION alongside CHANGELOG + docs — but it now lives
# in release.sh's _release_prepare `git add`, so the assertions point there.
#
# SPEC-10: the release-branch commit (release.sh prepare) stages VERSION
# SPEC-11: VERSION is staged before docs/wiki in that commit's git add order
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "release — VERSION included in release PR commit (#1483 / #1490)"
setup_test_env "release-yml-version"

RELEASE_SH="$REPO_ROOT/scripts/release.sh"

# ── SPEC-10: release.sh prepare stages VERSION on the release-branch commit ───
# The prepare path stages the version_file (VERSION, sandbox-overridable) and the
# changelog on one `git add`, then docs on the next. Confirm the version_file is
# staged (a dropped VERSION would leave the release commit without the bump).
_spec10_version=false
if /usr/bin/grep -qE '\$git_cmd add "\$version_file" "\$changelog"' "$RELEASE_SH" 2>/dev/null; then
    _spec10_version=true
fi
if $_spec10_version; then
    assert_pass "[SPEC-10] release.sh prepare stages VERSION (version_file) on the release commit"
else
    assert_fail "[SPEC-10] release.sh prepare stages VERSION on the release commit" \
        "Expected the prepare git add to stage \$version_file in $RELEASE_SH"
fi

# ── SPEC-11: VERSION is staged before docs/wiki (ordering invariant) ──────────
# version_file + changelog are added FIRST; docs/wiki + README added AFTER. Prove
# the version_file add line precedes the docs/wiki add line in release.sh.
_v_line="$(/usr/bin/grep -n '\$git_cmd add "\$version_file"' "$RELEASE_SH" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_d_line="$(/usr/bin/grep -n '\$git_cmd add "\$REPO_ROOT/docs/wiki"' "$RELEASE_SH" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -n "$_v_line" && -n "$_d_line" && "$_v_line" -lt "$_d_line" ]]; then
    assert_pass "[SPEC-11] VERSION is staged before docs/wiki in the release commit"
else
    assert_fail "[SPEC-11] VERSION is staged before docs/wiki in the release commit" \
        "version_file line=$_v_line docs/wiki line=$_d_line in $RELEASE_SH"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
