#!/usr/bin/env bash
# Tests: scripts/lib/lint-llm-envelope.sh (#1993, ADR-060 §1)
#
# A lint that has only ever reported zero is indistinguishable from a lint that
# cannot report at all — the failure mode #1991 exists to catch. Every case
# below therefore drives the scanner against a seeded fixture root.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-llm-envelope (#1993, ADR-060)"
setup_test_env "lint-llm-envelope"

LINT="$REPO_ROOT/scripts/lib/lint-llm-envelope.sh"
FX="$TEST_TEMP_DIR/plugins"; mkdir -p "$FX/agent/probe"

_run_lint() { set +e; bash "$LINT" "$FX" >/dev/null 2>&1; local _r=$?; set -e; printf '%s' "$_r"; }

# ─── SPEC-1: the real tree passes ───────────────────────────────────────────
set +e; bash "$LINT" >/dev/null 2>&1; _s1=$?; set -e
assert_eq "[SPEC-1] the real plugins tree has no markdown-document field" "0" "$_s1"

# ─── SPEC-2: a field NAME ending in _md is caught ───────────────────────────
# This is impact_feedback_md, the field that killed run 32886190954.
cat > "$FX/agent/probe/plugin.sh" <<'FX'
_probe_schema='{"schema_version":1,"missing":[],"probe_feedback_md":"<report>"}'
FX
assert_eq "[SPEC-2] a *_md field name is refused" "1" "$(_run_lint)"

# ─── SPEC-3: a markdown PLACEHOLDER is caught even with an innocent name ────
# The next one will not be called _md; it will be called `report`.
cat > "$FX/agent/probe/plugin.sh" <<'FX'
_probe_schema='{"schema_version":1,"report":"<a markdown summary for the operator>"}'
FX
assert_eq "[SPEC-3] a markdown placeholder is refused despite an innocent name" "1" "$(_run_lint)"

# ─── SPEC-4: short plain-text fields are DATA and are not flagged ───────────
# ADR-060 §5 is the line. Flagging these would make the lint unusable and would
# push detail back into a free-text blob — the pressure that creates them.
cat > "$FX/agent/probe/plugin.sh" <<'FX'
_probe_schema='{"schema_version":1,"missing":[{"step_id":"<id>","files_to_add":["<path>"],"reason":"<why these files need to be in scope>","evidence":"<the symbol that links them>"}],"summary":"<one-line assessment>","description":"<what this step accomplishes>"}'
FX
assert_eq "[SPEC-4] short plain-text fields are not flagged" "0" "$(_run_lint)"

# ─── SPEC-5: test fixtures are out of scope ────────────────────────────────
# A test legitimately carries a retired envelope in order to assert it is
# ignored — impact-prompt-contract-test.sh has four. Flagging those would make
# the lint fight the tests that prove the retirement works.
mkdir -p "$FX/agent/probe/tests"
cat > "$FX/agent/probe/plugin.sh" <<'FX'
_probe_schema='{"schema_version":1,"missing":[]}'
FX
cat > "$FX/agent/probe/tests/probe-test.sh" <<'FX'
legacy='{"schema_version":1,"probe_feedback_md":"<report>"}'
FX
assert_eq "[SPEC-5] a */tests/* fixture is not flagged" "0" "$(_run_lint)"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
