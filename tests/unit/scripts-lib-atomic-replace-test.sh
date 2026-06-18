#!/usr/bin/env bash
# Tests: scripts/lib/helpers.sh — atomic_replace primitive (#909)
#
# atomic_replace <src> <dst> copies src to a unique temp in dst's directory then
# renames it into place, so a concurrent reader of dst never observes a torn
# intermediate. .bak is the corruption-recovery source, so its rotation must be
# atomic. Case E is the load-bearing negative control: it FAILS against a bare
# `cp` and passes only with the temp+rename primitive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "scripts/lib/helpers.sh — atomic_replace (#909)"
setup_test_env "atomic-replace"

_strays() { find "$TEST_TEMP_DIR" -name "$1.tmp.*" 2>/dev/null | wc -l | tr -d ' '; }

# ── A: dst absent → created with src content ──────────────────────────────────
SRC="$TEST_TEMP_DIR/src-a"; DST="$TEST_TEMP_DIR/dst-a"
printf '{"a":1}' > "$SRC"
atomic_replace "$SRC" "$DST"
assert_file_exists "A: dst created" "$DST"
assert_eq "A: dst has src content" '{"a":1}' "$(cat "$DST")"
assert_eq "A: no stray .tmp.*" "0" "$(_strays dst-a)"

# ── B: dst exists → atomically replaced ───────────────────────────────────────
SRC="$TEST_TEMP_DIR/src-b"; DST="$TEST_TEMP_DIR/dst-b"
printf '{"old":1}' > "$DST"; printf '{"new":1}' > "$SRC"
atomic_replace "$SRC" "$DST"
assert_eq "B: dst holds new content" '{"new":1}' "$(cat "$DST")"
assert_eq "B: no stray .tmp.* after success" "0" "$(_strays dst-b)"

# ── C: unreadable src → non-zero rc, no stray, dst unchanged ──────────────────
SRC="$TEST_TEMP_DIR/src-c"; DST="$TEST_TEMP_DIR/dst-c"
printf '{"keep":1}' > "$DST"; : > "$SRC"; chmod 000 "$SRC"
set +e; atomic_replace "$SRC" "$DST"; rc=$?; set -e
chmod 644 "$SRC"
assert_eq "C: returns non-zero on cp failure" "1" "$rc"
assert_eq "C: no stray .tmp.* after failure" "0" "$(_strays dst-c)"
assert_eq "C: dst unchanged on failure" '{"keep":1}' "$(cat "$DST")"

# ── D: no strays after repeated replacements ──────────────────────────────────
SRC="$TEST_TEMP_DIR/src-d"; DST="$TEST_TEMP_DIR/dst-d"
for i in $(seq 1 20); do printf '{"i":%d}' "$i" > "$SRC"; atomic_replace "$SRC" "$DST"; done
assert_eq "D: zero .tmp.* strays after 20 replacements" "0" "$(_strays dst-d)"

# ── E [SPEC-1]: concurrent writers — reader never observes a torn dst ──────────
# 256KB payload so a bare cp has a real partial-write window on any platform
# (verified: bare cp tears here, mv never does — mv is atomic at any size).
BLOB="$(head -c 256000 /dev/zero | tr '\0' 'x')"
TEMPL="$TEST_TEMP_DIR/templ"; printf '{"data":"%s"}' "$BLOB" > "$TEMPL"
EXP_BYTES="$(wc -c < "$TEMPL" | tr -d ' ')"
DST="$TEST_TEMP_DIR/dst-e"; cp "$TEMPL" "$DST"
TORN="$TEST_TEMP_DIR/torn"; DONE="$TEST_TEMP_DIR/done"; rm -f "$TORN" "$DONE"
(
    while [[ ! -f "$DONE" ]]; do
        if [[ -f "$DST" ]]; then
            jq empty "$DST" >/dev/null 2>&1 || touch "$TORN"
            b="$(wc -c < "$DST" 2>/dev/null | tr -d ' ' || echo 0)"
            [[ "$b" -gt 0 && "$b" -lt "$EXP_BYTES" ]] && touch "$TORN"
        fi
        sleep 0.001
    done
) &
reader=$!
pids=()
for i in $(seq 1 10); do
    ( source "$REPO_ROOT/scripts/lib/helpers.sh"
      s="$TEST_TEMP_DIR/src-e-$i"; cp "$TEMPL" "$s"
      atomic_replace "$s" "$DST" ) &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
touch "$DONE"; wait "$reader" 2>/dev/null || true
if [[ -f "$TORN" ]]; then
    assert_fail "[SPEC-1] reader never observed a torn dst (10 concurrent writers)" "torn read detected"
else
    assert_pass "[SPEC-1] reader never observed a torn dst (10 concurrent writers)"
fi
set +e; jq empty "$DST" >/dev/null 2>&1; jr=$?; set -e
assert_eq "E: final dst is valid JSON" "0" "$jr"
assert_eq "[SPEC-2] no stray .tmp.* after concurrent replacements" "0" "$(_strays dst-e)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
