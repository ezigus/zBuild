#!/usr/bin/env bash
# tests/unit/runner-engine-provenance-test.sh — record which engine graded a run (#1791).
#
#   SPEC-1 [change]: init_state persists engine_sha / engine_branch
#   SPEC-2 [change]: the resolver reads install metadata, and is not fooled by the
#                    semver VERSION file it collides with on a case-insensitive FS
#   SPEC-3 [change]: the resolver falls back to git in a source checkout
#   SPEC-4 [change]: drift is reported only for non-terminal failure reasons
#   SPEC-5 [guard] : an engine at the remote tip reports no drift (no false alarm)
#
# ADR-023 freezes the engine per run, so "which engine graded this?" is not
# recoverable after the fact — it is recorded or it is lost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "runner — engine provenance (#1791)"
setup_test_env "runner-engine-provenance"

# shellcheck source=/dev/null
source "$REPO_ROOT/core/state/resume.sh" >/dev/null 2>&1 || true
# shellcheck source=/dev/null
source "$REPO_ROOT/core/pipeline/runner.sh" >/dev/null 2>&1 || true

# Absent at the merge-base — stub to a failing value so each assertion reddens
# individually instead of `set -e` killing the file on the first call.
declare -F _runner_engine_sha >/dev/null 2>&1 || _runner_engine_sha() { return 1; }
declare -F _runner_engine_branch >/dev/null 2>&1 || _runner_engine_branch() { return 1; }
declare -F _runner_report_engine_drift >/dev/null 2>&1 || _runner_report_engine_drift() { return 1; }

# ─── SPEC-1: the run's state records the engine ──────────────────────────────
print_test_section "1. state records which engine graded the run"

ST="$TEST_TEMP_DIR/state.json"
init_state "$ST" "run-1791" 1791 "abc123def456" "main" >/dev/null 2>&1 || true

assert_eq "[SPEC-1] init_state persists engine_sha" \
    "abc123def456" "$(jq -r '.engine_sha // ""' "$ST" 2>/dev/null || true)"
assert_eq "[SPEC-1] init_state persists engine_branch" \
    "main" "$(jq -r '.engine_branch // ""' "$ST" 2>/dev/null || true)"

# Omitted arguments must not produce a null/absent field — an unknown engine is
# still a recorded fact, and a missing key would read as "nobody looked".
ST2="$TEST_TEMP_DIR/state2.json"
init_state "$ST2" "run-1791b" 1791 >/dev/null 2>&1 || true
assert_eq "[SPEC-1] a run with no engine metadata records 'unknown', not null" \
    "unknown" "$(jq -r '.engine_sha // "null"' "$ST2" 2>/dev/null || true)"

# ─── SPEC-2: install metadata wins, and the VERSION collision is handled ─────
print_test_section "2. resolver reads install metadata"

ENG="$TEST_TEMP_DIR/engine"
mkdir -p "$ENG"
cat > "$ENG/version" <<'EOF'
sha=deadbeefcafe1234
branch=release
installed_at=2026-01-01T00:00:00Z
EOF
assert_eq "[SPEC-2] sha comes from the install metadata" \
    "deadbeefcafe1234" "$(_runner_engine_sha "$ENG" 2>/dev/null || true)"
assert_eq "[SPEC-2] branch comes from the install metadata" \
    "release" "$(_runner_engine_branch "$ENG" 2>/dev/null || true)"

# On a case-INSENSITIVE filesystem `version` and `VERSION` are the same file, so
# the resolver must key on the `sha=` line rather than on the filename. Simulate
# the collision by putting semver content where the metadata is read from.
ENG_COLLIDE="$TEST_TEMP_DIR/engine-collide"
mkdir -p "$ENG_COLLIDE"
printf '1.2.0.0\n' > "$ENG_COLLIDE/version"
_collide="$(_runner_engine_sha "$ENG_COLLIDE" 2>/dev/null || true)"
assert_eq "[SPEC-2] a semver VERSION file is never mistaken for a sha" \
    "" "$(printf '%s' "$_collide" | grep -F '1.2.0.0' || true)"

