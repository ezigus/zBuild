#!/usr/bin/env bash
# tests/integration/engine-isolation-test.sh
# Acceptance tests for ADR-023 engine isolation (#1629).
#
# The engine must be stable for the whole run: a pipeline executing from the
# working tree it is editing changes the machinery evaluating its own next stage.
# #1305 is the case study — its build stage moved the same accessors four times
# across 5 iterations and never converged.
#
# SPEC-1: `pipeline start` from INSIDE the target repo is refused (rc=2)
# SPEC-2: the refusal names both roots and the remedy (actionable, not cryptic)
# SPEC-3: --dev-engine permits it, and warns that mid-run edits will land
# SPEC-4: ZBUILD_DEV_ENGINE=1 is an equivalent escape hatch
# SPEC-5: an engine OUTSIDE the target repo is permitted (the installed shape)
# SPEC-6: other subcommands are unaffected — the guard is scoped to pipeline start
# SPEC-7: a symlinked path to the engine must not silently disable the guard (#1641)
# SPEC-8: --dev-engine still works in that spelling (the hole is closed, not the door)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "ADR-023 engine isolation (#1629)"
setup_test_env "engine-isolation"

# A throwaway git repo standing in for the target being worked on.
TARGET="$TEST_TEMP_DIR/target"
mkdir -p "$TARGET"
git -C "$TARGET" init -q 2>/dev/null
git -C "$TARGET" config user.email t@t; git -C "$TARGET" config user.name t
: > "$TARGET/file.txt"; git -C "$TARGET" add -A; git -C "$TARGET" commit -qm init 2>/dev/null

# _run_in <dir> [extra args...] — invoke the repo's CLI from <dir>, capture rc+output.
# --dry-run keeps this cheap: the guard fires before any stage dispatch.
_run_in() {
    local dir="$1"; shift
    _OUT="$(cd "$dir" && bash "$REPO_ROOT/scripts/zbuild" pipeline start --issue 999 --dry-run "$@" 2>&1)"
    _RC=$?
}

# ── SPEC-1/2: refused from inside the engine's own repo, with an actionable message ──
# The engine here is $REPO_ROOT/scripts/zbuild, so running from $REPO_ROOT makes
# engine root == target root — exactly the CI shape this issue fixes.
_run_in "$REPO_ROOT"
assert_eq "[SPEC-1] pipeline start from inside the target repo is refused (rc=2)" "2" "$_RC"
_msg_ok=0
grep -q "engine isolation" <<< "$_OUT" && \
grep -q "engine root:" <<< "$_OUT" && \
grep -q "target root:" <<< "$_OUT" && \
grep -q "install.sh" <<< "$_OUT" && \
grep -q -- "--dev-engine" <<< "$_OUT" && _msg_ok=1
if [[ "$_msg_ok" -eq 1 ]]; then
    assert_pass "[SPEC-2] refusal names both roots, the install remedy, and the override"
else
    assert_fail "[SPEC-2] refusal must be actionable" "output: $_OUT"
fi

# ── SPEC-3: --dev-engine permits it, and says what the risk is ──────────────
_run_in "$REPO_ROOT" --dev-engine
if [[ "$_RC" -ne 2 ]] && grep -q "dev-engine" <<< "$_OUT"; then
    assert_pass "[SPEC-3] --dev-engine permits the run and warns about mid-run edits"
else
    assert_fail "[SPEC-3] --dev-engine must permit the run with a warning" "rc=$_RC output: $_OUT"
fi

# ── SPEC-4: env-var escape hatch is equivalent ──────────────────────────────
_OUT="$(cd "$REPO_ROOT" && ZBUILD_DEV_ENGINE=1 bash "$REPO_ROOT/scripts/zbuild" pipeline start --issue 999 --dry-run 2>&1)"
_RC=$?
if [[ "$_RC" -ne 2 ]] && grep -q "dev-engine" <<< "$_OUT"; then
    assert_pass "[SPEC-4] ZBUILD_DEV_ENGINE=1 is an equivalent escape hatch"
