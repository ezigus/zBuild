#!/usr/bin/env bash
# tests/unit/persist-secret-mask-test.sh — nothing the engine saves carries a
# secret (#2588, ADR-050).
#
# M1 [change] a GitHub token (ghs_, ghp_, gho_, ghu_, ghr_, github_pat_) is a
#             credential to the shared scan (#2532 run 45102665787: a ghs_ token
#             in a test-failure summary passed the scan; push protection caught
#             it and GitHub revoked the token)
# M2 [change] the engine's own token (the job's GITHUB_TOKEN) is masked before a
#             push: in a summary it is <secret>, the rest of its words kept
# M3 [change] ...and the scan then finds nothing to refuse the push for
# M4 [guard]  a file with no secret is left byte-for-byte as it was
# M5 [guard]  a GitHub token that is not the engine's own is still refused
# M7 [change] the snapshot commit itself holds <secret>: the masking runs before
#             the files are staged, not only before the push (review of #2588)
# M6 [change] a refused push's reason keeps GitHub's words: push protection's
#             banner lines are set aside, so what was refused, and why, is kept
#             (#2532 run 45102665787 showed only the banner)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/secret-patterns.sh
source "$REPO_ROOT/scripts/lib/secret-patterns.sh"
# shellcheck source=../../core/state/artifact-persist.sh
source "$REPO_ROOT/core/state/artifact-persist.sh"

print_test_header "nothing saved carries a secret (#2588)"
setup_test_env "persist-secret-mask"

# Built from parts so this file itself holds no token-shaped string.
_t() { printf '%s_%s' "$1" "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"; }

print_test_section "M1: GitHub tokens are credentials"
for _p in ghs ghp gho ghu ghr; do
    _k="$(zbuild_scan_secret_content "got: GITHUB=$(_t "$_p") PATH0=/x" || true)"
    assert_eq "[M1] a ${_p}_ token is found" "github_token" "$_k"
done
_k="$(zbuild_scan_secret_content "token github_pat_$(printf 'A%.0s' {1..40})" || true)"
assert_eq "[M1] a github_pat_ token is found" "github_token" "$_k"

print_test_section "M2-M5: the engine's own token is masked before the push"
export GITHUB_TOKEN="$(_t ghs)"   # as on a CI runner (setup_test_env cleared it)
ART="$TEST_TEMP_DIR/artifacts"; mkdir -p "$ART"
printf '%s\n' "- RG9 failed — expected: GH=unset GITHUB=unset, got: GH=unset GITHUB=$(_t ghs) PATH0=/x" > "$ART/test-failures-summary.md"
printf 'all clean here\n' > "$ART/clean.md"; _before="$(cksum < "$ART/clean.md")"
# The one scan every push path runs (the stage-end push, the persist stage).
_rc=0; _artifact_persist_find_secret "$ART" >/dev/null || _rc=$?
_body="$(cat "$ART/test-failures-summary.md")"
if [[ "$_body" == *"$(_t ghs)"* ]]; then assert_fail "[M2] the token is gone from the file" "still there"; else assert_pass "[M2] the token is gone from the file"; fi
assert_contains "[M2] ...replaced by <secret>, the rest kept" "$_body" "got: GH=unset GITHUB=<secret> PATH0=/x"
assert_eq "[M3] the scan finds nothing to refuse the push for" "1" "$_rc"
assert_eq "[M4] a clean file is untouched" "$_before" "$(cksum < "$ART/clean.md")"
printf 'leaked: %s\n' "$(_t ghp)" > "$ART/other.md"
_out="$(_artifact_persist_find_secret "$ART" || true)"
assert_eq "[M5] another GitHub token is still refused, by its file" "other.md:github_token" "$_out"
unset GITHUB_TOKEN

print_test_section "M7: the commit that is pushed holds no token"
_R="$TEST_TEMP_DIR/m7-repo"; mkdir -p "$_R"
( cd "$_R" && git init -q -b main . && git config user.email t@e.st && git config user.name t \
  && printf 'x\n' > f && git add f && git commit -qm init ) >/dev/null 2>&1
_ST="$TEST_TEMP_DIR/m7-state"; mkdir -p "$_ST/artifacts"
export GITHUB_TOKEN="$(_t ghs)"
printf 'got: GITHUB=%s\n' "$GITHUB_TOKEN" > "$_ST/artifacts/test-failures-summary.md"
_I="$(zb_test_issue)"
( cd "$_R" && _artifact_persist_snapshot "$_ST" "$_I" ) >/dev/null 2>&1 || true
_c="$(git -C "$_R" show "zbuild/state/issue-$_I:artifacts/test-failures-summary.md" 2>/dev/null || true)"
assert_contains "[M7] the snapshot holds <secret>" "$_c" "got: GITHUB=<secret>"
if [[ "$_c" == *"$GITHUB_TOKEN"* ]]; then assert_fail "[M7] ...and never the token" "the token is in the commit"; else assert_pass "[M7] ...and never the token"; fi
unset GITHUB_TOKEN

print_test_section "M6: a refused push says why"
_e="$TEST_TEMP_DIR/push.err"
{ printf 'remote: error: GH013: Repository rule violations found for refs/heads/zbuild/state/issue-2532.\n'
  printf 'remote: \nremote: - GITHUB PUSH PROTECTION\n'
  printf 'remote:   %s\n' "$(printf '—%.0s' {1..120})"
  printf 'remote:     Resolve the following violations before pushing again\n'
  printf 'remote:     - Push cannot contain secrets\n'
  printf 'remote:       —— GitHub Personal Access Token ——————————————————\n'
  printf 'remote:         locations:\n'
  printf 'remote:           - commit: 0123abcd\n'
  printf 'remote:             path: artifacts/test-failures-summary.md:11\n'
  printf 'To https://github.com/o/r.git\n ! [remote rejected] zbuild/state/issue-2532 -> zbuild/state/issue-2532 (push declined due to repository rule violations)\n'; } > "$_e"
_r=""; _artifact_persist_push_reason_v _r "$_e"
assert_contains "[M6] the rule is named" "$_r" "GH013: Repository rule violations"
assert_contains "[M6] ...what it refused" "$_r" "Push cannot contain secrets"
assert_contains "[M6] ...what kind of secret" "$_r" "GitHub Personal Access Token"
assert_contains "[M6] ...which file" "$_r" "path: artifacts/test-failures-summary.md:11"
if [[ "$_r" == *"——————"* ]]; then assert_fail "[M6] ...without the banner's rules" "kept"; else assert_pass "[M6] ...without the banner's rules"; fi
# The engine's own token in git's stderr is masked in the reason too.
export GITHUB_TOKEN="$(_t ghs)"
printf 'remote: invalid credentials for %s\n' "$GITHUB_TOKEN" > "$_e"
_r=""; _artifact_persist_push_reason_v _r "$_e"
if [[ "$_r" == *"$GITHUB_TOKEN"* ]]; then assert_fail "[M6] ...the engine's own token is masked in it" "the token is there"; else assert_pass "[M6] ...the engine's own token is masked in it"; fi
assert_contains "[M6] ...shown as <secret>" "$_r" "invalid credentials for <secret>"
unset GITHUB_TOKEN

cleanup_test_env
print_test_results
exit $((FAIL > 0))
