#!/usr/bin/env bash
# scripts/run-mutation.sh — mutation testing harness (issue #298)
#
# For each tests/mutation/*.md spec:
#   1. Lint required structural sections (## File / ## Mutation /
#      ## Expected failing test / ## Result / ## Patch / ## Test).
#   2. Extract the ```bash code block under ## Patch — apply it (mutates code).
#   3. Extract the ```bash code block under ## Test — run it; expect non-zero.
#   4. Restore ONLY the files the patch touched, via `git checkout --`.
#      EXIT trap restores them on crash too.
#
# A mutation that does NOT cause the targeted test to fail is a real bug:
# the test doesn't cover the mutation, or the production code path is dead.
# That's the whole point of mutation testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUTATION_DIR="$REPO_ROOT/tests/mutation"

passed=0
failed=0
results=()

# Tracked across all mutations so the EXIT trap can clean up half-applied state.
declare -a _PATCH_TOUCHED_FILES=()

# ─── Helpers ────────────────────────────────────────────────────────────────

# Extract the first ```bash ... ``` block under a given header from a .md file.
_extract_bash_block() {
    local file="$1" header="$2"
    awk -v hdr="$header" '
        $0 == hdr            { in_section = 1; next }
        in_section && /^## / { in_section = 0 }
        in_section && /^```bash[[:space:]]*$/ { in_code = 1; next }
        in_code && /^```[[:space:]]*$/ { in_code = 0; exit }
        in_code              { print }
    ' "$file"
}

# Restore ONLY the files patches touched (not the user's pre-existing
# uncommitted changes). Also clean any .mutbak sed artifacts.
_restore_patches() {
    local f
    for f in "${_PATCH_TOUCHED_FILES[@]:-}"; do
        [[ -n "$f" && -e "$REPO_ROOT/$f" ]] || continue
        git -C "$REPO_ROOT" checkout -- "$f" 2>/dev/null || true
    done
    _PATCH_TOUCHED_FILES=()
    find "$REPO_ROOT" -name '*.mutbak' -not -path '*/.git/*' \
        -not -path '*/legacy/*' -not -path '*/.claude/*' -delete 2>/dev/null || true
}

# Record which files the patch modified (relative to repo root), then capture
# them in the global _PATCH_TOUCHED_FILES so the trap can restore on crash.
_record_patch_touched() {
    local pre="$1"
    local post
    post="$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null || true)"
    # Anything in post that isn't in pre is a patch-introduced change.
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        grep -Fxq "$f" <<< "$pre" || _PATCH_TOUCHED_FILES+=("$f")
    done <<< "$post"
}

# EXIT trap: only restore patches; never touch the user's pre-existing diff.
trap '_restore_patches' EXIT INT TERM

# ─── Main loop ──────────────────────────────────────────────────────────────

# Snapshot the pre-existing modified file set so the patch-touched detector
# can subtract it.
PRE_EXISTING_DIFF="$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null || true)"

for doc in "$MUTATION_DIR"/*.md; do
    [[ -f "$doc" ]] || continue
    name="$(basename "$doc")"

    # 1. Lint structural sections.
    structural_ok=1
    for section in "## File" "## Mutation" "## Expected failing test" "## Result" "## Patch" "## Test"; do
        if ! grep -qF "$section" "$doc"; then
            echo "FAIL $name: missing section '$section'" >&2
            structural_ok=0
        fi
    done
    if [[ $structural_ok -eq 0 ]]; then
        failed=$((failed + 1))
        results+=("FAIL  $name  (structural)")
        continue
    fi

    # 2. Extract patch + test bash blocks.
    patch_code="$(_extract_bash_block "$doc" "## Patch")"
    test_code="$(_extract_bash_block "$doc" "## Test")"
    if [[ -z "$patch_code" || -z "$test_code" ]]; then
        echo "FAIL $name: ## Patch and/or ## Test bash block is empty" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (empty patch/test block)")
        continue
    fi

    # 3. Apply patch.
    if ! (cd "$REPO_ROOT" && bash -c "set -euo pipefail; $patch_code"); then
        echo "FAIL $name: patch script returned non-zero" >&2
        _record_patch_touched "$PRE_EXISTING_DIFF"
        _restore_patches
        failed=$((failed + 1))
        results+=("FAIL  $name  (patch failed)")
        continue
    fi

    # Detect what the patch touched (excluding pre-existing diff).
    _record_patch_touched "$PRE_EXISTING_DIFF"
    if [[ ${#_PATCH_TOUCHED_FILES[@]} -eq 0 ]]; then
        echo "FAIL $name: patch ran but touched no new files (sed/awk no-op?)" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (no-op patch)")
        continue
    fi

    # 4. Run targeted test; expect NON-ZERO.
    set +e
    (cd "$REPO_ROOT" && bash -c "$test_code") >/dev/null 2>&1
    test_rc=$?
    set -e

    # 5. Restore the files this patch touched.
    _restore_patches

    if [[ $test_rc -ne 0 ]]; then
        passed=$((passed + 1))
        results+=("PASS  $name  (caught: rc=$test_rc)")
    else
        echo "FAIL $name: mutation was NOT caught — test passed despite the mutation" >&2
        failed=$((failed + 1))
        results+=("FAIL  $name  (mutation slipped past test — coverage gap)")
    fi
done

echo
echo "─── Mutation test results ──────────────────────────────"
for line in "${results[@]}"; do
    echo "  $line"
done
echo "──────────────────────────────────────────────────────"
echo "mutation: $passed/$((passed + failed)) passed"

[[ $failed -eq 0 ]]
