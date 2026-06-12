#!/usr/bin/env bash
# Tests: core/redaction/scope-redaction.sh — co-located unit tests (Wave 4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../../core/redaction/scope-redaction.sh
source "$REPO_ROOT/core/redaction/scope-redaction.sh"

print_test_header "core/redaction/scope-redaction.sh — co-located unit tests"
setup_test_env "scope-redaction-colocated"

export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

INPUT="$TEST_TEMP_DIR/prompt.txt"
OUTPUT="$TEST_TEMP_DIR/redacted.txt"
MANIFEST="$TEST_TEMP_DIR/scope.md"

# ── Refuses without scope manifest (fail-closed) ─────────────────────────────
printf 'hello world\n' > "$INPUT"
set +e; apply_scope_redaction "$INPUT" "$OUTPUT" "" >/dev/null 2>&1; rc=$?; set -e
assert_eq "refuses: empty manifest path → rc=1" "1" "$rc"

: > "$MANIFEST"
set +e; apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST" >/dev/null 2>&1; rc=$?; set -e
assert_eq "refuses: empty manifest → rc=1" "1" "$rc"

# ── Redacts out-of-scope paths ────────────────────────────────────────────────
cat > "$MANIFEST" <<'EOF'
+ src/included/
+ docs/
EOF

cat > "$INPUT" <<'EOF'
path: src/included/file.go
path: src/excluded/secret.go
path: docs/README.md
EOF

: > "$ZBUILD_EVENTS_JSONL"
apply_scope_redaction "$INPUT" "$OUTPUT" "$MANIFEST"
out="$(cat "$OUTPUT")"

if printf '%s\n' "$out" | grep -q "src/included/file.go"; then
    assert_pass "in-scope path is preserved"
else
    assert_fail "in-scope path is preserved" "missing: src/included/file.go"
fi

# Out-of-scope path is wrapped in <out-of-scope-context> tags (not deleted)
if printf '%s\n' "$out" | grep -q "out-of-scope-context"; then
    assert_pass "out-of-scope path is wrapped in out-of-scope-context tags"
else
    assert_fail "out-of-scope path is wrapped in out-of-scope-context tags" "no marker found in output"
fi

# ── apply_scope_redaction emits redaction.applied event ───────────────────────
assert_event_emitted "apply_scope_redaction emits redaction.applied" "$ZBUILD_EVENTS_JSONL" "redaction.applied"

# ─── #818: `+ ./` allowlist + path-detector tightening ──────────────────────
# Fresh fixtures for the #818 cases to avoid bleed from the prior allowlist.
INPUT2="$TEST_TEMP_DIR/p818.txt"
OUTPUT2="$TEST_TEMP_DIR/r818.txt"
MANIFEST2="$TEST_TEMP_DIR/scope818.md"

# T-818-1: `+ ./` allowlist (universal) — future file declared in plan
#          (no on-disk existence) MUST NOT be wrapped.
printf '+ ./\n' > "$MANIFEST2"
cat > "$INPUT2" <<'EOF'
Step 1 modifies plugins/agent/cq-preflight/manifest.yaml and tests/integration/full-pipeline-cycle-seq-3level-test.sh
EOF
apply_scope_redaction "$INPUT2" "$OUTPUT2" "$MANIFEST2" >/dev/null
if grep -q '<out-of-scope-context>' "$OUTPUT2"; then
    assert_fail "T-818-1: + ./ universal allow: in-scope path must NOT be wrapped" \
        "got: $(cat "$OUTPUT2")"
else
    assert_pass "T-818-1: + ./ universal allow — future-file plan path not wrapped"
fi

# T-818-2: `+ ./` allowlist — prose like 'cycle/plateau' MUST NOT be wrapped.
printf '+ ./\n' > "$MANIFEST2"
cat > "$INPUT2" <<'EOF'
The cycle handles cycle/plateau and plateau/convergence detection.
EOF
apply_scope_redaction "$INPUT2" "$OUTPUT2" "$MANIFEST2" >/dev/null
if grep -q '<out-of-scope-context>' "$OUTPUT2"; then
    assert_fail "T-818-2: prose fragments must NOT be wrapped" \
        "got: $(cat "$OUTPUT2")"
else
    assert_pass "T-818-2: prose 'cycle/plateau' not wrapped (path-detector tightened)"
fi

# T-818-3: regression — narrow allowlist still wraps OOS paths.
printf '+ plugins/\n' > "$MANIFEST2"
cat > "$INPUT2" <<'EOF'
Modified plugins/agent/foo/plugin.sh and core/router/route.sh
EOF
apply_scope_redaction "$INPUT2" "$OUTPUT2" "$MANIFEST2" >/dev/null
out_txt="$(cat "$OUTPUT2")"
if [[ "$out_txt" == *"<out-of-scope-context>core/router/route.sh"* ]]; then
    assert_pass "T-818-3: narrow allowlist still wraps OOS core/ path"
else
    assert_fail "T-818-3: narrow allowlist should wrap core/router/route.sh" \
        "got: $out_txt"
fi
if [[ "$out_txt" == *"<out-of-scope-context>plugins/"* ]]; then
    assert_fail "T-818-3: narrow allowlist incorrectly wrapped in-scope plugins/ path" \
        "got: $out_txt"
else
    assert_pass "T-818-3: narrow allowlist preserves in-scope plugins/ path"
fi

# T-818-4: file with extension under `+ ./` still in scope (regression for
#          path-detector — the extension qualifier must not reject a real path).
printf '+ ./\n' > "$MANIFEST2"
cat > "$INPUT2" <<'EOF'
Touch config/event-schema.json and docs/adr/ADR-018.md per the contract.
EOF
apply_scope_redaction "$INPUT2" "$OUTPUT2" "$MANIFEST2" >/dev/null
if grep -q '<out-of-scope-context>' "$OUTPUT2"; then
    assert_fail "T-818-4: + ./ + extension-qualified path must NOT be wrapped" \
        "got: $(cat "$OUTPUT2")"
else
    assert_pass "T-818-4: + ./ + json/md extension paths preserved"
fi

cleanup_test_env
print_test_results
