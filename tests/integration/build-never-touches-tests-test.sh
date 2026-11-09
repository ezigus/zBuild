#!/usr/bin/env bash
# Integration test (#2508, ADR-030 §8): build never touches a file in the test
# folders, and has no other file list.
#
# #1805 run 42556446368: build removed a guard to answer a lens and rewrote
# pipeline-resume-test.sh to match, because its scope list allowed both; and a
# helper test-author left uncommitted was counted as build's out-of-scope file.
# Now the test folders are test-author's: a build change inside them is put
# back, and every change outside them is build's and is kept.
#
# B1 a change build makes to a test file is put back
# B2 a file build creates in a test folder is removed
# B3 each one is reported (build.scope.violation, the summary's list)
# B4 build's changes outside the test folders are kept and committed, with no
#    file list from design or a plan
# B5 build's prompt has no scope list; it says it may change any file outside
#    the test folders and none inside them
# B6 build may answer a test that should change "not mine", and that answer is
#    a finding for the stage that owns the tests
# B7 build asks for no more files: its result carries no request to widen a
#    file list, and its next try is told the test-folder change was put back
# B8 what the repository defines as off limits is put back the same way: a
#    path outside the repository, inside .git/, or on the repository's own list
#    (.zbuild/private-paths); it is reported, shown to the next try as a
#    finding, and never committed. Nothing else is off limits: not the engine's
#    default private files (a tracked .npmrc is build's to change), and never a
#    file for its name alone (ordinary code whose name holds "secret")
# B9 a file build moves from outside the test folders into them is put back
#    whole: the copy in the test folders goes, and the file it moved from is
#    there again — not committed as deleted (review on #2513)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build never touches the test folders (#2508)"
setup_test_env "build-never-touches-tests"

_ZB_ID="$(zb_test_issue)"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_STATE_DIR="$TEST_TEMP_DIR/state"
export ZBUILD_RUN_ID="build-2508-$$"
export ZBUILD_ISSUE="$_ZB_ID"
mkdir -p "$ZBUILD_EVENTS_DIR" "$ZBUILD_STATE_DIR/artifacts/stage-io"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"

REPO="$(setup_git_temp_repo build2508)"
mkdir -p "$REPO/tests" "$REPO/src"
( cd "$REPO" \
    && printf 'assert old\n' > tests/a-test.sh \
    && printf 'echo app\n' > src/app.sh \
    && printf 'patterns v1\n' > src/secret-patterns.sh \
    && printf 'registry=a\n' > .npmrc \
    && printf 'move me\n' > src/move.sh \
    && mkdir -p .zbuild && printf 'config/prod-keys/\n' > .zbuild/private-paths \
    && git add -A && git commit -q -m seed ) >/dev/null

# The model: changes a test, creates a helper in the test folder, and does the
# real work outside it.
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
cat > "${ZB_PROMPT_COPY}"
printf 'assert new\n' > "$PWD/tests/a-test.sh"
printf 'helper\n' > "$PWD/tests/new-helper.sh"
printf 'echo app v2\n' > "$PWD/src/app.sh"
printf 'echo new\n' > "$PWD/src/new.sh"
printf 'patterns v2\n' > "$PWD/src/secret-patterns.sh"
printf 'registry=b\n' > "$PWD/.npmrc"
git -C "$PWD" mv src/move.sh tests/moved-test-helper.sh
mkdir -p "$PWD/config/prod-keys" && printf 'k\n' > "$PWD/config/prod-keys/k.txt"
jq -n --arg r $'did the work\nANSWER test finding 1: not mine — the test must change: tests/a-test.sh: it pins the old output\nCOMMIT_SUMMARY: change app\nLOOP_COMPLETE' \
    '{result:$r, usage:{input_tokens:5, output_tokens:5}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH" ZB_PROMPT_COPY="$TEST_TEMP_DIR/prompt-seen.txt"

cat > "$TEST_TEMP_DIR/template.yaml" <<'YAML'
id: standard
name: Standard
defaults:
  strategy: fanout
stages:
  - id: build
    gate: auto
    roles: [builder]
    io:
      destinations: [file]
      tail_lines: 40
YAML

STATE_DIR="$TEST_TEMP_DIR/state-build"
mkdir -p "$STATE_DIR/artifacts"
printf 'scope: all\n' > "$STATE_DIR/scope-manifest.md"
STATE_FILE="$STATE_DIR/state.json"
printf '{"issue":%s,"branch":"feat/2508"}' "$_ZB_ID" > "$STATE_FILE"
STAGE_INPUTS_DRIVER="$TEST_TEMP_DIR/stage-inputs-driver.json"
jq -n --arg sm "$STATE_DIR/scope-manifest.md" \
    '{"schema_version":1,"stage":"build","inputs":{"scope_manifest":$sm}}' > "$STAGE_INPUTS_DRIVER"

