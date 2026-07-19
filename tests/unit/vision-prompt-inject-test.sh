#!/usr/bin/env bash
# Tests: VIS-C (ADR-049) — vision preamble injection via _route_redact_prompt chokepoint.
# Verifies: Intent preamble in single-shot + loop prompts; fail-open for absent/invalid docs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "vision-prompt-inject: preamble injection via redaction chokepoint (VIS-C)"
setup_test_env "vision-prompt-inject"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/bin"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
printf 'bootstrap' > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID 2>/dev/null || true
unset ZBUILD_SCOPE_MANIFEST 2>/dev/null || true

# ── Vision doc fixture ────────────────────────────────────────────────────────
mkdir -p "$TEST_TEMP_DIR/vision_repo/docs"
cat > "$TEST_TEMP_DIR/vision_repo/docs/VISION.md" <<'VISION'
## Intent
Build reliable, well-tested automation pipelines for quality delivery.

## Principles
- Fail-closed on security boundaries.
- Audit everything.
VISION

# ── Prompt dump (non-ZBUILD_ path so it survives _zbuild_make_fresh_shell) ────
_PROMPT_DUMP="$TEST_TEMP_DIR/captured_prompt"

# ── No-op claude mock — records -p arg, outputs valid JSON w/ LOOP_COMPLETE ──
# Variable $_PROMPT_DUMP is expanded at heredoc creation time (survives scrub).
cat > "$TEST_TEMP_DIR/bin/claude" << MOCK
#!/usr/bin/env bash
dump="$_PROMPT_DUMP"
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == "-p" && -n "\${2:-}" ]] && printf '%s' "\$2" > "\$dump" && shift 2 && continue
  shift
done
jq -n '{result: "ok\nLOOP_COMPLETE", usage: {input_tokens: 5, output_tokens: 5}}'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# ── Load router (sources vision.sh by construction after VIS-C) ──────────────
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# Helper: reset events log for each test
reset_events() { : > "$ZBUILD_EVENTS_JSONL"; }

# ─── SPEC-1: route_to_model with valid vision doc → _ROUTE_REDACTED_PROMPT ────
#     contains preamble (CHANGE: fails at baseline — no injection without VIS-C)
reset_events
export ZBUILD_RUN_ID="vis-spec1-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/vision_repo"
set +e
route_to_model "T2" "stage task SPEC1" 2>/dev/null; _rc=$?
set -e
assert_eq "[SPEC-1] route_to_model with valid vision rc=0" "0" "$_rc"
assert_contains "[SPEC-1] _ROUTE_REDACTED_PROMPT contains Intent preamble" \
    "$_ROUTE_REDACTED_PROMPT" "# Intent (advisory)"
unset ZBUILD_RUN_ID

# ─── SPEC-2: route_to_model_loop with valid vision doc → iter prompt has preamble
#     (CHANGE: fails at baseline — no injection without VIS-C)
_LOOP_REPO="$TEST_TEMP_DIR/loop_repo"
mkdir -p "$_LOOP_REPO/docs"
( cd "$_LOOP_REPO" \
  && git init -q \
  && git config user.email t@t \
  && git config user.name t \
  && printf 'seed\n' > seed.txt \
  && git add seed.txt \
  && git commit -q -m seed ) >/dev/null
cat > "$_LOOP_REPO/docs/VISION.md" <<'LOOPVISION'
## Intent
Autonomous build pipeline for quality software delivery.

## Principles
- Test everything before ship.
LOOPVISION

_PROMPT_FILE="$TEST_TEMP_DIR/loop_prompt.txt"
printf 'LOOP_STAGE_TASK_SPEC2\n' > "$_PROMPT_FILE"

reset_events
export ZBUILD_RUN_ID="vis-spec2-run"
export ZBUILD_REPO_ROOT="$_LOOP_REPO"
: > "$_PROMPT_DUMP"
set +e
route_to_model_loop "T2" "$_PROMPT_FILE" "$_LOOP_REPO" 2 2>/dev/null; _rc=$?
set -e
assert_eq "[SPEC-2] route_to_model_loop with valid vision rc=0" "0" "$_rc"
_loop_captured="$(cat "$_PROMPT_DUMP" 2>/dev/null || true)"
assert_contains "[SPEC-2] loop iter prompt contains Intent preamble" \
    "$_loop_captured" "# Intent (advisory)"
# Idempotency: a loop iteration's prompt carries EXACTLY ONE preamble — the
# per-iteration prompt file is fresh, so the injection must not accumulate copies.
_loop_preamble_count="$(grep -c '# Intent (advisory)' <<< "$_loop_captured" || true)"
assert_eq "[SPEC-2] loop iter prompt has EXACTLY ONE preamble (no accumulation)" \
    "1" "$_loop_preamble_count"
unset ZBUILD_RUN_ID

# ─── SPEC-3: no vision doc → route_to_model proceeds without error (GUARD) ────
mkdir -p "$TEST_TEMP_DIR/no_vision_here"
reset_events
export ZBUILD_RUN_ID="vis-spec3-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/no_vision_here"
set +e
route_to_model "T2" "stage task SPEC3" 2>/dev/null; _rc=$?
set -e
assert_eq "[SPEC-3] no vision doc → route_to_model rc=0 (fail-open)" "0" "$_rc"
unset ZBUILD_RUN_ID

