#!/usr/bin/env bash
# Tests: scripts/lib/identity.sh — the one derivation of repo id, repo slug,
# goal hash and scope key (#1930, ADR-059 §6).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/identity.sh
source "$REPO_ROOT/scripts/lib/identity.sh"

print_test_header "identity lib (#1930)"

setup_test_env "zb-identity"

# A throwaway repo whose origin we can rewrite per case. Every slug/id case
# runs against a REAL git config rather than a stubbed reader, because the
# thing under test is how git's own output is parsed.
_ID_REPO="$TEST_TEMP_DIR/repo"
mkdir -p "$_ID_REPO"
git -C "$_ID_REPO" init -q
git -C "$_ID_REPO" config user.email "t@example.com"
git -C "$_ID_REPO" config user.name "t"

_set_origin() {
    git -C "$_ID_REPO" remote remove origin 2>/dev/null || true
    [[ -n "${1:-}" ]] && git -C "$_ID_REPO" remote add origin "$1"
    return 0
}

# ─── [SPEC-1][change] the module is sourceable with NOTHING attached ─────────
# This is the whole reason the module exists. Before it, reusing a sha256 meant
# sourcing scripts/lib/plan-context.sh, which sources llm-agent.sh. If this
# assertion ever fails, the extraction has been undone.
print_test_section "[SPEC-1][change] identity.sh pulls in no plan stage and no LLM machinery"

_leaked="$(bash -c '
    source "'"$REPO_ROOT"'/scripts/lib/identity.sh"
    declare -F | awk "{print \$3}" | grep -c -E "^(_llm_|llm_|plan_context_|_plan_)" || true
')"
assert_eq "[SPEC-1] no llm-agent / plan-context functions come along" "0" "$_leaked"

# The named gate from #1930: cleanup.sh and worktree.sh are the two consumers
# that could not reach this code before. Sourcing each ALONGSIDE identity.sh
# must work, and must still not drag the plan stage in.
for _consumer in cleanup worktree; do
    _rc=0
    _out="$(bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/scripts/lib/helpers.sh"
        source "'"$REPO_ROOT"'/scripts/lib/identity.sh"
        source "'"$REPO_ROOT"'/scripts/lib/'"$_consumer"'.sh"
        declare -F zbuild_repo_id >/dev/null || exit 3
        declare -F plan_context_write >/dev/null && exit 4
        echo ok
    ' 2>&1)" || _rc=$?
    assert_eq "[SPEC-1] ${_consumer}.sh can source identity.sh (rc)" "0" "$_rc"
    assert_contains "[SPEC-1] ${_consumer}.sh + identity.sh: no plan stage" "$_out" "ok"
done

# ─── [SPEC-2][guard] repo_id and goal_hash are byte-identical to the originals ─
# This change MOVED two functions. If either output drifts, every existing
# plan-context cache leaf silently stops resolving — a resume miss that looks
# exactly like a cold start. The formulas are restated here on purpose: the
# guard is worthless if it calls the function it is guarding.
print_test_section "[SPEC-2][guard] moved formulas are unchanged"

_set_origin "https://github.com/ezigus/zBuild.git"
_expect_id="$(cd "$_ID_REPO" && printf '%s' "https://github.com/ezigus/zbuild" | shasum -a 256 | cut -d' ' -f1)"
_actual_id="$(cd "$_ID_REPO" && zbuild_repo_id)"
assert_eq "[SPEC-2] repo_id: credentials/.git/case normalisation unchanged" "$_expect_id" "$_actual_id"

_expect_gh="$(printf '%s' "onetwothree" | shasum -a 256 | cut -d' ' -f1)"
assert_eq "[SPEC-2] goal_hash: whitespace-insensitive, formula unchanged" \
    "$_expect_gh" "$(zbuild_goal_hash "  one two
    three  ")"

# Credentials must never reach the hash — the same URL with and without them
# has to key the same cache entry.
_set_origin "https://user:tok@github.com/ezigus/zBuild.git"
assert_eq "[SPEC-2] repo_id: embedded credentials are stripped" \
    "$_expect_id" "$(cd "$_ID_REPO" && zbuild_repo_id)"

# ─── [SPEC-3][change] one slug parser — the divergence is closed ─────────────
# release-tarball.sh accepted any URL containing github.com; design/plugin.sh
# matched two literal prefixes and returned empty otherwise. So a repo cloned
# over ssh:// got a release tarball and NO design blob URL, silently. Every
# form below must now resolve identically for both callers.
print_test_section "[SPEC-3][change] every GitHub remote form resolves to one slug"

for _url in \
    "git@github.com:ezigus/zBuild.git" \
    "https://github.com/ezigus/zBuild.git" \
    "https://github.com/ezigus/zBuild" \
    "ssh://git@github.com/ezigus/zBuild.git" \
    "https://user:tok@github.com/ezigus/zBuild.git" \
    "https://GitHub.com/ezigus/zBuild.git" \
