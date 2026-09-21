#!/usr/bin/env bash
# tests/unit/ci-transcript-collection-test.sh
# CI collects Claude session JSONL transcripts on EVERY outcome, encrypted (#1728 follow-up).
#
# #1728 shipped inert: its collect step was gated on `failure() &&
# github.event.repository.private`, and this repository is public, so the step
# was skipped on every run it was written to diagnose. A 6-hour GitHub kill is
# `cancelled`, not `failure()`, so even a private repo would have lost the runs
# that need it most. The privacy gate stood in for redaction; the substitute is
# encryption with a repo secret, so the bundle can ride in a public artifact.
#
# SPEC ids are the design's ids — the acceptance gate binds per-SPEC TESTFILEs by
# id, so a renumbering here silently unbinds a SPEC from its only assertion.
#
# SPEC-1[change]: the collect step's if: is `always()` — failure, cancel, and success alike
# SPEC-2[change]: with ZBUILD_TRANSCRIPT_KEY set, recent $HOME/.claude/projects/*.jsonl land in
#                 $ZBUILD_STATE_DIR/claude-transcripts.tar.gz.enc (paths mirrored, symlinks and
#                 stale files excluded) and NO plaintext copy remains in the state dir
# SPEC-3[change]: with the key unset on a public repo the block copies NOTHING, says so, exits 0
# SPEC-4[change]: the collect step precedes "Upload pipeline artifacts" (or it lands in no artifact)
# SPEC-6[change]: the job log lists every transcript found (name + size) so a run with zero
#                 transcripts is distinguishable from a collect step that never looked
# SPEC-7[change]: docs/wiki/Troubleshooting.md names the .enc bundle, the secret, and the decrypt cmd
# SPEC-8[guard]:  with the key unset on a PRIVATE repo the plaintext copy still works (old path)
# SPEC-9[change]: a project dir named like Claude Code names them (`-home-runner-…`, a leading
#   dash) is collected — #1841 found 36 transcripts and copied 0 (dirname read the name as an option)
#
# SPEC-5 (the upload step keeps if: always() + path: ZBUILD_STATE_DIR) stays in
# tests/unit/ci-state-isolation-test.sh, which already asserts it.
#
# The run block is executed with GHA's own flags (`bash -eo pipefail`), not a
# bare `bash -c`: a bare `mkdir -p` failure would merely be counted here but
# aborts the real step, so the laxer shell would hide a live failure mode.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CI transcript collection — every outcome, encrypted (#1728)"
setup_test_env "ci-transcript-collection"

WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"

_STEP_HEADING='Collect claude session transcripts'
_KEY='test-only-transcript-key-not-a-secret'

# ── Extract the step's if: clause (SPEC-1) ──────────────────────────────────
_COLLECT_IF="$(awk -v h="$_STEP_HEADING" '
    index($0, "      - name: " h) == 1 { instep = 1; next }
    instep && /^      - name: /        { exit }
    instep && /^        if: /          { sub(/^        if: /, ""); print; exit }
' "$WF")"

if [[ "$_COLLECT_IF" == "always()" ]]; then
    assert_pass "[SPEC-1] collect step runs on every outcome (if: always())"
else
    assert_fail "[SPEC-1] collect step if: must be 'always()' — a 6h kill is cancelled, not failure()" \
        "if: [$_COLLECT_IF]"
fi

# ── SPEC-4: the step must precede the upload, or it collects into nothing ────
_COLLECT_LINE="$(grep -n "      - name: $_STEP_HEADING" "$WF" | head -1 | cut -d: -f1)"
_UPLOAD_LINE="$(grep -n '      - name: Upload pipeline artifacts' "$WF" | head -1 | cut -d: -f1)"
if [[ -n "$_COLLECT_LINE" && -n "$_UPLOAD_LINE" && "$_COLLECT_LINE" -lt "$_UPLOAD_LINE" ]]; then
    assert_pass "[SPEC-4] collect step precedes 'Upload pipeline artifacts'"
else
    assert_fail "[SPEC-4] collect step must appear before 'Upload pipeline artifacts'" \
        "collect=[$_COLLECT_LINE] upload=[$_UPLOAD_LINE]"
fi

# ── SPEC-7: the operator doc names the bundle, the secret, and how to open it ─
_DOC="$REPO_ROOT/docs/wiki/Troubleshooting.md"
for needle in 'claude-transcripts.tar.gz.enc' 'ZBUILD_TRANSCRIPT_KEY' 'openssl enc -d'; do
    if grep -qF "$needle" "$_DOC"; then
        assert_pass "[SPEC-7] Troubleshooting.md mentions '$needle'"
    else
        assert_fail "[SPEC-7] Troubleshooting.md must mention '$needle'" "no match in $_DOC"
    fi
