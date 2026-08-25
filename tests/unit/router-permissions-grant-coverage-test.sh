#!/usr/bin/env bash
# Tests: #1961 — the --add-dir grant must COVER every path the engine hands a
# model as a literal write target.
#
# WHY THIS FILE EXISTS SEPARATELY FROM router-permissions-test.sh. That file
# asserts the grant is "exactly the repo root + stage scratch" — which is what
# the code did, and the code was wrong. A test that pins the implementation
# cannot fail when the implementation is the defect. #1919 shipped with every
# assertion green and every design stage dead.
#
# So this file asserts the REQUIREMENT instead, and derives it from the
# manifests rather than restating it: whatever paths the engine tells models to
# write, the grant covers them. A stage that declares a new literal write target
# tomorrow is covered by construction, or this test names it. That is the
# property #1919's suite did not have.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../scripts/lib/helpers.sh
source "$REPO_ROOT/scripts/lib/helpers.sh"
# shellcheck source=../../scripts/lib/test-helpers.sh
source "$REPO_ROOT/scripts/lib/test-helpers.sh"

print_test_header "router-permissions-grant-coverage — the grant covers the write targets (#1961)"
setup_test_env "router-permissions-grant-coverage"
_test_cleanup_hook() { cleanup_test_env; }

export ZBUILD_MODELS_FILE="$REPO_ROOT/config/models.json"
export ZBUILD_EVENTS_DIR="$TEST_TEMP_DIR/events"
export ZBUILD_EVENTS_JSONL="$TEST_TEMP_DIR/events/events.jsonl"
export ZBUILD_EVENTS_DB="$TEST_TEMP_DIR/events/events.db"
export ZBUILD_EVENT_SCHEMA="$REPO_ROOT/config/event-schema.json"
mkdir -p "$TEST_TEMP_DIR/events"

# shellcheck source=../../core/event-bus/event-bus.sh
source "$REPO_ROOT/core/event-bus/event-bus.sh"
# shellcheck source=../../core/router/permissions.sh
source "$REPO_ROOT/core/router/permissions.sh"

# A synthetic run laid out the way lifecycle.sh lays a real one out: artifacts/
# and scratch/ as SIBLINGS under the state dir. The sibling relationship is the
# whole bug — granting scratch does not reach artifacts.
STATE_DIR="$TEST_TEMP_DIR/run-state"
export ZBUILD_ARTIFACT_DIR="$STATE_DIR/artifacts"
export ZBUILD_STAGE_SCRATCH="$STATE_DIR/scratch/design"
export ZBUILD_REPO_ROOT="$TEST_TEMP_DIR/worktree"
mkdir -p "$ZBUILD_ARTIFACT_DIR" "$ZBUILD_STAGE_SCRATCH" "$ZBUILD_REPO_ROOT"

_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
_zbuild_build_permissions_settings

# The granted roots, as the spawn will actually carry them.
mapfile -t _granted < <(_zbuild_permission_args | grep -A1 -xF -- '--add-dir' | grep -vxF -- '--add-dir' | grep -vxF -- '--')

