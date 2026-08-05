#!/usr/bin/env bash
# Integration: guard that setup_test_env sandboxes ZBUILD_STATE_DIR so
# stage-io writes during acceptance-gate test replay cannot escape to the
# outer pipeline's state directory (#1713).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Establish a canary ZBUILD_STATE_DIR BEFORE sourcing test-helpers so that
# ORIG_STATE_DIR at source time captures this value — matching the real
# scenario where the pipeline exports ZBUILD_STATE_DIR before `npm test` runs.
CANARY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeticity-canary.XXXXXX")"
export ZBUILD_STATE_DIR="$CANARY_DIR"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

# CANARY_DIR is outside TEST_TEMP_DIR so the master trap does not remove it;
# hook into the standard cleanup point so it is removed on exit/signal.
_test_cleanup_hook() { rm -rf "$CANARY_DIR" 2>/dev/null || true; }

print_test_header "acceptance-gate harness hermeticity (#1713)"

# Snapshot the pre-setup value for SPEC-3's restore assertion.
_PRE_SETUP_STATE_DIR="${ZBUILD_STATE_DIR:-}"

# ── SPEC-1 (change): setup_test_env redirects ZBUILD_STATE_DIR into sandbox ──
setup_test_env "hermeticity"

if [[ "${ZBUILD_STATE_DIR:-}" == "$CANARY_DIR" ]]; then
    assert_fail "[SPEC-1] setup_test_env must redirect ZBUILD_STATE_DIR away from the canary" \
        "ZBUILD_STATE_DIR still == canary ($CANARY_DIR)"
elif [[ "${ZBUILD_STATE_DIR:-}" == "$TEST_TEMP_DIR"* ]]; then
    assert_pass "[SPEC-1] setup_test_env sandboxes ZBUILD_STATE_DIR inside TEST_TEMP_DIR"
else
    assert_fail "[SPEC-1] ZBUILD_STATE_DIR points to unexpected location" \
        "expected prefix $TEST_TEMP_DIR, got ${ZBUILD_STATE_DIR:-<unset>}"
fi

# ── Run minimal acceptance-gate replay with file stage-io enabled ─────────────
# The 'file' destination causes stage_io_end to write records under
# ${ZBUILD_STATE_DIR}/artifacts/stage-io/. At the merge-base baseline these
# land in the canary; after the fix they land in the sandbox (SPEC-2).
export _TPL_STAGE_IO_DESTS_acceptance_gate="file,stdout"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"

_GATE_REPO="$(setup_git_temp_repo "hermeticity-gate")"
_GIT="$(command -v git)"

(
    cd "$_GATE_REPO"
    "$_GIT" checkout -q -b feature
    mkdir -p tests
    printf '#!/usr/bin/env bash\nmy_fn() { return 0; }\n' > impl.sh
    cat > tests/feature-test.sh << 'TESTEOF'
#!/usr/bin/env bash
# [SPEC-1] feature is implemented
IMPL="$(cd "$(dirname "$0")/.." && pwd)/impl.sh"
[[ -f "$IMPL" ]] || exit 1
source "$IMPL"; my_fn
TESTEOF
    chmod +x tests/feature-test.sh impl.sh
    "$_GIT" add -A; "$_GIT" commit -q -m "feat"
) >/dev/null 2>&1

cat > "$_GATE_REPO/design.md" << 'DESIGNEOF'
```acceptance
SPEC-1: feature is implemented
TESTFILES:
tests/feature-test.sh
```
DESIGNEOF

_GATE_STATE="$_GATE_REPO/.zbuild-state"
mkdir -p "$_GATE_STATE/artifacts"
export ZBUILD_EVENTS_DIR="$_GATE_STATE/events"
mkdir -p "$ZBUILD_EVENTS_DIR"
export ZBUILD_EVENTS_JSONL="$ZBUILD_EVENTS_DIR/events.jsonl"
: > "$ZBUILD_EVENTS_JSONL"
unset _ZBUILD_ACCEPTANCE_GATE_LOADED

set +e
(
    cd "$_GATE_REPO"
    # shellcheck source=../../plugins/agent/spec-acceptance/plugin.sh
    source "$REPO_ROOT/plugins/agent/spec-acceptance/plugin.sh"
    acceptance_gate_run "acceptance-gate" "$_GATE_STATE/pipeline-state.json"
) >/dev/null 2>&1
set -e

# ── SPEC-2 (change): canary dir has zero stage-io/*.json files ────────────────
_CANARY_IO_COUNT=0
if [[ -d "$CANARY_DIR" ]]; then
    _CANARY_IO_COUNT="$(find "$CANARY_DIR" -name "*.json" -path "*/stage-io/*" 2>/dev/null | wc -l | tr -d ' ')"
fi
assert_eq "[SPEC-2] canary ZBUILD_STATE_DIR has zero stage-io records after gate replay" \
    "0" "$_CANARY_IO_COUNT"

# ── SPEC-3 (guard): cleanup_test_env restores ZBUILD_STATE_DIR ───────────────
# Invariant: cleanup_test_env always leaves ZBUILD_STATE_DIR equal to the
# value it had before setup_test_env was called. Passes at both baseline
# (nothing changed) and after the fix (changed then restored).
cleanup_test_env
assert_eq "[SPEC-3] cleanup_test_env restores ZBUILD_STATE_DIR to pre-setup value" \
    "$_PRE_SETUP_STATE_DIR" "${ZBUILD_STATE_DIR:-}"

print_test_results
