#!/usr/bin/env bash
# tests/unit/digest-parts-test.sh — the parts digest takes the fast path above
# the size the single digest does (#2615 R6, ADR-065 §5).
#
# zb_digest_v sums text past _ZB_DIGEST_SHELL_MAX bytes with one cksum: the
# shell's loop costs about 6 µs a byte. zb_parts_digest_v had no such limit, so a
# 100 KB requirements file cost about 2 s, in tests and in real runs.
#
#   DG1 [code]  parts past the limit are summed by cksum, over the very bytes a
#               file holding them has (each part, a NUL between): the same
#               digest as that file's
#   DG2 [guard] parts within the limit keep the shell's digest: one part's is
#               the single digest of its text
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "the parts digest past the shell's limit (#2615)"
setup_test_env "digest-parts"
export ZBUILD_DIGEST_SHELL_MAX=16
# shellcheck source=../../scripts/lib/digest.sh
source "$REPO_ROOT/scripts/lib/digest.sh"

print_test_section "DG1: past the limit"
parts=("first part, twenty bytes" "second part" "third")
F="$TEST_TEMP_DIR/parts.bin"; printf '%s\0%s\0%s' "${parts[@]}" > "$F"
want=""; read -r _c _n < <(cksum < "$F"); want="ck$_c-$_n"
got=""; zb_parts_digest_v got parts
assert_eq "[DG1] the parts are summed by cksum over their bytes, a NUL between" "$want" "$got"
fd=""; zb_file_digest_v fd "$F"
assert_eq "[DG1] ...the same digest as the file that holds them" "$fd" "$got"

print_test_section "DG2: within the limit"
small=("abc")
s=""; zb_parts_digest_v s small
d=""; zb_digest_v d "abc"
assert_eq "[DG2] one small part's digest is the single digest of its text" "$d" "$s"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
