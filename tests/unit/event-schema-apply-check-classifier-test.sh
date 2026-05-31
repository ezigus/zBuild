#!/usr/bin/env bash
# Unit test (#529): every build.apply_check.failed / .unavailable event must
# carry the apply_check.classifier_branch field and git_apply_rc uniformly,
# so triage can map an event back to one of the table branches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #529: apply_check.classifier_branch in events"
setup_test_env "build-apply-check-classifier-events"

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
    set -e
    rm -f "$tmp"
}

# Helper: assert the most recent event with a matching type carries the
# given fields via grep on the JSONL stream.
assert_event_has_field() {
    local label="$1" type="$2" field="$3" expected="$4"
    local line
    line="$(grep -F "\"type\":\"$type\"" "$ZBUILD_EVENTS_JSONL" 2>/dev/null | tail -n 1)"
    if [[ -z "$line" ]]; then
        assert_fail "$label" "no event of type $type emitted"
        return
    fi
    local got
    got="$(printf '%s' "$line" | jq -r --arg f "$field" '.data[$f] // ""' 2>/dev/null || echo '')"
    if [[ "$got" == "$expected" ]]; then
        assert_pass "$label ($field=$got)"
    else
        assert_fail "$label" "expected $field=$expected, got $field=$got"
    fi
}

# ─── B9: corrupt patch → apply_check.classifier_branch=corrupt_format ───────
print_test_section "B9: corrupt patch event payload"
REPO9="$(mk_repo b9)"
DIFF9="$TEST_TEMP_DIR/b9.patch"
cat > "$DIFF9" <<'PATCH'
diff --git a/f.txt b/f.txt
index 0000000..1111111 100644
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,3 @@
-a
+A
 b
@@ THIS IS NOT A VALID HUNK HEADER @@
PATCH
: > "$ZBUILD_EVENTS_JSONL"
run_gate "$REPO9" "$DIFF9"
assert_event_has_field "B9: failed event has classifier_branch=corrupt_format" \
    "build.apply_check.failed" "apply_check.classifier_branch" "corrupt_format"
assert_event_has_field "B9: failed event has git_apply_rc=128" \
    "build.apply_check.failed" "git_apply_rc" "128"

# ─── B8: context fail → classifier_branch=context ───────────────────────────
print_test_section "B8: context event payload"
REPO8="$(mk_repo b8)"
DIFF8="$TEST_TEMP_DIR/b8.patch"
cat > "$DIFF8" <<'PATCH'
diff --git a/f.txt b/f.txt
index 0000000..1111111 100644
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,3 @@
-WRONG_OLD_CONTENT
+A
 b
 c
PATCH
: > "$ZBUILD_EVENTS_JSONL"
run_gate "$REPO8" "$DIFF8"
assert_event_has_field "B8: failed event has classifier_branch=context" \
    "build.apply_check.failed" "apply_check.classifier_branch" "context"
assert_event_has_field "B8: failed event has git_apply_rc=1" \
    "build.apply_check.failed" "git_apply_rc" "1"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
