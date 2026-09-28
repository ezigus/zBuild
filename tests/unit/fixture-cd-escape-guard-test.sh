#!/usr/bin/env bash
# tests/unit/fixture-cd-escape-guard-test.sh
# A git fixture's `cd` into its temp repo must be fatal, or the fixture runs in
# the caller's checkout (#2103; ADR-024 test contract).
#
# On 2026-09-15 `tests/integration/intake-branch-ahead-count-test.sh` cloned a
# temp repo, the clone failed, and its seeding subshell — `( set -e; cd "$tmp";
# git checkout -b master; …; git push origin HEAD:master ) || return 1` — ran
# every line in the real worktree: it created and checked out `master`, committed
# `seed.txt` there, and PUSHED that branch to the real origin. Bash ignores
# `set -e` inside any compound command whose status is tested (`( … ) || …`,
# `&&`, `if (`, `! (`), and several fixture files never set -e at all.
#
# SPEC-1[change]: no test file or helper contains the hazardous shape — a bare
#                 `cd "$var"` followed by a git command where nothing stops a failed
#                 cd: inside a subshell whose status is tested (set -e is inert there,
#                 and shellcheck's SC2164 does not look inside a function's subshell),
#                 or anywhere in a file that never sets -e
# SPEC-2[guard]:  the scanner flags a synthetic offender and passes both safe forms
#                 (`cd "$x" || exit 1`; a plain subshell under file-level set -e)
# SPEC-3[change]: setup_git_temp_repo with an unreachable TEST_TEMP_DIR returns 1 and
#                 leaves the caller's checkout untouched (HEAD, branch, no seed.txt)
# SPEC-4[change]: setup_git_master_origin (extracted from the offending test) with a
#                 failing clone returns 1, leaves the caller's checkout untouched, and
#                 pushes nothing to the caller's origin
# SPEC-5[change]: run-tests.sh fails any test file that changes the checkout it runs
#                 from — HEAD, current branch, or the tracked working tree — naming
#                 what moved; a file that only reads git state passes (guard)
# SPEC-6[change]: run-tests.sh fences pushes: a push to the checkout's real origin URL
#                 from inside a test is rewritten to a dead path; a push to a test's
#                 own temp origin is untouched (guard)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "git fixtures never escape into the caller's checkout (#2103)"
setup_test_env "fixture-cd-escape-guard"

# _scan_cd_escapes <file>... → "file:line  reason" per hazardous site
_scan_cd_escapes() {
    local f
    for f in "$@"; do
        awk -v F="$f" '
          /^set -[a-z]*e/ {sete=1}
          # depth-aware: a nested ( … ) inside the fixture block must not close it early
          /^[[:space:]]*(if|!|while|until)?[[:space:]]*\([[:space:]]*(set -e)?[[:space:]]*$/ {
              if (!inblk) { inblk=1; cdline=0; git=0; open=$0; depth=0 } else depth++
              next }
          inblk && /^[[:space:]]*cd "\$[A-Za-z_0-9]+"[[:space:]]*$/ && !cdline {cdline=NR}
          inblk && cdline && (/(^|[^A-Za-z_])git (push|commit|checkout|add|init|branch|tag|rm|clone)/ || /real_git/) {git=1}
          inblk && /^[[:space:]]*\)/ {
              if (depth > 0) { depth--; next }
              tested = ($0 ~ /\)[^|]*(\|\||&&)/) || (open ~ /^[[:space:]]*(if|!|while|until)/)
              if (cdline && git && (tested || !sete))
                  printf "%s:%d  %s\n", F, cdline, (tested ? "subshell status is tested (set -e inert)" : "file never sets -e")
              inblk=0; cdline=0; git=0 }
          # top level (no subshell): a bare cd is only stopped by file-level set -e
          !inblk && !sete && /^cd "\$[A-Za-z_0-9]+"[[:space:]]*$/ {topcd=NR}
          !inblk && topcd && /(^|[^A-Za-z_])git (push|commit|checkout|add|init|branch|tag|rm|clone)/ {
              printf "%s:%d  top-level cd in a file that never sets -e\n", F, topcd; topcd=0 }
        ' "$f"
    done
}

