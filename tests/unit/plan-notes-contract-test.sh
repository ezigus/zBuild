#!/usr/bin/env bash
# Tests: plan's `notes` declaration says what the prompt actually asks for.
#
# The schema line declared `notes` as "optional caveats; empty string if none".
# The PROMPT, in three separate places, instructs the model to do the opposite:
#
#   "A plan built from partial understanding, with the gaps noted in `notes`,
#    BEATS running out of turns and producing no plan at all."
#   "emit your best-effort plan NOW with assumptions in `notes`"
#   "A partial plan with gaps in `notes` BEATS a hard SIGTERM"
#
# So when run 32886190954 returned ~1200 characters of numbered prose there, that
# was the field doing its designed job — not drift. The declaration was what had
# gone stale, and reading the declaration alone makes `notes` look like a defect
# to be bounded.
#
# It must NOT be bounded. `notes` is the pressure valve that lets plan emit a
# usable partial plan instead of burning its whole budget and producing nothing;
# a short cap would push it toward the hard timeout the prompt exists to avoid.
#
# ADR-060 does not conflict. Its line is a multi-paragraph MARKDOWN DOCUMENT in
# an envelope field; long plain text in a declared data field is data, and the
# ADR says so explicitly. `lint-llm-envelope.sh` agrees — plan passes it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "plan.notes — the declaration matches the prompt"
setup_test_env "plan-notes-contract"

PLUGIN="$REPO_ROOT/plugins/agent/plan/plugin.sh"

# ── SPEC-1: the prompt still asks for gaps and assumptions in notes ─────────
# Asserted first, because it is the premise. If the prompt stops asking, the
# declaration below becomes wrong in the other direction and this file should
# fail rather than quietly bless a stale description.
_asks=0
grep -q 'gaps noted in .*notes' "$PLUGIN" && _asks=$(( _asks + 1 ))
grep -q 'assumptions in .*notes' "$PLUGIN" && _asks=$(( _asks + 1 ))
grep -q 'gaps in .*notes' "$PLUGIN" && _asks=$(( _asks + 1 ))
if [[ "$_asks" -ge 2 ]]; then
    assert_pass "SPEC-1: the prompt directs gaps/assumptions into notes ($_asks sites)"
else
    assert_fail "SPEC-1: the prompt directs gaps/assumptions into notes" \
        "only $_asks site(s) — if the prompt changed, the declaration below must change with it"
fi

# ── SPEC-2: the declaration does not contradict it ─────────────────────────
# "empty string if none" invited the reading that a non-empty notes is a defect.
_decl="$(grep -oE '"notes": "<[^"]*>"' "$PLUGIN" | head -1)"
if [[ -n "$_decl" && "$_decl" != *"empty string if none"* ]]; then
    assert_pass "SPEC-2: the declaration no longer says notes should be empty"
else
    assert_fail "SPEC-2: the declaration no longer says notes should be empty" \
        "got: ${_decl:-<no declaration found>} — this contradicts the prompt"
fi
if [[ "$_decl" == *gap* || "$_decl" == *assumption* ]]; then
    assert_pass "SPEC-2: the declaration names what the prompt asks for"
else
    assert_fail "SPEC-2: the declaration names what the prompt asks for" \
        "got: ${_decl:-<none>}"
fi

# ── SPEC-3: notes stays a flat string, and stays consumed ──────────────────
# The consumer at plugin.sh:172 flattens steps + notes into one searchable blob
# for the forbidden-phrase check. Restructuring notes into an array would need
# that consumer changed in the same commit; asserting it here so a future
# "bound it into caveats[]" cannot half-land.
if grep -qE '\(\.notes // ""\)' "$PLUGIN"; then
    assert_pass "SPEC-3: the forbidden-phrase blob still consumes notes as a string"
else
    assert_fail "SPEC-3: the forbidden-phrase blob still consumes notes as a string" \
        "the consumer changed shape — notes and its reader must move together"
fi

# ── SPEC-4: no length cap is imposed on notes ─────────────────────────────
# The thing this file exists to prevent. A cap trades a complete partial plan
# for a hard timeout that produces nothing, which the prompt calls the worse
# outcome in as many words.
if grep -qE 'notes.*:0:[0-9]+|notes.*head -c|_plan_truncate_notes' "$PLUGIN"; then
    assert_fail "SPEC-4: notes is not length-capped" \
        "a cap pushes plan toward the hard timeout the prompt exists to avoid"
else
    assert_pass "SPEC-4: notes is not length-capped"
fi

print_test_results
