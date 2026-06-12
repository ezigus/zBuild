#!/usr/bin/env bash
# Tests: ADR-021 v3 R2 — router rc=124 and rc=137 propagation.
#
# The sync path (_route_call_claude) historically collapsed every nonzero rc
# from the claude CLI to `return 1`, defeating downstream classify logic that
# maps rc=124 (gtimeout SIGTERM) → verdict=error and rc=137 (SIGKILL/OOM) →
# verdict=error. After this change, those two rcs MUST reach the caller of
# route_to_model verbatim. All other claude-emitted nonzero rcs still collapse
# to 1 — only the two infra-failure rcs are reserved.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router rc=124/137 propagation — ADR-021 v3 R2"
setup_test_env "router-rc124-propagation"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.zbuild"
echo -n "bootstrap" > "$HOME/.zbuild/scope-override-token"
export ZBUILD_SCOPE_OVERRIDE=1

_install_rc_mock() {
    local rc="$1"
    cat > "$TEST_TEMP_DIR/bin/claude" <<MOCK
#!/usr/bin/env bash
printf '' > /dev/stderr
exit $rc
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
}

# shellcheck source=../../core/pipeline/template.sh
source "$REPO_ROOT/core/pipeline/template.sh"
# shellcheck source=../../core/router/route.sh
source "$REPO_ROOT/core/router/route.sh"

# ─── T1: rc=124 propagates verbatim (gtimeout SIGTERM semantics) ─────────────
unset ZBUILD_ROUTER_MAX_TURNS ZBUILD_CURRENT_STAGE ZBUILD_ROUTER_JSON_OUTPUT
: > "$ZBUILD_EVENTS_JSONL"

_install_rc_mock 124
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T1: route_to_model returns rc=124 verbatim (NOT collapsed to 1)" \
    "124" "$rc"

# ─── T2: rc=137 propagates verbatim (SIGKILL/OOM semantics) ──────────────────
: > "$ZBUILD_EVENTS_JSONL"
_install_rc_mock 137
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T2: route_to_model returns rc=137 verbatim (NOT collapsed to 1)" \
    "137" "$rc"

# ─── T3: other nonzero rcs still collapse to 1 (claude-emitted error class) ──
: > "$ZBUILD_EVENTS_JSONL"
_install_rc_mock 2
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T3: claude rc=2 collapses to route_to_model rc=1 (claude-error class)" \
    "1" "$rc"

: > "$ZBUILD_EVENTS_JSONL"
_install_rc_mock 99
set +e
route_to_model "T2" "ping" --skip-precondition >/dev/null 2>&1
rc=$?
set -e
assert_eq "T3b: claude rc=99 collapses to route_to_model rc=1" "1" "$rc"

# ─── T4: rc=0 still succeeds (regression guard) ──────────────────────────────
: > "$ZBUILD_EVENTS_JSONL"
cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "OK-RESPONSE"
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/bin/claude"
set +e
out="$(route_to_model "T2" "ping" --skip-precondition 2>/dev/null)"
rc=$?
set -e
assert_eq "T4: rc=0 still propagates (regression guard)" "0" "$rc"
assert_contains "T4: response body still printed on success" "$out" "OK-RESPONSE"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