# _covered <abs_path> — rc=0 when some granted root contains it.
_covered() {
    local target="$1" root
    for root in "${_granted[@]}"; do
        [[ -n "$root" ]] || continue
        [[ "$target" == "$root" || "$target" == "$root"/* ]] && return 0
    done
    return 1
}

# ─── SPEC-1: the artifact dir is granted ─────────────────────────────────────
# The single directory every model-written stage output resolves under. Measured
# on CLI 2.1.241 (#1961): with repo+scratch alone the identical write is refused;
# adding this root the write lands.
if _covered "$ZBUILD_ARTIFACT_DIR/design.md"; then
    assert_pass "[SPEC-1] the grant covers the artifact dir (design.md write target)"
else
    assert_fail "[SPEC-1] the grant covers the artifact dir (design.md write target)" \
        "granted: ${_granted[*]}"
fi

# ─── SPEC-2: every declared checkpoint path is covered ───────────────────────
# Derived from the manifests, not listed here. stage-checkpoint.sh injects these
# paths into the prompt as literals (a model cannot read an exported path —
# env-scrub unsets the whole ZBUILD_* namespace), so an uncovered one is a stage
# told to write somewhere it may not.
# _checkpoint_paths_in <manifest> — every `path:` belonging to an outputs entry
# that declares `role: checkpoint`, one per line.
#
# ORDER-INDEPENDENT by construction: the entry is buffered and emitted when it
# ENDS, so `role:` before `path:` — legal YAML — resolves the same as the other
# order. A "remember the last path: seen" parser reads correctly on today's
# manifests and, on a reversed entry, prints the PREDECESSOR's path: the
# coverage check then passes while silently verifying the wrong file. This is
# the same defect PR #1881 fixed in _checkpoint_declared_path
# (scripts/lib/stage-checkpoint.sh); mirroring its shape rather than inventing a
# second parser with a different set of blind spots.
_checkpoint_paths_in() {
    awk '
        function flush_entry() {
            if (role == "checkpoint" && path != "") print path
            path=""; role=""
        }
        /^outputs:/ { in_out=1; next }
        in_out && /^[a-zA-Z_]/ { flush_entry(); in_out=0 }
        in_out && /^[[:space:]]*-[[:space:]]*id:/ { flush_entry(); next }
        in_out && /^[[:space:]]+path:[[:space:]]*/ {
            p=$0; sub(/^[[:space:]]+path:[[:space:]]*/, "", p)
            gsub(/^["'"'"']|["'"'"']$/, "", p)
            sub(/[[:space:]]*#.*$/, "", p); path=p; next
        }
        in_out && /^[[:space:]]+role:[[:space:]]*checkpoint([[:space:]]|$|#)/ { role="checkpoint"; next }
        END { flush_entry() }
    ' "$1" 2>/dev/null
}

_checkpoint_count=0
_uncovered=""
while IFS= read -r _manifest; do
    _raw="$(_checkpoint_paths_in "$_manifest")"
    [[ -n "$_raw" ]] || continue
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        _p="${_p//\$\{artifact_dir\}/$ZBUILD_ARTIFACT_DIR}"
        _p="${_p//\$\{artifacts_dir\}/$ZBUILD_ARTIFACT_DIR}"
        _p="${_p//\$\{state_dir\}/$STATE_DIR}"
        _checkpoint_count=$((_checkpoint_count + 1))
        _covered "$_p" || _uncovered+="$_manifest -> $_p"$'\n'
    done <<< "$_raw"
done < <(find "$REPO_ROOT/plugins" -name manifest.yaml -print)

# Vacuity guard: an awk that silently matched nothing would make SPEC-2 pass by
# scanning zero paths — green, and proving nothing. #1961's whole lesson.
if [[ "$_checkpoint_count" -gt 0 ]]; then
    assert_pass "[SPEC-2] scan found $_checkpoint_count declared checkpoint path(s) — not vacuous"
else
    assert_fail "[SPEC-2] scan found declared checkpoint path(s)" \
        "zero found — the manifest scan matched nothing, so coverage below is vacuous"
fi

if [[ -z "$_uncovered" ]]; then
    assert_pass "[SPEC-2] every declared checkpoint path falls under a granted root"
else
    assert_fail "[SPEC-2] every declared checkpoint path falls under a granted root" \
        "uncovered:"$'\n'"$_uncovered""granted: ${_granted[*]}"
fi

# ─── SPEC-3: the run STATE dir is NOT granted ────────────────────────────────
# artifacts/ is the model's output surface; pipeline-state.json and events.jsonl
# are the engine's ledger. Granting the parent would be the easy fix and would
# hand a model the ability to rewrite its own verdict. The narrow grant is the
# point of #1919 — widening it to fix #1961 would trade one defect for a worse one.
if _covered "$STATE_DIR/pipeline-state.json"; then
    assert_fail "[SPEC-3] the run state dir is NOT granted" \
        "pipeline-state.json is writable by the model; granted: ${_granted[*]}"
else
    assert_pass "[SPEC-3] the run state dir is NOT granted (engine ledger stays out of reach)"
fi

if _covered "$STATE_DIR/events.jsonl"; then
    assert_fail "[SPEC-3] the event log is NOT granted" \
        "events.jsonl is writable by the model; granted: ${_granted[*]}"
else
    assert_pass "[SPEC-3] the event log is NOT granted"
fi

# ─── SPEC-4[guard]: the two original roots still hold ────────────────────────
# #1919's grants are load-bearing and this change must not trade one for another.
if _covered "$ZBUILD_REPO_ROOT/core/router/route.sh"; then
    assert_pass "[SPEC-4] the repo root is still granted"
else
    assert_fail "[SPEC-4] the repo root is still granted" "granted: ${_granted[*]}"
fi
if _covered "$ZBUILD_STAGE_SCRATCH/claude-settings.json"; then
    assert_pass "[SPEC-4] the stage scratch dir is still granted"
else
    assert_fail "[SPEC-4] the stage scratch dir is still granted" "granted: ${_granted[*]}"
fi

# ─── SPEC-5: the grant tracks ZBUILD_ARTIFACT_DIR, never a path literal ──────
# ADR-059: six call sites already fail silently when the layout moves. A grant
# that hardcoded `<state>/artifacts` would keep passing every assertion above
# while granting the wrong directory the moment #141's issue-keyed layout starts
# firing. Move the env var; the grant must follow it.
export ZBUILD_ARTIFACT_DIR="$TEST_TEMP_DIR/relocated/artifacts"
mkdir -p "$ZBUILD_ARTIFACT_DIR"
_ZBUILD_PERMISSIONS_SETTINGS_FILE=""
_zbuild_build_permissions_settings
mapfile -t _granted < <(_zbuild_permission_args | grep -A1 -xF -- '--add-dir' | grep -vxF -- '--add-dir' | grep -vxF -- '--')
if _covered "$ZBUILD_ARTIFACT_DIR/design.md"; then
    assert_pass "[SPEC-5] the grant follows ZBUILD_ARTIFACT_DIR when the layout moves"
else
    assert_fail "[SPEC-5] the grant follows ZBUILD_ARTIFACT_DIR when the layout moves" \
        "granted: ${_granted[*]}"
fi

# ─── SPEC-6: the checkpoint scan is field-order independent ─────────────────
# SPEC-2 is only as good as the parser feeding it. A parser that silently
# resolves the WRONG path keeps SPEC-2 green and the vacuity guard satisfied —
# the count still increments — so the failure is invisible from the outside.
# Driven against fixtures because no manifest in the tree reverses the order
# today, which is exactly what makes it a latent trap rather than a live bug.
_FIX="$TEST_TEMP_DIR/fixtures"
mkdir -p "$_FIX"

cat > "$_FIX/reversed.yaml" <<'YAML'
outputs:
  - id: some_checkpoint
    role: checkpoint
    path: ${artifact_dir}/reversed-checkpoint.md
YAML
_got="$(_checkpoint_paths_in "$_FIX/reversed.yaml")"
assert_eq "[SPEC-6] role: before path: still resolves the entry's own path" \
    '${artifact_dir}/reversed-checkpoint.md' "$_got"

cat > "$_FIX/predecessor.yaml" <<'YAML'
outputs:
  - id: not_a_checkpoint
    path: ${artifact_dir}/innocent-bystander.json
  - id: real_checkpoint
    role: checkpoint
    path: ${artifact_dir}/real-checkpoint.md
YAML
_got="$(_checkpoint_paths_in "$_FIX/predecessor.yaml")"
assert_eq "[SPEC-6] a preceding non-checkpoint entry's path is not attributed to it" \
    '${artifact_dir}/real-checkpoint.md' "$_got"

cat > "$_FIX/none.yaml" <<'YAML'
outputs:
  - id: plain
    path: ${artifact_dir}/plain.json
YAML
_got="$(_checkpoint_paths_in "$_FIX/none.yaml")"
assert_eq "[SPEC-6] a manifest with no checkpoint yields nothing" "" "$_got"

cleanup_test_env
print_test_results
exit $((FAIL > 0))
