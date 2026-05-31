#!/usr/bin/env bash
# Unit test (#509): _build_apply_check precondition / silent-failure paths.
# F1: git tool unavailable → unavailable, fail-closed
# F2: empty/missing diff.patch → skipped (delegated to U5 in main test)
# F3: .git/rebase-merge present → precondition_failed, fail-closed
# F4: git apply --check rc>1 (catastrophic) → unavailable, fail-closed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #509: _build_apply_check preconditions + silent-failure"
setup_test_env "build-apply-check-pre"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

mk_repo() {
    local r="$TEST_TEMP_DIR/$1"
    mkdir -p "$r"
    (
        cd "$r"
        git init -q
        git config user.email t@t
        git config user.name t
        printf 'a\nb\nc\n' > f.txt
        git add f.txt
        git commit -q -m seed
    ) >/dev/null
    printf '%s' "$r"
}

run_gate() {
    local repo="$1" diff_path="$2"
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/zb-gate.XXXXXX")"
    set +e
    _build_apply_check "$repo" "$diff_path" "$tmp"
    local rc=$?
    set -e
    local ok reason
    ok="$(jq -r '.ok' "$tmp" 2>/dev/null || echo 'parse_error')"
    reason="$(jq -r '.reason // ""' "$tmp" 2>/dev/null || echo '')"
    rm -f "$tmp"
    printf '%s|%s|%s' "$rc" "$ok" "$reason"
}

# ─── F1: git binary missing → unavailable, fail-closed ───────────────────────
print_test_section "F1: git unavailable → fail-closed unavailable"
REPO1="$(mk_repo f1)"
DIFF1="$TEST_TEMP_DIR/f1.patch"
printf 'diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,1 @@\n-a\n+A\n' > "$DIFF1"
# Shim PATH so `git` resolves nowhere.
_old_path="$PATH"
SHIM_DIR="$TEST_TEMP_DIR/shim-empty"
mkdir -p "$SHIM_DIR"
# Provide essentials but not git.
for tool in jq bash sed awk grep cat head tail mktemp rm cut wc tr date printf dirname basename mkdir touch chmod test sh; do
    real="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$real" ]] && ln -sf "$real" "$SHIM_DIR/$tool"
done
PATH="$SHIM_DIR" \
res="$(PATH="$SHIM_DIR" run_gate "$REPO1" "$DIFF1")"
PATH="$_old_path"
rc="${res%%|*}"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
reason="$(printf '%s' "$res" | awk -F'|' '{print $3}')"
assert_eq "F1: rc=1 (git missing fail-closed)" "1" "$rc"
assert_eq "F1: ok=false" "false" "$ok"
assert_eq "F1: reason=tool_unavailable" "tool_unavailable" "$reason"

# ─── F3: .git/rebase-merge present → precondition_failed ─────────────────────
print_test_section "F3: rebase-merge state → precondition_failed"
REPO3="$(mk_repo f3)"
mkdir -p "$REPO3/.git/rebase-merge"
DIFF3="$TEST_TEMP_DIR/f3.patch"
( cd "$REPO3" && sed -i.bak 's/a/A/' f.txt && rm -f f.txt.bak && git diff HEAD ) > "$DIFF3"
res="$(run_gate "$REPO3" "$DIFF3")"
rc="${res%%|*}"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
reason="$(printf '%s' "$res" | awk -F'|' '{print $3}')"
assert_eq "F3: rc=1 (precondition fail-closed)" "1" "$rc"
assert_eq "F3: ok=false" "false" "$ok"
assert_eq "F3: reason=precondition_failed" "precondition_failed" "$reason"

# ─── F4: corrupted git index (.git/index unreadable) → unavailable ───────────
print_test_section "F4: catastrophic git apply rc>1 → unavailable fail-closed"
REPO4="$(mk_repo f4)"
DIFF4="$TEST_TEMP_DIR/f4.patch"
# Truly malformed patch payload that makes git apply error at the parse stage
# (rc may be 1 from a real git; we still expect fail-closed: rc=1).
printf 'this is not a valid diff payload at all\nnope\n' > "$DIFF4"
res="$(run_gate "$REPO4" "$DIFF4")"
rc="${res%%|*}"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
assert_eq "F4: rc=1 (fail-closed on unparseable patch)" "1" "$rc"
assert_eq "F4: ok=false" "false" "$ok"

# Helper that returns classifier_branch as well.
run_gate_full() {
    local repo="$1" diff_path="$2"
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/zb-gate.XXXXXX")"
    set +e
    _build_apply_check "$repo" "$diff_path" "$tmp"
    local rc=$?
    set -e
    local ok reason branch grc
    ok="$(jq -r '.ok' "$tmp" 2>/dev/null || echo 'parse_error')"
    reason="$(jq -r '.reason // ""' "$tmp" 2>/dev/null || echo '')"
    branch="$(jq -r '.classifier_branch // ""' "$tmp" 2>/dev/null || echo '')"
    grc="$(jq -r '.git_apply_rc // ""' "$tmp" 2>/dev/null || echo '')"
    rm -f "$tmp"
    printf '%s|%s|%s|%s|%s' "$rc" "$ok" "$reason" "$branch" "$grc"
}

