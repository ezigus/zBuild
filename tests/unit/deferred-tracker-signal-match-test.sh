#!/usr/bin/env bash
# Tests: scripts/deferred-tracker.sh::match_signal_phrases
#
# Behavioral coverage for ADR-020 §Signal phrases (locked v1). Each positive
# phrase must match its canonical form; past-tense usage must be filtered;
# "phase \d+" is explicitly excluded (removed after review found false positives).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/deferred-tracker.sh
source "$REPO_ROOT/scripts/deferred-tracker.sh"

print_test_header "deferred-tracker — match_signal_phrases (ADR-020 / #531)"

# ─── Positive matches ────────────────────────────────────────────────────────
out="$(match_signal_phrases "This needs a separate issue for the refactor.")"
assert_contains "P1: 'separate issue' matched" "$out" "separate issue"

out="$(match_signal_phrases "Let's file a follow-up for this work.")"
assert_contains "P2: hyphenated 'follow-up' matched" "$out" "follow-up"

out="$(match_signal_phrases "as a follow up later.")"
assert_contains "P3: spaced 'follow up' matched" "$out" "follow up"

out="$(match_signal_phrases "OUT OF SCOPE for v1")"
assert_contains "P4: case-insensitive match" "$out" "out of scope"

out="$(match_signal_phrases "deferred to phase 2")"
assert_contains "P5: 'deferred to' matched" "$out" "deferred to"

out="$(match_signal_phrases "// TODO(followup): refactor this")"
assert_contains "P6: 'TODO(followup)' matched" "$out" "TODO(followup)"

out="$(match_signal_phrases "nice-to-have for next milestone")"
assert_contains "P7: 'nice-to-have' matched" "$out" "nice-to-have"

out="$(match_signal_phrases "left as exercise for the reader")"
assert_contains "P8: 'left as exercise' matched" "$out" "left as exercise"

out="$(match_signal_phrases "let's punt on this for now")"
assert_contains "P9: 'punt' matched" "$out" "punt"

# ─── Negative: past-tense filtered (REGRESSION LOCK for ADR-020) ─────────────
out="$(match_signal_phrases "the bug was deferred to next sprint, already fixed")"
assert_eq "N1: past-tense 'was deferred' filtered" "" "$out"

# ─── Negative: 'phase \d+' explicitly excluded (REGRESSION LOCK) ─────────────
out="$(match_signal_phrases "phase 1 of the rollout went well")"
assert_eq "N2: 'phase 1' NOT a signal" "" "$out"

out="$(match_signal_phrases "phase 2 finished on time")"
assert_eq "N3: 'phase 2' NOT a signal" "" "$out"

# ─── Negative: clean text produces no matches ────────────────────────────────
out="$(match_signal_phrases "Just a normal PR with no deferred work.")"
assert_eq "N4: clean text produces nothing" "" "$out"

# ─── Multiple matches in one body ────────────────────────────────────────────
out="$(match_signal_phrases "needs a separate issue and a follow-up")"
assert_contains "M1: multiple phrases — separate issue" "$out" "separate issue"
assert_contains "M2: multiple phrases — follow-up" "$out" "follow-up"

print_test_results
