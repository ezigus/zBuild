#!/usr/bin/env bash
# Tests: scripts/lib/acceptance-block.sh — extract_acceptance_block (ADR-031 / issue #864)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"

print_test_header "acceptance-block extractor — extract_acceptance_block (ADR-031)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── TC-1: absent block returns empty stdout and non-zero exit ─────────────────
tc1_file="$WORK_DIR/tc1_design.md"
cat > "$tc1_file" <<'EOF'
# Design

No acceptance block here.

```scope
scripts/lib/foo.sh
```
EOF

set +e
tc1_out="$(extract_acceptance_block "$tc1_file")"
tc1_rc=$?
set -e
assert_eq "TC-1: absent block returns non-zero" "1" "$tc1_rc"
assert_eq "TC-1: absent block produces empty stdout" "" "$tc1_out"

# ── TC-2: well-formed single-entry block emits spec + TESTFILES + path ────────
tc2_file="$WORK_DIR/tc2_design.md"
cat > "$tc2_file" <<'EOF'
# Design

Some prose.

```acceptance
SPEC: extract_acceptance_block returns 0 when block is present
TESTFILES:
tests/unit/acceptance-block-test.sh
```
EOF

set +e
tc2_out="$(extract_acceptance_block "$tc2_file")"
tc2_rc=$?
set -e
assert_eq "TC-2: well-formed block returns 0" "0" "$tc2_rc"
assert_contains "TC-2: output contains SPEC line" "$tc2_out" "SPEC: extract_acceptance_block returns 0 when block is present"
assert_contains "TC-2: output contains TESTFILES sentinel" "$tc2_out" "TESTFILES:"
assert_contains "TC-2: output contains test file path" "$tc2_out" "tests/unit/acceptance-block-test.sh"

# ── TC-3: multi-entry block emits all specs and all test files ────────────────
tc3_file="$WORK_DIR/tc3_design.md"
cat > "$tc3_file" <<'EOF'
# Design

```acceptance
SPEC: function emits SPEC lines in order
SPEC: function emits TESTFILES sentinel after specs
SPEC: function lists all test file paths
TESTFILES:
tests/unit/acceptance-block-test.sh
tests/integration/pipeline-test.sh
```
EOF

set +e
tc3_out="$(extract_acceptance_block "$tc3_file")"
tc3_rc=$?
set -e
assert_eq "TC-3: multi-entry block returns 0" "0" "$tc3_rc"
assert_contains "TC-3: first SPEC present" "$tc3_out" "SPEC: function emits SPEC lines in order"
assert_contains "TC-3: second SPEC present" "$tc3_out" "SPEC: function emits TESTFILES sentinel after specs"
assert_contains "TC-3: third SPEC present" "$tc3_out" "SPEC: function lists all test file paths"
assert_contains "TC-3: first test file present" "$tc3_out" "tests/unit/acceptance-block-test.sh"
assert_contains "TC-3: second test file present" "$tc3_out" "tests/integration/pipeline-test.sh"

# ── TC-4: malformed block (no closing fence) returns non-zero without crash ───
tc4_file="$WORK_DIR/tc4_design.md"
cat > "$tc4_file" <<'EOF'
# Design

```acceptance
SPEC: some spec
TESTFILES:
tests/unit/foo-test.sh
EOF
# Note: no closing ``` — EOF ends the file mid-block

set +e
tc4_out="$(extract_acceptance_block "$tc4_file")"
tc4_rc=$?
set -e
# No closing fence: block is treated as found but malformed; should not crash
assert_eq "TC-4: no closing fence does not crash (rc 0 or 1)" "$(( tc4_rc == 0 || tc4_rc == 1 ? 0 : 1 ))" "0"

# Variant: block with no TESTFILES section — should return non-zero
tc4b_file="$WORK_DIR/tc4b_design.md"
cat > "$tc4b_file" <<'EOF'
# Design

```acceptance
SPEC: some spec with no testfiles section
```
EOF

set +e
tc4b_out="$(extract_acceptance_block "$tc4b_file")"
tc4b_rc=$?
set -e
assert_eq "TC-4b: missing TESTFILES returns non-zero" "1" "$tc4b_rc"
assert_contains "TC-4b: SPEC line still emitted" "$tc4b_out" "SPEC: some spec with no testfiles section"

# ── TC-5: design.md with both ```scope and ```acceptance extracts only acceptance
tc5_file="$WORK_DIR/tc5_design.md"
cat > "$tc5_file" <<'EOF'
# Design

```scope
scripts/lib/acceptance-block.sh
tests/unit/acceptance-block-test.sh
```

Some prose between blocks.

```acceptance
SPEC: only acceptance block content is extracted
TESTFILES:
tests/unit/acceptance-block-test.sh
```
EOF

set +e
tc5_out="$(extract_acceptance_block "$tc5_file")"
tc5_rc=$?
set -e
assert_eq "TC-5: returns 0 with both blocks" "0" "$tc5_rc"
assert_contains "TC-5: acceptance SPEC present" "$tc5_out" "SPEC: only acceptance block content is extracted"
# scope block content must not appear in output
if echo "$tc5_out" | grep -q "^scripts/lib/acceptance-block.sh$"; then
    FAIL=$((FAIL + 1))
    printf "  \033[31m✗\033[0m TC-5: scope block content leaked into output\n"
else
    PASS=$((PASS + 1))
    printf "  \033[32m✓\033[0m TC-5: scope block content absent from output\n"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
