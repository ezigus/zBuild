#!/usr/bin/env bash
# Tests: scripts/lib/lint-bare-timeout.sh (#1752)
#   SPEC-4: linter exits 1 on bare timeout; exits 0 on clean fixture; allow comment suppresses
#   SPEC-5: scripts/release.sh line ~629 carries a lint-bare-timeout:allow comment
#   SPEC-6: ADR-036 amendment names _acceptance_timeout_prefix, timeout-cmd.sh, Enforced-by
#   SPEC-7: package.json lint script contains lint-bare-timeout.sh; live repo passes linter
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "lint-bare-timeout.sh — bare timeout detection and exemption (#1752)"
setup_test_env "lint-bare-timeout"
_test_cleanup_hook() { cleanup_test_env; }

LINT="$REPO_ROOT/scripts/lib/lint-bare-timeout.sh"
T="$TEST_TEMP_DIR/tree"
mkdir -p "$T"

_run_lint() {
    local _dir="${1:-$T}"
    local _rc=0
    bash "$LINT" "$_dir" >/dev/null 2>&1 || _rc=$?
    printf '%s' "$_rc"
}

# ── [#1752/SPEC-4]: linter behavior on fixtures ───────────────────────────────
print_test_section "[#1752/SPEC-4] linter exits 1 on bare timeout; exits 0 on clean fixture"

# Fixture 1: bare timeout invocation — linter must reject it
printf '#!/usr/bin/env bash\ntimeout 30 some_command\n' > "$T/bad.sh"
_rc4a="$(_run_lint "$T")"
assert_eq "[#1752/SPEC-4] linter exits 1 on .sh file with bare timeout command" "1" "$_rc4a"

# Fixture 2: clean file, no bare timeout — linter must accept it
printf '#!/usr/bin/env bash\necho ok\n' > "$T/bad.sh"
_rc4b="$(_run_lint "$T")"
assert_eq "[#1752/SPEC-4] linter exits 0 on clean fixture with no bare timeout" "0" "$_rc4b"

# Fixture 3: bare timeout with allow comment — linter must suppress the finding
printf '#!/usr/bin/env bash\ntimeout 30 some_command # lint-bare-timeout:allow: exempted by test\n' \
    > "$T/bad.sh"
_rc4c="$(_run_lint "$T")"
assert_eq "[#1752/SPEC-4] linter exits 0 when allow comment suppresses the finding" "0" "$_rc4c"

rm -f "$T/bad.sh"

# ── [#1752/SPEC-5]: scripts/release.sh ~629 has lint-bare-timeout:allow comment ─
print_test_section "[#1752/SPEC-5] scripts/release.sh bare timeout line has lint-bare-timeout:allow"

_rel="$REPO_ROOT/scripts/release.sh"

if grep -q "lint-bare-timeout:allow" "$_rel" 2>/dev/null; then
    assert_pass "[#1752/SPEC-5] scripts/release.sh contains lint-bare-timeout:allow comment"
else
    assert_fail "[#1752/SPEC-5] scripts/release.sh contains lint-bare-timeout:allow comment" \
        "no lint-bare-timeout:allow comment found in release.sh"
fi

# The allow comment must be on the same line as the timeout invocation
if grep -qE "timeout[[:space:]][^#]*#[[:space:]]*lint-bare-timeout:allow" "$_rel" 2>/dev/null; then
    assert_pass "[#1752/SPEC-5] allow comment is on the timeout invocation line in release.sh"
else
    assert_fail "[#1752/SPEC-5] allow comment is on the timeout invocation line in release.sh" \
        "no line with both a timeout invocation and lint-bare-timeout:allow found"
fi

# ── [#1752/SPEC-6]: ADR-036 amendment names helper and Enforced-by ────────────
print_test_section "[#1752/SPEC-6] ADR-036 amendment paragraph and Enforced-by section"

_adr="$REPO_ROOT/docs/adr/ADR-036-acceptance-contract-teeth.md"
_adr_content=""
_adr_content="$(cat "$_adr" 2>/dev/null || true)"

if grep -qF "_acceptance_timeout_prefix" <<< "$_adr_content" 2>/dev/null; then
    assert_pass "[#1752/SPEC-6] ADR-036 amendment mentions _acceptance_timeout_prefix"
else
    assert_fail "[#1752/SPEC-6] ADR-036 amendment mentions _acceptance_timeout_prefix" \
        "amendment paragraph missing reference to _acceptance_timeout_prefix"
fi

if grep -qF "scripts/lib/timeout-cmd.sh" <<< "$_adr_content" 2>/dev/null; then
    assert_pass "[#1752/SPEC-6] ADR-036 amendment names scripts/lib/timeout-cmd.sh"
else
    assert_fail "[#1752/SPEC-6] ADR-036 amendment names scripts/lib/timeout-cmd.sh" \
        "amendment paragraph missing scripts/lib/timeout-cmd.sh"
fi

if grep -qF "scripts/lib/lint-bare-timeout.sh" <<< "$_adr_content" 2>/dev/null; then
    assert_pass "[#1752/SPEC-6] ADR-036 Enforced-by names scripts/lib/lint-bare-timeout.sh"
else
    assert_fail "[#1752/SPEC-6] ADR-036 Enforced-by names scripts/lib/lint-bare-timeout.sh" \
        "Enforced-by section missing scripts/lib/lint-bare-timeout.sh"
fi

if grep -qF "tests/unit/lint-bare-timeout-test.sh" <<< "$_adr_content" 2>/dev/null; then
    assert_pass "[#1752/SPEC-6] ADR-036 Enforced-by names tests/unit/lint-bare-timeout-test.sh"
else
    assert_fail "[#1752/SPEC-6] ADR-036 Enforced-by names tests/unit/lint-bare-timeout-test.sh" \
        "Enforced-by section missing tests/unit/lint-bare-timeout-test.sh"
fi

# ── [#1752/SPEC-7]: package.json lint script + live repo passes linter ────────
print_test_section "[#1752/SPEC-7] package.json lint script invokes lint-bare-timeout.sh"

_pkg="$REPO_ROOT/package.json"
_lint_script=""
_lint_script="$(jq -r '.scripts.lint // ""' "$_pkg" 2>/dev/null || true)"

if grep -qF "lint-bare-timeout.sh" <<< "$_lint_script" 2>/dev/null; then
    assert_pass "[#1752/SPEC-7] package.json lint script contains lint-bare-timeout.sh"
else
    assert_fail "[#1752/SPEC-7] package.json lint script contains lint-bare-timeout.sh" \
        "lint-bare-timeout.sh not found in npm run lint command"
fi

_live_rc=0
_live_out=""
_live_out="$(bash "$LINT" 2>&1)" || _live_rc=$?
assert_eq "[#1752/SPEC-7] running lint-bare-timeout.sh on the repo tree exits 0" \
    "0" "$_live_rc"
if [[ "$_live_rc" -ne 0 ]]; then
    printf '%s\n' "$_live_out" >&2
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
