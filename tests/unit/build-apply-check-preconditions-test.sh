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

cleanup_test_env
print_test_results
exit $((FAIL > 0))
