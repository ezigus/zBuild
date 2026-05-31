#!/usr/bin/env bash
# Tests (#530): `_route_loop_capture_diff` round-trips a `git diff HEAD` that
# survives both forward AND reverse `git apply --check` against the working tree
# state it was captured from.
#
# Root cause: bash `$()` strips trailing newlines + `printf '%s'` doesn't
# restore them, leaving the captured patch 1 byte short → forward apply fails
# with "corrupt patch at line N". Reverse apply masks the corruption (#519's
# bidirectional gate gap).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/_route_loop_capture_diff — round-trip (#530)"
setup_test_env "route-loop-capture-diff-530"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf '%s' "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

# shellcheck source=../../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── Helper: make a fresh repo whose seed file has a heredoc + trailing NL ───
make_heredoc_repo() {
    local name="$1"
    local repo="$TEST_TEMP_DIR/$name"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q
        git config user.email t@t
        git config user.name t
        git config commit.gpgsign false
        # Seed file ends in a trailing newline (the canonical reproducer:
        # a file ending in `EOF\n` which `$()` would strip).
        cat > tool.sh <<'SEED'
#!/usr/bin/env bash
do_thing() {
    cat > /tmp/x <<'EOF'
inner-line
EOF
}
SEED
        git add tool.sh
        git commit -q -m seed
    ) >/dev/null
    printf '%s\n' "$repo"
}

# ─── T1.a: round-trip an edit that adds a line below a heredoc ───────────────
test_round_trip_heredoc_edit() {
    local repo
    repo="$(make_heredoc_repo r1)"
    # Mutate: append a new line below the heredoc.
    cat >> "$repo/tool.sh" <<'NEW'
do_other() {
    echo other
}
NEW

    local cap_var=""
    _route_loop_capture_diff "$repo" 1000000 cap_var || {
        assert_fail "T1.a: capture rc=0" "got rc=$?"
        return
    }

    local out_patch="$TEST_TEMP_DIR/out-r1.patch"
    printf '%s' "$cap_var" > "$out_patch"

    # Canary 1: trailing newline preserved.
    local last_byte
    last_byte="$(tail -c1 "$out_patch" | od -An -tx1 | tr -d ' ')"
    if [[ "$last_byte" == "0a" ]]; then
        assert_pass "T1.a: captured diff ends in \\n"
    else
        assert_fail "T1.a: captured diff ends in \\n" "last byte=0x$last_byte"
    fi

    # Canary 2: byte-equal to raw `git diff HEAD`.
    local raw_patch="$TEST_TEMP_DIR/raw-r1.patch"
    git -C "$repo" diff HEAD > "$raw_patch"
    local raw_bytes cap_bytes
    raw_bytes="$(wc -c < "$raw_patch" | tr -d ' ')"
    cap_bytes="$(wc -c < "$out_patch" | tr -d ' ')"
    assert_eq "T1.a: capture byte-count == raw byte-count" "$raw_bytes" "$cap_bytes"

    # Canary 3: REVERSE applies cleanly (patch describes WT).
    if git -C "$repo" apply --check -R "$out_patch" 2>/dev/null; then
        assert_pass "T1.a: reverse apply --check ok"
    else
        assert_fail "T1.a: reverse apply --check ok" "rc=$?"
    fi

    # Canary 4: FORWARD applies cleanly against a stashed-clean tree.
    (
        cd "$repo"
        git stash push -u -q -m "round-trip-forward"
        if git apply --check "$out_patch" 2>err.log; then
            echo "FORWARD_OK"
        else
            echo "FORWARD_FAIL: $(cat err.log)"
        fi
        git stash pop -q 2>/dev/null || true
    ) > "$TEST_TEMP_DIR/fwd-r1.out"
    if grep -q '^FORWARD_OK' "$TEST_TEMP_DIR/fwd-r1.out"; then
        assert_pass "T1.a: forward apply --check ok (stashed-clean tree)"
    else
        assert_fail "T1.a: forward apply --check ok" \
            "$(cat "$TEST_TEMP_DIR/fwd-r1.out")"
    fi
}

# ─── T1.b: file with NO trailing newline (synthetic) ─────────────────────────
test_round_trip_no_trailing_newline() {
    local repo="$TEST_TEMP_DIR/r2"
    mkdir -p "$repo"
    (
        cd "$repo"
        git init -q
        git config user.email t@t
        git config user.name t
        git config commit.gpgsign false
        printf 'a\nb\nc' > note.txt   # NO trailing \n
        git add note.txt
        git commit -q -m seed
        printf 'a\nb\nc\nd' > note.txt   # still NO trailing \n
    ) >/dev/null

    local cap_var=""
    _route_loop_capture_diff "$repo" 1000000 cap_var || {
        assert_fail "T1.b: capture rc=0" "got rc=$?"; return; }
    local out_patch="$TEST_TEMP_DIR/out-r2.patch"
    printf '%s' "$cap_var" > "$out_patch"

    local raw="$TEST_TEMP_DIR/raw-r2.patch"
    git -C "$repo" diff HEAD > "$raw"
    local raw_b cap_b
    raw_b="$(wc -c < "$raw" | tr -d ' ')"
    cap_b="$(wc -c < "$out_patch" | tr -d ' ')"
    assert_eq "T1.b: \\ No newline diff byte-count matches raw" "$raw_b" "$cap_b"
    if git -C "$repo" apply --check -R "$out_patch" 2>/dev/null; then
        assert_pass "T1.b: reverse apply --check ok"
    else
        assert_fail "T1.b: reverse apply --check ok" "rc=$?"
    fi
}

# ─── Run ─────────────────────────────────────────────────────────────────────
test_round_trip_heredoc_edit
test_round_trip_no_trailing_newline

cleanup_test_env
print_test_results
exit $((FAIL > 0))
