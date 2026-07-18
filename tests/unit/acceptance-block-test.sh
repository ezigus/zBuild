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
if grep -q "^scripts/lib/acceptance-block.sh$" <<< "$tc5_out"; then
    FAIL=$((FAIL + 1))
    printf "  \033[31m✗\033[0m TC-5: scope block content leaked into output\n"
else
    PASS=$((PASS + 1))
    printf "  \033[32m✓\033[0m TC-5: scope block content absent from output\n"
fi

# ── TC-6: acceptance_spec_is_guard recognizes [guard] classifier ──────────────
tc6_file="$WORK_DIR/tc6_design.md"
cat > "$tc6_file" <<'EOF'
```acceptance
SPEC-1[guard]: invariant that must not regress
SPEC-2[change]: new behavior introduced
TESTFILES:
tests/unit/foo-test.sh
tests/integration/bar-test.sh
```
EOF

set +e
acceptance_spec_is_guard "$tc6_file" "SPEC-1"; tc6_guard_rc=$?
acceptance_spec_is_guard "$tc6_file" "SPEC-2"; tc6_change_rc=$?
acceptance_spec_is_guard "$tc6_file" "SPEC-99"; tc6_miss_rc=$?
set -e
assert_eq "TC-6: [guard] SPEC recognized as guard (rc=0)" "0" "$tc6_guard_rc"
assert_eq "TC-6: [change] SPEC not recognized as guard (rc=1)" "1" "$tc6_change_rc"
assert_eq "TC-6: missing SPEC not recognized as guard (rc=1)" "1" "$tc6_miss_rc"

# ── TC-7: acceptance_list_spec_ids returns bare ids from classified lines ─────
tc7_file="$WORK_DIR/tc7_design.md"
cat > "$tc7_file" <<'EOF'
```acceptance
SPEC-1[change]: first new behavior
SPEC-2[guard]: second invariant
SPEC-3: unclassified legacy
TESTFILES:
tests/unit/foo-test.sh
```
EOF

set +e
tc7_out="$(acceptance_list_spec_ids "$tc7_file")"; tc7_rc=$?
set -e
assert_eq "TC-7: acceptance_list_spec_ids returns 0 with classified ids" "0" "$tc7_rc"
assert_eq "TC-7: first id is bare SPEC-1" "1" "$(echo "$tc7_out" | grep -c '^SPEC-1$')"
assert_eq "TC-7: second id is bare SPEC-2" "1" "$(echo "$tc7_out" | grep -c '^SPEC-2$')"
assert_eq "TC-7: third id is bare SPEC-3" "1" "$(echo "$tc7_out" | grep -c '^SPEC-3$')"

# ── TC-8: acceptance_list_wiring — WIRING: none returns "none" token ──────────
# [SPEC-1] acceptance_list_wiring prints "none" and returns 0 for WIRING: none
tc8_file="$WORK_DIR/tc8_design.md"
cat > "$tc8_file" <<'EOF'
```acceptance
SPEC-1[change]: something new
WIRING: none
TESTFILES:
tests/unit/foo-test.sh
```
EOF

set +e
tc8_out="$(acceptance_list_wiring "$tc8_file")"
tc8_rc=$?
set -e
assert_eq "[SPEC-1] TC-8: WIRING: none returns 0" "0" "$tc8_rc"
assert_eq "[SPEC-1] TC-8: WIRING: none prints 'none' token" "none" "$tc8_out"

# ── TC-9: acceptance_list_wiring — single path target ────────────────────────
# [SPEC-2] acceptance_list_wiring prints the declared single wiring path
tc9_file="$WORK_DIR/tc9_design.md"
cat > "$tc9_file" <<'EOF'
```acceptance
SPEC-1[change]: something new
WIRING:
plugins/agent/acceptance-gate/plugin.sh
TESTFILES:
tests/unit/foo-test.sh
```
EOF

set +e
tc9_out="$(acceptance_list_wiring "$tc9_file")"
tc9_rc=$?
set -e
assert_eq "[SPEC-2] TC-9: single WIRING path returns 0" "0" "$tc9_rc"
assert_eq "[SPEC-2] TC-9: single path printed" "plugins/agent/acceptance-gate/plugin.sh" "$tc9_out"

# ── TC-10: acceptance_list_wiring — multi-path WIRING section ────────────────
# [SPEC-3] acceptance_list_wiring prints all declared wiring paths
tc10_file="$WORK_DIR/tc10_design.md"
cat > "$tc10_file" <<'EOF'
```acceptance
SPEC-1[change]: something new
WIRING:
plugins/agent/acceptance-gate/plugin.sh
config/event-schema.json
TESTFILES:
tests/unit/foo-test.sh
```
EOF

set +e
tc10_out="$(acceptance_list_wiring "$tc10_file")"
tc10_rc=$?
set -e
assert_eq "[SPEC-3] TC-10: multi-path WIRING returns 0" "0" "$tc10_rc"
assert_eq "[SPEC-3] TC-10: first wiring path present" "1" "$(echo "$tc10_out" | grep -c 'plugins/agent/acceptance-gate/plugin.sh')"
assert_eq "[SPEC-3] TC-10: second wiring path present" "1" "$(echo "$tc10_out" | grep -c 'config/event-schema.json')"

