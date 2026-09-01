#!/usr/bin/env bash
# tests/unit/summary-truncation-newest-test.sh — the summary block must keep the
# NEWEST summaries when it overflows, not the oldest (#2011).
#
# The defect: stage_summaries_prompt_block renders in COMPLETION order — oldest
# first — and `break`s the moment the running total exceeds the cap. So the
# summaries that survive are the ones furthest from the stage about to run, and
# the ones discarded are its most recent findings.
#
# Latent until #2000: ~9 producers before it, 28 after — 114,688B potential
# against a 24,576B cap, so overflow is now the normal path rather than an edge.
# Raising the cap is NOT the fix; ADR-029 records that per-iteration prompt
# growth caused three consecutive 900s max_turns timeouts. Which END is dropped
# is the defect.
#
#   SPEC-1 [change]: on overflow the MOST RECENTLY completed stage's summary is
#                    present in the block
#   SPEC-2 [guard] : retained summaries stay in COMPLETION order — the fix
#                    changes retention, not presentation
#   SPEC-3 [change]: an elision is marked explicitly, so it stays
#                    distinguishable from a stage that produced nothing
#   SPEC-4 [guard] : the per-summary cap and its own marker are untouched
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# A small total cap keeps the fixture legible; the per-summary cap stays real so
# SPEC-4 exercises the shipped value. Both are read at source time.
export ZBUILD_SUMMARY_TOTAL_MAX_BYTES=400

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"
# shellcheck source=../../scripts/lib/manifest-graph.sh
source "$REPO_ROOT/scripts/lib/manifest-graph.sh"
# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh" 2>/dev/null || true
# shellcheck source=../../core/plugin-registry/registry.sh
source "$REPO_ROOT/core/plugin-registry/registry.sh" 2>/dev/null || true
# shellcheck source=../../core/pipeline/input-resolve.sh
source "$REPO_ROOT/core/pipeline/input-resolve.sh"

print_test_header "stage summaries keep the NEWEST on overflow (#2011)"
setup_test_env "summary-truncation-newest"
_test_cleanup_hook() { cleanup_test_env; }

unset ZBUILD_STAGE_INPUTS ZBUILD_INPUTS_FLOW 2>/dev/null || true

STATE="$TEST_TEMP_DIR/state"
ART="$STATE/artifacts"
PROOT="$TEST_TEMP_DIR/plugins"
mkdir -p "$ART" "$PROOT/tool"

# ─── Fixture: four mechanical stages, each declaring a summary ───────────────
# Bodies are sized so the first two alone approach the 400B cap: whichever end
# the renderer drops, it cannot keep all four.
for _n in one two three four; do
    mkdir -p "$PROOT/tool/tr-$_n"
    cat > "$PROOT/tool/tr-$_n/manifest.yaml" <<EOF
id: tr-$_n
name: TR $_n
kind: tool
version: 0.0.1
convergence: gate
hooks:
  run: tr_${_n}_run
inputs: []
outputs:
  - id: tr_${_n}_result
    path: \${artifact_dir}/tr-$_n-result.json
    type: json
    required: true
    primary: true
  - id: tr_${_n}_detail
    path: \${artifact_dir}/tr-$_n-summary.md
    type: text
    format: text
    required: false
    summary: true
EOF
    printf 'tr_%s_run() { return 0; }\n' "$_n" > "$PROOT/tool/tr-$_n/plugin.sh"
    # ~150B of distinctive body per stage.
    { printf 'MARKER-%s\n' "$_n"; printf 'padding %s\n' $(seq 1 12); } \
        > "$ART/tr-$_n-summary.md"
done

# Completion order is the key order of .stage_statuses — one..four.
cat > "$STATE/pipeline-state.json" <<'EOF'
{
  "stage_statuses": {
    "tr-one": "complete", "tr-two": "complete",
    "tr-three": "complete", "tr-four": "complete"
  },
  "stage_verdicts": {
    "tr-one": "pass", "tr-two": "pass", "tr-three": "pass", "tr-four": "pass"
  }
}
EOF

BLOCK="$(stage_summaries_prompt_block "$STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"

# ── SPEC-1: the newest survives ─────────────────────────────────────────────
assert_contains "[SPEC-1][change] the most recently completed stage's summary is present" \
    "$BLOCK" "MARKER-four"

# ── SPEC-2: retained entries stay in completion order ───────────────────────
# Whichever pair survives, an earlier stage must render above a later one.
_pos_three="$(printf '%s' "$BLOCK" | grep -n 'MARKER-three' | cut -d: -f1 | head -1)"
_pos_four="$(printf '%s' "$BLOCK" | grep -n 'MARKER-four' | cut -d: -f1 | head -1)"
if [[ -n "$_pos_three" && -n "$_pos_four" ]]; then
    assert_eq "[SPEC-2][guard] retained summaries stay in completion order" \
        "1" "$([[ "$_pos_three" -lt "$_pos_four" ]] && echo 1 || echo 0)"
else
    assert_pass "[SPEC-2][guard] retained summaries stay in completion order (only one retained)"
fi

# ── SPEC-3: the elision is explicit ─────────────────────────────────────────
assert_contains "[SPEC-3][change] an elision is marked, not silent" \
    "$BLOCK" "truncated"

# ── SPEC-4: the PER-SUMMARY cap and marker are untouched ────────────────────
# A single oversized summary still truncates with its own marker, independent of
# the total-budget policy this issue changes.
# The 400B total cap above would starve this case before the per-summary cap
# could speak; restore the shipped budget so SPEC-4 exercises the real value.
_ZB_SUMMARY_TOTAL_MAX_BYTES=24576
SOLO_STATE="$TEST_TEMP_DIR/solo"; SOLO_ART="$SOLO_STATE/artifacts"
mkdir -p "$SOLO_ART"
head -c 9000 /dev/zero | tr '\0' 'x' > "$SOLO_ART/tr-one-summary.md"
cat > "$SOLO_STATE/pipeline-state.json" <<'EOF'
{"stage_statuses":{"tr-one":"complete"},"stage_verdicts":{"tr-one":"pass"}}
EOF
SOLO="$(stage_summaries_prompt_block "$SOLO_STATE/pipeline-state.json" "$PROOT" 2>/dev/null || true)"
assert_contains "[SPEC-4][guard] the per-summary cap still marks its own truncation" \
    "$SOLO" "read the artifact directly for the full text"

print_test_results
exit $((FAIL > 0))