PRE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
DRIVER="$TEST_TEMP_DIR/driver.sh"
cat > "$DRIVER" <<EOF
set -euo pipefail
source "$REPO_ROOT/scripts/lib/helpers.sh"
source "$REPO_ROOT/core/event-bus/event-bus.sh"
source "$REPO_ROOT/core/pipeline/template.sh"
source "$REPO_ROOT/core/output/stage-io.sh"
source "$REPO_ROOT/plugins/agent/build/plugin.sh"
export ZBUILD_EVENTS_DIR="$ZBUILD_EVENTS_DIR" ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_JSONL"
export ZBUILD_EVENT_SCHEMA="$ZBUILD_EVENT_SCHEMA" ZBUILD_STATE_DIR="$ZBUILD_STATE_DIR"
export ZBUILD_MODELS_FILE="$ZBUILD_MODELS_FILE" ZBUILD_RUN_ID="$ZBUILD_RUN_ID" ZBUILD_ISSUE="$ZBUILD_ISSUE"
export ZBUILD_REPO_ROOT="$REPO" HOME="$HOME" PATH="$PATH" ZB_PROMPT_COPY="$ZB_PROMPT_COPY"
export ZBUILD_STAGE_INPUTS="$STAGE_INPUTS_DRIVER"
load_template "$TEST_TEMP_DIR/template.yaml"
export ZBUILD_CURRENT_STAGE=build
build_stage_run "ignored" "$STATE_FILE"
EOF
bash "$DRIVER" >"$TEST_TEMP_DIR/driver.log" 2>&1 || true; [[ -n "${ZB_DEBUG:-}" ]] && cat "$TEST_TEMP_DIR/driver.log"

# ── B1 / B2 ────────────────────────────────────────────────────────────────
assert_eq "[B1] build's change to a test file is put back" "assert old" "$(cat "$REPO/tests/a-test.sh")"
assert_eq "[B2] a file build created in a test folder is removed" "no" \
    "$([[ -e "$REPO/tests/new-helper.sh" ]] && echo yes || echo no)"

# ── B3 ─────────────────────────────────────────────────────────────────────
_sv="$(jq -r 'select(.type=="build.scope.violation") | .data.path' "$ZBUILD_EVENTS_JSONL" 2>/dev/null || true)"
assert_contains "[B3] the changed test file is reported" "$_sv" "tests/a-test.sh"
assert_contains "[B3] ...and the created one" "$_sv" "tests/new-helper.sh"
SUMMARY="$STATE_DIR/artifacts/build-summary.json"
assert_contains "[B3] the summary lists what was put back" \
    "$(jq -r '.scope_violations[]?' "$SUMMARY" 2>/dev/null)" "tests/a-test.sh"
assert_contains "[B3] build's summary says the test-folder change was put back" \
    "$(cat "$STATE_DIR/artifacts/build-summary.md" 2>/dev/null)" "it changed files in the test folders, which were put back"

# ── B4 ─────────────────────────────────────────────────────────────────────
POST_HEAD="$(git -C "$REPO" rev-parse HEAD)"
if [[ "$POST_HEAD" == "$PRE_HEAD" ]]; then
    assert_fail "[B4] build's work outside the test folders is committed" "HEAD did not move"
else
    _c="$(git -C "$REPO" show --name-only --format= HEAD)"
    assert_contains "[B4] build's change to a source file is committed" "$_c" "src/app.sh"
    assert_contains "[B4] ...and the source file it created" "$_c" "src/new.sh"
    if grep -q '^tests/' <<< "$_c"; then
        assert_fail "[B4] nothing in the test folders is in build's commit" "$_c"
    else
        assert_pass "[B4] nothing in the test folders is in build's commit"
    fi
fi

# ── B5 ─────────────────────────────────────────────────────────────────────
_p="$(tr -s '[:space:]' ' ' < "$ZB_PROMPT_COPY" 2>/dev/null)"
if grep -qF 'plan.files[]' <<< "$_p"; then
    assert_fail "[B5] build's prompt has no scope list" "it still says plan.files[]"
else
    assert_pass "[B5] build's prompt has no scope list"
