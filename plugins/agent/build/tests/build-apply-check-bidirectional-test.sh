#!/usr/bin/env bash
# Tests (#530): `_build_apply_check` runs BOTH forward AND reverse checks and
# fails-CLOSED if either fails.
#
# Backstory: #509 wired reverse-only (`-R`) because the WT already holds the
# changes. That masked the #530 trailing-newline truncation: reverse passed
# (parser saw the same byte stream), forward failed. The remedy: stash the
# tree clean, forward-check, unstash. Both must pass for ok:true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# shellcheck source=../../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plugin/build: _build_apply_check bidirectional gate (#530)"
setup_test_env "build-apply-check-bidir"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_RUN_ID="build-530-bidir-$$"
mkdir -p "$ZBUILD_EVENTS_DIR"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# shellcheck source=../../../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── Helper repo ─────────────────────────────────────────────────────────────
make_repo() {
    local repo="$TEST_TEMP_DIR/$1"
    mkdir -p "$repo"
    ( cd "$repo" && git init -q \
        && git config user.email t@t \
        && git config user.name t \
        && git config commit.gpgsign false \
        && printf 'line1\nline2\nline3\n' > a.txt \
        && git add a.txt && git commit -q -m seed ) >/dev/null
    printf '%s\n' "$repo"
}

# ─── T6.a: well-formed forward+reverse — ok:true ─────────────────────────────
test_clean_patch_passes() {
    local repo
    repo="$(make_repo r-good)"
    ( cd "$repo" && printf 'line1\nline2\nline3\nline4\n' > a.txt )
    local patch="$TEST_TEMP_DIR/good.patch"
    git -C "$repo" add -N . 2>/dev/null
    git -C "$repo" diff HEAD > "$patch"

    local result="$TEST_TEMP_DIR/result-good.json"
    set +e
    _build_apply_check "$repo" "$patch" "$result"
    local rc=$?
    set -e

    assert_eq "T6.a: clean patch rc=0" "0" "$rc"
    local ok fwd rev
    ok="$(jq -r '.ok' "$result" 2>/dev/null)"
    fwd="$(jq -r '.forward_ok' "$result" 2>/dev/null)"
    rev="$(jq -r '.reverse_ok' "$result" 2>/dev/null)"
    assert_eq "T6.a: ok=true" "true" "$ok"
    assert_eq "T6.a: forward_ok=true" "true" "$fwd"
    assert_eq "T6.a: reverse_ok=true" "true" "$rev"
}

# ─── T6.b: 1-byte-truncated patch (reverse-OK, forward-CORRUPT) — ok:false ──
test_truncated_patch_fails_closed() {
    local repo
    repo="$(make_repo r-trunc)"
    ( cd "$repo" && printf 'line1\nline2\nline3\nline4\n' > a.txt )
    local raw="$TEST_TEMP_DIR/raw-trunc.patch"
    local patch="$TEST_TEMP_DIR/trunc.patch"
    git -C "$repo" add -N . 2>/dev/null
    git -C "$repo" diff HEAD > "$raw"

    # Strip the final newline → the exact #530 corruption.
    local raw_bytes
    raw_bytes="$(wc -c < "$raw" | tr -d ' ')"
    head -c $(( raw_bytes - 1 )) "$raw" > "$patch"

    local result="$TEST_TEMP_DIR/result-trunc.json"
    set +e
    _build_apply_check "$repo" "$patch" "$result"
    local rc=$?
    set -e

    if [[ "$rc" != "0" ]]; then
        assert_pass "T6.b: bidirectional gate fails-CLOSED on forward-corrupt patch"
    else
        assert_fail "T6.b: bidirectional gate fails-CLOSED" "rc=$rc, result=$(cat "$result")"
    fi
    local ok fwd rev
    ok="$(jq -r '.ok' "$result" 2>/dev/null)"
    fwd="$(jq -r '.forward_ok' "$result" 2>/dev/null)"
    rev="$(jq -r '.reverse_ok' "$result" 2>/dev/null)"
    assert_eq "T6.b: ok=false" "false" "$ok"
    assert_eq "T6.b: forward_ok=false (this is the bug)" "false" "$fwd"
    # reverse_ok may be true or false depending on parser variation; we only
    # demand that EITHER side failing → ok:false.
}

test_clean_patch_passes
test_truncated_patch_fails_closed

cleanup_test_env
print_test_results
exit $((FAIL > 0))
