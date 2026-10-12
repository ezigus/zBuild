#!/usr/bin/env bash
# tests/unit/own-run-artifacts-first-test.sh — a stage's latest output is the
# live file, whichever try or run wrote it, and nothing else (#2252 A, amended).
#
# A rerun of an issue continues it: hydrate puts an earlier run's outputs back in
# their live places (ADR-050, amended; ADR-068 §8). So there is one place to
# read. The attempt record is the run's record for people, never an input
# (ADR-068 §6), and there is no second "restored" area to fall back to.
#
# O1 [guard]  the index never reads the attempt record
# O2 [guard]  live present → live
# O5 [guard]  the prior-output reader returns the live copy
# O6 [guard]  the prior-output reader never reads the attempt record
# O7 [change] the reader never reads a "restored" area: live missing → nothing
# O8 [change] a live file older than this run's start is still the latest output
#             — a rerun continues the issue, it does not start it over
# O11 [guard] nor for an output declared in a SUBFOLDER of the artifact dir
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"
# shellcheck source=../../scripts/lib/prior-output-reader.sh
source "$REPO_ROOT/scripts/lib/prior-output-reader.sh"

print_test_header "a stage's latest output is the live file, and nothing else"
setup_test_env "own-run-artifacts-first"
unset ZBUILD_CYCLE_ITER ZBUILD_CYCLE_FEEDBACK_DIR

S="$TEST_TEMP_DIR/state"; ART="$S/artifacts"; RESTORED="$S/restored-artifacts/artifacts"
P="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART" "$RESTORED" "$P/agent/design"
export ZBUILD_STATE_DIR="$S" ZBUILD_RESTORED_ARTIFACTS_DIR="$RESTORED"
cat > "$P/agent/design/manifest.yaml" <<'EOF'
id: design
kind: agent
outputs:
  - id: design
    path: ${artifact_dir}/design.md
    format: markdown
    required: true
    primary: true
  - id: nested
    path: ${artifact_dir}/sub/nested.json
    format: json
    required: false
EOF
_TPL_STAGES=(design)
# _archive <stage> <iter> <basename> <content> — what attempt-archive.sh leaves.
_archive() {
    local d="$ART/attempts/$1/iter-$2-attempt-1"
    mkdir -p "$d"; printf '%s\n' "$4" > "$d/$3"
}
_indexed() { jq -r --arg id "$1" '.inputs[$id] // empty' "$(_inputs_resolve_stage later "$P" "$S")" 2>/dev/null; }

print_test_section "O1-O2: the index"
printf 'OLD RUN design\n' > "$RESTORED/design.md"
_archive design 1 design.md "THIS RUN design round 1"
assert_eq "[O1] live missing → the index has no entry (not the attempt record, not a restored copy)" "" "$(_indexed design)"
printf 'THIS RUN live design\n' > "$ART/design.md"
assert_eq "[O2] live present → live" "$ART/design.md" "$(_indexed design)"

print_test_section "O5-O7: the prior-output reader"
printf 'LIVE build summary\n' > "$ART/build-summary.json"
assert_eq "[O5] the reader returns the live copy" "LIVE build summary" "$(_read_prior_output build-summary.json)"
rm -f "$ART/build-summary.json"
_archive build 1 build-summary.json "ARCHIVED build summary"
assert_eq "[O6] live missing → not the attempt record" "" "$(_read_prior_output build-summary.json)"
printf 'OLD RUN impact\n' > "$RESTORED/impact.json"
assert_eq "[O7] live missing → not a restored area either" "" "$(_read_prior_output impact.json)"

print_test_section "O8: an earlier run's live file is the latest output"
printf 'EARLIER RUN plan\n' > "$ART/plan.json"; touch -t 202609300000 "$ART/plan.json"
mkdir -p "$S/runtime"; : > "$S/runtime/run-start"
assert_eq "[O8] a live file older than this run's start is still read" "EARLIER RUN plan" \
    "$(ZBUILD_RUN_START_MARKER="$S/runtime/run-start" _read_prior_output plan.json)"

print_test_section "O11: an output in a subfolder"
_archive design 4 nested.json "THIS RUN nested"
assert_eq "[O11] a subfolder output → not the attempt record" "" "$(_indexed nested)"
mkdir -p "$ART/sub"; printf '{"n":1}\n' > "$ART/sub/nested.json"
assert_eq "[O11] …and its live file once written" "$ART/sub/nested.json" "$(_indexed nested)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