fi
assert_contains "[B5] build may change any file outside the test folders, and none inside" "$_p" \
    "You may change any file outside the test folders (tests/*, plugins/*/*/tests/*), and none inside them"
assert_contains "[B5] build is told how to answer a test that should change" "$_p" \
    "not mine — the test must change: <test file>: <why>"

# ── B6 ─────────────────────────────────────────────────────────────────────
assert_contains "[B6] build's \"not mine\" about a test is a finding for the stage that owns the tests" \
    "$(jq -r '.data.findings[]?.text' "$STATE_DIR/artifacts/build-tests-result.json" 2>/dev/null)" \
    "tests/a-test.sh: it pins the old output"

# ── B7 ─────────────────────────────────────────────────────────────────────
assert_eq "[B7] build's result carries no request for more files" "false" \
    "$(jq 'has("scope_expansion_request") or has("out_of_scope_files")' "$SUMMARY" 2>/dev/null)"
assert_contains "[B7] its next try is told the test-folder change was put back" \
    "$(jq -r '.data.findings[]?.text' "$SUMMARY" 2>/dev/null)" "in the test folders, which only the stage that writes the tests may change; it was put back"

# ── B8 ─────────────────────────────────────────────────────────────────────
assert_eq "[B8] a file on the repository's own list that build created is removed" "no" \
    "$([[ -e "$REPO/config/prod-keys/k.txt" ]] && echo yes || echo no)"
_v8="$(jq -r '.scope_violations[]?' "$SUMMARY" 2>/dev/null)"
assert_contains "[B8] it is reported" "$_v8" "config/prod-keys/k.txt"
assert_contains "[B8] its next try is told it may not be changed" \
    "$(jq -r '.data.findings[]?.text' "$SUMMARY" 2>/dev/null)" "which no stage may change"
_c8="$(git -C "$REPO" show --name-only --format= HEAD)"
if grep -qF config/prod-keys/ <<< "$_c8"; then
    assert_fail "[B8] no off-limits file is in build's commit" "$_c8"
else
    assert_pass "[B8] no off-limits file is in build's commit"
fi
assert_eq "[B8] a tracked .npmrc (an engine default, not the repository's) is kept" "registry=b" \
    "$(cat "$REPO/.npmrc" 2>/dev/null)"
assert_contains "[B8] ...and committed" "$_c8" ".npmrc"
assert_eq "[B8] ordinary code whose name holds \"secret\" is kept" "patterns v2" \
    "$(cat "$REPO/src/secret-patterns.sh" 2>/dev/null)"
assert_contains "[B8] ...and committed" "$_c8" "src/secret-patterns.sh"
if grep -qxF src/secret-patterns.sh <<< "$_v8"; then
    assert_fail "[B8] ...and not reported as put back" "$_v8"
else
    assert_pass "[B8] ...and not reported as put back"
fi
# A path outside the repository never reaches git's diff; the rule build applies
# to each path is checked on its own.
_off() ( source "$REPO_ROOT/plugins/agent/build/plugin.sh" >/dev/null 2>&1
         export ZBUILD_REPO_ROOT="$REPO"
         _build_path_off_limits "$1" "$REPO" && echo off || echo ok )
assert_eq "[B8] a path outside the repository is off limits" "off off" "$(_off ../outside.sh) $(_off /etc/passwd)"
assert_eq "[B8] .git/ is off limits" "off off" "$(_off .git/config) $(_off .git)"
assert_eq "[B8] a path on the repository's own list is off limits" "off" "$(_off config/prod-keys/a.txt)"
assert_eq "[B8] the engine's default private files are not" "ok ok ok" "$(_off .npmrc) $(_off keys/deploy.pem) $(_off config/.env.local)"
assert_eq "[B8] a name holding secret or credential is not" "ok ok" "$(_off scripts/lib/secret-patterns.sh) $(_off app/credentials_controller.rb)"

# ── B9 ─────────────────────────────────────────────────────────────────────
assert_eq "[B9] the file build moved into the test folders is gone from them" "no" \
    "$([[ -e "$REPO/tests/moved-test-helper.sh" ]] && echo yes || echo no)"
assert_eq "[B9] the file it moved from is there again, as it was" "move me" \
    "$(cat "$REPO/src/move.sh" 2>/dev/null)"
_c9="$(git -C "$REPO" show --name-status --format= HEAD)"
if grep -qE '^D[[:space:]]+src/move\.sh$' <<< "$_c9"; then
    assert_fail "[B9] build's commit does not delete the file it moved from" "$_c9"
else
    assert_pass "[B9] build's commit does not delete the file it moved from"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
