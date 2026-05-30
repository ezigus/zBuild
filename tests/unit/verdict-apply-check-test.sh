#!/usr/bin/env bash
# Unit test (#509): verdict_classify maps the new corrupt_diff verdict to fail.
# V1: build-summary verdict=corrupt_diff → verdict_classify → "fail"
# V2: build extract path returns corrupt_diff when summary carries it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "build #509: verdict_classify includes corrupt_diff"
setup_test_env "verdict-apply-check"

# shellcheck source=../../core/pipeline/verdict.sh
source "$REPO_ROOT/core/pipeline/verdict.sh"

# ─── V1: verdict_classify ─────────────────────────────────────────────────────
print_test_section "V1: verdict_classify corrupt_diff → fail"
cls="$(verdict_classify corrupt_diff)"
assert_eq "V1: corrupt_diff classifies as fail" "fail" "$cls"

# Sanity: existing mappings still work.
assert_eq "V1: pass → pass"             "pass" "$(verdict_classify pass)"
assert_eq "V1: scope_violation → fail"  "fail" "$(verdict_classify scope_violation)"

# ─── V2: build summary with verdict=corrupt_diff round-trips ─────────────────
print_test_section "V2: build-summary verdict=corrupt_diff round-trip"
summary="$TEST_TEMP_DIR/build-summary.json"
jq -n --argjson sv false --arg v corrupt_diff \
    '{schema_version:3, verdict:$v, scope_violation:$sv, apply_check:{ok:false, reason:"context"}}' \
    > "$summary"
raw="$(_verdict_extract_from_build_summary "$summary")"
assert_eq "V2: extractor returns corrupt_diff verbatim" "corrupt_diff" "$raw"
assert_eq "V2: classified as fail" "fail" "$(verdict_classify "$raw")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