# ── TC-11: acceptance_list_wiring — absent WIRING section returns non-zero ───
# [SPEC-4] acceptance_list_wiring returns 1 when no WIRING: section declared
tc11_file="$WORK_DIR/tc11_design.md"
cat > "$tc11_file" <<'EOF'
```acceptance
SPEC-1[change]: something new
TESTFILES:
tests/unit/foo-test.sh
```
EOF

set +e
tc11_out="$(acceptance_list_wiring "$tc11_file")"
tc11_rc=$?
set -e
assert_eq "[SPEC-4] TC-11: absent WIRING section returns non-zero" "1" "$tc11_rc"
assert_eq "[SPEC-4] TC-11: absent WIRING produces empty output" "" "$tc11_out"

# ── TC-12: WIRING: after TESTFILES: is not collected as a testfile ────────────
# Defensive: design.md may have TESTFILES: before WIRING: — parser must not
# include WIRING: or wiring paths in the testfile list.
tc12_file="$WORK_DIR/tc12_design.md"
cat > "$tc12_file" <<'EOF'
```acceptance
SPEC-1[change]: something new
TESTFILES:
tests/unit/foo-test.sh
tests/integration/bar-test.sh
WIRING:
plugins/agent/acceptance-gate/plugin.sh
```
EOF

set +e
tc12_tf="$(acceptance_list_testfiles "$tc12_file")"
tc12_wiring="$(acceptance_list_wiring "$tc12_file")"; tc12_wiring_rc=$?
set -e
assert_eq "TC-12: TESTFILES list excludes WIRING: sentinel" "0" \
    "$(echo "$tc12_tf" | grep -c '^WIRING:$' || true)"
assert_eq "TC-12: TESTFILES list excludes wiring path" "0" \
    "$(echo "$tc12_tf" | grep -c 'acceptance-gate/plugin.sh' || true)"
assert_eq "TC-12: TESTFILES list contains first testfile" "1" \
    "$(echo "$tc12_tf" | grep -c 'foo-test.sh')"
assert_eq "TC-12: TESTFILES list contains second testfile" "1" \
    "$(echo "$tc12_tf" | grep -c 'bar-test.sh')"
assert_eq "[SPEC-2] TC-12: acceptance_list_wiring still parses WIRING after TESTFILES" "0" \
    "$tc12_wiring_rc"
assert_eq "[SPEC-2] TC-12: wiring path returned when WIRING after TESTFILES" \
    "plugins/agent/acceptance-gate/plugin.sh" "$tc12_wiring"

# ── TC-13: acceptance_list_wiring — path-traversal guard drops unsafe targets ─
# A WIRING path that is absolute or contains '..' must never be surfaced as a
# revert target (it could ablate a file outside the repo tree). Mixed with a
# safe path, only the safe one is returned.
tc13_file="$WORK_DIR/tc13_design.md"
cat > "$tc13_file" <<'EOF'
```acceptance
SPEC-1[change]: something new
TESTFILES:
tests/unit/foo-test.sh
WIRING:
../../etc/passwd
/etc/hosts
config/templates/simple.yaml
EOF
printf '%s\n' '```' >> "$tc13_file"

set +e
tc13_out="$(acceptance_list_wiring "$tc13_file")"
set -e
assert_eq "TC-13: traversal '..' path dropped" "0" \
    "$(printf '%s\n' "$tc13_out" | grep -c 'passwd' || true)"
assert_eq "TC-13: absolute path dropped" "0" \
    "$(printf '%s\n' "$tc13_out" | grep -c '/etc/hosts' || true)"
assert_eq "TC-13: safe wiring path retained" "1" \
    "$(printf '%s\n' "$tc13_out" | grep -c '^config/templates/simple.yaml$' || true)"

# ── TC-14: [SPEC-1] acceptance_list_testfiles_for_spec — per-SPEC binding ────────
# When SPEC-1: prefix lines exist, only those paths are returned for SPEC-1.
tc14_file="$WORK_DIR/tc14_design.md"
cat > "$tc14_file" <<'EOF'
```acceptance
SPEC-1[change]: per-SPEC feature
SPEC-2[change]: other feature
WIRING: none
TESTFILES:
SPEC-1: tests/unit/foo-test.sh
SPEC-2: tests/integration/bar-test.sh
```
EOF

set +e
tc14_s1="$(acceptance_list_testfiles_for_spec "$tc14_file" "SPEC-1")"
tc14_s2="$(acceptance_list_testfiles_for_spec "$tc14_file" "SPEC-2")"
set -e
assert_eq "[SPEC-1] TC-14: per-SPEC returns SPEC-1 bound path only" \
    "tests/unit/foo-test.sh" "$tc14_s1"
