#!/usr/bin/env bash
# Tests: purge is a PATH operation the engine owns (#2024, ADR-062 §3).
#
# `plugins/tool/test/manifest.yaml` declared the last `cleanup:` hook in the
# tree. Its two halves are now both covered by the engine:
#
#   release — kill the suite's process group. The engine does this from the
#             registered record (#2024); before that registration existed, this
#             hook was the ONLY thing in the tree that ever killed a stage's
#             children, which is why ADR-062 §4 forbade removing it first.
#   purge   — delete the staging tree. It is created via zbuild_engine_tmpdir,
#             which under dispatch resolves to ZBUILD_STAGE_SCRATCH — i.e.
#             `<run>/scratch/<stage>` (core/pipeline/stage-scratch.sh:86). So it
#             already sits inside an engine-owned area and needs no plugin to
#             find it.
#
# ADR-054 §7 is the line that must not move: purge deletes the SCRATCH tree and
# nothing else. A failed run keeps its complete evidence.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "purge deletes the scratch tree, and only that (#2024)"
setup_test_env "teardown-purge-scratch"

_mk_run() {
    local sd="$1"
    mkdir -p "$sd/scratch/test" "$sd/artifacts" "$sd/runtime"
    echo '{"stage_statuses":{"test":"complete"}}' > "$sd/pipeline-state.json"
    mkdir -p "$sd/scratch/test/zbuild-test-stage.ABC123/repo"
    echo staged > "$sd/scratch/test/zbuild-test-stage.ABC123/repo/file.txt"
    echo evidence > "$sd/artifacts/test.md"
    echo state > "$sd/pipeline-state.json.bak"
}

_run_teardown() {
    local sd="$1" scope="$2"
    ( export ZBUILD_TEARDOWN_SCOPE="$scope" ZBUILD_STATE_DIR="$sd"
      source "$REPO_ROOT/scripts/lib/proc-group.sh"
      emit_event() { :; }
      source "$REPO_ROOT/plugins/tool/teardown/plugin.sh"
      teardown_run "teardown" "$sd/pipeline-state.json"
    ) >/dev/null 2>&1 || true
}

# ── SPEC-1: purge removes the staging tree ─────────────────────────────────
SD1="$TEST_TEMP_DIR/run1"; _mk_run "$SD1"
_run_teardown "$SD1" purge
if [[ ! -d "$SD1/scratch/test/zbuild-test-stage.ABC123" ]]; then
    assert_pass "SPEC-1: purge removes the staging tree without a plugin hook"
else
    assert_fail "SPEC-1: purge removes the staging tree without a plugin hook" \
        "staging survived — the hook was doing this, and nothing replaced it"
fi

# ── SPEC-2: purge keeps the evidence (ADR-054 §7) ──────────────────────────
# The rule that makes purge safe to run at all. A purge that eats artifacts
# turns every failed run into an unexplainable one.
if [[ -f "$SD1/artifacts/test.md" && -f "$SD1/pipeline-state.json" ]]; then
    assert_pass "SPEC-2: artifacts and pipeline state survive purge"
else
    assert_fail "SPEC-2: artifacts and pipeline state survive purge" \
        "purge deleted evidence — ADR-054 §7 violated"
fi

# ── SPEC-3: RELEASE still deletes nothing ──────────────────────────────────
# The scope distinction is the whole contract. Release frees live resources;
# only purge removes paths.
SD2="$TEST_TEMP_DIR/run2"; _mk_run "$SD2"
_run_teardown "$SD2" release
if [[ -d "$SD2/scratch/test/zbuild-test-stage.ABC123" ]]; then
    assert_pass "SPEC-3: release deletes nothing, staging intact"
else
    assert_fail "SPEC-3: release deletes nothing, staging intact" \
        "release removed a path — that is purge's job, not release's"
fi

# ── SPEC-4: the last per-stage cleanup hook is gone ────────────────────────
# ADR-062 §3. Asserted on the manifest, because that is the contract surface —
# a hook function left in the plugin with no declaration is dead code, but a
# DECLARED hook is a stage owning its own cleanup, which is the thing retired.
if grep -qE '^[[:space:]]*cleanup:' "$REPO_ROOT/plugins/tool/test/manifest.yaml"; then
    assert_fail "SPEC-4: no plugin declares a cleanup hook any more" \
        "tool/test still declares one — reclamation is not yet engine-owned"
else
    assert_pass "SPEC-4: no plugin declares a cleanup hook any more"
fi
_hooks="$(grep -rlE '^[[:space:]]*cleanup:' "$REPO_ROOT"/plugins/*/*/manifest.yaml 2>/dev/null || true)"
if [[ -z "$_hooks" ]]; then
    assert_pass "SPEC-4: tree-wide, zero cleanup hooks remain"
else
    assert_fail "SPEC-4: tree-wide, zero cleanup hooks remain" "$_hooks"
fi

print_test_results
