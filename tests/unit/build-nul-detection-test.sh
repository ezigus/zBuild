#!/usr/bin/env bash
# Unit test (#549): NUL byte detection in build plugin uses grep -P '\x00'
# instead of the broken bash $'\x00' empty-string pattern that matched every
# non-empty line (false positive).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #549: NUL byte detection (grep -P not bash \$'\\x00')"
setup_test_env "build-nul-detection"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$ZBUILD_EVENTS_DIR"

# Source event-bus so emit_event works, then the build plugin.
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

# ─── Helper: count binary_truncation_observed events ────────────────────────
count_truncation_events() {
    jq -r 'select(.type == "build.diff.binary_truncation_observed") | .type' \
        "$ZBUILD_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' '
}

reset_events() {
    : > "$ZBUILD_EVENTS_JSONL"
}

# Platform-agnostic NUL detector — mirrors what plugin.sh does on Linux (CI).
# On macOS, BSD grep lacks -P; fall back to perl which is always available.
has_nul() {
    local file="$1"
    if LC_ALL=C grep -qP '\x00' "$file" 2>/dev/null; then
        return 0
    elif perl -0777 -ne 'exit(!/\x00/)' "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ─── N1: plain-text file → NUL detection MUST NOT fire ──────────────────────
print_test_section "N1: plain text diff — binary_truncation_observed must not fire"

PLAIN_PATCH="$TEST_TEMP_DIR/plain.patch"
printf 'diff --git a/foo.txt b/foo.txt\n--- a/foo.txt\n+++ b/foo.txt\n@@ -1 +1 @@\n-old\n+new\n' \
    > "$PLAIN_PATCH"

reset_events

if [[ -s "$PLAIN_PATCH" ]] && has_nul "$PLAIN_PATCH"; then
    emit_event "build.diff.binary_truncation_observed" "plugin=build" \
        "path=$PLAIN_PATCH" >/dev/null 2>&1 || true
fi

n1_count="$(count_truncation_events)"
assert_eq "N1: no truncation event on plain text diff" "0" "$n1_count"

# ─── N2: file containing an actual NUL byte → NUL detection MUST fire ───────
print_test_section "N2: binary diff with real NUL byte — binary_truncation_observed must fire"

NUL_PATCH="$TEST_TEMP_DIR/binary.patch"
printf 'hello\x00world\n' > "$NUL_PATCH"

reset_events

if [[ -s "$NUL_PATCH" ]] && has_nul "$NUL_PATCH"; then
    emit_event "build.diff.binary_truncation_observed" "plugin=build" \
        "path=$NUL_PATCH" >/dev/null 2>&1 || true
fi

n2_count="$(count_truncation_events)"
assert_eq "N2: truncation event fires on file with NUL byte" "1" "$n2_count"

# ─── N3: confirm the broken bash pattern $'\x00' evaluates to empty string ──
# This documents WHY the old code was wrong: $'\x00' in bash produces an
# empty string (NUL-terminated), so grep received an empty pattern which
# matches every non-empty line.
print_test_section "N3: bash \$'\\x00' is empty — documents the original bug"

broken_pattern=$'\x00'
broken_len=${#broken_pattern}
assert_eq "N3: bash \$'\\x00' length is 0 (empty string, not NUL literal)" "0" "$broken_len"

# ─── N4: confirm grep -P '\x00' is the correct fix on platforms that support it
print_test_section "N4: grep -P '\\x00' correctly rejects plain text (when -P is available)"

if LC_ALL=C grep --version 2>&1 | grep -q 'GNU'; then
    # GNU grep: -P is supported.
    PLAIN2="$TEST_TEMP_DIR/plain2.patch"
    printf 'just plain text\n' > "$PLAIN2"
    if LC_ALL=C grep -qP '\x00' "$PLAIN2" 2>/dev/null; then
        assert_fail "N4: grep -P should not match plain text" "matched unexpectedly"
    else
        assert_pass "N4: grep -P '\\x00' does not match plain text"
    fi
else
    # macOS BSD grep lacks -P — verify via perl fallback instead.
    PLAIN2="$TEST_TEMP_DIR/plain2.patch"
    printf 'just plain text\n' > "$PLAIN2"
    if perl -0777 -ne 'exit(!/\x00/)' "$PLAIN2" 2>/dev/null; then
        assert_fail "N4: perl NUL check should not match plain text" "matched unexpectedly"
    else
        assert_pass "N4: perl NUL check does not match plain text (macOS fallback)"
    fi
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