# ── SPEC-2: the scanner itself ───────────────────────────────────────────────
_fx="$TEST_TEMP_DIR/fixtures"; mkdir -p "$_fx"
cat > "$_fx/offender-tested.sh" <<'X'
set -euo pipefail
(
    set -e
    cd "$tmp"
    git commit -q -m seed
) >/dev/null 2>&1 || return 1
X
cat > "$_fx/offender-no-set-e.sh" <<'X'
set -uo pipefail
(
    cd "$REPO"
    echo seed > seed.txt; git add seed.txt; git commit -q -m seed
) >/dev/null
X
cat > "$_fx/safe-guarded.sh" <<'X'
set -uo pipefail
(
    cd "$REPO" || exit 1
    git commit -q -m seed
) >/dev/null || return 1
X
cat > "$_fx/offender-top-level.sh" <<'X'
set -uo pipefail
cd "$REPO_A"
git log --oneline -1
git commit -q -m seed
X
cat > "$_fx/offender-nested.sh" <<'X'
set -uo pipefail
(
    cd "$REPO"
    (
        echo inner
    )
    git commit -q -m seed
) >/dev/null || return 1
X
cat > "$_fx/safe-set-e-plain.sh" <<'X'
set -euo pipefail
(
    cd "$REPO"
    git commit -q -m seed
) >/dev/null
X
assert_contains "[SPEC-2] status-tested subshell with bare cd + git is flagged" \
    "$(_scan_cd_escapes "$_fx/offender-tested.sh")" "offender-tested.sh:4"
assert_contains "[SPEC-2] bare cd + git in a file without set -e is flagged" \
    "$(_scan_cd_escapes "$_fx/offender-no-set-e.sh")" "offender-no-set-e.sh:3"
assert_contains "[SPEC-2] top-level bare cd + git in a file without set -e is flagged" \
    "$(_scan_cd_escapes "$_fx/offender-top-level.sh")" "offender-top-level.sh:2"
assert_contains "[SPEC-2] a nested subshell inside the fixture block does not hide the cd" \
    "$(_scan_cd_escapes "$_fx/offender-nested.sh")" "offender-nested.sh:3"
assert_eq "[SPEC-2] cd guarded with '|| exit 1' is not flagged" "" "$(_scan_cd_escapes "$_fx/safe-guarded.sh")"
assert_eq "[SPEC-2] plain subshell under file-level set -e is not flagged" "" "$(_scan_cd_escapes "$_fx/safe-set-e-plain.sh")"

# ── SPEC-1: the real tree ────────────────────────────────────────────────────
_files=()
while IFS= read -r f; do _files+=("$f"); done < <(
    { printf '%s\n' "$REPO_ROOT/scripts/lib/test-helpers.sh"
      find "$REPO_ROOT/tests" "$REPO_ROOT/plugins" "$REPO_ROOT/core" -name '*-test.sh' -not -path '*/legacy/*' 2>/dev/null
    } | grep -v '/fixture-cd-escape-guard-test.sh$' | sort -u)
_hits="$(_scan_cd_escapes "${_files[@]}")"
if [[ -z "$_hits" ]]; then
    assert_pass "[SPEC-1] no fixture can run its git commands in the caller's checkout (${#_files[@]} files scanned)"
else
    assert_fail "[SPEC-1] fixtures with an unguarded cd before git — add '|| exit 1' (or return 1) to the cd" \
        "$(printf '\n%s' "$_hits")"
fi

# ── a fake "real checkout" with its own origin, to prove nothing leaks into it ─
# The origin is a COPY of the caller's .git marked bare — no push, no clone.
# Both spawn a transport helper (git-receive-pack / git-upload-pack) through
# git's exec-path, and on the machine that produced #2103 that path is broken
# (Apple's shim answers with the Xcode-licence refusal). The fixture must not
# depend on the very fault it is guarding against.
_origin="$TEST_TEMP_DIR/real-origin.git"
_caller="$TEST_TEMP_DIR/real-checkout"; mkdir -p "$_caller"
( cd "$_caller" || exit 1
  git init -q -b work 2>/dev/null || { git init -q && git checkout -q -b work; }
  git config user.email c@c; git config user.name caller; git config commit.gpgsign false
  echo real > real.txt; git add real.txt; git commit -q -m real ) >/dev/null 2>&1
cp -R "$_caller/.git" "$_origin" && git -C "$_origin" config core.bare true
git -C "$_caller" remote add origin "$_origin"
_head0="$(git -C "$_caller" rev-parse HEAD)"
assert_eq "[fixture] the fake origin starts with only 'work'" "work" \
    "$(git -C "$_origin" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ' | sed 's/ $//')"