# ─── F5: rc=128 + fatal: → reason=tool_state ─────────────────────────────────
# Simulate `git apply` emitting a fatal: error with rc=128 via shim. This is
# the "git ran but its environment is broken" case (e.g. corrupt index,
# unreachable HEAD found mid-apply). Must classify as tool_state — NOT
# tool_unavailable (binary IS present) and NOT corrupt_format (patch is fine).
print_test_section "F5: rc=128 + fatal: → tool_state"
REPO5="$(mk_repo f5)"
DIFF5="$TEST_TEMP_DIR/f5.patch"
( cd "$REPO5" && sed -i.bak 's/a/A/' f.txt && rm -f f.txt.bak && git diff HEAD ) > "$DIFF5"
SHIM5="$TEST_TEMP_DIR/shim-fatal"
mkdir -p "$SHIM5"
REAL_GIT_F5="$(command -v git)"
cat > "$SHIM5/git" <<SH
#!/usr/bin/env bash
args=("\$@")
i=0
sub=""
while [[ \$i -lt \${#args[@]} ]]; do
    a="\${args[\$i]}"
    case "\$a" in
        -C|-c) i=\$((i + 2)); continue ;;
        --*) i=\$((i + 1)); continue ;;
        *) sub="\$a"; break ;;
    esac
done
if [[ "\$sub" == "apply" ]]; then
    printf 'fatal: index file corrupt\n' >&2
    exit 128
fi
exec $REAL_GIT_F5 "\$@"
SH
chmod +x "$SHIM5/git"
_save_path="$PATH"
res="$(PATH="$SHIM5:$PATH" run_gate_full "$REPO5" "$DIFF5")"
PATH="$_save_path"
rc="$(printf '%s' "$res" | awk -F'|' '{print $1}')"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
reason="$(printf '%s' "$res" | awk -F'|' '{print $3}')"
branch="$(printf '%s' "$res" | awk -F'|' '{print $4}')"
assert_eq "F5: rc=1 fail-closed" "1" "$rc"
assert_eq "F5: ok=false" "false" "$ok"
assert_eq "F5: reason=tool_state" "tool_state" "$reason"
assert_eq "F5: classifier_branch=tool_state" "tool_state" "$branch"

# ─── F6: rc=127 (git apply not found via shim) → tool_unavailable_127 ───────
# Shim a stub `git` whose behavior is: respond normally for metadata (so
# precondition checks pass) but exit 127 with "command not found" stderr for
# `git apply` — modeling sandbox/PATH oddities where apply subcommand is
# unreachable while the main binary is.
print_test_section "F6: rc=127 → tool_unavailable_127"
REPO6="$(mk_repo f6)"
DIFF6="$TEST_TEMP_DIR/f6.patch"
( cd "$REPO6" && sed -i.bak 's/a/A/' f.txt && rm -f f.txt.bak && git diff HEAD ) > "$DIFF6"
SHIM6="$TEST_TEMP_DIR/shim-rc127"
mkdir -p "$SHIM6"
REAL_GIT_F6="$(command -v git)"
cat > "$SHIM6/git" <<SH
#!/usr/bin/env bash
# Walk args to find subcommand (skip -C <dir> / -c key=val).
args=("\$@")
i=0
sub=""
while [[ \$i -lt \${#args[@]} ]]; do
    a="\${args[\$i]}"
    case "\$a" in
        -C|-c) i=\$((i + 2)); continue ;;
        --*) i=\$((i + 1)); continue ;;
        *) sub="\$a"; break ;;
    esac
done
if [[ "\$sub" == "apply" ]]; then
    printf "git: 'apply' is not a git command\n" >&2
    exit 127
fi
exec $REAL_GIT_F6 "\$@"
SH
chmod +x "$SHIM6/git"
_save_path="$PATH"
res="$(PATH="$SHIM6:$PATH" run_gate_full "$REPO6" "$DIFF6")"
PATH="$_save_path"
rc="$(printf '%s' "$res" | awk -F'|' '{print $1}')"
reason="$(printf '%s' "$res" | awk -F'|' '{print $3}')"
branch="$(printf '%s' "$res" | awk -F'|' '{print $4}')"
grc="$(printf '%s' "$res" | awk -F'|' '{print $5}')"
assert_eq "F6: rc=1 fail-closed" "1" "$rc"
assert_eq "F6: reason=tool_unavailable" "tool_unavailable" "$reason"
assert_eq "F6: classifier_branch=tool_unavailable_127" "tool_unavailable_127" "$branch"
assert_eq "F6: git_apply_rc=127" "127" "$grc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