done

# ── Extract the run block; every remaining SPEC executes it for real ─────────
_BLOCK="$(awk -v h="$_STEP_HEADING" '
    index($0, "      - name: " h) == 1 { instep = 1; next }
    instep && /^      - name: /        { exit }
    instep && /^        run: \|/       { inrun = 1; next }
    inrun  && /^        [a-z]/         { exit }
    inrun                              { sub(/^          /, ""); print }
' "$WF")"

if [[ -z "$_BLOCK" ]]; then
    assert_fail "[SPEC-2] collect step's run block must be extractable" \
        "no run: block found under step '$_STEP_HEADING' in $WF"
    cleanup_test_env; print_test_results; exit 1
fi

# _seed_home <home>: a project dir with one recent, one stale, one symlinked jsonl
_seed_home() {
    local home="$1" proj="$1/.claude/projects/myrepo"
    mkdir -p "$proj"
    printf '{"type":"assistant","message":"hello"}\n' > "$proj/recent.jsonl"
    printf '{"type":"assistant","message":"old"}\n'   > "$proj/stale.jsonl"
    # GNU `date -d` first, BSD `date -v` second (same order as the stat -c/-f
    # precedent). `touch -d '8 hours ago'` is GNU-only and fails silently on BSD.
    local ts
    ts="$(date -d '8 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-8H +%Y%m%d%H%M 2>/dev/null)"
    if [[ -z "$ts" ]] || ! touch -t "$ts" "$proj/stale.jsonl"; then
        assert_fail "[SPEC-2] test fixture must be able to backdate a file" \
            "neither 'date -d' nor 'date -v' produced a usable timestamp"
    fi
    printf 'SECRET\n' > "$home/outside-secret.jsonl"
    ln -sf "$home/outside-secret.jsonl" "$proj/linked.jsonl"
    mkdir -p "$home/.claude/projects/otherrepo"
    printf '{"type":"assistant","message":"other"}\n' > "$home/.claude/projects/otherrepo/recent.jsonl"
}

# _run_block <home> <state> <private:true|false> <key-or-empty>
# Sets _OUT (stdout+stderr) and _RC. Deliberately NOT `_OUT="$(...)"`: a command
# substitution is a subshell, and an _RC assigned inside it never reaches this
# scope — every "exits 0" assertion would then test the initial value forever.
_RC=0; _OUT=""
_run_block() {
    _RC=0
    (
        export HOME="$1" ZBUILD_STATE_DIR="$2" REPO_PRIVATE="$3" ZBUILD_TRANSCRIPT_KEY="$4"
        export RUNNER_TEMP="$TEST_TEMP_DIR"
        bash -eo pipefail -c "$_BLOCK"
    ) > "$TEST_TEMP_DIR/run-block.out" 2>&1 || _RC=$?
    _OUT="$(cat "$TEST_TEMP_DIR/run-block.out")"
}

# ── SPEC-2: key set → encrypted bundle, no plaintext, decrypts to the right set
_H2="$TEST_TEMP_DIR/home-enc"; _S2="$TEST_TEMP_DIR/state-enc"
mkdir -p "$_H2" "$_S2"; _seed_home "$_H2"
_run_block "$_H2" "$_S2" false "$_KEY"
assert_eq "[SPEC-2] run block exits 0 with the key set" "0" "$_RC"
_ENC="$_S2/claude-transcripts.tar.gz.enc"
assert_file_exists "[SPEC-2] encrypted bundle claude-transcripts.tar.gz.enc is written" "$_ENC"
if [[ ! -e "$_S2/claude-transcripts" ]]; then
    assert_pass "[SPEC-2] no plaintext claude-transcripts/ remains in the state dir"
else
    assert_fail "[SPEC-2] plaintext claude-transcripts/ must not remain beside the bundle" \
        "$(ls -R "$_S2/claude-transcripts" 2>&1 | head -5)"
fi
if [[ -f "$_ENC" ]] && grep -q '"hello"' "$_ENC"; then
    assert_fail "[SPEC-2] bundle must not contain the transcript in the clear" "plaintext found in $_ENC"
else
    assert_pass "[SPEC-2] bundle does not contain the transcript in the clear"
fi
_DEC="$TEST_TEMP_DIR/dec"; mkdir -p "$_DEC"
if [[ -f "$_ENC" ]] && ZBUILD_TRANSCRIPT_KEY="$_KEY" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -pass env:ZBUILD_TRANSCRIPT_KEY -in "$_ENC" 2>/dev/null | tar -xzf - -C "$_DEC" 2>/dev/null; then
    assert_pass "[SPEC-2] bundle decrypts with ZBUILD_TRANSCRIPT_KEY via the documented command"
