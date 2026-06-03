#!/usr/bin/env bash
# Tests: core/router/route.sh — unit tests for precondition, model lookup, error paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "core/router/route — unit: precondition + model lookup + error paths"
setup_test_env "router-unit"

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events" "$TEST_TEMP_DIR/bin"

# Operator override token so --skip-precondition works in tests
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID 2>/dev/null || true

# Mock claude: records --model arg, echoes "ok".
# ADR-024 / #671 (Wave 13-B): the claude spawn is a fresh-user-shell —
# _zbuild_make_fresh_shell scrubs the ZBUILD_* namespace before exec, so
# the mock CANNOT read a ZBUILD_*-prefixed sidechannel env var. The
# sidechannel uses a non-ZBUILD_* path written into the mock at creation
# time via printf so it survives the scrub.
_LAST_MODEL_FILE="$TEST_TEMP_DIR/last_model"
printf '#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do\n    [[ "$1" == "--model" && -n "${2:-}" ]] && printf "%%s\\n" "$2" > "%s" && shift 2 && continue\n    shift\ndone\necho "ok"\nexit 0\n' "$_LAST_MODEL_FILE" > "$TEST_TEMP_DIR/bin/claude"
chmod +x "$TEST_TEMP_DIR/bin/claude"
export PATH="$TEST_TEMP_DIR/bin:$PATH"

# shellcheck source=../route.sh
source "$REPO_ROOT/core/router/route.sh"

# ── Invalid tier → rc=2 ─────────────────────────────────────────────────────
set +e
route_to_model "T9" "prompt" --skip-precondition 2>/dev/null; _rc=$?
set -e
assert_eq "invalid tier T9 → rc=2" "2" "$_rc"

# ── T0 not implemented → rc=2 ───────────────────────────────────────────────
set +e
route_to_model "T0" "prompt" --skip-precondition 2>/dev/null; _rc=$?
set -e
assert_eq "T0 not implemented → rc=2" "2" "$_rc"

# ── Missing tier arg → rc=2 ─────────────────────────────────────────────────
set +e
route_to_model 2>/dev/null; _rc=$?
set -e
assert_eq "no args → rc=2" "2" "$_rc"

# ── Precondition: no run_id (not bootstrap, no --skip-precondition) → rc=2 ──
: > "$ZBUILD_EVENTS_JSONL"
export ZBUILD_RUN_ID="some-run"
unset ZBUILD_SCOPE_OVERRIDE 2>/dev/null || true
set +e
route_to_model "T2" "prompt" 2>/dev/null; _rc=$?
set -e
assert_eq "precondition refused: no events log → rc=2" "2" "$_rc"
export ZBUILD_SCOPE_OVERRIDE=1
unset ZBUILD_RUN_ID 2>/dev/null || true

# Expected model IDs derived from config — never hardcoded (ADR-003)
_T1_EXPECTED="$(jq -r '.tiers.T1.candidates[0].id' "$ZBUILD_MODELS_FILE")"
_T2_EXPECTED="$(jq -r '.tiers.T2.candidates[0].id' "$ZBUILD_MODELS_FILE")"

# ── T1 → selects T1 candidate model ─────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T1" "ping" --skip-precondition 2>/dev/null; _rc=$?
set -e
assert_eq "T1 → rc=0" "0" "$_rc"
_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T1 selects T1 candidate model" "$_T1_EXPECTED" "$_model"

# ── T2 → selects T2 candidate model ─────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null; _rc=$?
set -e
assert_eq "T2 → rc=0" "0" "$_rc"
_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "T2 selects T2 candidate model" "$_T2_EXPECTED" "$_model"

# ── --model override ────────────────────────────────────────────────────────
: > "$TEST_TEMP_DIR/last_model"
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition --model "custom-model-id" 2>/dev/null; _rc=$?
set -e
assert_eq "--model override → rc=0" "0" "$_rc"
_model="$(cat "$TEST_TEMP_DIR/last_model" 2>/dev/null || true)"
assert_eq "--model override is respected" "custom-model-id" "$_model"

# ── Success emits model.route + model.outcome events ────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null; _rc=$?
set -e
assert_eq "T2 success → rc=0" "0" "$_rc"
assert_event_emitted "model.route event emitted" "$ZBUILD_EVENTS_JSONL" "model.route"
assert_event_emitted "model.outcome event emitted" "$ZBUILD_EVENTS_JSONL" "model.outcome"
assert_event_emitted "router.precondition.skipped event emitted" "$ZBUILD_EVENTS_JSONL" "router.precondition.skipped"

# ── No claude binary → rc=1 ─────────────────────────────────────────────────
OLDPATH="$PATH"
export PATH="/usr/bin:/bin"  # strip everything; no claude binary on minimal path
set +e
route_to_model "T2" "ping" --skip-precondition 2>/dev/null; _rc=$?
set -e
assert_eq "no claude binary → rc=1" "1" "$_rc"
export PATH="$OLDPATH"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
