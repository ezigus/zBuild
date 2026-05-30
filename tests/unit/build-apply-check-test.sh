#!/usr/bin/env bash
# Unit test (#509): _build_apply_check gate — `git apply --check` on the
# post-loop diff.patch BEFORE atomic_write of build-summary.json.
# Fail-CLOSED: invalid patch → rc=1 + verdict=corrupt_diff in summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #509: _build_apply_check unit (git apply --check gate)"
setup_test_env "build-apply-check-unit"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Source plugin so _build_apply_check is loaded.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# Helper: make a fresh git repo with a file we can diff against.
mk_repo() {
    local name="$1"
    local r="$TEST_TEMP_DIR/$name"
    mkdir -p "$r"
    (
        cd "$r"
        git init -q
        git config user.email t@t
        git config user.name t
        printf 'line1\nline2\nline3\n' > file.txt
        git add file.txt
        git commit -q -m seed
    ) >/dev/null
    printf '%s' "$r"
}

run_gate() {
    # Args: <repo> <diff_path>  → emits "<rc>|<ok>|<reason>" via tmp file
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

# ─── U1: valid diff applies cleanly → rc=0, ok=true ──────────────────────────
# The post-loop diff.patch is captured from `git diff HEAD` so the changes are
# ALREADY in the working tree. Gate uses `git apply --check -R` which validates
# the patch reverses cleanly (i.e. would forward-apply to HEAD).
print_test_section "U1: valid diff → gate passes"
REPO1="$(mk_repo u1)"
DIFF1="$TEST_TEMP_DIR/u1.patch"
( cd "$REPO1" && sed -i.bak 's/line2/LINE2/' file.txt && rm -f file.txt.bak \
    && git diff HEAD ) > "$DIFF1"
# Leave working tree mutated — this is the production state when the gate runs.
res="$(run_gate "$REPO1" "$DIFF1")"
assert_eq "U1: rc=0|ok=true|empty-reason" "0|true|" "$res"

# ─── U2: whitespace-trivial diff → passes (default --whitespace=warn) ────────
print_test_section "U2: whitespace-only diff passes"
REPO2="$(mk_repo u2)"
DIFF2="$TEST_TEMP_DIR/u2.patch"
( cd "$REPO2" && sed -i.bak 's/line2/line2  /' file.txt && rm -f file.txt.bak \
    && git diff HEAD ) > "$DIFF2"
# Working tree retains the whitespace mutation.
res="$(run_gate "$REPO2" "$DIFF2")"
rc="${res%%|*}"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
assert_eq "U2: rc=0 (whitespace warn ≠ error)" "0" "$rc"
assert_eq "U2: ok=true" "true" "$ok"

# ─── U3: hand-crafted bad line numbers → fails, reason=context ───────────────
print_test_section "U3: bad @@ line numbers fail"
REPO3="$(mk_repo u3)"
DIFF3="$TEST_TEMP_DIR/u3.patch"
cat > "$DIFF3" <<'PATCH'
diff --git a/file.txt b/file.txt
index 0000000..1111111 100644
--- a/file.txt
+++ b/file.txt
@@ -99,3 +99,3 @@
-line1
+CHANGED
 line2
PATCH
res="$(run_gate "$REPO3" "$DIFF3")"
rc="${res%%|*}"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
reason="$(printf '%s' "$res" | awk -F'|' '{print $3}')"
assert_eq "U3: rc=1 (fail-closed)" "1" "$rc"
assert_eq "U3: ok=false" "false" "$ok"
if [[ -n "$reason" && "$reason" != "null" ]]; then
    assert_pass "U3: reason field populated ($reason)"
else
    assert_fail "U3: reason field populated" "got: '$reason'"
fi

# ─── U4: hunk references missing target file → fails ─────────────────────────
print_test_section "U4: missing target file"
REPO4="$(mk_repo u4)"
DIFF4="$TEST_TEMP_DIR/u4.patch"
cat > "$DIFF4" <<'PATCH'
diff --git a/nonexistent.txt b/nonexistent.txt
--- a/nonexistent.txt
+++ b/nonexistent.txt
@@ -1,1 +1,1 @@
-old
+new
PATCH
res="$(run_gate "$REPO4" "$DIFF4")"
rc="${res%%|*}"
assert_eq "U4: rc=1 (missing target)" "1" "$rc"

# ─── U5: empty diff → skipped, rc=0, reason=empty_diff ───────────────────────
print_test_section "U5: empty diff is skipped"
REPO5="$(mk_repo u5)"
DIFF5="$TEST_TEMP_DIR/u5.patch"
: > "$DIFF5"
res="$(run_gate "$REPO5" "$DIFF5")"
rc="${res%%|*}"
ok="$(printf '%s' "$res" | awk -F'|' '{print $2}')"
reason="$(printf '%s' "$res" | awk -F'|' '{print $3}')"
assert_eq "U5: rc=0 (empty diff skip)" "0" "$rc"
assert_eq "U5: ok=true (skipped is not fail)" "true" "$ok"
assert_eq "U5: reason=empty_diff_skipped" "empty_diff_skipped" "$reason"

# ─── U6: trailing-whitespace warning → still passes (warn ≠ error) ───────────
print_test_section "U6: trailing whitespace only warning, not failure"
REPO6="$(mk_repo u6)"
DIFF6="$TEST_TEMP_DIR/u6.patch"
# Real git-diff with a trailing space added.
( cd "$REPO6" && printf 'line1\nline2 \nline3\n' > file.txt && git diff HEAD ) > "$DIFF6"
res="$(run_gate "$REPO6" "$DIFF6")"
rc="${res%%|*}"
assert_eq "U6: rc=0 (whitespace warn)" "0" "$rc"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