else
    assert_fail "[SPEC-2] bundle must decrypt with the documented openssl command" "decrypt/untar failed"
fi
assert_file_exists     "[SPEC-2] recent .jsonl is in the bundle under its project dir" "$_DEC/myrepo/recent.jsonl"
assert_file_exists     "[SPEC-2] same-named session from a second project survives"    "$_DEC/otherrepo/recent.jsonl"
assert_file_not_exists "[SPEC-2] a .jsonl older than the window is not in the bundle"   "$_DEC/myrepo/stale.jsonl"
if [[ ! -e "$_DEC/myrepo/linked.jsonl" ]]; then
    assert_pass "[SPEC-2] a symlinked .jsonl is not followed into the bundle"
else
    assert_fail "[SPEC-2] symlinked .jsonl must not be collected (find -type f)" "linked.jsonl present"
fi

# ── SPEC-6: the log names what was found, so "zero transcripts" is a finding ─
assert_contains "[SPEC-6] log lists each collected transcript by path" "$_OUT" "myrepo/recent.jsonl"
assert_contains_regex "[SPEC-6] log gives a transcript count" "$_OUT" "collected [0-9]+ claude session transcript"

# ── SPEC-3: key unset + public repo → fail closed, loudly, without failing the job
_H3="$TEST_TEMP_DIR/home-pub"; _S3="$TEST_TEMP_DIR/state-pub"
mkdir -p "$_H3" "$_S3"; _seed_home "$_H3"
_run_block "$_H3" "$_S3" false ""
assert_eq "[SPEC-3] key unset on a public repo exits 0 (does not fail the job)" "0" "$_RC"
assert_file_not_exists "[SPEC-3] key unset on a public repo writes no bundle" "$_S3/claude-transcripts.tar.gz.enc"
if [[ ! -e "$_S3/claude-transcripts" ]]; then
    assert_pass "[SPEC-3] key unset on a public repo copies no plaintext"
else
    assert_fail "[SPEC-3] key unset on a public repo must not copy plaintext" "claude-transcripts/ exists"
fi
assert_contains "[SPEC-3] key unset on a public repo names the missing secret" "$_OUT" "ZBUILD_TRANSCRIPT_KEY"
assert_contains "[SPEC-3] key unset on a public repo says transcripts were NOT collected" "$_OUT" "NOT collected"

# ── SPEC-8[guard]: key unset + private repo → the #1728 plaintext path still works
_H8="$TEST_TEMP_DIR/home-priv"; _S8="$TEST_TEMP_DIR/state-priv"
mkdir -p "$_H8" "$_S8"; _seed_home "$_H8"
_run_block "$_H8" "$_S8" true ""
assert_eq "[SPEC-8] private repo without a key exits 0" "0" "$_RC"
assert_file_exists     "[SPEC-8] private repo without a key keeps the plaintext copy" "$_S8/claude-transcripts/myrepo/recent.jsonl"
assert_file_not_exists "[SPEC-8] private repo without a key writes no bundle" "$_S8/claude-transcripts.tar.gz.enc"

# ── absent source: the common case for an early abort — must not fail the job ─
_HB="$TEST_TEMP_DIR/home-bare"; _SB="$TEST_TEMP_DIR/state-bare"
mkdir -p "$_HB" "$_SB"
_run_block "$_HB" "$_SB" false "$_KEY"
assert_eq "[SPEC-2] a missing ~/.claude/projects exits 0" "0" "$_RC"
assert_contains "[SPEC-2] a missing ~/.claude/projects says so rather than passing silently" "$_OUT" "nothing to collect"

# ── SPEC-9 (#2166): the real project-dir shape has a leading dash ───────────
# Claude Code names a project dir after its path with `/` → `-`, so every dir
# starts with `-`. #1841's log: "collected 0", "36 transcript(s) could not be
# copied", cp: cannot create regular file …/-home-runner-…/<id>.jsonl.
_H9="$TEST_TEMP_DIR/home-dash"; _S9="$TEST_TEMP_DIR/state-dash"
mkdir -p "$_H9/.claude/projects/-home-runner--zbuild-repos-o-r-issues-1841-worktree" "$_S9"
printf '{"type":"assistant","message":"dash"}\n' > "$_H9/.claude/projects/-home-runner--zbuild-repos-o-r-issues-1841-worktree/sess.jsonl"
_run_block "$_H9" "$_S9" true ""
assert_eq "[SPEC-9] a leading-dash project dir exits 0" "0" "$_RC"
assert_file_exists "[SPEC-9] …and its transcript is collected" "$_S9/claude-transcripts/-home-runner--zbuild-repos-o-r-issues-1841-worktree/sess.jsonl"
assert_contains "[SPEC-9] …and counted" "$_OUT" "collected 1 claude session transcript"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
