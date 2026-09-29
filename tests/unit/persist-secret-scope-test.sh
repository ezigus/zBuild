#!/usr/bin/env bash
# tests/unit/persist-secret-scope-test.sh — persist's push gate refuses only
# credential-shaped text the RUN introduced, as the secret-scan gate does.
#
# The two checks shared patterns (secret-patterns.sh) but not scope: the gate
# scans added diff lines, persist scanned whole artifact files. #1835's run
# (36534233685) passed the gate, then persist refused the push over
# `_RESUME_TOKEN="PRIOR_EXPLORATION_SENTINEL_42"` in an authored-testfiles copy —
# a line on main since #1114. The state snapshot never reached origin.
#
#   1 [change] a matching line already present at the merge-base is not refused
#   2 [guard]  a matching line the run ADDED is still refused
#   3 [change] a line carrying the gate's allow pragma is not refused
#   4 [guard]  with no merge-base to compare against, refuse (fail closed)
#   5 [guard]  one old line does not excuse a new one in the same file
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/secret-patterns.sh
source "$REPO_ROOT/scripts/lib/secret-patterns.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "persist refuses only secrets the run introduced (#1835 run)"
setup_test_env "persist-secret-scope"

# Built from fragments so this file never carries the shape it tests.
_OLD_LINE='_RESUME_''TOKEN="PRIOR_EXPLORATION_SENTINEL_42"'
_NEW_LINE='api_''key = "Zq8vN3kLx7PwR2mT"'

# A real repo whose trunk (origin/main) already carries _OLD_LINE, and a run
# branch on top of it — the merge-base is the trunk commit.
REPO="$TEST_TEMP_DIR/repo"
(
    git init -q --bare "$TEST_TEMP_DIR/remote.git"
    mkdir -p "$REPO/tests" && cd "$REPO" || exit 1
    git init -q -b main .
    git config user.email t@e.st; git config user.name t
    git remote add origin "$TEST_TEMP_DIR/remote.git"
    printf '#!/usr/bin/env bash\n%s\n' "$_OLD_LINE" > tests/plan-test.sh
    git add . && git commit -q -m base && git push -q -u origin main
    git checkout -q -b zbuild/issue-1
) >/dev/null 2>&1

ART="$TEST_TEMP_DIR/artifacts"
_reset_art() { rm -rf "$ART"; mkdir -p "$ART/authored-testfiles/tests"; }

# ── SPEC-1 [change] ───────────────────────────────────────────────────────────
_reset_art
printf '#!/usr/bin/env bash\n%s\necho more\n' "$_OLD_LINE" > "$ART/authored-testfiles/tests/plan-test.sh"
_f="$(_artifact_persist_find_secret "$ART" "$REPO")"; _rc=$?
assert_eq "[SPEC-1] a matching line already at the merge-base is not refused" "1" "$_rc"
assert_eq "[SPEC-1] and reports no finding" "" "$_f"

# ── SPEC-2 [guard] ────────────────────────────────────────────────────────────
_reset_art
printf '%s\n' "$_NEW_LINE" > "$ART/build-prompt.txt"
_f="$(_artifact_persist_find_secret "$ART" "$REPO")"; _rc=$?
assert_eq "[SPEC-2] a matching line the run added is refused" "0" "$_rc"
assert_contains "[SPEC-2] the finding names the file" "$_f" "build-prompt.txt"

# ── SPEC-3 [change] ───────────────────────────────────────────────────────────
_reset_art
printf '%s  # secret-scan:allow\n' "$_NEW_LINE" > "$ART/fixture.sh"
_f="$(_artifact_persist_find_secret "$ART" "$REPO")"; _rc=$?
assert_eq "[SPEC-3] a line carrying the allow pragma is not refused" "1" "$_rc"

# ── SPEC-4 [guard] ────────────────────────────────────────────────────────────
_reset_art
printf '%s\n' "$_OLD_LINE" > "$ART/authored-testfiles/tests/plan-test.sh"
NOGIT="$TEST_TEMP_DIR/not-a-repo"; mkdir -p "$NOGIT"
_f="$(_artifact_persist_find_secret "$ART" "$NOGIT")"; _rc=$?
assert_eq "[SPEC-4] with no merge-base, an old-looking line is still refused" "0" "$_rc"

# ── SPEC-5 [guard] ────────────────────────────────────────────────────────────
_reset_art
printf '%s\n%s\n' "$_OLD_LINE" "$_NEW_LINE" > "$ART/authored-testfiles/tests/plan-test.sh"
_f="$(_artifact_persist_find_secret "$ART" "$REPO")"; _rc=$?
assert_eq "[SPEC-5] an old line does not excuse a new one in the same file" "0" "$_rc"

print_test_results