# ─── SPEC-4: preamble precedes original stage prompt text (ordering check) ────
#     (CHANGE: fails at baseline — no preamble → ordering assertion fails)
reset_events
export ZBUILD_RUN_ID="vis-spec4-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/vision_repo"
set +e
route_to_model "T2" "ORIGINAL_STAGE_TASK_SPEC4" 2>/dev/null
set -e
_intent_pos="$(printf '%s' "$_ROUTE_REDACTED_PROMPT" | grep -n "# Intent (advisory)" 2>/dev/null | head -1 | cut -d: -f1 || echo 0)"
_task_pos="$(printf '%s' "$_ROUTE_REDACTED_PROMPT" | grep -n "ORIGINAL_STAGE_TASK_SPEC4" 2>/dev/null | head -1 | cut -d: -f1 || echo 99999)"
[[ "$_intent_pos" =~ ^[0-9]+$ ]] || _intent_pos=0
[[ "$_task_pos"   =~ ^[0-9]+$ ]] || _task_pos=99999
assert_eq "[SPEC-4] preamble is present (intent line > 0)" "1" \
    "$( [[ "$_intent_pos" -gt 0 ]] && echo 1 || echo 0 )"
assert_eq "[SPEC-4] preamble line precedes original prompt line" "1" \
    "$( [[ "$_intent_pos" -lt "$_task_pos" ]] && echo 1 || echo 0 )"
unset ZBUILD_RUN_ID

# ─── SPEC-5: redaction.applied emitted after preamble injection (GUARD) ───────
reset_events
export ZBUILD_RUN_ID="vis-spec5-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/vision_repo"
set +e
route_to_model "T2" "some stage prompt SPEC5" 2>/dev/null
set -e
assert_event_emitted "[SPEC-5] redaction.applied emitted (preamble through chokepoint)" \
    "$ZBUILD_EVENTS_JSONL" "redaction.applied"
unset ZBUILD_RUN_ID

# ─── SPEC-6: preamble header format = "# Intent (advisory)" (CHANGE) ─────────
#     (fails at baseline — no preamble header without VIS-C)
reset_events
export ZBUILD_RUN_ID="vis-spec6-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/vision_repo"
set +e
route_to_model "T2" "stage work SPEC6" 2>/dev/null
set -e
_first_line="$(printf '%s' "$_ROUTE_REDACTED_PROMPT" | head -1)"
assert_eq "[SPEC-6] preamble first line is '# Intent (advisory)'" \
    "# Intent (advisory)" "$_first_line"
unset ZBUILD_RUN_ID

# ─── SPEC-7: doc without ## Intent passes new validator → preamble IS injected (CHANGE) ──
#     (the old "invalid" doc is now valid under word-cap-only validation)
mkdir -p "$TEST_TEMP_DIR/no_intent_repo/docs"
cat > "$TEST_TEMP_DIR/no_intent_repo/docs/VISION.md" <<'NOVISION'
## Background
Some background text here with no Intent heading.

## Principles
- Keep it simple.
NOVISION

reset_events
export ZBUILD_RUN_ID="vis-spec7-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/no_intent_repo"
set +e
route_to_model "T2" "SPEC7_ORIGINAL_TASK" 2>/dev/null; _rc=$?
set -e
assert_eq "[SPEC-7] doc without ## Intent → route_to_model rc=0" "0" "$_rc"
_has_preamble="$(printf '%s' "$_ROUTE_REDACTED_PROMPT" | grep -c "# Intent (advisory)" 2>/dev/null || true)"
assert_eq "[SPEC-7] doc without ## Intent passes new validator → preamble IS injected" "1" "$_has_preamble"
unset ZBUILD_RUN_ID

# ─── SPEC-7 (fail-open guard): over-word-count doc → fail-open, no preamble ──
mkdir -p "$TEST_TEMP_DIR/over_limit_repo/docs"
{
    printf '## Background\n\n'
    python3 -c "print(' '.join(['word'] * 310))" 2>/dev/null \
        || printf 'word word word word word word word word word word\n%.0s' {1..31}
    printf '\n'
} > "$TEST_TEMP_DIR/over_limit_repo/docs/VISION.md"
reset_events
export ZBUILD_RUN_ID="vis-spec7b-run"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/over_limit_repo"
set +e
route_to_model "T2" "SPEC7B_ORIGINAL_TASK" 2>/dev/null; _rc=$?
set -e
assert_eq "[SPEC-7] over-word-count vision doc → fail-open, rc=0" "0" "$_rc"
_has_preamble_b="$(printf '%s' "$_ROUTE_REDACTED_PROMPT" | grep -c "# Intent (advisory)" 2>/dev/null || true)"
assert_eq "[SPEC-7] over-word-count doc fails new validator → no preamble injected" "0" "$_has_preamble_b"
unset ZBUILD_RUN_ID

print_test_results
