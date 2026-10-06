#!/usr/bin/env bash
# tests/unit/requirement-status-test.sh — every requirement has one status, read
# from its tag (#2304, ADR-069 §1).
#
# Why: design will tag each requirement `[code]`, `[no-code]` or `[done]`. The
# parser matched tags with `[a-z]+`, so `SPEC-2[no-code]:` did not look like a
# requirement at all and was silently dropped from every list.
#
# S1 a `[no-code]` requirement is listed and read like any other
# S2 the status of each tag, including the old ones ([change] → code,
#    [guard] → done), no tag, an unknown tag, and a missing id
# S3 `[done]` names its evidence after ` evidence: `; the requirement text
#    stops before it
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/acceptance-block.sh
source "$REPO_ROOT/scripts/lib/acceptance-block.sh"

print_test_header "requirement status — [code], [no-code], [done] (#2304, ADR-069 §1)"
setup_test_env "requirement-status"

DM="$TEST_TEMP_DIR/design.md"
cat > "$DM" <<'EOF'
# Design

```acceptance
SPEC-1[code]: the gate fails when the file is missing
SPEC-2[no-code]: the README explains the new flag
SPEC-3[done]: the loader already reads the file evidence: scripts/lib/x.sh:12 tests/unit/x-test.sh
SPEC-4[change]: an old-style change requirement
SPEC-5[guard]: an old-style guard requirement
SPEC-6: a requirement with no tag
SPEC-7[maybe]: a requirement with a tag nobody knows
TESTFILES:
SPEC-1: tests/unit/a-test.sh
SPEC-2: tests/unit/b-test.sh
WIRING: none
```
EOF

print_test_section "S1: a [no-code] requirement is listed"
assert_eq "[S1] every requirement id is listed, [no-code] included" \
    "SPEC-1 SPEC-2 SPEC-3 SPEC-4 SPEC-5 SPEC-6 SPEC-7" \
    "$(acceptance_list_spec_ids "$DM" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "[S1] the extracted block keeps the [no-code] line" \
    "$(extract_acceptance_block "$DM")" "SPEC-2[no-code]: the README explains the new flag"
assert_eq "[S1] the operator readout shows the [no-code] requirement's text" \
    "the README explains the new flag" "$(acceptance_spec_desc "$DM" SPEC-2)"

print_test_section "S2: the status of each tag"
assert_eq "[S2] [code] → code"           "code"            "$(acceptance_spec_status "$DM" SPEC-1)"
assert_eq "[S2] [no-code] → no-code"     "no-code"         "$(acceptance_spec_status "$DM" SPEC-2)"
assert_eq "[S2] [done] → done"           "done"            "$(acceptance_spec_status "$DM" SPEC-3)"
assert_eq "[S2] old [change] → code"     "code"            "$(acceptance_spec_status "$DM" SPEC-4)"
assert_eq "[S2] old [guard] → done"      "done"            "$(acceptance_spec_status "$DM" SPEC-5)"
assert_eq "[S2] no tag → empty"          ""                "$(acceptance_spec_status "$DM" SPEC-6)"
assert_eq "[S2] unknown tag → unknown:<tag>" "unknown:maybe" "$(acceptance_spec_status "$DM" SPEC-7)"
assert_eq "[S2] an id the block does not have → empty" "" "$(acceptance_spec_status "$DM" SPEC-99)"
assert_eq "[S2] SPEC-10 is not read from SPEC-1's line" "" \
    "$(acceptance_spec_status "$DM" SPEC-10)"

print_test_section "S3: evidence and requirement text"
assert_eq "[S3] [done] evidence is listed one item per line" \
    "scripts/lib/x.sh:12"$'\n'"tests/unit/x-test.sh" "$(acceptance_spec_evidence "$DM" SPEC-3)"
assert_eq "[S3] the requirement text stops before the evidence" \
    "the loader already reads the file" "$(acceptance_spec_text "$DM" SPEC-3)"
assert_eq "[S3] a requirement with no evidence has none" "" "$(acceptance_spec_evidence "$DM" SPEC-1)"
assert_eq "[S3] the text of a [no-code] requirement is read" \
    "the README explains the new flag" "$(acceptance_spec_text "$DM" SPEC-2)"
assert_eq "[S3] the text of a requirement with no evidence is unchanged" \
    "the gate fails when the file is missing" "$(acceptance_spec_text "$DM" SPEC-1)"

cleanup_test_env
print_test_results