# ─── SPEC-3: source checkouts fall back to git ───────────────────────────────
print_test_section "3. source checkout falls back to git"

_real_sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
if [[ -n "$_real_sha" ]]; then
    assert_eq "[SPEC-3] a git checkout with no install metadata resolves via git" \
        "$_real_sha" "$(_runner_engine_sha "$REPO_ROOT" 2>/dev/null || true)"
else
    assert_pass "[SPEC-3] a git checkout with no install metadata resolves via git (skipped: not a git tree)"
fi

# ─── SPEC-4 / SPEC-5: drift is reported for the right reasons only ───────────
print_test_section "4. drift reported only where a newer engine could matter"

_RUNNER_ENGINE_SHA="1111111111111111111111111111111111111111"
_RUNNER_ENGINE_BRANCH="main"
_ZBUILD_ROOT="$TEST_TEMP_DIR/norepo"   # ls-remote fails here → no drift claim
mkdir -p "$_ZBUILD_ROOT"

# A terminal reason must short-circuit BEFORE any git/network work.
_out="$(_runner_report_engine_drift "llm_unavailable" 2>&1 || true)"
assert_eq "[SPEC-4] a terminal failure reason reports no drift" "" "$_out"

_out2="$(_runner_report_engine_drift "" 2>&1 || true)"
assert_eq "[SPEC-4] an empty reason reports no drift" "" "$_out2"

# Non-terminal reason, but the remote is unreachable — best-effort means silent,
# never a spurious "your engine is stale" on an offline box.
_out3="$(_runner_report_engine_drift "max_iterations" 2>&1 || true)"
assert_eq "[SPEC-5] an unreachable remote does not fabricate a drift claim" "" "$_out3"

# Explicitly disabled.
_out4="$(ZBUILD_ENGINE_DRIFT_CHECK=0 _runner_report_engine_drift "blocked_on_scope" 2>&1 || true)"
assert_eq "[SPEC-5] the check can be disabled outright" "" "$_out4"

# The positive case — without it the rest of this section only proves the check
# stays quiet, which a `return 0` would also satisfy.
print_test_section "5. drift IS reported when the remote has moved on"

UP="$TEST_TEMP_DIR/upstream"; ENGCLONE="$TEST_TEMP_DIR/engineclone"
git init -q "$UP" 2>/dev/null
git -C "$UP" config user.email t@t; git -C "$UP" config user.name t
echo one > "$UP/f"; git -C "$UP" add f; git -C "$UP" commit -qm "first"
_old="$(git -C "$UP" rev-parse HEAD)"
git -C "$UP" branch -M main 2>/dev/null || true
git clone -q "$UP" "$ENGCLONE" 2>/dev/null
# Upstream advances AFTER the engine was taken — exactly the #1791 shape.
echo two > "$UP/f"; git -C "$UP" commit -qam "the fix that landed mid-run"

_RUNNER_ENGINE_SHA="$_old"
_RUNNER_ENGINE_BRANCH="main"
_ZBUILD_ROOT="$ENGCLONE"
_drift="$(_runner_report_engine_drift "blocked_on_scope" 2>&1 || true)"

assert_contains "[SPEC-4] a superseded engine is reported on a non-terminal failure" \
    "$_drift" "origin/main is now"
assert_contains "[SPEC-4] the report names the commit that landed mid-run" \
    "$_drift" "the fix that landed mid-run"

# Same tree, engine AT the tip → must stay silent.
_RUNNER_ENGINE_SHA="$(git -C "$UP" rev-parse HEAD)"
_none="$(_runner_report_engine_drift "blocked_on_scope" 2>&1 || true)"
assert_eq "[SPEC-5] an engine at the remote tip reports nothing" "" "$_none"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