; do
    _set_origin "$_url"
    assert_eq "[SPEC-3] slug from '$_url'" "ezigus/zBuild" \
        "$(cd "$_ID_REPO" && zbuild_repo_slug || true)"
done

# The form that used to diverge, stated as its own case so a regression names
# itself rather than hiding in the loop above.
_set_origin "ssh://git@github.com/ezigus/zBuild.git"
assert_eq "[SPEC-3] ssh:// — empty under the old design/plugin.sh parser" \
    "ezigus/zBuild" "$(cd "$_ID_REPO" && zbuild_repo_slug || true)"

# ─── [SPEC-4][guard] the slug is a path segment, so it is a traversal guard ──
# ADR-059 §5: a remote URL becomes a directory name here. Anything that is not
# exactly owner/repo must be REFUSED, not sanitised into something plausible —
# every caller already has a degraded path for "no slug".
print_test_section "[SPEC-4][guard] non-GitHub and unsafe remotes are refused"

# NOTE on the loop shape: this loop captures rc (`|| _rc=$?`) because refusal is
# what it asserts. SPEC-3 above uses `|| true` because it asserts a VALUE. Do not
# add a should-accept case here — assert_exit_code "1" would then pass on a
# false-positive refusal from a path that should have succeeded.
#
# The first four cases are HOST CONFUSION, and they are the reason this function
# parses the host instead of pattern-stripping to it. `${url#*github.com[:/]}`
# strips the shortest matching prefix and `*` matches `git@not`, so
# `git@notgithub.com:evil/target` used to yield `evil/target` — which
# `_release_repo` hands to `gh release download --repo`.
for _bad in \
    "git@notgithub.com:evil/target" \
    "https://evilgithub.com/evil/target" \
    "https://github.com.evil.io/evil/target" \
    "https://user:tok@notgithub.com/evil/target" \
    "https://gitlab.com/ezigus/zBuild.git" \
    "https://github.com/ezigus/zBuild/extra" \
    "git@github.com:../../etc/passwd" \
    "git@github.com:ezigus" \
    "/local/path/only" \
; do
    _set_origin "$_bad"
    _rc=0
    _slug="$(cd "$_ID_REPO" && zbuild_repo_slug)" || _rc=$?
    assert_exit_code "[SPEC-4] '$_bad' is refused" "1" "$_rc"
    assert_eq "[SPEC-4] '$_bad' echoes nothing" "" "$_slug"
done

# No remote at all: refused, and repo_id still answers (toplevel fallback).
_set_origin ""
_rc=0
_slug="$(cd "$_ID_REPO" && zbuild_repo_slug)" || _rc=$?
assert_exit_code "[SPEC-4] no origin → slug refused" "1" "$_rc"
assert_eq "[SPEC-4] no origin → slug echoes nothing" "" "$_slug"
# repo_id must STILL answer — a local-only clone needs a home (toplevel fallback).
assert_contains_regex "[SPEC-4] no origin → repo_id falls back to the toplevel path" \
    "$(cd "$_ID_REPO" && zbuild_repo_id)" "^[0-9a-f]{64}$"

# ─── [SPEC-5][change] scope_key is a function, not an inline expression ──────
print_test_section "[SPEC-5][change] scope_key: issue when present, else fallback"

assert_eq "[SPEC-5] issue present wins"      "1930" "$(zbuild_scope_key "1930" "manifesthash")"
assert_eq "[SPEC-5] empty issue → fallback"  "manifesthash" "$(zbuild_scope_key "" "manifesthash")"
assert_eq "[SPEC-5] unset issue → fallback"  "manifesthash" "$(zbuild_scope_key "${_UNSET_ISSUE:-}" "manifesthash")"

# issue=0 is the --goal sentinel and is NOT empty, so it passes through. Pinned
# here because ADR-059 §5 retires it and this assertion has to change with it.
assert_eq "[SPEC-5] issue=0 passes through (the --goal sentinel, ADR-059 §5)" \
    "0" "$(zbuild_scope_key "0" "manifesthash")"

# Both empty is a caller bug. Echoing "" would collapse <repo_id>/<key>/<hash>
# into <repo_id>/<hash> — two issues sharing a goal_hash would then overwrite
# each other's cache entry, silently resuming the wrong context.
_sk_rc=0
_sk_out="$(zbuild_scope_key "" "")" || _sk_rc=$?
assert_exit_code "[SPEC-5][guard] both empty → refused" "1" "$_sk_rc"
assert_eq "[SPEC-5][guard] both empty → echoes nothing" "" "$_sk_out"

print_test_results
