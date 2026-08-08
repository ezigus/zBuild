#!/usr/bin/env bash
# tests/unit/ci-transcript-collection-test.sh
# On CI failure, copy Claude session JSONL transcripts into the artifact (#1728).
#
# SPEC ids are the design's ids — the acceptance gate binds per-SPEC TESTFILEs by
# id, so a renumbering here silently unbinds a SPEC from its only assertion.
#
# SPEC-1[change]: the collect step's if: is `failure() && github.event.repository.private`
# SPEC-2[change]: the run block copies $HOME/.claude/projects/*.jsonl into $ZBUILD_STATE_DIR/claude-transcripts
# SPEC-3[change]: the condition gates on repository privacy, so a public repo skips the step
# SPEC-4[change]: the collect step precedes "Upload pipeline artifacts" (or it lands in no artifact)
# SPEC-7[change]: docs/wiki/Troubleshooting.md points CI operators at claude-transcripts/
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "CI transcript collection — diagnostics on failure (#1728)"
setup_test_env "ci-transcript-collection"

WF="$REPO_ROOT/.github/workflows/zbuild-pipeline.yml"

_STEP_HEADING='Collect claude session transcripts'

# ── Extract the step's if: clause (SPEC-1, SPEC-3) ──────────────────────────
_COLLECT_IF="$(awk -v h="$_STEP_HEADING" '
    index($0, "      - name: " h) == 1 { instep = 1; next }
    instep && /^      - name: /        { exit }
    instep && /^        if: /          { sub(/^        if: /, ""); print; exit }
' "$WF")"

# ── SPEC-1: the whole condition, not just one half of it ────────────────────
if [[ "$_COLLECT_IF" == "failure() && github.event.repository.private" ]]; then
    assert_pass "[SPEC-1] collect step runs only on failure() and only on a private repo"
else
    assert_fail "[SPEC-1] collect step if: must be 'failure() && github.event.repository.private'" \
        "if: [$_COLLECT_IF]"
fi

# ── SPEC-3: the privacy gate specifically — a public repo must skip ─────────
# Asserted separately from SPEC-1 because this is the access control standing in
# for redaction: if it degrades to `always()` or a bare failure(), unredacted
# model transcripts start uploading from public forks.
if grep -q 'github\.event\.repository\.private' <<< "$_COLLECT_IF"; then
    assert_pass "[SPEC-3] collect step is gated on repository privacy"
else
    assert_fail "[SPEC-3] collect step must gate on github.event.repository.private" \
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

# ── SPEC-7: the #1550 diagnostic note names the CI location ─────────────────
_DOC="$REPO_ROOT/docs/wiki/Troubleshooting.md"
if grep -q 'claude-transcripts' "$_DOC"; then
    assert_pass "[SPEC-7] Troubleshooting.md points operators at claude-transcripts/"
else
    assert_fail "[SPEC-7] Troubleshooting.md must name the claude-transcripts/ artifact subdir" \
        "no 'claude-transcripts' reference in $_DOC"
fi

