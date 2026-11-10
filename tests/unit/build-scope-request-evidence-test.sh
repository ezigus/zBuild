#!/usr/bin/env bash
# tests/unit/build-scope-request-evidence-test.sh — build reads the paths it
# reported as not reproducing from its own answer (#2252 B, #2322).
#
# #2508 (ADR-030 §8): build has no file list, so it makes no scope request and
# the request evidence rules (E1–E6) are gone with it. What stays is build's
# own report: the path it ran and found passing, read from its answer.
#
# E7 [change] the one answer vocabulary build is asked for,
#             `ANSWER … : wrong — not reproduced: <path>` (#2322), names the path
#             build ran, in markdown and in plain form, and a path that looks
#             like a glob is kept beside its look-alike
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../tests/lib/test-helpers.sh
source "$REPO_ROOT/tests/lib/test-helpers.sh"
print_test_header "build reads the paths it reported not reproducing (#2252 B)"
setup_test_env "build-scope-request-evidence"
# shellcheck source=../../plugins/agent/build/plugin.sh
source "$REPO_ROOT/plugins/agent/build/plugin.sh"

RESP7="$(printf 'Ran it.\n**ANSWER test finding 1:** wrong — not reproduced: tests/unit/order-test.sh\n')"
assert_eq "[E7] a not-reproduced answer names the path build ran" "tests/unit/order-test.sh" \
    "$(_build_not_reproduced "$RESP7")"
# review #2332: the plain (no markdown) form of the new answer reads the path too.
RESP7B="$(printf 'ANSWER test finding 1: wrong — not reproduced: tests/unit/order-test.sh\n')"
assert_eq "[E7] the plain answer form names the path build ran" "tests/unit/order-test.sh" \
    "$(_build_not_reproduced "$RESP7B")"
# review #2332: the duplicate check is literal — a path that looks like a glob
# pattern is not mistaken for another path.
assert_eq "[E7] a bracketed path is kept beside its look-alike" $'tests/a1.sh\ntests/a[1].sh' \
    "$(_build_not_reproduced "$(printf 'NOT_REPRODUCED: tests/a1.sh\nNOT_REPRODUCED: tests/a[1].sh\n')")"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