assert_eq "[SPEC-1] TC-14: SPEC-2 does not appear in SPEC-1 result" \
    "0" "$(echo "$tc14_s1" | grep -c 'bar-test.sh' || true)"
assert_eq "[SPEC-1] TC-14: per-SPEC returns SPEC-2 bound path only" \
    "tests/integration/bar-test.sh" "$tc14_s2"

# ── TC-15: [SPEC-2] acceptance_list_testfiles_for_spec — global fallback ──────────
# When no per-SPEC prefix for the requested SPEC, return the global bare-path pool.
tc15_file="$WORK_DIR/tc15_design.md"
cat > "$tc15_file" <<'EOF'
```acceptance
SPEC-1[change]: feature
WIRING: none
TESTFILES:
tests/unit/global-test.sh
tests/integration/global2-test.sh
```
EOF

set +e
tc15_out="$(acceptance_list_testfiles_for_spec "$tc15_file" "SPEC-1")"
set -e
assert_eq "[SPEC-2] TC-15: fallback to global pool for SPEC-1" \
    "1" "$(echo "$tc15_out" | grep -c 'global-test.sh')"
assert_eq "[SPEC-2] TC-15: fallback includes second global path" \
    "1" "$(echo "$tc15_out" | grep -c 'global2-test.sh')"

# ── TC-16: [SPEC-3] acceptance_has_per_spec_binding — true/false detection ────────
tc16_bound_file="$WORK_DIR/tc16_bound.md"
cat > "$tc16_bound_file" <<'EOF'
```acceptance
SPEC-1[change]: feature
WIRING: none
TESTFILES:
SPEC-1: tests/unit/a-test.sh
```
EOF

tc16_global_file="$WORK_DIR/tc16_global.md"
cat > "$tc16_global_file" <<'EOF'
```acceptance
SPEC-1[change]: feature
WIRING: none
TESTFILES:
tests/unit/a-test.sh
```
EOF

set +e
acceptance_has_per_spec_binding "$tc16_bound_file"; tc16_bound_rc=$?
acceptance_has_per_spec_binding "$tc16_global_file"; tc16_global_rc=$?
set -e
assert_eq "[SPEC-3] TC-16: has_per_spec_binding returns 0 when SPEC-n: present" \
    "0" "$tc16_bound_rc"
assert_eq "[SPEC-3] TC-16: has_per_spec_binding returns 1 when only bare paths" \
    "1" "$tc16_global_rc"

# ── TC-17: [SPEC-4] acceptance_list_testfiles strips SPEC-n: prefix (union) ──────
# The union function must return bare paths even when per-SPEC prefixes are used.
tc17_file="$WORK_DIR/tc17_design.md"
cat > "$tc17_file" <<'EOF'
```acceptance
SPEC-1[change]: feature a
SPEC-2[change]: feature b
WIRING: none
TESTFILES:
SPEC-1: tests/unit/alpha-test.sh
SPEC-2: tests/integration/beta-test.sh
tests/unit/global-test.sh
```
EOF

set +e
tc17_out="$(acceptance_list_testfiles "$tc17_file")"
set -e
assert_eq "[SPEC-4] TC-17: union includes SPEC-1 bound path (stripped)" \
    "1" "$(echo "$tc17_out" | grep -c '^tests/unit/alpha-test.sh$')"
assert_eq "[SPEC-4] TC-17: union includes SPEC-2 bound path (stripped)" \
    "1" "$(echo "$tc17_out" | grep -c '^tests/integration/beta-test.sh$')"
assert_eq "[SPEC-4] TC-17: union includes global bare path" \
    "1" "$(echo "$tc17_out" | grep -c '^tests/unit/global-test.sh$')"
assert_eq "[SPEC-4] TC-17: no SPEC-n: prefix leaks into union output" \
    "0" "$(echo "$tc17_out" | grep -c '^SPEC-' || true)"

# ── TC-18: [SPEC-5] backward-compat — global bare-path form unaffected ────────────
# Designs with no per-SPEC prefix must continue to work identically with the union.
tc18_file="$WORK_DIR/tc18_design.md"
cat > "$tc18_file" <<'EOF'
```acceptance
SPEC-1[change]: existing feature
WIRING: none
TESTFILES:
tests/unit/classic-test.sh
tests/integration/classic2-test.sh
```
EOF

set +e
tc18_out="$(acceptance_list_testfiles "$tc18_file")"
tc18_spec="$(acceptance_list_testfiles_for_spec "$tc18_file" "SPEC-1")"
set -e
assert_eq "[SPEC-5] TC-18: global-only design: union lists first path" \
    "1" "$(echo "$tc18_out" | grep -c 'classic-test.sh')"
assert_eq "[SPEC-5] TC-18: global-only design: union lists second path" \
    "1" "$(echo "$tc18_out" | grep -c 'classic2-test.sh')"
assert_eq "[SPEC-5] TC-18: for_spec fallback equals global pool (first path)" \
    "1" "$(echo "$tc18_spec" | grep -c 'classic-test.sh')"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