# ── SPEC-2: execute the real run block against a fake HOME ───────────────────
# Extracting and running the workflow's own block (rather than re-asserting its
# text) is what makes this load-bearing: a block that greps correctly but copies
# nothing still fails here.
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
else
    _FAKE_HOME="$TEST_TEMP_DIR/fake-home"
    _FAKE_PROJECTS="$_FAKE_HOME/.claude/projects/myrepo"
    _FAKE_STATE="$TEST_TEMP_DIR/zbuild-state"
    mkdir -p "$_FAKE_PROJECTS" "$_FAKE_STATE"

    printf '{"type":"assistant","message":"hello"}\n' > "$_FAKE_PROJECTS/recent.jsonl"
    printf '{"type":"assistant","message":"old"}\n'   > "$_FAKE_PROJECTS/stale.jsonl"

    # GNU `date -d` first, BSD `date -v` second (same order as the stat -c/-f
    # precedent). `touch -d '8 hours ago'` is GNU-only and fails silently on BSD,
    # which would leave stale.jsonl recent and invert the assertion below.
    _stale_ts="$(date -d '8 hours ago' +%Y%m%d%H%M 2>/dev/null \
        || date -v-8H +%Y%m%d%H%M 2>/dev/null)"
    if [[ -z "$_stale_ts" ]] || ! touch -t "$_stale_ts" "$_FAKE_PROJECTS/stale.jsonl"; then
        assert_fail "[SPEC-2] test fixture must be able to backdate a file" \
            "neither 'date -d' nor 'date -v' produced a usable timestamp"
    fi

    _EXEC_RC=0
    _EXEC_OUT="$(
        export HOME="$_FAKE_HOME"
        export ZBUILD_STATE_DIR="$_FAKE_STATE"
        bash -c "$_BLOCK" 2>&1
    )" || _EXEC_RC=$?

    if [[ "$_EXEC_RC" -eq 0 ]]; then
        assert_pass "[SPEC-2] collect run block executes cleanly"
    else
        assert_fail "[SPEC-2] collect run block must exit 0" \
            "rc=$_EXEC_RC output=[$_EXEC_OUT]"
    fi

    _DEST="$_FAKE_STATE/claude-transcripts"

    if [[ -f "$_DEST/myrepo/recent.jsonl" ]]; then
        assert_pass "[SPEC-2] a recent .jsonl is copied under its project dir"
    else
        assert_fail "[SPEC-2] recent .jsonl must be copied to \$ZBUILD_STATE_DIR/claude-transcripts" \
            "myrepo/recent.jsonl not found in [$_DEST]; block output=[$_EXEC_OUT]"
    fi

    if [[ ! -f "$_DEST/myrepo/stale.jsonl" ]]; then
        assert_pass "[SPEC-2] a .jsonl older than the 6-hour window is not copied"
    else
        assert_fail "[SPEC-2] stale .jsonl (older than 6 hours) must not be copied" \
            "myrepo/stale.jsonl unexpectedly found in [$_DEST]"
    fi

    # Two projects can hold same-named sessions; a flat copy would drop one.
    _P2="$_FAKE_HOME/.claude/projects/otherrepo"
    mkdir -p "$_P2"
    printf '{"type":"assistant","message":"other"}\n' > "$_P2/recent.jsonl"
    (
        export HOME="$_FAKE_HOME"
        export ZBUILD_STATE_DIR="$_FAKE_STATE"
        bash -c "$_BLOCK"
    ) >/dev/null 2>&1

    if [[ -f "$_DEST/myrepo/recent.jsonl" && -f "$_DEST/otherrepo/recent.jsonl" ]]; then
        assert_pass "[SPEC-2] same-named sessions from two projects both survive"
    else
        assert_fail "[SPEC-2] a flat copy must not clobber same-named sessions" \
            "expected both myrepo/ and otherrepo/ recent.jsonl under [$_DEST]"
    fi

    # A symlink is the one way an arbitrary file could be pulled into an upload
    # that skips redaction — -type f must exclude it.
    printf 'SECRET\n' > "$_FAKE_HOME/outside-secret.jsonl"
    ln -sf "$_FAKE_HOME/outside-secret.jsonl" "$_FAKE_PROJECTS/linked.jsonl"
    (
        export HOME="$_FAKE_HOME"
        export ZBUILD_STATE_DIR="$_FAKE_STATE"
        bash -c "$_BLOCK"
    ) >/dev/null 2>&1

    if [[ ! -e "$_DEST/myrepo/linked.jsonl" ]]; then
        assert_pass "[SPEC-2] a symlinked .jsonl is not followed into the artifact"
    else
        assert_fail "[SPEC-2] symlinked .jsonl must not be copied (find -type f)" \
            "linked.jsonl was collected from [$_FAKE_PROJECTS]"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