else
    assert_fail "[SPEC-4] ZBUILD_DEV_ENGINE=1 must permit the run" "rc=$_RC output: $_OUT"
fi

# ── SPEC-5: an engine outside the target repo is permitted ──────────────────
# This is the installed shape: engine at $ZBUILD_HOME, target elsewhere. The
# guard must NOT fire, so the run proceeds past it (whatever it does next).
_run_in "$TARGET"
if [[ "$_RC" -ne 2 ]] || ! grep -q "engine isolation" <<< "$_OUT"; then
    assert_pass "[SPEC-5] engine outside the target repo is permitted (installed shape)"
else
    assert_fail "[SPEC-5] guard must not fire when the engine is outside the target" \
        "rc=$_RC output: $_OUT"
fi

# ── SPEC-6: the guard is scoped to `pipeline start` only ────────────────────
# `--version` must keep working from inside the repo, or every dev invocation
# and half the test suite would break.
_ver_out="$(cd "$REPO_ROOT" && bash "$REPO_ROOT/scripts/zbuild" --version 2>&1)"; _ver_rc=$?
if [[ "$_ver_rc" -eq 0 ]] && ! grep -q "engine isolation" <<< "$_ver_out"; then
    assert_pass "[SPEC-6] non-pipeline subcommands are unaffected by the guard"
else
    assert_fail "[SPEC-6] the guard must be scoped to pipeline start" \
        "rc=$_ver_rc output: $_ver_out"
fi

# ── SPEC-7: a symlinked path must not defeat the guard ─────────────────────
# The engine root came from `pwd` (LOGICAL — symlinks intact) and the target root
# from `git rev-parse --show-toplevel` (PHYSICAL). For the SAME directory reached
# through a symlink the two spellings differ, the string compare failed, and the
# guard silently did not fire (#1641).
#
# This is what made the file above fail inside the pipeline's own test staging
# copy: `plugins/tool/test/plugin.sh` stages into $TMPDIR, and on macOS that is
# under /var -> /private/var. So SPEC-1..4 passed from the repo and failed for
# every dogfood run. Symlinking the repo reproduces it without copying the tree.
LINK="$TEST_TEMP_DIR/engine-via-symlink"
ln -s "$REPO_ROOT" "$LINK"
_sl_out="$(cd "$LINK" && bash "$LINK/scripts/zbuild" pipeline start --issue 999 --dry-run 2>&1)"
_sl_rc=$?
if [[ "$_sl_rc" -eq 2 ]] && grep -q "engine isolation" <<< "$_sl_out"; then
    assert_pass "[SPEC-7] the guard still refuses when the engine is reached via a symlink"
else
    assert_fail "[SPEC-7] a symlinked path must not silently disable engine isolation" \
        "rc=$_sl_rc link=$LINK -> $(cd "$LINK" && pwd -P) output: ${_sl_out:0:400}"
fi

# ── SPEC-8: the escape hatch still works through a symlink ─────────────────
# Canonicalising must not make --dev-engine unreachable in the spelling where the
# guard newly fires — otherwise SPEC-7 would trade a silent hole for a hard block.
_sl_dev_out="$(cd "$LINK" && bash "$LINK/scripts/zbuild" pipeline start --issue 999 --dry-run --dev-engine 2>&1)"
_sl_dev_rc=$?
if [[ "$_sl_dev_rc" -ne 2 ]] && grep -q "dev-engine" <<< "$_sl_dev_out"; then
    assert_pass "[SPEC-8] --dev-engine still permits the run via a symlinked path"
else
    assert_fail "[SPEC-8] the override must work in the spelling where the guard fires" \
        "rc=$_sl_dev_rc output: ${_sl_dev_out:0:400}"
fi

cleanup_test_env
print_test_results
exit $((FAIL > 0))