_snapshot_ok() {  # <label>: the caller checkout and its origin are untouched
    assert_eq "[$1] caller HEAD unchanged" "$_head0" "$(git -C "$_caller" rev-parse HEAD)"
    assert_eq "[$1] caller branch unchanged" "work" "$(git -C "$_caller" symbolic-ref --short HEAD)"
    assert_eq "[$1] caller has no master branch" "" "$(git -C "$_caller" branch --list master)"
    assert_file_not_exists "[$1] no seed.txt in the caller checkout" "$_caller/seed.txt"
    assert_eq "[$1] caller origin still has only 'work'" "work" "$(git -C "$_origin" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ' | sed 's/ $//')"
}

# ── SPEC-3: setup_git_temp_repo with an unreachable TEST_TEMP_DIR ────────────
_blocker="$TEST_TEMP_DIR/blocker"; : > "$_blocker"      # a FILE, so mkdir -p under it fails
_rc=0
( cd "$_caller" || exit 99
  TEST_TEMP_DIR="$_blocker/nope" setup_git_temp_repo r1 >/dev/null 2>&1 ) || _rc=$?
assert_eq "[SPEC-3] setup_git_temp_repo returns 1 when its repo dir cannot be made" "1" "$_rc"
_snapshot_ok "SPEC-3"

# ── SPEC-4: setup_git_master_origin with a failing clone ─────────────────────
_rc=0
if declare -F setup_git_master_origin >/dev/null; then
    _shim="$TEST_TEMP_DIR/shim"; mkdir -p "$_shim"
    # git that refuses to clone but is otherwise real — the exact failure of 2026-09-15.
    _real_git="$(command -v git)"
    printf '#!/usr/bin/env bash\n[[ "$1" == clone ]] && exit 128\nexec "%s" "$@"\n' "$_real_git" > "$_shim/git"
    chmod +x "$_shim/git"
    ( cd "$_caller" || exit 99
      PATH="$_shim:$PATH" setup_git_master_origin m1 >/dev/null 2>&1 ) || _rc=$?
    assert_eq "[SPEC-4] setup_git_master_origin returns 1 when the seed clone fails" "1" "$_rc"
    _snapshot_ok "SPEC-4"
else
    assert_fail "[SPEC-4] setup_git_master_origin must exist in test-helpers.sh (extracted from intake-branch-ahead-count-test)" "function not defined"
fi

# ── SPEC-5 / SPEC-6: the runner's tripwire and push fence ────────────────────
# A throwaway checkout with its own scripts/ copy, so the runner under test has
# THAT repo as REPO_ROOT and any damage lands there, not here.
_R="$TEST_TEMP_DIR/runner-checkout"; mkdir -p "$_R/tests/unit"
cp -R "$REPO_ROOT/scripts" "$_R/scripts"
( cd "$_R" || exit 1
  git init -q -b work 2>/dev/null || { git init -q && git checkout -q -b work; }
  git config user.email c@c; git config user.name caller; git config commit.gpgsign false
  git remote add origin /tmp/zbuild-real-origin-stand-in.git
  echo real > real.txt; git add real.txt scripts; git commit -q -m real ) >/dev/null 2>&1
_r_head0="$(git -C "$_R" rev-parse HEAD)"
cat > "$_R/tests/unit/escaper-test.sh" <<'X'
#!/usr/bin/env bash
# Simulates a fixture that escaped: acts on the checkout it was launched from.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1
git config user.email e@e; git config user.name escaper; git config commit.gpgsign false
git checkout -q -b master
echo seed > seed.txt; git add seed.txt; git commit -q -m seed
GIT_TRACE=1 git push -q origin HEAD:refs/heads/master 2>"$root/push-trace.txt" || true
exit 0
X
_r_out="$( cd "$_R" && ZBUILD_TESTS_DIR="$_R/tests" bash "$_R/scripts/run-tests.sh" --tier unit 2>&1 )"
assert_contains "[SPEC-5] a test that commits into the checkout is reported FAIL" "$_r_out" "unit: FAIL $_R/tests/unit/escaper-test.sh"
assert_contains "[SPEC-5] the failure names the escape" "$_r_out" "mutated the checkout"
assert_contains "[SPEC-5] the failure names what moved (branch)" "$_r_out" "work -> master"
_trace="$(grep 'git-receive-pack' "$_R/push-trace.txt" 2>/dev/null | head -1)"
assert_contains "[SPEC-6] a push to the checkout's origin is rewritten to a dead path" "$_trace" "zbuild-tests-must-not-push"
if grep -q 'zbuild-real-origin-stand-in' <<< "$_trace"; then
    assert_fail "[SPEC-6] the real origin URL must not be the push target" "trace=[$_trace]"
else
    assert_pass "[SPEC-6] the real origin URL is not the push target"
fi
# The --files targeted-rerun path exits the runner before the tier machinery;
# the fence must be up there too, or a rerun of the offending file is unfenced.
: > "$_R/push-trace.txt"
( cd "$_R" && git checkout -q work 2>/dev/null; git -C "$_R" branch -q -D master 2>/dev/null; rm -f "$_R/seed.txt" ) || true
( cd "$_R" && ZBUILD_TESTS_DIR="$_R/tests" bash "$_R/scripts/run-tests.sh" --files "$_R/tests/unit/escaper-test.sh" >/dev/null 2>&1 ) || true
assert_contains "[SPEC-6] the fence also covers the --files targeted-rerun path" \
    "$(grep 'git-receive-pack' "$_R/push-trace.txt" 2>/dev/null | head -1)" "zbuild-tests-must-not-push"
# GUARD: a test's own temp origin (any other URL) is left alone by the fence.
_own="$TEST_TEMP_DIR/own-origin.git"; mkdir -p "$_own"
cat > "$_R/tests/unit/own-origin-test.sh" <<X
#!/usr/bin/env bash
root="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
git -C "\$root" remote add own "$_own" 2>/dev/null
GIT_TRACE=1 git -C "\$root" push -q own HEAD:refs/heads/x 2>"\$root/own-trace.txt" || true
git -C "\$root" remote remove own
exit 0
X
# Second, clean run: the escaper is gone and the checkout restored; a file that
# only READS git state and one that pushes to its own temp origin must both pass.
# (Run separately from the escaper on purpose — in the parallel pool an escape
# blames every file whose window overlapped it, which the runner's message says.)
cat > "$_R/tests/unit/reader-test.sh" <<'X'
#!/usr/bin/env bash
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
git -C "$root" rev-parse HEAD >/dev/null; git -C "$root" status --porcelain >/dev/null
exit 0
X
rm -f "$_R/tests/unit/escaper-test.sh"
( cd "$_R" && git checkout -q work 2>/dev/null; git -C "$_R" branch -q -D master 2>/dev/null; rm -f "$_R/seed.txt" ) || true
_r_out2="$( cd "$_R" && ZBUILD_TESTS_DIR="$_R/tests" bash "$_R/scripts/run-tests.sh" --tier unit 2>&1 )"
assert_contains "[SPEC-5] a clean run with a read-only file and an own-origin push passes" "$_r_out2" "unit: 2/2 passed"
assert_contains "[SPEC-6] GUARD: a push to a test's own temp origin is not rewritten" \
    "$(grep 'git-receive-pack' "$_R/own-trace.txt" 2>/dev/null | head -1)" "$_own"

# ── SPEC-7 (#2126): the tripwire reads the checkout, it does not write it ────
# `git diff HEAD` refreshes a stat-stale index, which takes .git/index.lock in
# the REAL checkout before and after every test file. Under the parallel pool
# that lock is a write-boundary violation for whichever integration test is
# sweeping at that moment (runs 35170867620, 35173187510).
( cd "$_R" || exit 1; git checkout -q work 2>/dev/null; git branch -q -D master 2>/dev/null; rm -f seed.txt ) >/dev/null 2>&1
# Only the quiet file: reader-test.sh above runs `git status`, which refreshes
# the index itself — that is the fixture writing, not the runner.
rm -f "$_R/tests/unit/"*-test.sh
cat > "$_R/tests/unit/quiet-test.sh" <<'X'
#!/usr/bin/env bash
exit 0
X
# Stale stat: same content, newer mtime — exactly what makes git refresh the index.
sleep 1; touch "$_R/real.txt"
_idx0="$(cksum < "$_R/.git/index")"
_r7_out="$( cd "$_R" && ZBUILD_TESTS_DIR="$_R/tests" bash "$_R/scripts/run-tests.sh" --tier unit 2>&1 )"
assert_contains "[SPEC-7] the tier passes (nothing mutated the checkout)" "$_r7_out" 'unit: 1/1 passed'
if grep -q 'mutated the checkout' <<< "$_r7_out"; then
    assert_fail "[SPEC-7] no file tripped the tripwire" "$_r7_out"
else
    assert_pass "[SPEC-7] no file tripped the tripwire"
fi
assert_eq "[SPEC-7] the tripwire leaves .git/index byte-identical" "$_idx0" "$(cksum < "$_R/.git/index")"
assert_file_not_exists "[SPEC-7] no index.lock is left behind" "$_R/.git/index.lock"


cleanup_test_env
print_test_results
exit $((FAIL > 0))
